# SYNC transport + pool 正式化 + gfxstream pre-alloc(2026-07-21 三目標)

> 對應 /goal:1. 實作 sync 2. kgsl pre-alloc 改 swiotlb 同款(也走大頁)
> 3. gfxstream pre-alloc(kmod 實現 arena 內碎片,用戶空間重新映射回連續)。
> 與 [CMDLINE_V2.md](CMDLINE_V2.md) 對齊:pool 底座是軸 A(記憶體模型)的落實,
> sync 是 runtime dynamic-memory 的 `VmAccept::Sync` routing 補完。

---

## Goal 1 — VmAccept::Sync transport(已實作,待測)

### 架構
```
vm_control (vm_memory_handler_thread)
  RegisterMemory{vm_accept:Sync} → runtime_share() → handle
    → drive_guest_accept(tube, Accept, handle, gpa, size)   # 阻塞 ≤2s
        ‖ Tube ↓
  virtio-gunyah-accept device worker (crosvm)
        ‖ requestq(q0, host→guest 32B)/completionq(q1, guest→host 8B) ↓  ← 走 swiotlb
  guest: virtio_gunyah_accept.ko ── in-kernel API ──→ gunyah_guest.ko(raw-HVC RM client)
                                                       ↑ 同一核心也served virtio-gpu(Off 路線)
```

- **guest 兩層定案**:`gunyah_guest.ko` 是 accept 核心(已存在,export
  `gunyah_guest_mem_accept/release`);Off 路線(virtio-gpu front 自己 accept)與
  Sync 路線(新 virtio driver)是它的兩個 client。**handle 只活在 guest 端,gpa-keyed**
  (Sync 的 owner table 在 virtio_gunyah_accept.ko;RELEASE 請求只帶 gpa)。
- **wire protocol**(LE):req = {req_id u32, op u32(1=ACCEPT,2=RELEASE), handle u32,
  flags u32, gpa u64, size u64};comp = {req_id u32, ret i32}。virtio device id **60**
  (`virtio:d0000003C`)。
- **無雞生蛋**:vring/buffer 全走 boot 時已 bless 的 swiotlb(restricted-dma-pool)。
- **順序不變式**:release 在 host unshare 之前(同 virtgpu_vram.c 的教訓)。
- **阻塞面**:Sync 等待佔住共用的 vm_memory_handler_thread(全 device 的 memory
  request 串行)。accept 是 µs~ms 級 HVC;timeout 2s 只在 guest 模組缺席時發生。
- **gpu 切換**:`--gpu ...,vm-accept=sync`(預設 off = 現行為)。Sync 下 map_blob
  response 的 gunyah_handle=0 → guest virtio-gpu 跳過自己 accept(既有分支)。
- **Async**:enum 留著,目前註冊路徑回 ENOTSUP。

### 檔案清單(as-built)
- guest:`droidvm-guest-additions/virtio_gunyah_accept/`(新 kmod)+ dkms.conf/Makefile
- crosvm:`devices/src/virtio/gunyah_accept.rs`(新裝置)、virtio_ids(60)、
  mod.rs 三處 match、virtio_pci_device.rs(PCI class + VmRequester vm_accept 透傳)、
  vm_control lib.rs(訊息型別 + drive_guest_accept + Register/Unregister Sync 分支 +
  DynamicMapping.guest_synced)、api.rs(register_memory_for_blob 帶 vm_accept)、
  gpu parameters/mod/virtio_gpu(vm-accept plumb)、device_helpers + linux.rs(裝置
  建立於 devs 尾端保 PCI slot 穩定 + tube 到 vm_memory_handler)
- 裝置建立條件:`protection_type.isolates_memory()`(protected 才有 accept 概念)

### 測試階梯
1. 新 crosvm + 舊模式(vm-accept 不設)→ 行為 == 現狀(回歸)
2. gfx launcher + `vm-accept=sync` → guest dmesg 見 probe;vulkaninfo;vkcube;
   crosvm log 無 timeout;unmap 時 guest RELEASE 對稱
3. 分數對比 off vs sync(goal 3 of 上一輪 /goal)

---

## Goal 2 — kgsl pool 改 swiotlb 同款(purpose region)

### 現狀盤點(比想像近)
пул已有:pre-START bless(`prepare_kgsl_pool_arena`,gunyah/mod.rs:853)、no-map DT
node(fdt.rs:851 `gpu_blob_reserved@`,RM by-reg 匹配 bless;restricted-dma-pool 之坑
已註解)、mthp 大頁(prepare_lend_region → order-9 → gh_hugepage_reserve supply hook)。
**缺的只是「形式」**:env-var(NCTX_VRAM_MB/NCTX_POOL_FD/NCTX_POOL_GPA)+ Vm trait
hack + GPA 在 high-MMIO window 上方(而非 RAM 尾端的 layout 常規位置)。

### 目標形態(= simplefb/swiotlb 同款)
1. 新 `MemoryRegionPurpose::GpuPool`(**勿重用 ReservedMemory** —— 它 lend=true,
   且是 gfxstream pre-alloc 翻車主角)。lend=false → `GunyahVm::new` 通用迴圈
   boot SHARE;該 purpose 掛 mthp prepare(大頁供給,同今日)。
2. `guest_memory_layout()`(aarch64/src/lib.rs:543)追加 region:GPA 放 RAM 尾端
   swiotlb/simplefb 旁(layout 函數族 get_swiotlb_addr/get_simplefb_addr 延伸);
   大小來自 `--gpu` 的 pool 參數(CMDLINE_V2:per-proxy `vram=pre-alloc,size-mb=`),
   **--mem 之外追加**,不偷 guest RAM。
3. backing:region 的 shm(fd)+ shm_offset 交給 virglrenderer
   (`NCTX_POOL_FD`+新 `NCTX_POOL_FD_OFFSET`,或維持獨立 memfd 若 MemoryRegionOptions
   支援 per-region file backing)。
4. fdt:generic path 依 purpose 發 no-map node(名字 per-pool:`kgsl-pool` /
   `gfxstream-pool`,呼應 CMDLINE_V2 多池共存)。
5. guest front:`kgsl_pt` 從「virtio-gpu BAR 資訊」改為(或增加)「DT carveout
   memremap」;= 舊 task #10(Arena Stage 2)。可 cacheable 映射 → 可能緩解
   kgsl VNC scanout lag(待驗)。
6. 舊路徑 `prepare_kgsl_pool_arena` + NCTX_* env 留一版 deprecation(CMDLINE_V2 慣例)。

---

## Goal 3 — gfxstream pre-alloc(pool 子分配 + 碎片重映射)

### 前提(記憶體檔案 gfxstream-prealloc-blocked-protected)
anon arena + per-blob MAP_FIXED **在 protected 下死路**(guest 沒 accept arena→SIGBUS;
MAP_FIXED 換 fd 不會傳到 pinned stage-2)。唯一解 = **pool merge**:blob backing 從
boot-bless 的 memfd pool **子分配**,頁永遠是 pool 那些頁,stage-2 恆有效,零 runtime
share。

### 偵察定案(2026-07-21,gfxstream host 端)
**host-visible 記憶體本質 = gfxstream 自配 memfd + /dev/udmabuf 別名 import 進 turnip**
(driver 只 import 不 alloc)→ 池化完全可行。兩類都是 memfd:
- host-visible VkDeviceMemory:`VkDecoderGlobalState.cpp:6667-6754`
  (`SharedMemory.createNoMapping` → `CollapseMemfdToFolios` → udmabuf → dmabuf import);
  export 給 crosvm 的是 memfd(`:7332-7340`,STREAM_HANDLE_TYPE_MEM_SHM)
- RingBlob:`VirtioGpuResource.cpp:80-201`(`CreateWithShmem` + 2MB folio recipe +
  GunyahRingBlobPool pin/復用)
- VRAM knobs(GFXSTREAM_VRAM_*)= 同一條 memfd 路上的 routing/配額/collapse,
  非獨立分配器(`HostVisibleFolio.h`)
- **不可池化**(必須 driver/guest 配):ColorBuffer/Buffer(driver dmabuf)、
  guest-import(CREATE_GUEST_HANDLE)、AHB —— 這些留在 runtime guest-accept 路

**落點**:
1. pool 建立:crosvm GpuPool 第二塊(gfx 模式 gate,DT 名 `gfxstream-pool` 與 kgsl 池
   區分)→ GFXSTREAM_POOL_FD/OFFSET/GPA env
2. `VkDecoderGlobalState.cpp:6667`:alloc 改 pool 子分配(chunk list);udmabuf 用
   **UDMABUF_CREATE_LIST**(多段 {memfd,offset,size} → 單一 dmabuf,天然解 GPU 端碎片)
3. collapse 前移到 pool 建立時一次做(udmabuf pin 後不能 collapse,`HostVisibleFolio.h:136-143`)
4. export(`:7332`)/map:blob 不再進 BAR;map_blob response 擴充 pool-relative chunk list
5. host CPU 連續 VA:預留 span + 每 chunk MAP_FIXED(同 fd 不同 offset,不觸 stage-2,合法)
6. RingBlob:GunyahRingBlobPool 改從共享 pool 子分配

### 碎片問題與 kmod 重映射(user 指定設計)
пул長壽 + blob 大小混雜 → 碎片。設計:
- **host 子分配器**允許一個 blob 由 ≤N(暫定 32)個不連續 chunk 組成
  {pool_offset, size}[];host 端 gfxstream 需要連續 host VA 時,把 chunks 逐段
  MAP_FIXED 進一段預留 VA(fd 相同、offset 不同 → 不觸 stage-2,合法!與被判死的
  「換 fd」不同)。
- **map_blob 協定**:response 擴充 chunk list(guest 預留夠大的 resp buffer;
  cap N=32,超過 → 分配器 fail → host 報 OOM)。
- **guest kmod**:收 chunk list,把散落 pool GPA chunks 依序 io_remap 進**連續
  userspace VA**(同 virtgpu_vram mmap 路徑,fault/remap 迴圈化)——「用戶空間
  重新映射回連續」。GPU 側不受影響(host GPU 看 host VA;guest CPU 看 VA 連續)。
- kgsl 同型:P2 task #6(multi-run alloc + mmap stitching)= 同一套 chunk 機制,
  kgsl backend/前端複用。

### 依賴順序
Goal 2 的 pool 底座(purpose region、多池、fd+offset)是 Goal 3 的地基;
Goal 3 = 底座上的 gfxstream 子分配器 + chunk 協定 + guest 重映射。

### as-built 進度(2026-07-21)
- ✅ **crosvm pool 底座**:`aarch64/src/lib.rs` GpuPool region 兩 gate(NCTX_KGSL_PT|NCTX_GFX_POOL_MB),導出 `GFXSTREAM_POOL_FD/_FD_OFFSET/_GPA/_SIZE`;boot SHARE-bless + 大頁 + create_shm_node 全複用 kgsl 路。build 過。
- ✅ **gfxstream host pool 子分配器**:新 `host/vulkan/HostVisiblePool.h`(free-list、contiguous 優先、碎片多 chunk 分裂、coalesce free、env 讀 pool)。**單元測試過**(contiguous/hole 復用/OOM/40K 碎片裂 3 段)。
- ✅ **偵察 file:line 全圖**(見下)。

### 精確接線圖(偵察確認)
| 層 | 檔案:行 | 現況 | pre-alloc 改法 |
|---|---|---|---|
| guest cmd decode | gpu/mod.rs:621-656 | host-visible = BLOB_MEM_HOST3D 無 iovec | 不改 |
| gfxstream host alloc | VkDecoderGlobalState.cpp:6667 | 每 alloc 新 memfd | **改成 HostVisiblePool::alloc → udmabuf(pool_fd, offset)**,MemoryInfo 記 pool_offset |
| host export | VkDecoderGlobalState.cpp:7332 + VirtioGpuResource.cpp:1132 ExportBlob | 回 memfd(MEM_SHM) | 帶 pool_offset(新欄位/新 handle_type STREAM_HANDLE_TYPE_MEM_POOL) |
| rutabaga | gfxstream.rs:504 export_blob / 478 map_info | handle+cache/access | 攜 pool_offset 到 crosvm |
| crosvm map | gpu/virtio_gpu.rs:1279 resource_map_blob | export→runtime_share BAR | pool-resident→**不 runtime_share**,回 pool GPA(kgsl 式,precedent=KgslPoolMap:101) |
| 協定 | gpu/protocol.rs:528 resp_map_info.gunyah_handle | 一個 spare u32 | 3a:reuse 帶 pool_offset+flag;3b:變長帶 runs[] |
| guest kernel | virtgpu_vram.c:47-102 mmap + :1363 resp parse | handle!=0→accept;vram_node 在 BAR | **handle==0 已 skip accept**(現成!);vram_node 改指 pool GPA(pool base 從 DT gpu_blob_reserved node 讀) |
| guest kernel mmap | virtgpu_vram.c io_remap(vram_node.start) | 單段 BAR | 3b:複用 kgsl multi-run io_remap(kgsl_pt_chardev.c:799 / kgsl_pt_dmaheap.c:93) |
| guest ICD | DrmVirtGpuBlob.cpp:155 mmap DRM fd | kernel 決定 GPA | **不改** |

### 里程碑切分
**3a(contiguous,zero-SHARE,可測)**:gfxstream 只從 pool 拿**單一連續 chunk**,拿不到→fallback 今天的 runtime SHARE(保正確)。協定只需帶一個 pool_offset(reuse gunyah_handle 欄位 + map_info flag bit)。guest kernel:pool_gpa(從 DT reserved-memory node 讀一次)+ pool_offset → vram_node.start,handle==0 skip accept(現成分支),單段 io_remap。**達成核心目標**(host-visible 從 boot-blessed pool、零 runtime SHARE)於常見情形。
**3b(碎片)**:pool 碎片時 alloc 回多 chunk;擴 resp_map_info 成變長帶 nr_runs+runs[];guest kernel 複用 kgsl multi-run io_remap 拼連續 VA。消除 3a 的 fallback。= 也順手補上 kgsl 的 task #6(P2 碎片)。

### 待實作(3a 的 5 處跨層改動)
1. gfxstream `VkDecoderGlobalState.cpp:6667` — HostVisiblePool 子分配 + udmabuf offset(UdmabufCreator 加 .offset)+ 移除 per-alloc collapse(pool 已整塊 collapse)+ MemoryInfo.poolOffset
2. gfxstream export(`:7332` + `VirtioGpuResource.cpp:1132`)— 帶 poolOffset(建議新 handle_type MEM_POOL,os_handle 復用傳 offset,或 stream_renderer_handle 加欄位)
3. rutabaga `gfxstream.rs` — export_blob/map_info 攜 pool_offset(Rust FFI struct 加欄位)
4. crosvm `gpu/virtio_gpu.rs:1279` — pool-resident 分支:不 runtime_share,OkMapInfo 回 pool_offset;protocol.rs resp 加 flag
5. guest kmod `virtgpu_vram.c`/`virtgpu_kms.c` — 讀 DT pool base + pool-resident vram_node 置於 pool GPA(handle==0 accept-skip 已存在)

---

## 執行順序
1. ✅ Sync 實作(guest kmod 建好裝好;crosvm 編譯中)
2. Sync 測試階梯(回歸 → sync 開啟 → 對比分數)
3. Goal 2:purpose region + layout + fdt + NCTX offset + guest front memremap
4. Goal 3:gfxstream 偵察 → 子分配器 → chunk 協定 → guest kmod 重映射 → 測試
