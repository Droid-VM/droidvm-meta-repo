# virgl venus 路線 survey(2026-08-11)

四方源碼實證:mesa vn(guest driver)、virglrenderer vkr(host renderer)、crosvm(本 fork)、
droidvm-guest-additions(guest kernel)。所有主張皆有 file:line 出處;推論會標明。

設計前提(使用者定調):**pre-alloc 池是正式路線,runtime-share 不穩、只做 demo/bring-up**
(gunyah memparcel 上限未解前無實用價值)。

---

## 0. 結論

**可行,而且比 gfxstream 當初省力:venus 上游已經把「guest-alloc + host import」寫成一等公民
(`use_guest_vram` 模式),guest 端流程、import 協定、roundtrip 時序全都現成**;我們要補的是
host 端 glue(crosvm 已有九成基建)和 build(venus 根本沒編進 libvirglrenderer,這是最大單一
blocker)。guest kernel **零必要改動**——池子路由與 sync accept 已實證 renderer-agnostic。

三句話版本:

1. venus 原生**預設是 host-alloc 設計**(ring/shmem/mappable VkDeviceMemory 全是 host 配好
   注入 guest)——這條在 pVM 撞我們已知的 EFAULT 牆,不能用。
2. 但 venus 有現成的 **guest-alloc 模式**(`GUEST_VRAM`/`use_guest_vram`):guest 先配 blob、
   `vkAllocateMemory` 變成 import——與我們 gfxstream 的 guest-blob export 架構**同構**,
   host 端接法就是 udmabuf import(vkr 留了唯一一扇門,見 §1.3)。
3. 唯一必須留在 host 側的是 ring/CS/reply shmem(memfd,crosvm 可控的普通頁);
   正式路線做 vkr 的 pool merge(仿 gfxstream HostVisiblePool),
   bring-up 階段可先走 runtime-share+accept(既有 generic 路,day one 能通)。

---

## 1. venus 原生記憶體分配路線(問題一的答案)

### 1.1 總表

| # | 路線 | blob_mem / flags | 誰配頁 | guest 怎麼拿到 | 出處 |
|---|---|---|---|---|---|
| 1 | ring / CS / reply shmem | `HOST3D` + `MAPPABLE`,**blob_id=0,無條件** | **host**(vkr `os_create_anonymous_file` memfd) | `VIRTGPU_MAP`+mmap(BAR) | vn_renderer_virtgpu.c:1396-1402, 1530-1553;vkr_context.c:335-344 |
| 2 | HOST_VISIBLE VkDeviceMemory(預設) | `HOST3D` + `MAPPABLE`,blob_id=mem 物件 id | **host**(真 VkDeviceMemory,vkr 強制注入 export info、export fd 給 VMM mmap) | lazy 到 `vkMapMemory` 才建 blob+map | vn_device_memory.c:440-470;vkr_device_memory.c:174-197;vkr_context.c:319-435 |
| 3 | device-local 不可 map | 無 blob | host only | 不進 guest | vn_device_memory.c:316 |
| 4 | exportable(WSI/AHB) | `HOST3D` + `SHAREABLE`(+`CROSS_DEVICE`) | host(同 2) | PRIME fd | vn_device_memory.c:201-227 |
| 5 | **guest_vram 模式**(HOST_VISIBLE 或 exportable 全走這) | `GUEST_VRAM`(變體 A)或 `HOST3D`(變體 B) | **guest**(專用 heap) | guest 先建 blob → `vkAllocateMemory` 掛 `VkImportMemoryResourceInfoMESA{res_id}` 變 import | vn_device_memory.c:152-199;vn_renderer_virtgpu.c:1502-1507 |

要點:

- **venus 的 map 永遠不是 host 指標交接**:vkr 的 `vkMapMemory` dispatch 全是 NULL
  (vkr_device_memory.c:342-345),一律「export fd → VMM mmap → 注入 guest」。
- `use_guest_vram` 的存在理由寫在 venus_hw.h:67-71:*"hypervisor does not support memory
  pages injections"* ——**這就是 pKVM/gunyah pVM 的約束**,上游已經為它設計過。
- guest_vram 模式連「guest 新配的頁 host 要先 attach 才能讀」的 roundtrip 都已內建
  (vn_cs.c:299-313、vn_ring.c:706-708)——share/accept handshake 有現成掛點。
- **ring/shmem 不受 guest_vram 影響**,`shmem_blob_mem` 無條件 = HOST3D blob_id=0
  (vn_renderer_virtgpu.c:1552)。這是 mesa 端唯一「躲不開 host-alloc」的路線。
- 硬性 gate:`PARAM_HOST_VISIBLE` 或 `PARAM_GUEST_VRAM` 至少要有一個,否則 ICD init 直接失敗
  (vn_renderer_virtgpu.c:1620-1635)。feedback buffer(fence/semaphore/query 回報頁)
  = 普通 host-visible VkDeviceMemory,跟著路線 2/5 走(vn_feedback.c:82-107)。

### 1.2 vkr(host 端)怎麼接

- `vkAllocateMemory` 三種 backing:純 host alloc(非 HOST_VISIBLE)/ HOST_VISIBLE 強制加
  export info(DMA_BUF 優先,否則 OPAQUE_FD)/ gbm bo fallback(vkr_device_memory.c:128-246)。
- **`BLOB_MEM_GUEST` 走 `resource_create_blob` 永遠只是 iovec**(virglrenderer.c:1126-1135),
  `fd_type=INVALID`,進不了 Vulkan——只能當 CPU shmem。vkr 全樹**沒有任何 udmabuf 呼叫**。
- ring 支援 scatter-gather iovec,但 head/tail/status 是 host 直接 deref 的裸指標
  (vkr_ring.c:86-88)——ring 頁必須真的 CPU 可讀寫,pVM 下等於必須是已 share 的頁。
  SHM attach 的 mmap **寫死 offset 0**(vkr_context.c:484-491),pool 切片要補 fd_offset。

### 1.3 唯一的「guest 頁 → VkDeviceMemory」大門(host 端)

vkr 不自己做 udmabuf,但留了完整的 import 鏈:

```
crosvm: guest pool 頁 → create_udmabuf(既有) → virgl_renderer_resource_import_blob(
            blob_mem=HOST3D|GUEST_VRAM, fd_type=DMABUF)          [virglrenderer.c:1387-1442]
guest:  vkAllocateMemory + VkImportMemoryResourceInfoMESA{res_id}  [mesa 端 guest_vram 流程自動發]
vkr:    virgl_resource_export_fd → VkImportMemoryFdInfoKHR{DMA_BUF} [vkr_device_memory.c:42-76]
```

QC driver 的 dma_buf import 能力**已在 gfxstream 移植中實證**(GUESTIMPORT pattern_match=1,
Adreno SMMU 對 imported udmabuf I/O-coherent)。同 driver 同機制,信心高。

**所以問題一的直接答案:venus 原生兩條都有——預設 host-alloc,guest-alloc(guest_vram)
是為「不能做 page injection 的 hypervisor」設計的一等公民模式;host 端 udmabuf import
是預期中的 VMM 實作方式,vkr 只認 fd。**

---

## 2. 對照 pVM 三條硬約束

| gfxstream 踩出來的約束 | venus 對應 | 判定 |
|---|---|---|
| host driver 頁 share 進 guest = EFAULT 牆 | 路線 2/4(QC VkDeviceMemory export fd → mmap → 注入)正面撞牆 | **禁用**;全部 HOST_VISIBLE/exportable 導到 guest_vram(路線 5) |
| guest 頁給 host GPU 必須池+udmabuf | 路線 5 = 同構;guest kernel 池路由 renderer-agnostic 已實證 | **現成** |
| host-alloc 注入必須 share+accept(且 pre-alloc 池優先) | 路線 1(ring/shmem,crosvm 可控 memfd)是唯一需要的 host→guest 注入 | pool merge(正式)/ runtime-share(demo) |

guest kernel 側逐項驗證過(droidvm-guest-additions @ wip/3d-accel):

- blob 路由只看 `blob_mem` 與 DT 節點,**零 capset/context-type 判斷**(virtgpu_ioctl.c:586-610);
  `BLOB_MEM_GUEST`+`MAPPABLE` 任何 userspace 發都自動進 gpu_guest 池(in-tree gpool_test 就是
  這個 call shape)。
- HOST3D mappable 的 sync accept 全在 host 驅動(`add_mapping_blob(VmAccept::Sync)`,
  virtio_gpu.rs:2008)+ gunyah_guest.ko,virtio-gpu driver 無 memparcel code(a23294d 之後);
  2MiB 對齊與 BAR 首 2MiB guard 是 RM 性質,對 venus blob 同樣自動生效。
- crosvm 的 map 路(pool 短路 → export_blob → map fallback → add_mapping_blob)全程
  component-dispatch,virtio_gpu.rs **沒有任何 gfxstream cfg gate**。

---

## 3. 建議架構(pre-alloc 優先)

| venus 分配 | 正式落地 | 用到的既有件 | 要新做的 |
|---|---|---|---|
| ring / CS / reply shmem | **gfx_host 池 pool merge**:vkr `get_blob(blob_id==0)` 改從 VMM 提供的 pool fd 子分配 | pool region + `MAP_INFO_POOL` 短路(generic)、`GFXSTREAM_POOL_FD` 環境變數樣式 | vkr 池子分配器 + `resource_pool_offset` 的 venus 版;SHM fd_offset |
| HOST_VISIBLE / exportable VkDeviceMemory | **gpu_guest 池(guest_vram 路線)** | guest kernel 池(零改)、crosvm `create_udmabuf`、vkr import 鏈 | mesa 一小包 + crosvm import_blob 分支(§4) |
| device-local | host alloc,不共享 | 原生 | 無 |
| scanout / WSI | guest 池 blob + PRIME;host 顯示走 `pool_scanout_iovecs` 直讀或 `export_display_blob`(udmabuf 窗,virgl 端已實作) | 兩者皆既有且 generic | 驗證而已 |

**bring-up 階梯**(把 demo 路當鷹架):
phase 0 = ring 先走 runtime-share+accept(零新碼,驗 venus 能不能點亮)→
phase 1 = guest_vram 接通(核心工作)→ phase 2 = ring pool merge(去 runtime-share)。

---

## 4. 工作清單

### Build(最大單一 blocker)
- `virglrenderer/Android.bp` 沒編 venus:srcs 無 `src/venus/*.c`(:88-137 只當 include dir),
  `prebuilt-intermediates/config.h:48-50` 的 `ENABLE_VENUS` 註解掉。要:加 vkr srcs、開
  ENABLE_VENUS、link Vulkan loader(host 端 QC ICD)。venus-protocol header 已 in-tree;
  meson codegen(vkr_device_object.py)產物需一次性 check-in 或 Soong genrule。
- render server 不需要(in-process 可跑,meson 只擋反向;virglrenderer.c:236-241),
  但 in-process 時 `supports_blob_id_0=false`(vkr_renderer.c:36 綁 RENDER_SERVER flag)——
  **改成無條件 true**(get_blob 本身不看這 flag,capset bit 只是告知 guest)。

### crosvm(基建九成現成)
- `context-types=venus` 已 wired(capset id 4、`VIRGL_RENDERER_VENUS` 自動設,
  rutabaga_core.rs:1414-1417)。**規則:絕不與 gfxstream 系 context-types 混列**
  (混列 = gfxstream 勝出 + virgl 系 capset 被 poison,rutabaga_core.rs:1391-1412);
  venus 與 `drm` 同 family **可同 run 並存**(未來 drm2kgsl+venus 一 VM 雙 ICD 的可能性)。
- guest blob → venus:`CREATE_GUEST_HANDLE` → `create_udmabuf`(virtio_gpu.rs:1766-1802 既有)
  → 現在 fork 是 `set_guest_blob_fd` vfunc park(virgl_renderer.rs:775-810),但 vkr 沒實作
  (回 ENOTSUP 靜默降級)。二選一:vkr 實作 `set_guest_blob_fd`(把 fd 綁進 resource 使
  `export_fd` 可用),或 crosvm 對 venus+MEM_DMABUF 改呼叫 `resource_import_blob`。
- venus 專屬 gaps:vram quota 在 `#[cfg(feature="gfxstream")]` 塊裡(gpu/mod.rs:1619-1702,
  venus 會**完全沒有 VRAM 配額**);`pool-blob-max-kb`/`gfx-host-pre-alloc-mb`/`gunyah-pvm` 等
  env 全在 `mode==ModeGfxstream` gate 裡(gpu.rs:111-147);pool 的 purpose/env/DT 節點要給
  venus 一份(或沿用 `gfx_host` 名字——guest kernel 只認 `gfx_host`/`drm2kgsl_host` 兩個前綴,
  virtgpu_kms.c:77-87)。
- `fixed_blob_mapping` 本 build 因帶 gfxstream feature 而 = false(parameters.rs:150),
  ExternalMapping fallback 可達——別做 venus-only build,會翻成 true 變 latent trap。

### vkr 小補丁包
- `supports_blob_id_0 = true`、capset `use_guest_vram = true`。
- SHM attach mmap 尊重 fd_offset(vkr_context.c:486;fork 在 virglrenderer.c:326-332 已為
  同類問題修過一次)。
- (phase 2)blob_id==0 的 pool merge 分配器。
- gbm `exit(-1)` 陷阱:QC driver 若 dma_buf/opaque export 都不支援,
  `vkr_physical_device_get_gbm_device` 直接 exit(-1)(vkr_physical_device.c:18-28 +
  vrend_winsys_gbm_stubs.c:28)。先實測 QC 能力,必要時把這條改成 graceful fail。

### mesa vn 小補丁包
- guest_vram 流程改發 `BLOB_MEM_GUEST` + `CREATE_GUEST_HANDLE` flag(而不是 GUEST_VRAM 0x4,
  免得動 guest kernel;kernel 對 GUEST 自動進池)。
- dma-buf re-import 的 `info.blob_mem != bo_blob_mem` 檢查放寬(vn_renderer_virtgpu.c:1219-1227,
  否則跨行程 WSI import 全滅——kwin 案的教訓)。
- (選)`VK_EXT_memory_budget` 讀池子 getparam 0x1000/0x1001/0x1002(照 mesa-gfxstream 207f1816)。

### guest kernel
- **必要改動:零**。
- 選修:guest-pool blob 的 prime dma-buf export 有 latent bug(`vram_node.start=0` →
  `dma_map_resource` 映到 PA 0,且 1-entry sg_table 表不了 scattered 池 blob;
  virtgpu_vram.c:205-214)——venus 的 `SHAREABLE|MAPPABLE` 組合是第一個會踩的候選。
  同裝置 PRIME(compositor 走同一個 virtio-gpu)不經這條,cross-device 才會;先標記後修。

---

## 3.5 池子佈局定案(2026-08-11)

**`venus_host` 池(新)**:運行時由 host 分配、兩邊都要看到的資源。把 VkDeviceMemory 全數導到
guest_vram 後,這一族**只剩 venus 傳輸層**——全部經 `virtgpu_shmem_create()`、wire 上一律
`HOST3D + blob_id=0 + MAPPABLE`,host 端在 vkr `get_blob` 的 blob_id==0 分支配置
(= pool merge 接管的唯一入口):

| 資源 | 大小 | 數量/生命週期 | 出處 |
|---|---|---|---|
| instance ring | 131268 B → **132 KiB** | 每 VkInstance 一條;**非 2 冪,venus shmem cache 永遠 miss**,create/destroy 都打到池 | vn_instance.c:146-157, vn_ring.c:249-295 |
| per-thread TLS ring | **20 KiB**(16 KiB+196 B) | 每個有 submit 的執行緒一條 | vn_common.c:322-335 |
| CS shmem pool chunk | **≥8 MiB,翻倍**(8→16→32) | 每 instance;chunk 耗盡換新、無 free list,靠 2 冪 cache 回收 → 持續 churn | vn_instance.c:328-329, vn_renderer_util.c:69-121 |
| reply shmem pool chunk | **≥1 MiB,翻倍** | 每 instance | vn_instance.c:331-332 |
| oversized 直接提交 CS(ring->upload) | ≥1 MiB | 臨時,cache 回收 | vn_ring.c:322-323 |

不在 venus_host 的確認:**feedback buffer 不在**(它是普通 HOST_COHERENT VkDeviceMemory,
vn_feedback.c 走 vn_AllocateMemory → guest_vram → gpu_guest 池)——venus_host 裡沒有 per-frame
熱輪詢頁,只有 ring 控制字(CPU-CPU cached 即可)。device-local 無 blob、QC driver 頁永不落池。

**`gpu_guest` 池(維持原案)**:virtio-gpu 驅動 drm_buddy 管理的 guest-alloc 資源 =
所有 guest_vram VkDeviceMemory(HOST_VISIBLE、exportable/WSI scanout、feedback buffer),
host 經 udmabuf import。

設計要點:
- **容量**:每 Vulkan 行程穩態 ≈ 10-20 MiB(132K ring + n×20K TLS + 8-16M CS + 1-2M reply);
  KDE 級桌面 ≈ 100-200 MiB + 翻倍 headroom。起手 **256 MiB**,實測調。
- **4K 粒度,無 2 MiB slot 問題**:池開機一次 SHARE,pool-resident blob 零 memparcel,
  gfxstream BAR 的每 blob 2 MiB 對齊約束不適用(同 gfx_host 池「按實際大小 4K 用」)。
- **池滿語意**:CS 翻倍撞池頂時 vkr 必須回 alloc 失敗讓 guest 退化,不可 abort。
- **配置器歸屬 host**(vkr pool merge 層,pool fd/GPA/size 經 env 傳入,仿 GFXSTREAM_POOL_FD);
  vkr 對池整段 mmap 一次,ring/CS 指標直接指進去——順帶繞開 SHM attach 寫死 offset 0 的問題。
- **工作清單增量**:crosvm 新 `MemoryRegionPurpose` + `--pre-alloc venus-host-mb=` + DT 節點
  `venus_host` + `resource_pool_offset` venus 版;guest kernel **一行**——
  `virtio_gpu_find_pool_base()` 的前綴清單加 `venus_host`(virtgpu_kms.c:77-87;
  §4「零必要改動」的唯一修正)。

---

## 5. 風險與未知(依序驗證)

1. **QC host driver 能力 probe(第一步,半天)**:Vulkan≥1.1、`VK_EXT_external_memory_dma_buf`
   import(已證)、**dma_buf/opaque export 能力**(決定 exit(-1) 陷阱與 host-alloc scanout
   export;vkr_physical_device.c:152-170 就是要複製的測試)、`KHR_external_fence_fd`(sync_fd)。
   host 端跑個 20 行 probe 或直接看 vulkaninfo。
2. venus 的 assert 都是 NDEBUG 會消失的 `assert()`(supports_blob_id_0 等,
   vn_renderer_virtgpu.c:1489/1497/1499)——capset 沒設對不會 fail-fast,會以怪異行為呈現。
3. feedback buffer 是熱頁(guest CPU 寫、host CPU 輪詢)——落 guest 池後 host 經 GuestMemory
   讀,CPU-CPU cached,同 gfx_host ASG 經驗,預期 OK。
4. vkr ring thread 的 busy-wait 行為要重驗(ring-consumer sleep-poll 燒手機的前科);
   vkr 有 idle→WAIT 機制,但參數要在多 client 桌面上驗,不是單 app。
5. 效能定位:多一層 wire decode + 同型 per-frame 同步,預期 **gfxstream 同級**
   (vkmark ~4400 級),MC 類 workload 不會到 drm2kgsl 的原生水準(213 vs ~100 的那道溝)。
   venus 的價值是上游正統路線 + 單 virglrenderer 家族(可與 drm2kgsl 同 run)。

---

## 6. 附:demo 路線(runtime-share)的樣子

零 vkr/mesa 改動下最短點亮路徑:build venus + `context-types=venus` + `supports_blob_id_0=true`
+ ring/mappable 全走 export fd → `add_mapping_blob(Sync)` → runtime-share+accept。
**每個 blob 一個 memparcel**,mappable VkDeviceMemory 還是會撞 EFAULT 牆(QC 頁),
所以 demo 也至少要接 guest_vram 才有畫面——結論:phase 0 只驗 ring 與 instance 建立,
真正出圖必須等 phase 1。runtime-share 不進正式設計。
