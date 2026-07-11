# gfxstream Production Arena — 实作计画(接地版)

目标:gfxstream host-visible 记忆体祝福一次,消灭 per-BO share/unshare churn
(= EPERM/毒化/RM残留/长期开机崩溃的根源)。task #15。

## 已确认的现状(2026-07-11 侦察)

DroidVM 的 host-visible 路径 = **`VulkanAllocateHostVisibleAsUdmabuf`**
(`virtio-gpu-gfxstream-renderer.cpp:160` 起,条件 `IsAndroidKernel6_6() && HasUdmabufDevice()`
→ DroidVM 恒 TRUE)。流程在 `VkDecoderGlobalState.cpp` 的
`on_vkAllocateMemory` impl(6113;host-visible 段 6609):

```
emulateHostVisible (6611) = hostVisible && !importEmulatedExternalMemory
  → udmabuf 分支(6673):每次 alloc 建一个 per-alloc SharedMemory
    → createNoMapping → udmabuf descriptor → importFdInfo(dmabuf)
    → 成为 VkDeviceMemory → memoryInfo.blobId(6902)→ 导出 blob → share 给 guest
free: on_vkFreeMemory(6998)→ 销毁 SharedMemory + unshare blob  ← churn 在这
```

已有可复用件:
- **RingBlob 池**(`VirtioGpuResource.cpp:95` `GetGunyahRingBlobPool`):祝福一次/按
  rounded size 回收/永不 unshare/PMD 对齐 `MADV_COLLAPSE` folio 背书。**arena 的雏形**。
- **SubAllocator**(`host/address_space/`):现成的 offset 子分配器(v2 用)。
- guest 子分配的 CoherentMemory 机制在 **guest mesa gfxstream_vk 的 ResourceTracker**
  (不在此 host tree;v2 才需要,待在 guest 定位)。

## Config(user 定案 2026-07-11,全 env 可调不写死)

- `GFXSTREAM_ARENA_MB` = 预分配总量(祝福上限),预设 1024。
- `GFXSTREAM_ARENA_THRESHOLD_KB` = size 阈值(KB):
  - `>0`:BO `< threshold` → arena,`>= threshold` → 动态 per-blob(混合)
  - `0` = 全动态(arena 关闭 = 现行行为)
  - `-1` = 全预分配(所有 host-visible 进 arena;arena 满/放不下 → `VK_ERROR_OUT_OF_DEVICE_MEMORY`)

## 分层实作

### v1(本阶段):host 端 blessed recycle pool,**guest 透明**
把 RingBlob 池推广到 host-visible udmabuf memory:
- 池按 rounded-size bucket 持有 folio-backed `SharedMemory`(+udmabuf desc + VkDeviceMemory),
  祝福后**永不 unshare**,free 时归还 bucket 复用。
- 总量受 `GFXSTREAM_ARENA_MB` cap;超出走动态(hybrid)或回 OOM(strict/-1)。
- 每个 alloc 仍 = 一个 blob(整块),guest 照旧整块 map → **零 guest 改动**。
- 效果:blob 永不 unshare/re-share → churn=0 → EPERM/毒化结构性消失。
- 代价:整块粒度(小 alloc 占整个 bucket),不如子分配紧;但直接杀 churn。
- 插入点:`on_vkAllocateMemory` udmabuf 分支(6673)取池、`on_vkFreeMemory`(6998)归还。
- 新档:`host/vulkan/HostVisibleArena.{h,cpp}`;抽 RingBlob 的 collapse recipe 成共用 helper。

### v2(后续):offset 子分配,紧打包,需 guest ICD 配合
- 复用 guest gfxstream_vk ResourceTracker 的 CoherentMemory 子分配(map 大块一次,
  vkAllocateMemory 回 (block, offset),vkMapMemory = block_ptr+offset)。
- host 端 arena 提供 (blob_id, offset);协议传 offset;guest 按 offset map。
- 碎片化:块池 buddy;溢出走 v1 整块或动态。

## 风险
- 巨型 blob 物理碎片 → 池块一律 folio 背书(size/2MB entries,见 nctx 统一原则)。
- VkDeviceMemory 复用需同 device/同 memoryTypeIndex bucket。
- dedicated allocation / VkExportMemory / scanout → 强制走动态路。
