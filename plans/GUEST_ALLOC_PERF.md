# pVM guest-alloc(官方 gfxstream 路線)+ cacheable pool — 性能目標 90% host

2026-07-22 立。動機:host-alloc 兩模式都不理想——
- runtime-share(2 hypercall/blob):vkmark 3500 / MC 110fps,但撞 39-parcel 上限會崩。
- pre-alloc pool:vkmark 1500 / MC 40fps,穩但**慢一半**(pool 映射 non-cacheable)。
- host native:7000~10000。

目標:走**官方 gfxstream guest-alloc 路線**(`BLOB_MEM_GUEST` + 官方 `attach_iov`),讓 guest kernel
自主分配,達官方宣稱 ~90% host 性能。**不參考 kgsl 路線**(host 分配 + proto 開銷 + non-cacheable,
正是要避開的坑;半成品性能糟)。

## pVM 的根本約束與解法
protected VM 下 host(crosvm/VMM)**看不到任意 guest 頁** → 官方 guest-alloc(shmem 任意 RAM +
attach_iov)在 pVM 不通。**解法**:guest-alloc 的 backing 從**開機 SHARE-blessed 的 GpuPool** 切,
guest 頁=池頁,crosvm 有池 memfd 讀寫得到 → 官方 attach_iov 成立。這是「用池當 backing 來源」,
**非** kgsl 那套 host-allocates + 自訂 proto。

## 設計原則(使用者定,2026-07-22)
**盡量和官方 gfxstream 相同,唯一差異=分配搜尋空間從整個 guest RAM 縮到 reserved pool**。
- guest 拿記憶體會遇到**和官方一樣**的「user 空間要連續、物理碎片」問題 → 官方用 **scatter-gather
  多段 ents(attach_iov)** 解;我們照做,**不要**單段連續 pool_resident(那是 fork 的東西)。
- 其他一切(mesa 路、cmd_resource_create_blob、host import、mmap)盡量原封不動走官方。

## 關鍵簡化發現(2026-07-22 codebase 查證)
1. **crosvm iovec 路零改動**:GpuPool region 是 host-accessible GuestMemory(`gunyah/mod.rs:285`
   lend=false SHARE'd;`guest_memory.rs:509` `check_host_access(GpuPool)=Ok` 即使 protected)。
   官方 guest-blob 路 `resource_create_blob`(`virtio_gpu.rs:1244`)對 `blob_mem!=HOST3D` 已呼叫
   `sglist_to_rutabaga_iovecs(vecs, mem, None)` → `mem.get_slice_at_addr` **直接解析 pool GPA**。
   **不需寫 GfxPoolMap**(kgsl 的 KgslPoolMap 是因它的池是 standalone memfd 不在 GuestMemory;gfx 在)。
2. **guest-alloc 不走 resource_map_blob**:官方 guest-alloc,guest **自己 mmap 自己的 GEM 物件**(擁有頁),
   不經 host 的 pool_resident map 路。故 cacheability 由 **guest 怎麼映射自己的池頁**決定,非 host map_info。

## 架構(官方對齊,scatter-gather,非 kgsl/非單段)
```
guest mesa (官方 udmabuf 路,幾乎不改)
  └ createBlob(kBlobMemGuest, CREATE_GUEST_HANDLE)
guest kernel virtio-gpu (主改)
  └ BLOB_MEM_GUEST → 從 guest-side pool allocator(drm_mm/gen_pool over guest-slice)自主 carve offset
  └ backing = 池頁 [gpu_pool_base+off, +size);ents = {gpu_pool_base+off, size}(單段連續)
  └ cmd_resource_create_blob 送 ents(官方路)
  └ mmap:cacheable(map_info=CACHED)io_remap gpu_pool_base+off
crosvm (小改)
  └ resource_create_blob guest-blob 分支已呼叫 sglist_to_rutabaga_iovecs(vecs, mem, pool)
  └ 需:gfx-pool GPA→host 解析(乾淨新寫 GfxPoolMap 讀 GFXSTREAM_POOL_FD/GPA/SIZE;不用 kgsl 的)
  └ resource_map_blob 對 pool 回傳 map_info=CACHE_CACHED(cacheability 一半)
host gfxstream (不改):官方 attach_iov import
```

## 性能兩支柱
1. **免 per-alloc hypercall**:guest 自主分配,池開機一次 SHARE,runtime 零 hypercall(勝 runtime-share 的 2 hypercall/blob)。
2. **cacheable**:池映射 cacheable(勝 pre-alloc 的 non-cacheable)。**前提=guest-CPU↔host-GPU 對池記憶體硬體同調**;sm8750 SMMU/coherent interconnect 大機率同調(待驗)。不同調則退 WC(仍勝 uncached)。

### cacheability = 保留 no-map + kmod 自己加 cacheable 映射(2026-07-22 使用者定 + 查證)
**不拿掉 no-map**(拿掉 → 區塊進內核 general RAM、失去 no-exec 保護,不可)。改由 kmod 對 no-map
區自己建 cacheable 映射,只給 GPU blob 用:
- **userspace**:`io_remap_pfn_range` + **Normal-Cacheable pgprot**(不套 `pgprot_writecombine`,用
  `vm_get_page_prot(vm_flags)` 給的 Normal Cacheable),`VM_PFNMAP`(no-map 無 struct page 亦可)。
  只經 DRM blob mmap 暴露(RW,無 exec;DRM mmap 不給 exec + stage-2 no-x)→ app 拿不到 general
  RAM/x 權限。
- **kernel 存取**(若需):`memremap(pa, size, MEMREMAP_WB)`。
- **已證實**:`kgsl_pt_core.c:204` 對**同一塊 no-map pool** 用 `memremap(...,MEMREMAP_WB)` 建 WB
  cacheable 視圖(不採 kgsl 架構,只借這個已驗證的 mapping primitive)。
- **同調**:cacheable + host GPU 寫 → guest CPU cache 需同調。sm8750 硬體同調則直接用;否則 sync
  點加 cache maintenance。實測畫面 corruption 定案(增量 2)。
- **現況慢因**:gfx pool mmap 拿 host 送的 `map_info=WC`→`pgprot_writecombine`→WC 讀慢。guest-alloc
  路由 guest 自控 pgprot=Normal Cacheable 解決。

### (參考)cacheability 兩處(host-alloc 舊路)
- **guest mmap pgprot**(`virtgpu_vram.c:90-93`):map_info WC→writecombine、UNCACHED→noncached、**CACHED(0x01)/NONE(0x00)→預設 cacheable**。
- **map_info 來源**:pool_resident 取自 host response(`virtgpu_vq.c:1385` `mi & CACHE_MASK`);host `resource_map_blob`(crosvm `virtio_gpu.rs:1298`)現回 `map_info & RUTABAGA_MAP_CACHE_MASK`——查 rutabaga 對 pool blob 送什麼,改成 CACHED。
- **DT reserved-memory `no-map`**(crosvm `fdt.rs:851-873`):no-map = 無 linear cacheable 映射,guest 只能 io_remap(device mem)。若要 guest 端 cacheable linear,需評估拿掉 no-map 對 Gunyah bless 的影響(bless 靠 reg 比對,未必需 no-map;待查)。但走 mmap pgprot=CACHED 的 io_remap 路,理論上也能 cacheable(io_remap + cacheable pgprot),優先試這條免動 no-map。

## 池分段 = 兩個獨立池(2026-07-22 使用者定,取代單池+partition)
不用「單池 + 邊界值傳遞」——**建兩個獨立 SHARE'd 池**,邊界變成結構本身(各池自己的 size),
無 magic number 要傳/同步:
- **CLI**:`--pre-alloc "gfx-host-mb=N gfx-guest-mb=M"`(拆自舊 `gfx-mb`)。
- **host 池**(`gfx-host-mb`)= `MemoryRegionPurpose::GpuPool`,現有 `GFXSTREAM_POOL_*` env + `gfx_host`
  DT 節點。gfxstream `HostVisiblePool` **只認這個**(不動)。ASG ring + host-visible host-alloc 用它。
- **guest 池**(`gfx-guest-mb`)= 新 `MemoryRegionPurpose::GpuPoolGuest`,**不給 GFXSTREAM_POOL_* env**;
  新 `gpu_guest` DT 節點。guest kmod(guest-alloc 模式)**只認這個**,整塊 own、跑自己的
  頁分配器。host 端 `get_slice_at_addr` 對它(host-accessible)解析 guest-blob mem-entries。
- 兩池都 SHARE(lend=false)+ hugepage-prepare + shm-vdevice(stage-2 mapping 免 accept)。
- **Component A(capset partition)退役**——沒有 partition 要傳了。env 橋:`gfx-host-mb→NCTX_GFX_POOL_MB`、
  `gfx-guest-mb→NCTX_GFX_GUEST_POOL_MB`。
- tradeoff:兩固定池不能動態 rebalance(設計本就固定切片,無損)。
- **crosvm 端已實作**:config.rs 拆參數、guest_memory.rs `GpuPoolGuest` purpose + check_host_access、
  aarch64/lib.rs 第二 region + build_vm collect gpu_guest_resv、fdt.rs `gpu_guest` 節點、
  gunyah bless/shm-vdevice/hugepage、geniezone。

## 實作順序(依賴序)
1. **[crosvm] gfx-pool GPA 解析**:新寫 `GfxPoolMap`(讀 GFXSTREAM_POOL_FD/GPA/SIZE,mmap;host_ptr 翻譯),接進 `sglist_to_rutabaga_iovecs`。Rust-only,可對現有 guest-blob 路增量測。
2. **[crosvm] map_info=CACHED**:`resource_map_blob` pool 分支回 CACHE_CACHED。
3. **[guest kernel] guest-side pool allocator + BLOB_MEM_GUEST carve**:drm_mm over guest-slice(範圍從 DT/capset);object_create BLOB_MEM_GUEST 分支改從池分配、ents 指池、pool_resident mmap cacheable。**需 module rebuild + initrd surgery**([[kgsl-initrd-kmod-deploy]])。
4. **[bringup] udmabuf=true 全鏈**:切 run script udmabuf=true;vkmark/MC 量測 vs host-alloc;驗證同調正確性(畫面無 corruption)。host-alloc(udmabuf=false)全程保留可退。

## 安全
guest-alloc 全鏈 gate 在 udmabuf=true;現行 MC(host-alloc,udmabuf=false)wire/路徑**零改動**、隨時可退。
guest kernel 改屬 udmabuf=true 專用分支。crosvm GfxPoolMap 只在 gfx-pool GPA 命中時作用,不影響 host-alloc。
