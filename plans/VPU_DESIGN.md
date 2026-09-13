# VPU 設計：記憶體模型、行程模型、工作包

2026-09-04。承接 `VIRTIO_MEDIA_PLAN.md`（2026-08-26），把 §2.1 的記憶體地基按新方向重寫，
其餘章節（相機控制項、codec 對映、驗收）仍然有效，差異列在 §0.2。
事實來源是 2026-09-04 的 13 路平行 survey，原始報告在 `/root/gitrs/DroidVM/logs/vpu_survey/`，
本文只引用結論，每條帶 file:line（路徑相對 meta repo；`crosvm/` = `crosvm_build/external/crosvm/`，
`vmedia/` = `crosvm_build/external/virtio-media/`）。

開發機：5566（PLK110 / canoe / SM8850 / Android 16 / kernel 6.12），VM `Ubuntu-resolute`
（Ubuntu 26.04.1、kernel 7.0.0-30-generic、headers + dkms 可用、drm_buddy 已載入）。
5568 給 USB 工作用，不碰。建置一律綁 CPU 0-7、`JOBS=8`（`build-host-notes` memory）。

---

## 0. 一頁摘要

### 0.1 要做什麼

| 目標 | 交付 |
|---|---|
| 池子系統 | `media_host`（host 配置）+ `media_guest`（guest driver 用 drm_buddy 配置、host 匯入）；`protected-without-firmware` 兩池都建，`pseudo-unprotected` 只建 `media_host`；guest 池不在 → driver 從系統 RAM 配置，KVM 也能跑 |
| 相機 | guest 經 V4L2 用主機相機，含 zoom / AF / flash / AE / AWB 等 Android 框架功能 |
| 編解碼 | guest 經 V4L2 stateful codec 介面驅動主機 MediaCodec，能力從 `AMediaCodecStore` 即時查，不寫死 |

### 0.2 與 VIRTIO_MEDIA_PLAN.md 的差異（新方向覆蓋舊決定）

| 舊 | 新 | 原因 |
|---|---|---|
| D8：v1 不做 `media_guest`，USERPTR 不碰 | `media_guest` 是 pVM 的正式路徑；OUTPUT 方向的 buffer 由 guest driver 擁有 | 使用者需求；且 pVM 下 USERPTR 的 SG 路徑本來就只有指向 SHARE'd 記憶體才可能通（`vmedia/driver/scatterlist_filler.c:303` 送的是裸 GPA） |
| D3/D4：guest 端 ~30 行、host 端「allocator 重指到池」 | guest 端 ~30 行只是 `media_host` 那半；`media_guest` 那半是 driver 內配置器（~400 行）；host 端 crate 的 buffer backing 要改，不是 allocator 換 base | `add_mapping(fd, len, cookie)` 收的是每個 buffer 自己的 memfd（`vmedia/device/src/lib.rs:120-126`、`crosvm/devices/src/virtio/media.rs:161-165`），池內 buffer 是池 memfd 的一段 |
| 「協定一個 bit 都不用改」 | 仍然成立 | 兩種 buffer 都用既有 MMAP / USERPTR 線格式 |
| 沒提 BAR | **Gunyah 上有 `media_host` 時裝置不宣告 shm region** | 每個 media 裝置要 4 GiB BAR（`media.rs:537,634-641`），Gunyah 64-bit MMIO 視窗只容一個 4 GiB BAR + 512 MiB（`crosvm/aarch64/src/lib.rs:262-266`），GPU 已佔用；guest `/proc/iomem` 證實視窗 `1c0800000-31fffffff` |
| 相機 backend 的行程模型未定 | vhost-user media backend + app uid helper（同 `snd_helper`） | 相機 uid 必須是前景的 app uid（plan §2.2）；`snd_helper.rs:5-23` 是現成先例；in-VMM 的 root 行程開不了相機 |
| §0 表：5566 有 DV 硬解/硬編 | 沒有；live 的 `media_codecs_canoe_v2.xml` 不含 DV，硬體 APV 被註解掉 | 5566 實測 |
| §7 首列：`/dev/video32,33` 是相機節點 | 5566 上是 `msm_vidc_v4l2`（硬體 codec 的 V4L2 節點） | 5566 實測；但目標 (b) 明寫「經 MediaCodec 框架」，此路徑只作為實驗備案 |

### 0.3 里程碑（每個都可獨立驗收）

| # | 交付 | 驗收 |
|---|---|---|
| M1 | 兩個池 + crate buffer allocator + in-VMM `simple` / `loopback` 測試裝置 + SG 解析修正 | pVM 上 `v4l2-ctl --stream-mmap` 從 simple 裝置抓到 pattern，driver log 印 `media_host` base；loopback 裝置 OUTPUT→CAPTURE 資料一致 |
| M2 | guest driver：池探測、driver-owned buffer、DKMS 第三模組 | 同上但 OUTPUT buffer 來自 `media_guest`（dmesg 印 drm_buddy 池）；`driver_owned_queues=none` 退回純 host MMAP 仍過；無池 VM（KVM 或拿掉 `--pre-alloc`）fallback 仍過 |
| M3 | vhost-user media backend + uid helper | M1/M2 的測試改走 `crosvm device media` 全過；helper 以 app uid 跑 |
| M4 | 相機裝置 A1 | plan A1 驗收（`ffmpeg -f v4l2` 錄到會動的畫面、gst `v4l2src` smoke） |
| M5 | 相機控制項 A2、事件 A3、app 整合 A4 | plan A2–A4 驗收 |
| M6 | `android_codec` + MediaCodec decoder backend B1–B3 | plan B1–B3 驗收 |
| M7 | encoder device + backend C1–C3 | plan C1–C3 驗收 |

---

## 1. 決定設計的十件事（已核實）

1. **池子機制通用，加池是機械工作**，但兩處漏了不會編譯錯只會靜默失效：`check_host_access` 的 `other => Err` 兜底（`crosvm/vm_memory/src/guest_memory.rs:1074`）和 `is_pool` 的 `matches!`（`crosvm/hypervisor/src/gunyah/mod.rs:616-624`）。完整 recipe 在 survey `crosvm-pools.md` §3（9 個檔案）。
2. **protection type 對池子零影響**：pseudo-unprotected 下池子一樣建、SHARE、bless、出 DT 節點（`crosvm-pools.md` §2）。「pseudo 只建 `media_host`」不需要 crosvm 判斷 —— app 端 `VpuConfig.guestPoolMbFor()` 在非保護模式回 0（`DroidVM/.../VpuConfig.java:73-87`），daemon 不送 `media-guest-mb` 就是了。
3. **media 裝置的 MMAP 分配器是個 `[0, 4 GiB)` 的 `AddressAllocator`，映進 PCI shm BAR**（`media.rs:139-190, 598-605`）；guest 端只在一處把 `mmap_region.addr` 加上去（`vmedia/driver/virtio_media_driver.c:702`），munmap 一處減回去（`:625`）。
4. **crosvm 的 SG 直接映射在 aarch64 是壞的**：`GuestMemoryMapping::new` 把 GPA 當 `offset_region()` 的參數又當 memfd offset（`media.rs:239-243`；`offset_region` 會加上 `regions[0].guest_base = 0x8000_0000`，`guest_memory.rs:1538-1543`）。正確算法在 udmabuf 路徑（`vm_memory/src/udmabuf/sys/linux.rs:70-85`：`find_region` → `memfd_offset + map_offset`）。修好之後 `media_guest`、restricted-dma-pool、`SharedGuestRam`、KVM RAM 四種來源都走同一條路。
5. **`check_host_access` 依 region purpose 放行**：`GpuPoolGuest` 等池走 `check_pool_backed_range`（step 0 時直接 Ok）、`SharedGuestRam`/`StaticSwiotlbRegion` 無條件 Ok、一般 lent RAM 拒絕（`guest_memory.rs:1031-1075`）。所以 guest-owned buffer 只要落在「池 / swiotlb / 共享 RAM」就能被 host 讀寫。
6. **guest driver 的 USERPTR 路徑送裸 GPA、立刻 unpin**（`scatterlist_filler.c:247-313`），每個 command 最多 1024 條 SG（16 KiB shadow buffer，`session.h:23`）。driver-owned buffer 若連續配置，SG 只有一條。
7. **driver 端 MMAP→USERPTR 轉譯有 7 個攔截點**：REQBUFS/CREATE_BUFS、QUERYBUF、`virtio_media_send_buffer_ioctl` 的 `:244-249` 之間、`scatterlist_filler.c:380/386` 的 memory gate、DQBUF event 的 memcpy（`virtio_media_driver.c:352`）、mmap handler、`session.h` 新欄位（`virtio-media-driver.md` §4.3）。
8. **guest-additions 已有可抄的原語**：`/reserved-memory` 名字前綴查找（`virtgpu_kms.c:54-75`）、drm_buddy 池初始化與配置（`virtgpu_vram.c:447-694`）、mmap pgprot（`:78-87`，池頁預設 cacheable）、無池 fallback 的警告（`:488-511`）、DKMS 第三模組只要 dkms.conf 三行 + Makefile 兩行（`guest-additions.md` §3.3）。
9. **udmabuf 匯入的三跳都是通用 API**：`mem.pool_ref_iovecs` → `driver.create_udmabuf(mem, vecs)` → `pool_unref_iovecs`（`host-udmabuf.md` §3.2）。5566 用的是內建 udmabuf（`list_limit=1024`、`size_limit_mb=64`），DroidVM 的 `udmabuf-gki-6.12.ko` 沒載。
10. **crate 兩個 guest 可觸發的崩潰**：SUBSCRIBE_EVENT 的 `.unwrap()`（`vmedia/device/src/ioctl.rs:1109-1110`）、`get_userptr_regions` 遇 `len==0` 的無窮迴圈（`:68-82`）。上裝置前先修。

---

## 2. 記憶體模型

### 2.1 三類 buffer

| 類 | 誰配置 | 誰寫 | 用在 | V4L2 對 userspace | 對 host 的線格式 | 記憶體來源 |
|---|---|---|---|---|---|---|
| **host-owned** | host device | host | CAPTURE queue（相機幀、解碼幀、編碼位元流） | MMAP | MMAP command（`driver_addr` = 池內 offset） | `media_host` 池；無池 → 每 buffer memfd + shm BAR（upstream，KVM 用） |
| **guest-owned** | guest driver | guest | OUTPUT queue（待解位元流、待編原始幀） | MMAP（driver 自己的 cookie + remap） | USERPTR + SG list（GPA） | `media_guest` 池（drm_buddy）；無池 → `dma_alloc_pages()`（pVM 落 restricted-dma-pool、其他落系統 RAM） |
| **user USERPTR** | app | app | app 自己用 USERPTR 時 | USERPTR | USERPTR + SG list | app 的頁；host 能不能碰取決於 §2.3 |

**規則：方向決定歸屬。** 產生資料的那一側擁有記憶體：host→guest 的資料放 host 池，guest→host 的資料放 guest 池。
複製次數兩種歸屬相同（host 端 backend 都是 CPU 拷貝），guest 池的價值在 pVM 可達性、
BAR 不必存在、以及日後 dma-buf 零拷貝（§3.5）。

driver 端提供模組參數 `driver_owned_queues = output | none | all`（預設 `output`）：
`none` = 純 upstream 行為（全部 host MMAP，A/B 對照用）、`all` = 連 CAPTURE 也由 guest 擁有（不用 `media_host`）。
host 端裝置對每個 queue 同時支援 MMAP 與 USERPTR，所以三種設定都能跑。

### 2.2 兩個池

| | `media_host` | `media_guest` |
|---|---|---|
| purpose | `MemoryRegionPurpose::MediaPool` | `MemoryRegionPurpose::MediaPoolGuest` |
| CLI | `--pre-alloc media-host-mb=N` | `--pre-alloc media-guest-mb=M` |
| `consume_system_mem` | true（與 `gfx_host`/`drm2kgsl_host`/`venus_host` 同，`PoolPreflight` 已假設 host 池在 `--mem` 內） | false（同 `gpu_guest`，preflight 要加上） |
| growable | 否（step 0） | v1 否（step 0）。growable 需要 `/dev/gunyah_share`，5566 沒載該模組；且引入 pool_id 排序陷阱（`crosvm-pools.md` §3.11） |
| DT 節點 | `media_host@<gpa>`，`compatible = "droidvm,pool"`，`no-map` | `media_guest@<gpa>`，同上 |
| 交給消費端 | `(fd, fd_offset, host_va, gpa, size)` 直接從 `vm.get_memory().regions()` 取（不經 env，因為 helper 行程在 env 設定前就 exec 了；in-VMM 也同一支 helper fn） | 只有 DT 節點；host 以 GPA 解析 |
| 預設大小 | 256 MiB（`VpuConfig.DEFAULT_HOST_POOL_MB`） | 128 MiB |
| sizing 依據 | 1080p NV12 3.1 MiB × 8 × 相機數 + 4K NV12 12.4 MiB × 10（解碼） | 4K 原始幀 12.4 MiB × 4（編碼輸入）+ 位元流 1 MiB × 8 |

### 2.3 模式矩陣

| 模式 | guest RAM | swiotlb | host-owned buffer 落點 | guest-owned buffer 落點（有池 / 無池） | user USERPTR |
|---|---|---|---|---|---|
| `protected-vm-without-firmware`（5566 dev VM） | LENT | 256 MiB restricted-dma-pool | `media_host`（必要；無池則裝置在啟動時拒絕，見 §3.3） | `media_guest` / `dma_alloc_pages` → restricted-dma-pool（host 可讀，`StaticSwiotlbRegion => Ok`） | host 拒絕（`ProtectedMemoryAccess`），ioctl 回 EFAULT |
| `protected-vm-pseudo-unprotected`（app 新 VM 預設） | SHARE'd（`SharedGuestRam`） | 無 | `media_host` | 不建 guest 池 / `dma_alloc_pages` → 系統 RAM（host 可讀） | 可 |
| Unprotected / KVM | 一般 memslot | 無 | `media_host` 若有；否則 memfd + shm BAR（upstream） | 不建 / 系統 RAM | 可 |

### 2.4 fallback 規則（driver 端，probe 時決定、log 印出）

```
media_host 節點存在 → host MMAP 以池 base 映射，bounds = 節點 reg 長度
              不存在 → virtio_get_shm_region()；失敗 → host MMAP 不可用（REQBUFS(MMAP) 對 host-owned queue 回 -ENOMEM，並 pr_warn）
media_guest 節點存在 → drm_buddy 池，連續配置
              不存在 → dma_alloc_pages()（連續）；若 /reserved-memory 有 restricted-dma-pool 則 pr_info 說明落在 bounce pool
```

### 2.5 生命週期不變式

* host device 在回應 REQBUFS(0) / STREAMOFF / CLOSE **之前**必須放掉該 queue 所有 guest-owned buffer 的 host 映射（arena / udmabuf），
  driver 收到回應後才把 block 還給 drm_buddy（同 virtio-gpu 的「等 RESOURCE_UNREF 回應再 free」，`virtgpu_vq.c:617-636`）。
* host-owned buffer 的 offset 重用：`MmapMappingManager` 只在 munmap refcount 歸零後才移除（`vmedia/device/src/mmap.rs:146-161, 263-289`）；
  池模式下 allocator 的釋放也綁在同一點，DRC 換 buffer 不會踩到 guest 還 map 著的舊視圖。
* driver 的 `vm_ops` 補 `.open`（fork / VMA split 的 refcount，今天只有 `.close`，`virtio_media_driver.c:645-647`）。

---

## 3. 主機端（crosvm）

### 3.1 池子（WP-H1）

照 `crosvm-pools.md` §3 的 12 步做，重點：

* `guest_memory.rs:165-243` 加 `MediaPool` / `MediaPoolGuest`（`#[sorted]`，放在 `GuestMemoryRegion` 與 `ProtectedFirmwareRegion` 之間）。
* `guest_memory.rs:1031-1075` `check_host_access` 兩個 arm → `check_pool_backed_range`。
* `gunyah/mod.rs:432-471`（lend=false）、`:616-624`（`is_pool`）、`gunyah/aarch64.rs:194-243`（shm vdevice）、`geniezone/mod.rs:604-629`。
* `config.rs:757-819` `PreAllocConfig` 加 `media_host_mb`、`media_guest_mb`（v1 不加 prealloc/step/max_grants）。
* `cmdline.rs:2051-2062` help 文字補齊（順手把 `venus-host-mb`、`test-pool-*` 也補上）。
* `sys/linux.rs:2350-2381` env bridge `NCTX_MEDIA_POOL_MB` / `NCTX_MEDIA_GUEST_POOL_MB`。
* `aarch64/src/lib.rs:695-800` `pool_specs()` 兩條 `PoolSpec`；`:1750-1885` 收集 `(gpa,size)`；`fdt.rs:964-1006, 1057-1152` 兩個 `create_pool_node`。
* 新增 `vm_memory::MediaPoolHandle::from_guest_memory(&GuestMemory) -> Option<{fd, fd_offset, host_va, gpa, size}>`（找 purpose 為 `MediaPool` 的 region），供 §3.2 與 helper 使用。
* 單元測試：`pool_specs()` 兩個 env 同時給時的順序與對齊；`check_host_access` 對兩個新 purpose。

### 3.2 media 裝置的 buffer backing（WP-M2，與 §4 一起做）

`media.rs` 現況：`HostMemoryMapper { shm_mapper, allocator }`（`:139-144`），`activate` 要求 shm mapper 存在（`:588-592`）。改成：

```rust
enum HostBacking {
    /// upstream：每個 buffer 一個 memfd，映進 PCI shm BAR
    Bar { shm_mapper: ArcedMemoryMapper, allocator: AddressAllocator },
    /// DroidVM：buffer 是 media_host 池的一段，guest 直接以池 base + offset 映射
    Pool { pool: MediaPoolHandle, allocator: AddressAllocator /* 池內 offset 空間 */, host_map: MemoryMapping },
}
```

* `CrosvmVirtioMediaDevice::new(.., pool: Option<MediaPoolHandle>)`：有池 → `get_shared_memory_region()` 回 `None`（不要 BAR），`activate` 不再要求 shm mapper。
* 實作 crate 的 `VirtioMediaBufferAllocator`（§4.1）：`Pool` 模式從池內 allocator 切、回 `HostBuffer { fd: 池 memfd dup, fd_offset, len, host_ptr, pool_offset: Some }`；`Bar` 模式回每 buffer memfd（`host_ptr` 為 mmap 後指標，`pool_offset: None`）。
* `VirtioMediaHostMemoryMapper::add_mapping(&HostBuffer, cookie, rw)`：`pool_offset` 為 Some → 直接回它（guest 加池 base）；否則走今天的 `shm_mapper.add_mapping` 路徑。`remove_mapping` 對稱。

### 3.3 啟動時的拒絕（不要靜默退化）

`--virtio-media` 裝置建立時（in-VMM 或 helper）：hypervisor 為 Gunyah 且無 `media_host` → 直接 `bail!("virtio-media on gunyah needs --pre-alloc media-host-mb")`。
KVM 無池 → 走 BAR。這是 `CMDLINE_V2.md:459-465` 的規則（需要的東西不在就啟動失敗）。

### 3.4 guest-owned buffer 的解析（WP-M2）

* 修 `GuestMemoryMapping::new`（`media.rs:195-270`）：每條 SG 用 `mem.find_region(GuestAddress(start))` 拿 `(mapping, map_offset, memfd_offset)` 與 `mem.shm_region(addr)` 拿 fd，`arena.add_fd_offset(pos, len, fd, memfd_offset + map_offset)`；先 `check_host_access_range` 擋 lent RAM（回 `EFAULT`，不 panic）；空 SG list 回 `EINVAL`；Protection 依方向（OUTPUT 只讀）。
* `MAPPING_THRESHOLD` 保留（<1 KiB 走 shadow）。
* 新增 `media/guest_buf.rs`：`GuestBufferImport { sgs, mapping: GuestMemoryChunk, dmabuf: OnceCell<SafeDescriptor> }`，`dmabuf()` 走 `pool_ref_iovecs` → `UdmabufDriver::create_udmabuf` → 記得 `pool_unref_iovecs`（step 0 時是 no-op）。udmabuf driver 開失敗（`/dev/udmabuf` 不在或非 root）→ `dmabuf()` 回 Err，CPU 路徑不受影響。單元測試：以 memfd-backed `GuestMemory` 造一個假 region，驗證 arena 內容與 udmabuf mmap 內容一致。
* **v1 沒有 dma-buf 消費者**（相機幀在 `AImageReader` 的 `AHardwareBuffer` 裡、MediaCodec ByteBuffer 模式自己擁有 buffer；`AHardwareBuffer_createFromHandle` 是 VNDK 不是 NDK）。udmabuf 匯入以介面 + 測試形式交付，零拷貝消費者是後續工作。→ §11 Q1。

### 3.5 裝置註冊與 CLI（WP-M2）

新 CLI `--virtio-media KEY=VALUE,...`（可重複），`kind` 必填：

| kind | 用途 | 其他 key |
|---|---|---|
| `simple` | 既有 pattern 產生器（等同 `--simple-media-device`，保留舊 flag） | — |
| `loopback` | 測試用 M2M：OUTPUT 收 guest 資料原樣拷進 CAPTURE（MPLANE，NV12 與 RGB3 各一格式），驗證 guest-owned + host-owned 全鏈 | `card=` |
| `camera` | M4 | `camera_id=`, `card=`, `role=main|aux`, `uid=`, `gid=` |
| `decoder` / `encoder` | M6 / M7 | `uid=` 等 |

`uid` 存在 → 走 §6 的 helper；否則 in-VMM。

---

## 4. crate（Droid-VM/virtio-media fork，`device/`）

### 4.1 buffer allocator（WP-M2）

`device/src/lib.rs` 新 trait：

```rust
pub struct HostBuffer { pub fd: OwnedFd, pub fd_offset: u64, pub len: u64,
                        pub ptr: NonNull<u8> /* host 映射 */, pub pool_offset: Option<u64> }
pub trait VirtioMediaBufferAllocator {
    fn allocate(&mut self, len: u64) -> Result<HostBuffer, i32>;   // ENOMEM 於耗盡
    fn release(&mut self, buf: HostBuffer);
}
```

* `VirtioMediaHostMemoryMapper::add_mapping` 簽章改為 `(&mut self, buffer: &HostBuffer, offset: u64, rw: bool) -> Result<u64, i32>`；`MmapMappingManager::create_mapping` 跟著改。
* `memfd.rs` 的 `MemFdBuffer` 變成 `Bar` 模式 allocator 的實作細節；device 不再直接 `MemFdBuffer::new`。
* `video_decoder.rs` 的 `VideoDecoderBufferBacking::new(queue, index, sizes)` 加 allocator 參數（backend 從 allocator 拿 CAPTURE buffer）。
* 耗盡錯誤路徑：REQBUFS 回 `-ENOMEM` 並 log 池用量（回答 plan §2.1 的「錯誤落在哪個 ioctl」）。

### 4.2 USERPTR / guest-owned 支援

* `simple_device.rs` 維持 CAPTURE-only，但 REQBUFS 接受 `UserPtr`（`all` 模式測試用）；QBUF 對 UserPtr 平面呼叫 `new_mapping` 並寫入。
* 新 `devices/loopback_device.rs`：`V4L2_CAP_VIDEO_M2M_MPLANE | STREAMING`；兩條 queue 都接受 MMAP 與 USERPTR；QBUF(OUTPUT) 的內容拷進下一個可用 CAPTURE buffer，發兩個 DQBUF event；映射持有到 DQBUF 為止（§2.5）。
* 上述兩個裝置實作 `subscribe_event`（只接 `Eos`/`SourceChange`，其餘 EINVAL），避免 §1.10 的 unwrap。

### 4.3 穩固性修補（WP-M2）

* `ioctl.rs:1109-1110` 兩個 `.unwrap()` → `EINVAL`。
* `ioctl.rs:68-82` `len == 0` → `Err(EINVAL)`；entries 上限 `MAX_SG_ENTRIES = 4096`。
* `mmap.rs` `remove_mapping` 的 O(n) 掃描加 `guest_addr → offset` 表（30 fps × N 路會用到）。
* `Cargo.toml` 加 feature `loopback-device`；`Android.bp` 同步（`features:` 清單手動維護，cargo_embargo 產物）。

### 4.4 crate 版本

fork 是 0.0.6（`device/Cargo.toml:3`），`Android.bp:21` 寫 0.0.5；crosvm `Cargo.lock` 的 0.0.7 與 soong build 無關。
`decoder_adapter.rs`（crosvm，`video-decoder` feature）對的是 0.0.7 API，Android build 不編它，**不要引用**。

---

## 5. guest driver（fork `vmedia/driver/`，vendored 進 `droidvm-guest-additions/virtio_media/`）

### 5.1 池探測（probe）

* `#include <linux/of.h>`, `<linux/of_address.h>`；複製 `virtio_gpu_find_pool_base_named` 的形狀，回傳 base **與長度**。
* `media_host`：填 `vv->mmap_region = { addr: base, len }`；mmap 時 bounds-check `driver_addr + len <= mmap_region.len`（今天完全沒檢查，`virtio-media-driver.md` §2.3 第 5 點）。找不到 → `virtio_get_shm_region()`，回傳值要檢查（今天忽略）；兩者皆無 → `mmap_region.len = 0`，host-owned MMAP 回 `-ENOMEM`。
* `media_guest`：`drm_buddy_init(&vv->guest_pool, size, PAGE_SIZE)`（含 `virtgpu_drv.h:58-84` 的 7.1 `gpu_buddy` 改名 shim，vendored 一份）；找不到 → 無池，走 `dma_alloc_pages`。
* dmesg 各印一行（`virtio-media: media_host base %pa len %llu` / `media_guest ... (drm_buddy)` / `no pool, ...`），A1 驗收看這幾行。

### 5.2 driver-owned buffer 配置器（`virtio_media_alloc.c`，新檔）

```c
struct vmedia_dbuf {                 /* 每個 driver-owned plane 一個 */
    struct list_head blocks;         /* drm_buddy blocks（池模式） */
    struct page *pages; dma_addr_t dma; size_t npages;   /* dma_alloc_pages 模式 */
    u64 cookie;                      /* userspace 的 mmap offset，>= VMEDIA_DBUF_COOKIE_BASE */
    u32 nents; struct virtio_media_sg_entry *sg;   /* 預先算好的 SG（GPA） */
    refcount_t maps;                 /* vm_ops open/close */
    size_t len;
};
```

* 池模式：`drm_buddy_alloc_blocks(.., DRM_BUDDY_CONTIGUOUS_ALLOCATION)`；失敗退回非連續（多條 SG）；再失敗 `-ENOMEM`。
* 無池：`dma_alloc_pages(&vdev->dev, len, &dma, DMA_BIDIRECTIONAL, GFP_KERNEL)`；SG 用 `page_to_phys(page)`。
* cookie 空間：`VMEDIA_DBUF_COOKIE_BASE = 0xC000_0000`，每 buffer 一頁遞增（host 的 `MmapMappingManager` 從 0 起、每 buffer 一頁，兩者不會撞）。
* `VIRTIO_SHADOW_BUF_SIZE` 從 16 KiB 提到 64 KiB（非連續 fallback 時 4K 幀約 3100 條）。

### 5.3 攔截點（照 `virtio-media-driver.md` §4.3 的 7 點）

1. REQBUFS / CREATE_BUFS：`b->memory == MMAP && queue_is_driver_owned(type)` → 配置 count 個 dbuf，送 host 時 `memory = USERPTR`，回程改回 MMAP 並修 `capabilities`（設 `SUPPORTS_MMAP`、清 `SUPPORTS_USERPTR`）。count=0 → 先送 host、**收到回應後**才釋放 dbuf（§2.5）。
2. QUERYBUF：送 host 後把 `memory`/`m.offset`/`length` 換成 dbuf 的。
3. PREPARE_BUF / QBUF：在 `virtio_media_send_buffer_ioctl` 的 `:244` 與 `:249` 之間把 `b` 改成 USERPTR + `m.userptr = cookie`（opaque，host 原樣回）+ `length`，回程還原。
4. SG 產生：新 `scatterlist_filler_add_buffer_dbuf()` 直接寫 dbuf 預算好的 SG，不走 `vb2_create_framevec`。
5. DQBUF event：`memory` 欄位一併還原成 MMAP、`m.offset` 換回 cookie。
6. mmap handler：cookie ≥ `COOKIE_BASE` → 查 dbuf、`remap_pfn_range` / `dma_mmap_pages`，`vm_ops` 帶 `.open/.close`；否則走 host 路徑。
7. `session.h`：`struct virtio_media_buffer` 加 `struct vmedia_dbuf *dbuf[VIDEO_MAX_PLANES]`；queue state 加 `driver_owned`。

### 5.4 其他修補

* `virtio_media_driver.c:815` 的 `V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE` → `V4L2_CAP_VIDEO_OUTPUT_MPLANE`（loopback 是 M2M 不受影響，但順手修）。
* `VIRTIO_MEDIA_EVT_ERROR` 的 `/* TODO close session! */`（`:421`）：標記 session dead，之後 ioctl 回 `-ENODEV`、poll 回 `POLLERR`；相機被搶、codec 被 reclaim 時 guest 才有乾淨退出。
* 模組參數：`driver_owned_queues`（§2.1）、`pool_debug`（每次配置印一行）。

### 5.5 DKMS（droidvm-guest-additions）

* `virtio_media/` 目錄 = fork `driver/` 的 vendored 副本 + `linux/` shim 標頭；`sync-virtio-media.sh` 從 fork 同步並記錄 commit。
* `dkms.conf` 加 `BUILT_MODULE_NAME[2]="virtio-media"`、`BUILT_MODULE_LOCATION[2]="virtio_media/"`、`DEST_MODULE_LOCATION[2]="/updates/dkms"`；`Makefile` 兩行；不需要 `gunyah_guest` symvers（v1 非 growable）。
* `hooks.sh:62-65, 192-196` 的 `virtio_gpu` 專屬檢查不用改（guest 沒有 in-tree virtio-media 可取代）。

---

## 6. 行程模型（WP-M3）

2026-09-04 依 `logs/vpu_survey/m3-vhost-user.md` 修訂。目標：`--virtio-media ...,uid=N` 時，media 裝置跑在一個
以 app uid 執行的 vhost-user backend 行程裡（`crosvm device media`），VMM 端是既有的 vhost-user frontend。
相機（M4）需要它；codec 也一律走它（一個行程模型）。

### 6.1 已核實的框架事實

* `DeviceType::Media` 在 frontend 已完整接好（variant、`min_queues()==2`、PCI class），`--vhost-user type=media,socket=`
  今天就能 parse；`MediaDeviceConfig` 已帶 `uid`/`gid`，只差 `device_helpers.rs:1284-1289` 那個 bail。
* backend 端的 `GuestMemory` 由 `SET_MEM_TABLE` 重建（`vhost/user/device/handler.rs:245-258`），**region 沒有 purpose、
  `protected` 永遠 false**（`guest_memory.rs:468-483, :764`）→ `check_host_access` 無條件 Ok、`MediaPoolHandle::from_guest_memory`
  永遠 None、`pool_ref_iovecs` 為 no-op。`find_region` / `shm_region` / `get_slice_at_addr` / udmabuf 都正常。
* frontend 把**所有** region 原樣送給 backend（含 memfd，`vhost_user_frontend/mod.rs:257-275`），只掉 purpose。所以池的 fd 不必繼承，
  給 GPA 就能在 backend 的 region 表找到那條 region（`start == pool_gpa`），fd / fd_offset / size 全部可得。
* frontend 的 shm-region 轉發寫死 `device_type == Gpu`（`vhost_user_frontend/mod.rs:170-176`）→ backend 的 `Bar` 模式拿不到 BAR。
* `access_platform`：snd 的做法是 backend 寫死 `Unprotected`，**由 VMM 把 `access_platform` 蓋進序列化的 params**
  （`snd.rs:98-106` + `device_helpers.rs:631`）；helper 內拿不到 `ProtectionType`，media 照抄。
* `start_queue` 一次給一條 queue；media 的 `Worker` 要兩條 → gpu 的 stash-and-start（`gpu.rs:219-244`）。
* 沒有 jail：app 一律 `--disable-sandbox`，fork 的 `EMBEDDED_BPFS` 是空的，`crosvm device` 不套 jail。`LD_LIBRARY_PATH`/`LD_PRELOAD`
  整組繼承（`$APP/usr/lib` 會遮蔽 `/system/lib64`，`6_build_apk_prepare.sh:28-52` 的舊坑）。
* helper 死掉：VMM 當 crash 處理、VM 結束（`linux.rs:4831-4840`）。v1 接受。

### 6.2 決定

| 題目 | 決定 |
|---|---|
| 池的交接 | `--pool-gpa <gpa>` 一個數字 + `--pool-fd <fd>` 一條 `base::Tube`（`SOCK_SEQPACKET` socketpair，CLOEXEC 與 `--fd` 同法清掉、必填參數——舊 VMM 配新 helper 在 argv 解析就大聲失敗）；backend 在第一次 `start_queue`（mem table 已到）時從 region 表重建 `MediaPoolHandle`、自己 mmap 整個池（`MappedPool`），**但完全不配置**：每個 offset 都經 tube 向 VMM 要（M8 取代 F12 的切片；規則見下方「池由 VMM 統一配置」） |
| Bar 模式 out-of-process | **不支援**。`uid=` 且無 `media_host` 池 → 裝置建立時拒絕（訊息說明）。Gunyah 與有池的 KVM 都走池模式 |
| host 存取的重新閘門 | VMM 從自己的 `GuestMemory`（有 purpose、有 protected）算出「host 可碰的 GPA 視窗」清單（所有池、`StaticSwiotlbRegion`、`SharedGuestRam`、`ShimHandoff`、`SharedFramebuffer`；非保護 VM 則整段 RAM），放進 JSON config；backend 的 `GuestMemoryMapper` 以 `HostAccessPolicy::Windows` 對每條 SG entry range-check，越界回 `EFAULT`。in-VMM 用 `HostAccessPolicy::GuestMemory`（今天的 `check_host_access`）。同一個 trait，兩個實作 |
| 兩條 queue | stash-and-start：兩條都 `start_queue` 後才起 `Worker` 執行緒（與 in-VMM 同一個 `Worker`，抽成共用） |
| 執行緒 | `Worker` 仍是獨立 OS thread（executor 只管 vhost-user 控制面）；相機（M4）另有自己的擷取執行緒 + eventfd 餵 `poll_fd` |
| `access_platform` | VMM 依 `ProtectionType` 蓋進 params，backend 據此加 `VIRTIO_F_ACCESS_PLATFORM`（不重蹈 virtio-snd lent-memory 事故） |
| udmabuf | helper 內 `/dev/udmabuf` 開不了（0600 root）→ `dmabuf()` 回 Err；v1 無消費者，維持 |
| 啟動 | `snd_helper.rs` 泛化為 `device_helper::launch(subcommand, params_json, uid, gid, supp_gids)`；exec 不 fork；`PR_SET_PDEATHSIG`；pid 進 `worker_process_pids` 與 `pid_debug_label_map`（crash log 才有名字） |

**池由 VMM 統一配置（2026-09-06 M8 取代 F12 的靜態切片；缺陷 D49、F12 追蹤項 1、review-m8）。**
`pool.rs` 的不變式沒變：池「必須是整個 VM 共用的——兩個各自持有私有 allocator 的裝置在同一個視窗上都會發出
offset 0、0x1000、…，guest 就把同一段實體記憶體映射成兩個互不相干的 buffer」。D49 的洞是三個 `HelperOnly`
行程各自在同一個 256 MiB 視窗上重建 allocator；F12 用靜態切片（權重 64/128/64）堵住了 aliasing，但切片是牆：
ffmpeg 的 4K 解碼要 ~20 個 CAPTURE buffer（~190 MiB），無論相機和編碼器多閒也塞不進解碼器的 128 MiB 切片
（F12-encoder §4.1、B10 §4.1 觀察項）。M8 拆牆的方式是拆掉 helper 的 allocator 本身。

**規則**：整個 VM 只有一個 allocator——VMM 內的 `MediaPoolAllocator`。in-VMM 裝置照舊直接持 lease；
helper 完全不配置：經 `--pool-fd` 向 VMM 要每一個 offset，自己只保留整池的 mmap（`MappedPool`）
在拿到的 offset 上建 `HostBuffer`。VMM 為每個 helper 起一條 `media pool <card>` 執行緒，持有該 helper 的
lease、逐一回答（pool 鎖只在 reserve/unreserve 內、不跨 tube 操作；client 的 send/recv 與 server 的 send
都以 `POOL_RPC_TIMEOUT`（5 s）為界）。guest 可見的契約不變（offset 仍在 `[0, pool.size)`，guest 仍映射
`media_host base + offset`）；`MediaBackendParams` 不再有 `pool_slice`（`deny_unknown_fields` 讓混版 JSON
大聲失敗），權重、`carve_slices`、`with_slice` 全數移除。

**協定**（`pool.rs`，serde-JSON over `SOCK_SEQPACKET`，不傳 fd）：`Hello{card}` 是新 tube 上的第一則、
唯一不回答的訊息——helper 報上自己真正的 card 字串（`droidvm decoder`、`camera <id>`…），server 執行緒此後的
log 行與執行緒名都採用它（VMM 的 launch 行保留 kind + card 供對照）。其餘都帶 `id`（client 的計數器）：
`Reserve{id,len}` → `Reserved{id,offset}` / `Errno{id,errno}`（`ENOMEM`＝池滿、`EINVAL`＝零或荒謬長度）；
`Release{id,offset}` → `Released{id}`（非本人的 offset 由 VMM 記 error 並拒絕、仍回 ack）；
`ReleaseAll{id}` → `Released{id}`（＝`release_owner` 但 lease 不掉）。逾時只毀那一次請求（`EIO`），
下一趟把遲到的舊 id 答案排掉（bounded drain）重新同步；只有 `Disconnected` 才把連線標死。
tube 與計數器在同一個 Mutex 後面、橫跨 send+recv 持鎖——「同時最多一個未答請求」由型別保證。

**回收**：sweep（lease 掉落 → `reclaiming N media_host buffers …`）只在 **EOF** 上發生——EOF 是唯一證明
helper 行程已死、不可能再寫它手上 buffer 的事件；其他任何 tube 錯誤都保住 lease（log 一次、繼續服務；
連線真的不能用就 park 在 blocking recv 上等 EOF）。virtio reset（裝置在 helper 內被拆、行程活著）由兩層歸還：
`RemotePoolAllocator::Drop` 逐一 `Release` 它記得的未還 offset，`MediaBackend::stop` 再補一發 `ReleaseAll`。
helper 死亡本身照 §6.1：非乾淨退出仍是 `ExitState::Crash`、VM 結束（M3 §5.1，v1 接受）；sweep 讓這條路
與清乾淨退出的池帳目一樣乾淨，將來若把 helper 死改成可存活，池這邊不必再動。

log 可見（`deploy/vpu/README.md`）：VMM 的 `launched media helper: … pool served by the VMM over fd N …`、
helper 的 `serving MMAP buffers from the media_host pool (gpa …, 256 MiB), allocated by the VMM`、
每次 Release/ReleaseAll 後的 `pool: "<card>" holds N bytes, pool used M of S`、滿了的
`media_host pool exhausted for "<card>": …`（處置：真的整池都不夠才把 `media-host-mb`（app `VpuConfig`，
預設 256）加大）、EOF 的 `the pool connection for "<card>" is closed` ＋ reclaim 行。

### 6.3 WP M3 清單

1. `devices/src/virtio/media.rs`：把 `Worker`、`EventQueue`、`HostMapper`、`PoolBufferAllocator`、`GuestMemoryMapper` 抽成 in-VMM 與 backend 共用；
   `GuestMemoryMapper` 加 `HostAccessPolicy`。
2. 新 `devices/src/virtio/vhost/user/device/media.rs`（+ `sys/linux.rs`）：`MediaBackend` 實作 `VhostUserDevice`
   （features 含 access_platform、protocol features、`max_queue_num=2`、`read_config` 回 `VirtioMediaDeviceConfig`、stash-and-start、`reset` 停 Worker）；
   `run_media_device(opts)`：`--fd N --config-json ...`，config 帶 `MediaDeviceConfig` + `pool_gpa` + `access_windows` + `access_platform`。
3. `src/crosvm/cmdline.rs` `DevicesSubcommand::Media`、`main.rs` 分派。
4. `src/crosvm/sys/linux/device_helper.rs`（泛化自 `snd_helper.rs`；snd 改用它）；`device_helpers.rs::create_virtio_media_device` 的 `uid` 分支：
   算視窗、組 params、launch、以 VMM 端 socket 建 vhost-user frontend（`type=media`）；`sys/linux.rs` 記 pid。
5. app 端不用改（`uid=` 已出）。
6. 驗收：`--virtio-media kind=loopback,card=lb0,uid=<app uid>` 與 `kind=simple,uid=` 各跑一次 smoke（三種 driver 模式）+ v4l2-compliance；
   `ps` 看到 `crosvm device media` 以 app uid 執行；SG 越界（假 USERPTR）回 EFAULT 而非 helper 死亡；helper 被 SIGTERM 時 VMM 的處置與 log；
   in-VMM 路徑（無 `uid=`）不退化。

## 7. 相機與編解碼（沿用舊 plan §3–§5，修訂如下）

### 7.1 相機裝置（WP-M4 = 舊 plan A1，2026-09-04 定案）

**分層**：crate 內的 `devices/camera.rs` 是通用的 V4L2 capture 裝置，透過 `CameraBackend` trait 取幀與控制，
不含任何 Android 程式碼；Android 實作 `AndroidCameraBackend` 放在 crosvm（`devices/src/virtio/media/android_camera_backend.rs`，
`cfg(target_os = "android")`，用既有的 `android_camera` crate）。裝置永遠跑在 M3 的 helper（app uid）裡；
in-VMM 的 `kind=camera` 沒有 `uid=` 一律拒絕（root 開不了相機，plan §2.2）。

**crate trait**（形狀，實作時以編譯為準）：

```rust
pub struct CameraInfo { id, name, sizes: Vec<(u32,u32)>, frame_intervals: per size, zoom_range, af_modes, flash, ae_modes,
                        fps_ranges, exposure_range_ns, iso_range, awb_modes, antibanding, effects, scenes, stabilization,
                        max_regions, active_array }
pub trait CameraBackend: Send { type Stream: CameraStream;
    fn info(&self) -> &CameraInfo;
    fn open_stream(&mut self, w, h, fps: (u32,u32), sink: CaptureSink) -> Result<Self::Stream, i32>; }
pub trait CameraStream: Send {
    fn poll_fd(&self) -> BorrowedFd;                       // eventfd：每幀 / 每個事件 +1
    fn take_filled(&mut self) -> Vec<FilledBuffer>;        // {index, bytesused, timestamp_ns, sequence}
    fn give_empty(&mut self, b: EmptyBuffer);              // {index, ptr(SendPtr), len, stride}
    fn set_controls(&mut self, ctrls: &[CameraControl]) -> Result<(), i32>;   // 一次 submit
    fn get_control(&self, id) -> ...; fn take_events(&mut self) -> Vec<CameraEvent>;  // AF_STATE 等變更（A3）
    fn close(self); }
```

**執行緒與資料流**（依 M3 survey 的約束：`Camera` 是 `!Send`、`next_frame` 阻塞、executor 單執行緒）：
`AndroidCameraBackend::open_stream` 起一條**擷取執行緒**擁有 `Camera`；Worker（裝置執行緒）把空的 CAPTURE buffer
（池內 host 指標 + 長度）經 channel 借給擷取執行緒；擷取執行緒在 `AImageReader` callback/`next_frame` 後**直接拷進池 buffer**
（逐行、緊排 `bytesperline = width`、NV21 → NV12 chroma swap；`dump_frame` 記錄的最後一列少一 byte 的怪癖要處理），
回傳 `FilledBuffer` 並對 eventfd `+1`；Worker 的 `process_events` 收回、發 DQBUF 事件。一次拷貝。
借出中的 buffer 由擷取執行緒獨占；STREAMOFF/REQBUFS(0)/CLOSE 先 `close()` 擷取執行緒（join）再釋放 buffer（§2.5）。

**V4L2 面**：`V4L2_CAP_VIDEO_CAPTURE_MPLANE | STREAMING`；格式只有 `NV12`（1 plane）；ENUM_FRAMESIZES = characteristics 的
YUV_420_888 尺寸；ENUM_FRAMEINTERVALS 由 `SCALER_AVAILABLE_MIN_FRAME_DURATIONS` + `AE_AVAILABLE_TARGET_FPS_RANGES` 導出；
S_FMT 串流中回 EBUSY；G/S_PARM 的單值 fps → 最寬且 max==V 的支援區間（舊 plan D12 第 12 列）；REQBUFS 接受 MMAP（host-owned，池）
與 USERPTR（guest-owned CAPTURE，`driver_owned_queues=all`）；STREAMON 才 `open_stream`（首幀 ~256 ms），STREAMOFF 就關（把相機還給 Android）。
多裝置 = 多相機 id（一裝置一 session）；Main/Aux 分組（舊 plan §3.2）留到 M5。

**控制項（M5 = 舊 plan A2/A3）**：照舊 plan §3.1 表；數值約定：zoom ×100（min 67 on 5566）；**曝光採 V4L2 標準單位 100 µs**
（5566 的 85 µs 下限取整為 1，損失可忽略；不另立私有單位）；ISO 從 `SENSOR_INFO_SENSITIVITY_RANGE` 合成選單（100/200/…/16000）。
AE 狀態機 `(EXPOSURE_AUTO, FLASH_LED_MODE) → AE_MODE` 在 backend；`V4L2_EVENT_CTRL` 由 capture-result callback 產生、
只在值變更時發（AF_STATE、AE_STATE、active physical id）。**stream use case 沒有 NDK API → 放棄**（舊 plan D18(2)）。

**`android_camera` 要補**（crosvm，同一 WP）：Cargo workspace member、`libc` 進 `[dependencies]`、`libandroid_camera` 進
`devices/Android.bp` 與 `crosvm_device_only/Android.bp` 的 rustlibs；`open()` 錯誤路徑的資源釋放（RAII）；state callbacks 帶 context
（斷線/錯誤 → 事件 → session dead）；`ACaptureRequest_setEntry_i64`、AF_TRIGGER、各 `AVAILABLE_*` 與 range 讀取、rational 讀取；
capture-result callbacks（`ACameraCaptureSession_captureCallbacks`，8 欄位，在 callback 內讀 result）；
可選 `AImageReader_acquireLatestImage`（慢 guest 時丟舊幀）。

**驗收（= 舊 plan A1）**：在 5566 pVM、helper 以 app uid 執行、app 的 FGS 已撐著：guest `v4l2-ctl --all` 認得、
`--stream-mmap --stream-count=60 --stream-to=` 60 張幀非黑且會動（luma digest 不同）、`ffmpeg -f v4l2 -i /dev/videoN -t 5` 錄到會動的畫面、
gst `v4l2src ! fakesink` 跑通；另跑 `driver_owned_queues=all`（幀寫進 `media_guest`）與 pseudo-unprotected 各一輪。
前置 smoke：先用既有 `camera_probe capture --uid <app uid>` 在 5566 上確認 app 前景 + FGS 下相機開得了（舊 plan §0 的量測從未在 5566 做過）。

**已接受的 `v4l2-compliance` 失敗（D22，2026-09-05 定案，B8 量測更新）**：M5 的控制項落地**之前**，
`v4l2-compliance -d /dev/video0 -s` 在 5566 上跑完是 59 / 56 / 3（`logs/vpu_wp/B5-acceptance.md` §4.6）；
控制項落地**之後**一度是 **59 / 54 / 5**（`B7-ship.md` §5.3、`B7-controls.md` §15），多出來的兩條都是控制項的：
**D33**（`VIDIOC_QUERY_EXT_CTRL/QUERYMENU`，M5b 修掉：`V4L2_CID_PRIVATE_BASE + n` 的 alias 在五個 ioctl 一致解析）
與 **D34**（`VIDIOC_G/S/TRY_EXT_CTRLS`，F10 修掉：compound payload 走 pool 內的 bounce buffer，即本節下面所說的設計選項 (a)）。
**兩條都已經修好**，所以現在的基準回到落地前的數字：**59 / 56 / 3**（B8 §4 實測，`B8-acceptance.md` §4 逐條列名，
且 `VIDIOC_G/S/TRY_EXT_CTRLS` 與 `VIDIOC_QUERY_EXT_CTRL/QUERYMENU` 兩項都讀 `OK`）。

**三條不修、驗收以此為準**：
(1) `VIDIOC_S_FMT` 的 `testGlobalFormat`（`v4l2-test-formats.cpp:1161` `Global format mismatch`）——virtio-media 的格式
屬於每個 `open(2)` 的 session 而不是裝置，這正是「每個 format 測試都能是一次獨立的 `v4l2-ctl` 呼叫」成立的原因；
把 session 狀態上移到裝置等於重做整個 fork 的 session/stream 生命週期，不划算；
(2)(3) `USERPTR (no poll)` 與 `USERPTR (select)`——compliance 送的是它自己 malloc 的指標，protected VM 下 host 不能碰
（§2.3 / §2.4），B4 的 loopback 也是同樣這兩條，是**要求的行為**不是缺陷。

**D34 的收尾（原本列為第四條，已不再是）**：compound control 的 payload 是**應用自己那一頁**，而 camera 是
`HelperOnly`、helper 只能碰 pool（§6.2），所以 `VCAM_CID_AE_REGIONS` / `AF_REGIONS` 的 `G`、`S`、`TRY_EXT_CTRLS`
三個方向一度一律 `EFAULT`（B7-controls §9）。當時列出的兩個處置裡，**F10 走了 (a)：payload 經 pool 中轉**
（driver r19 的 bounce buffer），六個方向都精確 round-trip、越界回 `ERANGE`、AF 真的會對焦（B8 §5），
compliance 那一條也跟著消失。tap-to-focus / tap-to-meter 在出貨組態上**可用**，21 個控制項全數不受影響。

**三個「有回音但不改變畫面」的模式（D36，advisory）**：`AUTO_N_PRESET_WHITE_BALANCE`、`COLORFX`、`SCENE_MODE`
在 5566 上會被 HAL 接受並在 capture result 裡原值回報（ECHOED），但 YUV_420_888 的 reader session 拿到的畫素完全不變
（B8 §6：`Negative` 的 luma/U/V 與 `None` 相同）。**保留這三個控制項並記為 advisory**：值收得下、讀得回、不保證有畫面效果；
`V4L2_CTRL_FLAG_INACTIVE` 會是謊話，而 V4L2 沒有「best effort」旗標。判斷「HAL 丟掉」與「還沒輪到」要看
**result 自己那一份 request**（`ACaptureRequest_getConstEntry`），不能數 result 的張數——後者就是 D47（F11-misc 修掉）。

### 7.2 解碼器（WP-M6 = 舊 plan B1–B3，2026-09-04 定案）

事實來源：`logs/vpu_survey/mediacodec-ndk.md` §1–§5、`device-5566-host.md` §3–§4。

* **`android_codec` crate（crosvm）**：抄 `android_camera` 的 `ndk_api!` 形狀，只開 `libmediandk.so` + `libbinder_ndk.so`；
  API 36 的 `AMediaCodecStore_*` / `AMediaCodecInfo_*` / `ACodec*Capabilities_*` 一律**可選符號**（缺了不致命，退化成固定候選 + `isFormatSupported` 探測）；
  binder threadpool 照樣起（MediaCodec 反向服務 `BnResourceManagerClient`）。附 `codec_probe` 二進位（同 `camera_probe` 的 build/phony 形狀）：
  `list`（Store 列舉 + 每個 codec 的能力）、`decode --in x.h264 --out y.nv12`（真機驗證 `image-data` 版面與 `getOutputBuffer` 指標是否已含 `mPlane[0].mOffset`，survey 開放問題 1）。
* **能力列舉（回答「不寫死」）**：`AMediaCodecStore_getSupportedMediaTypes` 取 `FLAG_DECODER` 的 mime → 每個 mime `findNextDecoderForFormat` 迭代 →
  預設只留 `HARDWARE_ACCELERATED`（`allow_sw=true` 才含軟體）→ `getCanonicalName` 才是 `createCodecByName` 用的名字 →
  `getVideoCapabilities` 的 width/height range + alignment → `ENUM_FRAMESIZES`（stepwise）、`getSupportedFrameRatesFor` → `ENUM_FRAMEINTERVALS`。
  mime ↔ V4L2 OUTPUT fourcc：`video/avc`→`H264`、`video/hevc`→`HEVC`、`video/x-vnd.on2.vp9`→`VP90`、`video/av01`→**`AV01`**、`video/x-vnd.on2.vp8`→`VP80`。
  （`AV01` 是 `videodev2.h` 的 `V4L2_PIX_FMT_AV1` = `0x31305641`。這裡原本寫 `AV10`，是 **D54**，2026-09-06 由 polish 修在四個站點；
  改對之後 `v4l2-ctl --list-formats-out` 與 compliance 的 `-v` 都讀得到 `AV01`，但 census 沒有動——原因見下面的 **D59**。）
  Store 的 lazy static 無鎖 → 裝置建立時單執行緒暖機一次。
* **一個解碼裝置 = 全部硬體解碼器**：`ENUM_FMT(OUTPUT)` 列所有 mime；`S_FMT(OUTPUT)` 選 codec；`STREAMON(OUTPUT)` 才 `createCodecByName` + configure
  （`surface = NULL`、`KEY_COLOR_FORMAT = YUV420Flexible`、`KEY_MAX_INPUT_SIZE`、低延遲可選）+ `setAsyncNotifyCallback` + start。
* **CAPTURE 格式政策**：對 guest 只廣告 **NV12 單 plane、緊排**（`bytesperline = width`）。每個輸出 buffer 用 `AMediaCodec_getBufferFormat(idx)` +
  `AMediaFormat_getBuffer("image-data")` 讀 `MediaImage2`（104 bytes、`#[repr(C, packed)]`），用通用 plane walk 拷進池內 CAPTURE buffer 並重排成 NV12。
  一次拷貝（與相機同），不嘗試以 `bytesperline`/`sizeimage` 表達 QC 的 stride/slice 版面（舊 plan D29 的「零拷貝表達」放棄：copy 反正要做）。
  `crop` 由 `KEY_DISPLAY_CROP`/`display-width/height` 導出 → `G_SELECTION`。
* **crate 端**：沿用 `video_decoder.rs`（整套 stateful 狀態機），補：OUTPUT queue 接受 USERPTR（guest-owned 位元流；`new_mapping_for(readonly)`，持有到 `InputBufferDone`）、
  CAPTURE 接受 USERPTR（`all` 模式）、`streamoff(OUTPUT)` 通知 backend flush（seek，舊 TODO :1054）、`subscribe_event` 加 `Eos`/`SourceChange` 的 `SEND_INITIAL`、
  `StreamFormatChanged` 事件填 sequence/timestamp。`VideoDecoderBackend` trait 依實作需要微調（例如 `flush()`）。
* **backend `MediaCodecDecoderBackend`（crosvm，android）**：**async 模式**（舊 plan D26）；四個 callback 在 NDK looper thread 上只做入列 +
  eventfd（`poll_fd`），不做重活；Worker 的 `process_events` 取事件：`onAsyncInputAvailable` → 把待送的 guest 位元流拷進 `getInputBuffer` 並 `queueInputBuffer(pts µs, flags)`；
  `onAsyncOutputAvailable` → 取下一個排隊的 CAPTURE buffer 重排拷貝 → `releaseOutputBuffer(render=false)` → `FrameCompleted{bytes_used, timestamp, is_last: EOS flag}`；
  `onAsyncFormatChanged` → `StreamFormatChanged`（coded size、`min_output_buffers` = 4 + 保守值）；`onAsyncError` → `AMEDIACODEC_ERROR_RECLAIMED` 等 → error event、session dead。
  `drain()` = `queueInputBuffer(EOS)`；seek = `AMediaCodec_flush()` **然後 `start()`**（async 規則）；`AMediaCodec_stop` 阻塞，只在 Worker 上呼叫。
* **驗收**：舊 plan B1（`codec_probe decode` 出正確 YUV、列出 Store 清單）、B2（guest 解成 rawvideo 對軟解做 md5/SSIM；DRC 片；中途 seek）、
  B3（VP9、HEVC；AV1 待 guest 的 gst 1.28.1+ `v4l2av1dec`，5566 的 gst 是 1.28.2 → 可試）。全部在 helper（app uid）內跑；codec 不需要 FGS。
  **驗收的客戶端是 GStreamer，不是 ffmpeg**（2026-09-06 依 `logs/vpu_wp/B9-acceptance.md` 修訂）：B9 §2 用
  `v4l2h264dec` / `v4l2h265dec` / `v4l2vp9dec` 各自解到 EOS，輸出與軟解**逐位元相同**（h264 300 張、h265 300 張、vp9 60 張），
  DRC 片 **120/120、兩段都出**（§2.3）。ffmpeg 的結果要照下面第一點讀。
  * **D27（DRC 停在 60/120）與 D27b（drain 之後不續播；`-stream_loop 2` 只出 300/900）改記為 ffmpeg 客戶端的限制，不是裝置缺陷。**
    同一個檔、同一個裝置，gst 走完 120/120（B9 §2.3），ffmpeg 五跑五次都停在 60（B9 §3.1）；而 ffmpeg 的 `v4l2m2m` 解碼器
    **沒有 `.flush` callback**（`v4l2_m2m_dec.c` 的 `M2MDEC` 巨集，F11-decoder §(3) 讀過原始碼），所以第一次 EOF 之後
    `s->draining` 一直為真、後續封包永遠不會入列。裝置這一側是合規的（crate 在 `DEC_CMD_START` 或 `STREAMOFF/STREAMON`
    之後續播，fork 有單元測試釘住）。誠實的說法是「動態解析度切換可用；ffmpeg 的 `v4l2m2m` 客戶端不會重啟 CAPTURE」，
    文件不再寫「裝置停在 60」。
  * **D28 與 D48 是同一個缺陷**（B9 §3.3、§4.1）：codec 還無法從收到的位元流宣告格式時，第一個 OUTPUT buffer 被無限期扣住，
    於是（a）`v4l2-compliance -d /dev/video1 -s` 卡在**第一個** streaming 子測試、（b）`ffmpeg -c:v h264_v4l2m2m` 解自家相機
    錄出來的 mp4 一張都出不來（D44：ffmpeg 的 muxer 把 SPS/PPS 寫成 31 bytes 的獨立 sample，正好是那個「宣告不出來」的輸入）。
    **這是唯一擋出貨的一條**，驗收門檻三條都要過：`pollrace.py /dev/video1 /tmp/small.h264` 要回得到 POLLOUT、
    `ffmpeg -c:v h264_v4l2m2m -i cam.mp4` 要跑完、`v4l2-compliance -d /dev/video1 -s` 要過得了第一個 streaming 子測試。
  * **`v4l2-compliance` 的預期值**（2026-09-06 依 `logs/vpu_wp/B11-acceptance.md` §3 改寫。這一格的歷史值得記著：
    B9 之後這裡寫過「D50 修好之後應回到 48 / 47 / 1」，被 B10 證偽；B10 之後又寫了一次同一個預測，
    理由換成 D54，**再度被 B11 證偽**。兩次都是在沒有讀過 `v4l2-compliance` 原始碼的情況下對它的行為下注。
    下面全部是量測，沒有預測）：

    | 節點 | 呼叫 | Total / Succeeded / Failed | 失敗的來由 |
    |---|---|---|---|
    | 解碼器 `/dev/video1` | 不帶 `-s` | **48 / 46 / 2** | **D30**（`VIDIOC_G/S_PARM`）與 **D59**（`testEvents` 分類）——根因都是 **D70**（工具側，見下）|
    | 解碼器 `/dev/video1` | 帶 `-s` | **跑不完**：`rc=124`，停在 `Video Output Multiplanar: Frame #002`，卡在 `virtio_media_dqbuf(CAPTURE)` | **D70**（工具側）：設計如此的死結，**不是裝置缺陷**（見下）——D58 由 B14 定案為 D70 |
    | 編碼器 `/dev/video2` | 不帶 `-s` | **48 / 48 / 0** | — |
    | 編碼器 `/dev/video2` | 帶 `-s` | **55 / 50 / 5** | 一個根因 `v4l2-test-buffers.cpp(398): !g_bytesused(p)` 加四條連鎖 = **D43**，接受 |
    | 相機 `/dev/video0` | 帶 `-s` | **59 / 56 / 3** | §7.1 那三條，接受 |

    **為什麼不帶 `-s` 停在 48 / 46 / 2，而且會一直停在這裡（D59）。** 失敗的第二條是
    `v4l2-test-controls.cpp(1180)` —— `testEvents` 的分類斷言。它會炸是因為節點**沒有被認成 stateful
    decoder** 卻帶著 D29 給的 `V4L2_CID_MIN_BUFFERS_FOR_CAPTURE`，而分類是 `determine_codec_mask()`
    走 `ENUM_FMT` 決定的：碰到第一個它不認得的壓縮格式就 `default: return`，`codec_mask` 留在 0。
    那個格式是 AV1。**D54 是真的，也修好了**（`AV10` → `AV01`，四個站點：crosvm 的
    `android_codec_backend/android.rs:265`、`android_codec_backend/android_encoder.rs:190`，fork 的
    `video_decoder.rs:209` 與 `video_encoder.rs:293` 的 `fourcc_description`；binary 裡 `AV10` 0 命中），任何以 fourcc 比對的客戶端現在看得到 AV1；
    但它買不到這一分：`v4l2-compliance` **1.32.0** 的 `determine_codec_mask()`
    （`v4l2-compliance.cpp:511-610`，B11 整段讀過）在 OUTPUT 側只認
    `H263 / H264 / H264_NO_SC / H264_MVC / MPEG1 / MPEG2 / MPEG4 / XVID / VC1_* / VP8 / VP9 / HEVC / FWHT`
    → `STATEFUL_DECODER`，以及 `MPEG2_SLICE / H264_SLICE / HEVC_SLICE / VP8_FRAME / VP9_FRAME /
    AV1_FRAME / FWHT_STATELESS` → `STATELESS_DECODER`。**`V4L2_PIX_FMT_AV1` 在整個函式裡不存在**
    （`grep -n AV1` 只有一筆，line 596，是 stateless 的 `AV1_FRAME`），所以拼對的 `AV01` 和拼錯的 `AV10`
    落在同一個 `default`。這是 **D59**，工具的限制，不是裝置的缺陷。
    **處置：AV1 繼續廣告**（客戶端看得到才是重點，設計 §11.5「不寫死」），這一格的預期值就是 **48 / 46 / 2**；
    要它變成 48 / 47 / 1 只有兩條路，都不划算：等 upstream v4l-utils 加一個 case，或把 AV1 從
    `CODED_FORMATS` 拿掉——後者是為了工具的分數而讓真客戶端看不到一個真格式。
  * **D58 = D30 = D59 = 同一條工具限制，B14 定案為 D70**（2026-09-13 依 `logs/vpu_wp/B14-accept-A.md` §3 補）。
    B14 讀了 `v4l2-compliance.cpp:567-601` 的 `determine_codec_mask`：它 switch 每一個壓縮 OUTPUT 格式，
    結尾是 `default: return;`——一個發生在 `node.codec_mask = mask`（`:607-610`）**之前**的早退。`AV01` 不在任何一個
    arm（v4l-utils 1.32.0 只認 stateless 的 `'AV1F'`；這台 kernel 的 `videodev2.h` 連 `V4L2_PIX_FMT_AV1` 符號都沒有），
    所以碰到 OUTPUT 的第四個格式就早退，`codec_mask` 留在 `0`。**節點於是從來沒被認成 stateful decoder**：
    compliance 對 encoder 印 `Detected Stateful Encoder`，對這個 decoder **一條 `Detected …` 都不印**（B14 §3.3 的鐵證）。
    連鎖三條：(a) `-s` 的 streaming 測試永遠不下 `V4L2_DEC_CMD_STOP`（`v4l2-test-buffers.cpp:1335` 要
    `node->codec_mask & STATEFUL_DECODER`），於是 `:1345-1348` 的 blocking `DQBUF(CAPTURE_MPLANE)` 等一個
    zero-filled 位元流永遠生不出來的畫格——這就是 **D58** 的死結（B14 量到：裝置早已把三個 OUTPUT buffer
    全數經 grace 交回，之後靜默 279 s）；(b) `testEvents` 的 `MIN_BUFFERS_FOR_CAPTURE` 存在斷言
    走 else arm = **D59**；(c) `G/S_PARM` 的 `node->is_m2m && !is_stateful_enc` 斷言 = **D30**。三條同一個根因。
    **上游修法（一段話的草稿）**：在 `determine_codec_mask` 的 stateful switch 裡，於 `default: return;` 之前，
    為 `V4L2_PIX_FMT_AV1`（`v4l2_fourcc('A','V','0','1')`）加一個 `case … mask = 1 << STATEFUL_DECODER; break;`
    ——與 `HEVC`/`VP9` 同排；這樣 `codec_mask` 才會被設，`-s` 才會下 `DEC_CMD_STOP` 而不是卡在 `DQBUF(CAPTURE)`。
    （這是給 v4l-utils 的 patch，不是給 DroidVM 的：裝置這一側完全合規，AV1 是一個真格式。）
  * **D48 修好了，但同一個提前釋放開了兩個新洞；D55 + D56 是 WP-F13 的題目，要當成一件事修**
    （2026-09-06 依 B10-acceptance §1.4、§2.2、§13 補）：
    * **D55**：SOURCE_CHANGE 之前的提前釋放會把「正在等第一個 SOURCE_CHANGE、因此停止餵資料」的客戶端的 OUTPUT queue
      清空。mainline 的 `v4l2_m2m_poll_for_data` 在 CAPTURE 未 streaming 且 OUTPUT 空時回 `POLLPRI|POLLERR`，
      而 GStreamer 的 `gst_v4l2_object_poll` 把 `POLLERR` 當致命——**這正是 D45 原本的機制**。
      DRC 片在 gst 下 **20 跑 4 敗**（0 張），純串流不受影響（codec 從第一個 buffer 就宣告得出格式，釋放根本不會觸發）。
      F12-decoder 當時的安全論證是「會回應 POLLOUT 去餵下一個 buffer 的客戶端，OUTPUT queue 不會空」——
      gst 的 `wait_for_src_ch` 刻意不餵，這個案例在出貨前就是紙上可查的。
    * **D56**：500 ms 的 `DEFERRED_INPUT_DONE_DEADLINE` 只在 backend 被喚醒（codec callback）時評估，不是計時器。
      餵了消化不了的位元流之後就沉默的 codec，會讓客戶端**永遠**停在那裡：解碼器的 `-s` 實測
      `3 bitstream buffers in, 0 frames out`、24.6 分鐘 0 個 callback、1500 s `rc=124`。這是 guest 今天就碰得到的無限期停擺。
    * **兩者是同一個設計題**：這個扣住必須 (i) 在 SOURCE_CHANGE 之前結束時**不把客戶端的 OUTPUT queue 清空**
      （例如最多釋放 N-1 個，或在 SOURCE_CHANGE 未決期間壓住 POLLERR 條件），且 (ii) 依**真時鐘**結束
      （helper poll loop 裡的 timerfd；fork 的 `poll.rs` 今天只 poll session eventfd）。
      只修其中一個會重新打開 D48（沒有上界）或 D45/D55（順序錯、queue 空）。
    * F13 的驗收門檻（全部是已有的量測設施）：gst DRC **20/20**、20 KB `pollrace.py` 仍拿得到 POLLOUT、
      200 KB 仍是 POLLPRI 先到、解碼器 `-s` **會結束**（分數不拘，這個節點從來沒有過一個分數）、
      不帶 `-s` 回到 48 / 47 / 1、故事的 decode-back 仍與軟解逐位元相同。
  * **F13 交出了什麼，還剩什麼**（2026-09-06 依 `logs/vpu_wp/B11-acceptance.md` 補，六條門檻過了四條）：
    * **D55 修好**：gst DRC **20 / 20**（B10 是 16/20），零 `poll error`，二十跑同一個 md5。
      規則是「宣告即釋放」——能宣告的串流二十跑**沒有一次**走到 grace（§1）。
    * **D56 在它自己的案例上修好**：`GraceTimer`（每個 session 一條執行緒、真時鐘）在 250 ms 放行，
      20 KB 的 `pollrace.py` 五跑都在 **0.287–0.299 s** 拿到 POLLOUT，POLLERR 從未出現；
      200 KB 五跑 POLLPRI 與 POLLOUT 同一次喚醒（D45 的順序完好）。
    * **但 `-s` 還是跑不完，缺陷換成 D58**：楔子往後挪了一個 buffer——codec 現在**會**宣告
      （`3 bitstream buffers in, 0 frames out, 0 seek(s), 1 format change(s)`），客戶端卡在
      `SOURCE_CHANGE` **之後**的 `DQBUF(OUTPUT)`，正是 `awaiting_format()` 為 false、grace 蓋不到的窗。
      兩跑同形，節點事後完全恢復。這條是「guest 今天碰得到的無限期停擺」的殘餘，也是這個節點
      **從來沒有過一個 `-s` 分數**的原因。
    * **不帶 `-s` 沒有回到 48 / 47 / 1，而且不會**：見上面的 **D59**。這條門檻本身是錯的，不是沒達成。
    * **D53 不是「只發生在冷 codec」**：B11 連續解同一個檔十次，**1 次**丟了 49 張
      （`seek #1: 12 pending input(s) and 6 held output(s) dropped`），重啟後的三次冷解都逐張正確；
      同樣的簽名在 F13 之前的 F12 版本上也找得到，所以 250 ms 的扣住沒有把它變大。
      機制是 ffmpeg 在 reinit 時對 OUTPUT 下 `STREAMOFF`，`flush()` 依約丟掉 staged 的位元流。
      F13 §4 的規格論證（`STREAMOFF(OUTPUT)` 是 seek，`dev-decoder.rst` 說客戶端不該在第一個
      `SOURCE_CHANGE` 停 OUTPUT queue，所以裝置丟得對）**仍然成立**；被證偽的是它的經驗前提
      ——「只在冷 codec 上出現，因為冷 codec 宣告得慢」。**F15-decoder 已定案並落地，規則寫回這裡**
      （fork `029d85c` + crosvm `a6b1d8d`，2026-09-06；`logs/vpu_wp/F15-decoder.md` §1.1）：
      **在「格式變更未決」的窗內收到的 `STREAMOFF(OUTPUT)` 是 reinit，不是 seek**——`SOURCE_CHANGE` 已送出、
      CAPTURE 還沒為它（重新）`STREAMON` 的那段期間，裝置保住 staged 的位元流與 codec 手上的畫格與格式
      （session 旗標 `format_change_pending`，在 `FormatChanged` 設、在 `streamon(CAPTURE)` 與
      `V4L2_DEC_CMD_START` 清；backend 走新的 `reinit()` 而不是 `flush_and_restart`，印
      `decoder session N: reinit: keeping M staged input(s) across STREAMOFF(OUTPUT)`），CAPTURE 重開後照餵照送。
      窗外的 `STREAMOFF(OUTPUT)`（穩態、或還沒宣告過）**仍然是 seek**，照約定丟 staging——F13 §4 的規格論證沒有被推翻，
      只是被縮到它成立的範圍。**這條還沒在手機上量過**：B12 驗收的二進位（`ae3f7dd6…`）比這兩個 commit 早，
      所以 D53 要由 B13 用同一支檔連解十次（今天是 1-in-10）才算關。

  * **B12 在這個節點上新加的兩條——D64（與編碼 session 同時起就安靜掉張）與 D69（CAPTURE buffer 給太少安靜截斷，
    而裝置宣告的 `min 4` 與控制項回的 `1` 都遠低於 codec 真正的 `num-output-slots` 21）——連同 D62–D68
    記在 §7.4 末的缺陷帳裡，這裡不再各記一份。**
  * **D64 由 B14 重新定案，F16 §4.1「F15 的 reinit 規則關掉它」被推翻，F17 修好**（2026-09-13 依
    `logs/vpu_wp/B14-accept-A.md` §4 與 `logs/vpu_wp/F17.md` 補）。B14 量到 1080p decode+encode 同開 **0/6** 逐位元、
    5/6 是 B12 那個錯 md5 `34c34d37…`——**而且 `0 seek(s)`、`reinit: keeping 0`**：損害根本不在 seek/reinit。
    機制是 **D55/D56 grace 對「只有一個 OUTPUT buffer 在飛」的客戶端形成節流**：contention 下 codec 要 **7.56 s**
    才宣告，那段窗裡 grace 每 250 ms 才放一個 `InputBufferDone`，ffmpeg（一個 buffer、反覆重排 index 0）於是被限到
    ~4 packets/s——**30 條 grace 線精準對應 30 張丟失的畫格**（沒有 grace 線的 session 只掉 0–3 張）；per-frame md5 顯示
    頭尾完好、中段一條 ~60–70 張的帶（丟的畫格加上到下一個 IDR 之前所有引用它的畫格）。gst 排很多 OUTPUT buffer、不受節流，
    同樣 contention 下 300/300（3 跑 2 中逐位元）。**根因排序**：(a) MediaCodec 在 contention 下丟掉它收到但還沒解的輸入畫格
    ——這是 codec 層，改不了；(b)(c)(d) 都排除了：staging/feed 路徑沒有丟（`300 bitstream buffers in` 全數餵到）、
    held output 不丟（F16 已證、270 張都出得來、帶在中段不在宣告前的頭）、reinit 不 flush/restart codec（`reinit()` 只印一行、
    seek=0）。**觸發器是我們的 grace 節流**，所以修法就是拿掉節流：**grace 一次性**——同一個 pending-format 窗裡 grace 一放行過
    就不再壓後續的 `InputBufferDone`（gst 的順序保證只需要壓**第一個** buffer，會繼續餵的客戶端是 ffmpeg 形狀、不可被限速）。
    落地：crosvm backend 的 `grace_expired`（`android.rs` `note_input_done`/`release_deferred_input_done_if_stale`），
    fork 加測試 `a_never_announcing_codec_feeds_a_one_buffer_client_at_full_rate_after_the_first_grace`，
    D45 的順序（`source_change_precedes_the_output_buffer_that_produced_it`）與 B9 的 0-stale seek 都留綠。**B15 手機驗收才算關**。
  * **D70 / D71 / D72，B14 新加、F17 修**（fork + crosvm，2026-09-13；三條都在 §7.4 末的缺陷帳）。
    D70 見上（工具側，AV1 廣告不變）；D71 是 `format_change_pending` 在「宣告晚於客戶端 `STREAMON(CAPTURE)`」時永遠不清
    （ffmpeg 早開 CAPTURE），於是之後每個 `STREAMOFF(OUTPUT)`（含 EOF 關閉）都被當成 reinit——F17 在宣告落地時若 CAPTURE
    已為同一格式 streaming 就不設旗標，真 seek 又是 seek；D72 是 `REQBUFS(CAPTURE, n)` 低於宣告的最小值時照給（只從上界夾），
    F17 比照 vb2 抬到 `session.min_capture_buffers`（上限 `MAX_BUFFERS`）。
  * **D73 / D74 / D75，B14-accept-B 新加、F18 修**（fork + crosvm + rig，2026-09-13；三條都在 §7.4 末的缺陷帳）。
    D73 是 `REQBUFS`/`CREATE_BUFS` **全有或全無**——`libavdevice` 固定要 256 個、裝置夾到 32、4K 那組 379.75 MiB 塞不進
    320 MiB 的池，於是整個請求 `ENOMEM`，而池裝得下的 25–26 個本來就夠拍；F18 比照 vb2 改成配得到多少給多少（低於裝置底線
    才 `ENOMEM`），**這才是 D68 的解**，不是再加池。D74 是 D65 的 step 制對「在 32 MiB 邊界上來回」的 lease 沒有設限
    （60 s storm 約 226 000 條 `info`、ring 只剩 2.07 秒），F18 在 step 後面再加**每 lease 每秒一條**並把壓下的次數印在下一條
    行尾。D75 是 `tests/unbind_rebind.sh` 自己的兩個合成裝置假設（`v4l2-ctl` 在 ENODEV 路徑上回 0、byte 檢查寫死
    640×480 RGB3），害 D66 的三輪實質全過卻報 6 個假失敗。

### 7.3 編碼器（WP-M7 = 舊 plan C1–C3）

* crate 新 `devices/video_encoder.rs`：形狀鏡像 `video_decoder.rs`（OUTPUT = 原始 NV12、guest-owned；CAPTURE = 位元流、host-owned）；
  `ENCODER_CMD`/`TRY_ENCODER_CMD`（`STOP` → drain → LAST + EOS）；控制項用 `v4l2r::controls::codec` 現成型別：`BITRATE`、`BITRATE_MODE`、`GOP_SIZE`、
  `FORCE_KEY_FRAME`、`HEADER_MODE`、`H264/HEVC_PROFILE/LEVEL`、`PREPEND_SPSPPS_TO_IDR`；`queryctrl`/`query_ext_ctrl`/`querymenu`/`g|s|try_ext_ctrls` 由裝置實作。
* backend：`createEncoderByType`/`createCodecByName` + configure（`KEY_COLOR_FORMAT = YUV420SemiPlanar` 具體值、`KEY_BIT_RATE`、`KEY_BITRATE_MODE`（`ABitrateMode` 直接寫）、
  `KEY_I_FRAME_INTERVAL`、`KEY_FRAME_RATE`、`KEY_PROFILE/LEVEL`），**`getInputFormat` 讀 `stride`/`slice-height`**（缺 `slice-height` 表示 chroma offset 不是 stride 的整數倍 → 拒絕該 codec 或退回 planar），
  把 guest 的緊排 NV12 逐行填進 `getInputBuffer`（padding 到 stride，chroma 從 `stride*sliceHeight` 起），`queueInputBuffer` 整個 padded size；輸出 `BUFFER_FLAG_CODEC_CONFIG`
  依 `HEADER_MODE` 決定另發或併入第一幀，`KEY_FRAME` flag → `V4L2_BUF_FLAG_KEYFRAME`；動態改碼率/強制 I 幀用 `setParameters`（`video-bitrate`、`request-sync`）。
* 驗收：舊 plan C2（guest `ffmpeg -c:v h264_v4l2m2m out.mp4` 可播、釘時脈後 CPU ≤ libx264 的 1/3）、C3（kdenlive profile）。

### 7.4 codec 共同事項

* 兩個 codec 裝置都跑在 M3 helper；`--virtio-media kind=decoder[,allow_sw=true]` / `kind=encoder[,...]`，`uid=` 必填（一致的行程模型；codec 本身不需 FGS）。
* driver 端的 G/S_PARM 衝突（D6.4）：decoder 裝置對 v4l2-compliance 要 ENOTTY、encoder 要有；解法是 fork 擴充 config 區塊（40 bytes 之後加一個「host 實作的 ioctl 位圖」），
  driver 據此 `v4l2_disable_ioctl`；舊 host（沒有欄位，讀到 0）視為全支援。在 M6 與 M7 之間做。
* **ffmpeg 客戶端的已知限制（寫給使用者，四條都不是裝置缺陷；2026-09-06 依 B9-acceptance 補）**：
  (1) **drain 的尾巴會少幾張**（D41）——`v4l2_context.c` 在 draining 期間只要 CAPTURE 佇列空了就設 `ctx->done = 1`，
  不管裝置手上還握著幾張已解碼的畫格（F11-decoder §(5)），300 張進去約 288–291 張出來；裝置本身不掉張（C harness 300/300），
  緩解方式是 `-num_capture_buffers <大一點>`（**尚未實測**）或改走 GStreamer。
  (2) **動態解析度切換只出前半段**（D27）——ffmpeg 不重啟 CAPTURE；同一個檔 gst 是 120/120。
  (3) **`-stream_loop` 不會續播**（D27b）——`v4l2m2m` 沒有 `.flush`，EOF 之後不再入列，900 張只出 300 張；
  另外 `-stream_loop` 對 raw elementary stream 本來就沒有作用，要餵 mp4。
  (4) **自家錄的 mp4 目前解不回來**（D44 + D48）——ffmpeg 的 muxer 把 SPS/PPS 寫成獨立的 31-byte sample，正好踩中 D48；
  D48 修好之前請改用 GStreamer，或以 raw Annex-B 餵進去。
* `ResourceManagerService` 搶回：helper 是 app uid 的子行程、AM 看得到 app 但看不到 helper → 按舊 plan §2.2 估價不到、不易被選為受害者；被搶回時 `AMEDIACODEC_ERROR_RECLAIMED` → session dead。

**B12 驗收帶回來的缺陷帳（D62–D69，2026-09-06 依 `logs/vpu_wp/B12-acceptance.md` §15 與 `critic5.md` §2 記）。**
這一格是這八條的唯一總表——解碼器的（D64、D69）、編碼器的（D64 的反向、D67）、池與 log 的（D65）、
建置的（D62）、guest driver 的（D66）與容量的（D67、D68）都在這裡，§7.2 不再各記一份。
「M8 的池本身零缺陷」是這次驗收最該記住的一句：十六個量測窗全部以 `pool used 0` 收尾，六條新缺陷沒有一條在池的程式碼裡。

| 缺陷 | 是什麼 | 狀態 | 歸屬 | 修它的 WP |
|---|---|---|---|---|
| **D62** | `wip/vpu` 編不過：R8-11 把 `MappedPool::new` 搬進 `MediaBackend::start` 卻沒補 `use`（`media.rs:216`，`error[E0433]`） | **關**（曾是 blocker） | M8 / 建置 | crosvm **`6aac45b`**（一行 import）。教訓（`critic5.md` §2.1）：`deploy/vpu/harness.sh` 編不了 VMM 那個 crate，所以動到它又沒有 soong build 的 WP 就是在出沒編過的碼——F14 §7 item 3 自己白紙黑字預言了這一條，還是踩了 |
| **D63** | `harness.sh all` 不再確定性：fork 的 `a_refused_drain_leaves_no_drain_pending` 在有負載時 4 跑 2 敗（安靜時 12 跑 0 敗）；`collect_capture(…, 1)` 取第一個 CAPTURE dequeue 就斷言 `LAST`，grace 執行緒搶得贏它 | 開，minor | fork 測試 | **F16-codec**（順手修，否則每個未來的 gate 都是 flaky） |
| **D64** | 解碼 session 與編碼 session **幾乎同時建立**時，解碼輸出**安靜地少張**：1080p+1080p 掉 30/300（同一個錯 md5 `34c34d371c…`）、1080p+720p 掉 5、4K+1080p 掉 1。`ffmpeg` 回 0、stderr 全空 | **F17 修，待 B15 手機驗收**（HOST 已改，`0 seek(s)`／`reinit: keeping 0`——B14 §4 證偽了 F16「F15 關掉它」的說法） | codec 層 + 我們的 grace 節流，**不是池**、**不是 seek/reinit** | **F17-decoder**：D55/D56 grace 對「一個 buffer 在飛」的 ffmpeg 節流到 4 packets/s（30 grace 線 = 30 丟張），codec 於 contention 下丟輸入畫格。修法＝**grace 一次性**（`grace_expired`）；gst 只需壓第一個 buffer，會續餵的客戶端不可被限速。B15 門檻：1080p decode+encode 6/6 `bf32f00e5c4bca747bf7827ea5797b33`，4K+1080p 與 1080p+720p 各 3/3，每 session ≤ 1 條 grace 線 |
| **D65** | R8-3 的 `pool: "<card>" holds N bytes, pool used M of S` 是**每次 `Release` 一條 `INFO`**（`pool.rs:645`）；~9 400 releases/s 之下 1 MiB 的 `vm.sh log` ring **不到一秒**就被自己蓋掉 | **關**——F16-codec `e4e81a0da` 降成 32 MiB step 制，F18 再補每 lease 每秒一條的 ratelimit（見 **D74**，那才是振盪 lease 的解） | M8 / R8-3 | **F16-codec**：降成 `debug!`（`pool.rs:642` 那句「per REQBUFS/close, not per frame」正是被推翻的前提），或照 D51 的 ratelimit，或一次 REQBUFS 只印一條。降級之後怎麼讀，見 `deploy/vpu/README.md` |
| **D66** | `echo <dev> > /sys/bus/virtio/drivers/virtio_media/unbind`（session 還開著）**oops guest**：`vmedia_dbuf_buffer_from_host+0x70`，level-3 translation fault，留下 `modprobe -r` 清不掉的 `Zl [ffmpeg] <defunct>`；`modprobe -r` 這條路是**安全拒絕**的（B2 finding 2），sysfs 這條繞過了 refcount | 開，**high**（在 guest 內；VMM 這一側完全正確：`returns 20 outstanding pool reservations`、`pool used 0`、helper 活著、沒有 sweep） | guest driver r21（fork `driver/`） | **F16-driver**，交付新的 DKMS（**r22**）deb |
| **D67** | **4K 硬體編碼不可能**：編碼器的 OUTPUT queue 是 driver-owned，`virtio-media: driver-owned buffer allocation of 12441600 bytes (buffer 10 plane 0) failed: -12`——11 × 12 441 600 > 134 217 728，撞的是 **128 MiB 的 `media_guest`**，不是 VMM 的池（連 encoder session 都沒建起來） | 開，**high**——整個能力停在 2560×1440 | **容量**，不是程式：app 的 `vpu_guest_pool_mb`（`VpuConfig.java:41`，預設 128） | 沒有 WP：**§8 的「容量」段落**寫了兩個選項與代價，等使用者決定 |
| **D68** | `ffmpeg -f v4l2 -video_size 3840x2160 -i /dev/video0` 開不起來：它要 22 × 12 441 600 = 273 715 200 B，池是 268 435 456 B。VMM 正確地拒絕第 22 個並指名 `"Back camera (0)"`，沒有任何東西死掉；`v4l2-ctl` 的三 buffer 4K 擷取好好的 | **F18 修（見 D73）**，不是容量：B14-accept-B §2 用 strace 讀到客戶端要的是 **256**（不是 22），320 MiB 的池上是 32 × 12 443 648 = 379.75 MiB，**沒有任何手機肯給的池大小能關掉它**；`REQBUFS` 改成配得到多少給多少之後，同一個 320 MiB 池會給約 25 個 buffer 而不是 `ENOMEM`。B15 驗 | 不是容量而是 `REQBUFS` 的全有或全無（`libavdevice` 的 v4l2 indev 沒有 buffer 數選項） | **F18**（fork），§8 的「容量」段落只剩 D67 |
| **D69** | CAPTURE buffer 給太少會**安靜截斷**：8 個 → 300 張只出 73、16 個 → 119，兩者都 `rc=0` 且 stderr **0 bytes**；而客戶端能問到的每一個數字都是錯的——裝置宣告 `min 4 CAPTURE buffers`（`MIN_CAPTURE_BUFFERS` 常數，M6-backend 開放項 4）、`min_number_of_capture_buffers` 在閒置節點讀回 **1**、compliance 根本沒把節點分類（D59），而 codec 自己的 `num-output-slots` 是 **21** | **關**（損失半）——F16 修、B14 §5 證：8 buffer 現在 300/300 逐位元，gst 讀到 `G_CTRL(MIN_BUFFERS_FOR_CAPTURE)=21` 並排 25 | 解碼器裝置／backend | **F16-codec**：把 codec 真正的 `num-output-slots` 當成 CAPTURE 的最小值宣告出去，並讓給不夠變成大聲的失敗而不是安靜的短檔 |
| **D70** | 解碼器廣告 `'AV01'`（一個真格式），但 `v4l2-compliance` 1.32.0 的 `determine_codec_mask`（`.cpp:567-601`）沒有 AV1 的 case，碰到它就 `default: return`，`codec_mask` 留 0——**節點從來沒被認成 stateful decoder**。這是 **D58**（`-s` 卡在 `DQBUF(CAPTURE)`，永遠不下 `DEC_CMD_STOP`）、**D30**（`G/S_PARM`）、**D59**（`testEvents`）三條的**唯一**根因 | **關（工具側）**：AV1 繼續廣告，census 就是 48/46/2 且 `-s` 依設計卡住 | v4l-utils（**不是** DroidVM） | **F17-docs**：§7.2 記下這條、census 數字與一段上游 patch 草稿（在 `determine_codec_mask` 為 `V4L2_PIX_FMT_AV1` 加一個 stateful case） |
| **D71** | `format_change_pending` 在「宣告落地晚於客戶端 `STREAMON(CAPTURE)`」時**永遠不清**（ffmpeg 在 SOURCE_CHANGE 之前就開 CAPTURE）：`DEC_CMD_START` 只在 `drain != None` 時清，初次宣告 `drain` 是 `None`。於是之後每個 `STREAMOFF(OUTPUT)`（含 ffmpeg 的 EOF 關閉）都被誤判成 reinit，靜默解除 B9 的 0-stale-seek 性質 | **F17 修**（fork host 已改＋測試；B15 觀察「EOF 記成 seek 不是 reinit」） | fork `video_decoder.rs` | **F17-decoder**：宣告落地時若 CAPTURE 已為同一格式 streaming 就不設旗標（`STREAMON(CAPTURE)` 已在宣告之後、或宣告到來時 CAPTURE 已 streaming 且格式相符）；真 seek 又是 seek。測兩種順序 |
| **D72** | `REQBUFS(CAPTURE, n)` 低於宣告的最小值時**照給**（`video_decoder.rs` 只從上界夾到 `MAX_BUFFERS`）：ffmpeg 固定要 20、比宣告的 21 少一個，裝置就給 20 | **F17 修**（fork host 已改＋測試；B15 觀察 `REQBUFS(CAPTURE,20)` 回 21） | fork `video_decoder.rs` | **F17-decoder**：比照 vb2（`vb2_core_reqbufs` 把數量抬到 driver 的最小值），抬到 `session.min_capture_buffers`，上限 `MAX_BUFFERS`（V4L2 允許 `REQBUFS` 回比要求更多）。測 |
| **D73** | `REQBUFS`/`CREATE_BUFS` 是**全有或全無**：`libavdevice` 的 v4l2 indev 用寫死的 `desired_video_buffers = 256` 且沒有選項可改，裝置夾到 `MAX_BUFFERS`（32）後**一次配 32 個或一個都不配**，4K NV12 就是 32 × 12 443 648 = 379.75 MiB，320 MiB 的池裝不下 → 整個 `REQBUFS` 回 `ENOMEM`（B14-accept-B §2：帳爬到 311 091 200／25 個，第 27 個被拒），而同樣 4K 的 `REQBUFS(3)` 好好的。**沒有任何手機肯給的池大小能關掉它**，因為要幾個是客戶端寫死的 | **F18 修**（fork host 已改＋四個裝置各自的測試；B15 觀察 4K `ffmpeg -f v4l2` 拍得起來、`REQBUFS` 給約 25／256 且池的行指名它） | fork `camera.rs`／`loopback_device.rs`／`video_decoder.rs`／`video_encoder.rs` | **F18**：比照 vb2——`__vb2_queue_alloc` 配得到多少留多少，`vb2_core_reqbufs` 只在低於 queue 自己的底線時才 `-ENOMEM`（`videobuf2-core.c:977`），`vb2_core_create_bufs` 只在一個都沒配到時才失敗（`:1102`）；配不下就停在那裡並回**真的給了幾個**。底線＝camera／loopback／encoder 各 **1**（`streamon` 只擋空 queue），decoder CAPTURE 為 `session.min_capture_buffers`（**D72**，少於它是卡死不是變慢）。低於底線照舊 `undo_added` 全退 + `ENOMEM`（池的 exhausted 行照印）；短給時一條 `info!`，`CREATE_BUFS` 回真正建出來的 `index` + `count` |
| **D74** | D65 的 32 MiB step 只以**位元組**設限，對「在邊界上來回」的 lease 等於沒設限：B14-accept-B §4 的 4K×6 storm（74.7 MiB lease、每個 cycle 跨四次、60 s 56 503 cycles）打出約 **226 000** 條 `info`，1 MiB 的 ring 塞滿並繞回，`launched media helper`／`pool served by the VMM over fd`／`the pool connection for` 全被擠掉，只剩 **2.07 秒**歷史 | **F18 修**（crosvm 已改＋mpt 測試；B15 觀察 60 s 跨 step storm 之後開機那幾行還在、且看得到 `(N step crossings not logged)`） | M8 / `pool.rs`——F16-codec §6 item 4 自己記下的 caveat，這是它指的那根槓桿 | **F18**：step 規則不動（不跨 step 仍然一條都不印），後面再加**每 lease 每秒最多一條**（`POOL_LOG_INTERVAL`，D51 的 `pr_warn_ratelimited` 型）；窗內被壓下的跨越會計數，下一條印出來的行以 `(N step crossings not logged)` 帶出，`ReleaseAll`／sweep 照舊**一定**印並開新窗。判斷函式 `info_line_due` 把時鐘當參數，測試用模擬時間跑 10 000 次振盪 |
| **D75** | `deploy/vpu/tests/unbind_rebind.sh` 對真相機報 **6 個假失敗**（3 輪 × 2），而 **D66 的實質三輪全過**：(1) 斷言 `rc != 0`，但 v4l-utils 1.32.0 的 streaming loop 印完 ioctl 錯誤就 `return`——`v4l2-ctl --stream-mmap` 在自己的 ENODEV 路徑上**回 0**（B14-accept-B §1.2 直接量過）；(2) byte 檢查寫死 640×480 RGB3（921 600），那是合成 `kind=simple` 裝置的唯一格式，相機是 1280×720 NV12，於是正確的 30 × 1 382 400 = 41 472 000 B 被判成失敗 | **F18 修**（rig；B15 觀察相機上 `--rounds 3` 回 0 failures） | meta `deploy/vpu/tests/unbind_rebind.sh`（測試自己，不是產品） | **F18**：改判**症狀**——客戶端的輸出要出現 `No such device`／`ENODEV`／`POLLERR` 且行程在 15 s 窗內消失（結束碼只印出來備查）；期望位元組改成節點自己 `--get-fmt-video` 的各 plane `Size Image` 相加，m2m 的輸入檔同樣由 `--get-fmt-video-out` 決定，檔案裡不再有寫死的畫格大小。3 輪形狀、D/Z 檢查、dmesg splat 計數不動 |

## 8. app / daemon（WP-A1）

* `CrosvmBackendInstance.buildCommand` `:322-402`：三條 GPU 路線各自組 `--pre-alloc` 改成整台 VM 一個 `StringBuilder`；`appendMediaPoolOptions(sb, item, pvm)`：`vpu_enabled` 才加，`media-host-mb=<vpu_host_pool_mb>`，`media-guest-mb=<VpuConfig.guestPoolMbFor(..)>`（>0 才加）；**VPU-only VM（無 GPU）也要出**。`protected_vm` 讀取要提前到 `:346` 之前。
* `VpuConfig.guestPoolMbFor` 加 `isEnabled` 判斷（今天不看 `vpu_enabled`，`app-daemon.md` §6.1）。
* `PoolPreflight.neededPages` 加 media_guest。
* `buildPeripheralCommand` `:1323`：`VIRTIO_CAMERA` → `--virtio-media kind=camera,camera_id=<host_device>,card=...,uid=<appUid>`（M4 才啟用；先做成 `PeripheralType.VIRTIO_CAMERA.available` 仍為 false 時不出）。
* udmabuf `size_limit_mb` 的 sysfs 提高（`:1156-1158`）對 `vpu_enabled` 的 VM 也做。
* `droidvm up <vm_id|name>` CLI 動詞（`app/src/main/cpp/console/commands/`，送 `vm_start`）— 開發迭代必需。
* Java 與 crosvm 必須一起上裝置（`deny_unknown_fields`，`config.rs:755-756`）。
* **`log_level`（每台 VM 一個字串，預設 `info`；WP F15，缺陷 D60）**：`VmmLogLevel.java` 持有這個 key 與它的語法，
  `buildCommand` 把它出成**頂層** `--log-level <filter>`——在 crosvm 執行檔與 `run` 之間，和 `--extended-status` 並排。
  位置就是這個 key 存在的理由：`--log-level` 屬於 `CrosvmCmdlineArgs` 而不是 `run` 子命令，放在 `run` 之後
  argh 會讓整個 parse 失敗（`Unrecognized argument: --log-level`，VM 直接回 stopped），所以 `extra_options`
  這個縫**做不到**這件事（B11-acceptance §8 實測）。預設值不出旗標（crosvm 自己的預設就是 `info`），
  所以現有的命令列一個 token 都不會變。值是 env_logger 的 filter：一個 level 名，或 `info,base=debug` 這樣的複合式；
  沒有 `=` 的 directive 必須**本身是一個 level**（`verbose` 在這裡被拒，而不是變成一個叫 verbose 的模組 filter，
  因為 env_logger 從不讓 parse 失敗，讀不懂就丟掉繼續跑）。setter 會丟例外（打字的人看得到），
  命令列這一端只警告並退回預設（一個 log level 不該是 VM 開不起來的理由）。
  這條與 **D57**（VMM 把自己的 level 轉給每個 helper：`/proc/self/exe --log-level <filter> device media …`）
  合起來才是完整的一條鏈：在 F15 之前 D57 是對的但無從啟動，媒體堆疊裡每一個 `debug!` 在手機上都是死重。
  rig 的動詞是 `deploy/vpu/vm.sh log-level <name> <value>`（§9）。

* **容量：兩個池的大小是 4K 撞到的天花板。使用者已決（2026-09-06）：選項 A。**
  （依 `logs/vpu_wp/B12-acceptance.md` §8/§15 與 `critic5.md` §5 記；WP A6 實作。）M8 之後 `media_host` 不再有切片，一個 4K 解碼可以吃掉整池；
  於是擋住 4K 的不再是分配器，而是這兩個 store key 的預設值本身——它們是 `VpuConfig` 的
  `vpu_host_pool_mb`（**A6 起預設 320**，原 256）與 `vpu_guest_pool_mb`（**A6 起預設 192**，原 128），改一個數字就能試，不必動任何程式。

  算術（4K NV12 一張 = 3840 × 2160 × 1.5 = **12 441 600 B**；VMM 的池以 4 KiB 對齊記帳，所以每張佔 **12 443 648 B**）：

  | 撞到的東西 | 池 | 算術 | 結論 |
  |---|---|---|---|
  | **4K 硬體編碼**（D67） | `media_guest` 128 MiB = 134 217 728 B | guest driver 在 **buffer 10** 上 `failed: -12`，即第 11 張：11 × 12 441 600 = **136 857 600 > 134 217 728** | 128 MiB 只裝得下 **10** 張，編碼器的 driver-owned OUTPUT queue 至少要 11 張 → 4K 編碼開不起來（2560×1440 與 1080p 都好好的） |
  | **`ffmpeg -f v4l2` 的 4K 相機擷取**（D68） | `media_host` 256 MiB = 268 435 456 B | ffmpeg 的 v4l2 indev 要 **22** 張：22 × 12 443 648 = **273 760 256 > 268 435 456**；VMM 給到第 21 張（261 316 608 B，97.3 %）就拒絕 | 一個沒有 buffer 數選項的客戶端（`libavdevice` 真的沒有）碰到誠實的容量上限。`v4l2-ctl` 的 3 張 4K 擷取（37 330 944 B）好好的 |
  | 對照：**4K 硬體解碼** | `media_host` 256 MiB | 19 × 12 443 648 = **236 429 312 B（225.5 MiB）**，三個裝置同時的峰值 256 536 576（95.6 %） | 256 MiB **夠**——這正是 M8 買到的東西 |

  兩個選項，代價都算給你（6 GB `pool_want` 的手機：`hp.sh` 的 `pool_avail` 是 **3072 個 2 MiB 大頁 = 6144 MiB**；
  B12 那台 VM 起來以後是 `served=2624 pages (5248 MiB), pool_avail=448/3072`，也就是**還剩 448 頁 = 896 MiB**）。
  兩個池的代價**不是同一種**：`media_host` 在 crosvm 那側掛 `consume_system_mem`，所以它已經在 `--mem` 裡面
  （`PoolPreflight.neededPages` 不另外加它）——多給它一 MiB，就是 guest 少一 MiB 可用的 RAM；`media_guest` 是
  RAM **旁邊**的記憶體，`PoolPreflight` 逐 MiB 加進大頁需求（`bootMediaGuestMb`，2 MiB 一頁）。

  * **選項 A：把 app 的預設調大，一次調到「4K 都會過」為止。** 例如 **host 320 MiB / guest 192 MiB**（都對齊 2 MiB）。
    guest 192 MiB = 201 326 592 B 裝得下 **16** 張 4K（199 065 600 B），量到的需求是「≥ 11」，所以有餘裕——
    但**沒有量過 ffmpeg 到底要幾張**（只知道它在第 11 張上死掉），若它其實要 > 16 張，192 MiB 一樣不夠，這要 B13 量。
    host 320 MiB = 335 544 320 B 裝得下 **26** 張 4K：D68 的 22 張擷取過得去，剩下的 61 784 064 B 還放得下一整組
    19 張的 1080p 解碼（59 146 240 B，B12 §12.2 量到的數字），但**放不下**同時再來一個 19 張的 4K 解碼。
    代價：guest 128 → 192 是 **+64 MiB = +32 頁**（3072 頁裡的 1 %，B12 那個 boot 剩的 448 頁裡的 7 %）；
    host 256 → 320 是 **+64 MiB 從 guest 的 `--mem` 裡扣**，大頁需求不變——除非同時把 `memory_mb` 也加 64 MiB 補回去，
    那才又是 **+32 頁**。最壞情況（兩邊都補）**+64 頁 = +128 MiB**，剩的 448 頁還撐得住。
  * **選項 B：開機時從 codec 清單推出來，不要寫死。** 裝置建立時本來就會暖機列舉一次 Store（§7.2），
    所以「最大 coded size × codec 自己的輸出 slot 數」是拿得到的：5566 上那個數字是
    **`num-output-slots: int32(21)`**（D69 那條 log 行裡就有），最大 coded size 是 3840×2160。
    於是 `media_host` = 21 × 12 443 648 = **261 316 608 B（249.2 MiB）**，加上相機的工作組（3 張 4K = 37 330 944 B）
    與編碼器的 CAPTURE（B12 量到 ~4 MiB）≈ **302 841 856 B（288.8 MiB）→ 對齊後 290 MiB**，和選項 A 的 320 MiB 是同一個量級——
    差別是它會隨手機走，而不是替 5566 猜一個數字。`media_guest` 用同一個 21 去算會是 **249.2 MiB**（比 192 大得多，
    因為編碼器的輸入 slot 數我們沒有量過，只能保守借用 21）；那要 **+122 MiB = +61 頁**。
    代價是複雜度與失敗模式：清單讀不到（無硬體 codec、Store 列舉失敗）時要有一個 fallback 常數，
    而且池大小會變成「開機當下的清單」的函式——同一台 VM 兩次開機拿到不同的池大小，debug 起來比一個常數難。

  **決定（2026-09-06，使用者）：選項 A——host 320 MiB / guest 192 MiB；選項 B（從 codec 清單推導）暫緩。**
  理由是 D67／D68 是**已知的容量上限，不是缺陷**，而一個能讓 4K 編碼與 ffmpeg 4K 擷取都過去的常數，
  比一個會隨開機當下的 Store 清單變動的推導值好 debug；選項 B 留著，等「4K 編碼到底要幾張」與
  「編碼器的輸入 slot 數」量出來（B13／B14）再重開。

  這個決定在 6 GB `pool_want` 的手機上的大頁代價，只有 `media_guest` 那一半要付：
  guest 128 → 192 MiB 是 **+64 MiB = +32 個 2 MiB 大頁**，`PoolPreflight.neededPages` 會把它加進去，
  所以 B12 那台 VM 的 `served` 會從 **2624 頁（5248 MiB）變成 2656 頁（5312 MiB）**，
  `pool_avail` 從 448/3072 變成 **416/3072（832 MiB）**——3072 頁裡的 1 %。
  host 256 → 320 MiB 是 `consume_system_mem`，從 guest 自己的 `--mem` 裡扣，大頁需求一頁都不變
  （除非同時把 `memory_mb` 也加 64 MiB 補回去，那才又是 +32 頁）。

  實作落在 `VpuConfig.DEFAULT_HOST_POOL_MB` / `DEFAULT_GUEST_POOL_MB`（兩個都是 2 MiB 的倍數，
  guest 那個必須是，因為它是逐頁從保留區發出來的），editor 的版面預設與測試跟著改；
  **這是 default，不是 migration**——已經把這兩個 key 存進 config 的 VM（rig 的 Ubuntu-resolute 就是）
  仍然用它存的 256／128，要拿到新值得把 key 刪掉（`scratch-A5/cfg.sh vpuon` 就是這麼做的）。

---

## 9. 開發環境與流程（WP-D1）

* `deploy/vpu/` 新 rig：
  * `push_crosvm.sh`：`crosvm_out/` → `/data/local/tmp/crosvm_vpu.new` → `su cp` 到 `/data/data/cn.classfun.droidvm/usr/bin/crosvm`（先備份 `crosvm.bak.<date>`），逐檔 md5 驗證（`deploy/SETUP.md` 的 adb push 陷阱）。
  * `vm.sh start|stop|status|argv|log|log-level <name>`（`log-level` 是 WP F15 加的，見 §8 的 `log_level`）：讀 `run/droidvmd-port.txt` + token，走 IPC（`logs/vpu_survey/raw-5566-vm/dvmipc.py` 的形狀，改成 repo 內腳本）；daemon 沒起就用 `DaemonHelper.java:138-151` 的指令拉起（記得 `>/dev/null 2>&1 </dev/null`）。
  * `guest.sh ssh|scp|install-tools|install-deb`：從 `vms.json` 的 MAC 算 EUI-64（`poolvm.sh` 的 `eui()`），`apt-get install v4l-utils ffmpeg gstreamer1.0-tools gstreamer1.0-plugins-bad`。
  * `vm_extra.sh`：用 `vm_modify` 改 `extra_options`（VM 需 STOPPED），在 app 還沒接線前塞 `--pre-alloc media-host-mb=256,media-guest-mb=128 --virtio-media kind=loopback`。注意 `--pre-alloc` 單值：要把 daemon 自己出的 GPU 池那串合併（`extra_options` 排在 daemon 參數之後 → 後者覆蓋前者），所以 rig 要重組完整的一串。
* 建置：`systemd-run --unit=droidvm-step2 --collect -p AllowedCPUs=0-7 -p Nice=10 --setenv=JOBS=8 bash -c 'taskset -c 0-7 ./2_build_crosvm.sh'`。
* 手機規則：不 `kill -9` crosvm、同時只一個 crosvm、不重開機、不 rmmod、只動 5566。

---

## 10. 工作包

| WP | repo | 內容 | 相依 | 平行 |
|---|---|---|---|---|
| H1 | crosvm | §3.1 池子 + `MediaPoolHandle` + 單元測試 | — | 第一批 |
| G1 | virtio-media fork `driver/` + guest-additions | §5 全部 + DKMS + 在 5566 VM 上 `make` 通過、`insmod` 成功（無裝置時只 probe 不到） | — | 第一批 |
| A1 | DroidVM | §8 全部 | H1 的 key 名 | 第一批 |
| D1 | meta repo | §9 rig + guest 工具安裝 | — | 第一批 |
| M2 | virtio-media fork `device/` + crosvm | §4 全部 + §3.2–3.5（`HostBacking`、SG 修正、`GuestBufferImport`、`--virtio-media`、loopback 接線） | H1 | 第二批 |
| B1 | meta | 建置（capped）+ push + 在 5566 pVM 上跑 M1/M2 驗收 | H1, G1, M2, D1 | 第三批 |
| M3 | crosvm | §6 vhost-user backend + helper | M2 | 第四批 |
| C1 | crosvm `android_camera` + fork `device/` | 相機裝置 A1 | M3 | 第五批 |
| … | | A2–A4、B1–B3、C1–C3 照舊 plan | | |

每個 WP 的 agent 指令：**只改列出的檔案**、每個改動附 file:line 依據、不建置整棵 soong（用 `cargo check` 能做的做，soong build 由 B1 統一跑）、
不動裝置（G1 的 VM 內 `make` 例外）、commit 到各 repo 的 `wip/vpu`（不 push，由人審）。

---

## 11. 待人類決定

1. **udmabuf 的消費者**。v1 沒有 dma-buf 消費者（§3.4）；udmabuf 匯入以介面 + 測試交付。若你希望 v1 就零拷貝，需要 VNDK `AHardwareBuffer_createFromHandle` 的可行性探測（不是 NDK 公開 API）。
2. **`--protected-vm`（有韌體）** 要不要一併給 `media_guest`：`VpuConfig.guestPoolApplies` 包含它，本設計照 app 的規則（給）。
3. **要不要在 5566 裝 DroidVM 的 `gunyah-host-share` / `udmabuf` 模組**：現在沒載，udmabuf 上限 1024 entries / 64 MiB。v1 靜態池 + 連續配置不需要；若要 growable 或大 dma-buf 才需要（要重開機、`br-wifi` 會掉）。本設計預設**不裝**。
4. **數值 ABI**：曝光單位 100 µs 表達不了 5566 的 85 µs 下限；建議改 10 µs（`EXPOSURE_ABSOLUTE` 標準單位是 100 µs，改單位是私有約定，要寫進文件）。ISO 選單上限取 characteristics 的實際範圍。
5. **軟體 codec** 是否列入 ENUM_FMT（VP8 / AV1 編碼只有軟體）：預設不列。
6. **CAPTURE 也由 guest 擁有（`driver_owned_queues=all`）** 是否作為 pVM 預設：可省掉 `media_host`，但相機幀寫入 guest 池的路徑要先量（cacheable 映射下 CPU-CPU 同調沒問題，量的是 host 寫入 pool memfd 的速度）。本設計預設 `output`。
7. **推送，以及 manifest 的 `revision=` 要不要跟著動**（2026-09-06 記錄，這裡只是**紀錄現況**，沒有動任何檔案；每個 session 都被規則禁止 push，只有你能做）。
   現況：`crosvm-minimal.xml` 把 `external/crosvm` 與 `external/virtio-media` 都釘在 **`revision="droidvm"`**，只有
   `external/rust/crates/v4l2r` 釘 `wip/vpu`（那個 fork 上還沒有 `droidvm` 分支）。手機上跑的這份建置——crosvm、
   fork 的 device/ 與 guest driver、v4l2r、guest-additions、app、meta——完全落在七個**尚未推送**的 `wip/vpu` head 上。
   要讓別台機器重現它，需要兩件事，順序不能反：
   * **先推**七個 repo 的 `wip/vpu`。這是必要條件：`1_build_crosvm_prepare.sh` 在 `repo sync` 之後會用
     `lib_branch.sh::checkout_soong` 把每個 fork 沿「本 meta repo 的分支 → `droidvm` → manifest 的 revision」
     這條鏈走一次，所以**只要遠端有 `wip/vpu`，同名分支就會被選上，manifest 的 `revision=` 不必動**——
     critic3 §4 說「即使推了也要改 manifest 才 sync 得到」對 `repo sync` 本身成立，對這條建置路徑則過嚴。
     反過來說，在推之前這條路是走不通也不會安靜走錯的：`checkout_soong` 對「本地 `wip/vpu` 有遠端沒有的 commit」
     會直接報錯結束（`checkout -B would discard them`），而不是默默把本地工作丟掉。
   * **只有**當這批工作要成為預設（合併進各 fork 的 `droidvm`，或希望一個沒有 `wip/vpu` 的 meta 分支也能建出它）時，
     才需要動 manifest 的 `revision=`。那是一個獨立的決定，不是推送的前置。
   在你決定以前，這份建置（含 DKMS r21 的 deb）只存在於這台機器和那支手機上。

   **要推的東西有多少（2026-09-06 WP F16-docs 當場量：`git log <remote>/wip/vpu..HEAD --oneline | wc -l` 與反向）：
   七個 repo 合計 160 個 commit，七個都是純 fast-forward（`behind` 全部是 0），所以不會有衝突，也不必開新分支。**

   | repo | remote | HEAD | 未推 | 落後 |
   |---|---|---|---|---|
   | meta（本 repo） | `origin` | `faf01ac` | **28** | 0 |
   | `crosvm` | `droidvm` | `6aac45b` | **54** | 0 |
   | fork `virtio-media` | `droidvm` | `029d85c` | **47** | 0 |
   | `v4l2r` | `droidvm` | `7eb3afa` | **1** | 0 |
   | `droidvm-guest-additions` | `origin` | `2c7f6ef` | **8** | 0 |
   | `DroidVM`（app） | `origin` | `e5721ec` | **21** | 0 |
   | `crosvm-minimal-manifest` | `origin` | `8143624` | **1** | 0 |
   | **合計** | | | **160** | |

   這個數字每一輪 critique 都在長（140 → 143 → 153 → **160**）。順序：**`v4l2r` 先推**（manifest 已經把它釘在
   `wip/vpu`，遠端沒有這個分支的期間 manifest 指著一個不存在的名字），**meta 最後推**。
   遠端現在長什麼樣沒有查（這台機器上的 session 一律不連網、也不准 push），所以 `behind = 0` 是**對本機記錄的 remote ref 而言**。

   **七個 repo 上各有兩個本地（未推送）的 tag：`accepted-b11-2026-09-06` 與 `accepted-b12-2026-09-06`**
   （前者 2026-09-06 WP F15 記錄，後者同日補上；`git tag -l 'accepted-*'` 在七個 repo 裡都看得到）。
   一個 tag 名 = 一次驗收實際跑過的七個 head，也就是那份報告裡每一個數字所屬的建置：

   | repo | `accepted-b11-2026-09-06` | `accepted-b12-2026-09-06` |
   |---|---|---|
   | `crosvm` | `114de78` | **`6aac45b`** |
   | `crosvm_build/external/virtio-media`（fork） | `b19f620` | `b19f620` |
   | `crosvm_build/external/rust/crates/v4l2r` | `7eb3afa` | `7eb3afa` |
   | `droidvm-guest-additions` | `2c7f6ef` | `2c7f6ef` |
   | `DroidVM`（app） | `b13bb2e` | `b13bb2e` |
   | `crosvm-minimal-manifest` | `8143624` | `8143624` |
   | meta（本 repo） | `30ef120` | **`5d2c96e`** |

   B12 那一欄只有兩個 repo 動：crosvm 走到 M8 + F14 + D62 的那一行 import（`6aac45b`），meta 走到 F14 的文件
   （`5d2c96e`）。**要小心讀的是 crosvm 這格**：B12 驗收量的那顆二進位（md5 `ae3f7dd6aba933af71733c7007dcdc73`）
   是 `e294860` 加上 D62 那一行——`6aac45b` 正是把那一行變成 commit 的東西，所以它是**能重建那顆二進位的最早 head**，
   而不是「之後又動過的版本」。它也**早於** `a6b1d8d`（D53）與 fork 的 `029d85c`（D53/D58）：
   `logs/vpu_wp/B12-acceptance.md` 裡沒有一個數字說得上那兩個 commit 的話。

   分支名記不住一個建置——`wip/vpu` 會動，報告裡的「crosvm `114de78`」在下一個 WP commit 之後就找不回來了；
   七個 tag 一起下才記得住。約定是 `accepted-<wp>-<date>`，七個全下或一個都不下
   （只下一部分比不下更糟：讀的人會以為沒下的那幾個沒動過）。怎麼從 tag 重建，見
   `deploy/vpu/README.md` 的「The `accepted-*` tags」。
   **但 tag 只是配方，不是成品**：B11 驗收過的那顆二進位（md5 `a289e03fe6e16c6f7a1d8825cc99989a`、
   14 271 944 bytes）現在**只存在於手機上**，這台機器的 `crosvm_out/` 早已被後續建置覆蓋。
   **B12 那顆（`ae3f7dd6…`）也一樣，而且更糟**：這台機器的 `crosvm_out/` 在 B13 建置時就被蓋掉了，
   它現在只在手機上（`critic5.md` §3b）。連續兩輪如此——tag 記得住配方，記不住成品。

8. **helper 死亡的處置（2026-09-06 決定，這一條記在這裡是為了關掉它，不是為了問你）。**
   一個帶標籤的 media helper 非乾淨退出，VMM 仍然以 `ExitState::Crash` 結束整台 VM（§6.1、M3 §5.1）。
   **維持現狀**：F14 §6 item (f) 明白地接受了它，B12 驗收 §7 也實測過——`kill -TERM` 掉解碼器 helper 之後，
   log 依序出現 `the pool connection for "droidvm decoder" is closed`、
   `reclaiming 20 media_host buffers from a device that went away`、`exiting with crash`，
   下一次開機的第一筆記帳是 `holds == pool used`，大頁全數歸還（`served=0, pool_avail=3072/3072`），沒有漏掉的 memparcel。
   關鍵是 **M8 讓這個決定不再是池的問題**：sweep 只在 EOF 上跑、而且跑的是 VMM 自己手上的帳，
   所以「helper 死掉」這條路和乾淨退出一樣把池收乾淨——將來若有人要把 helper 死亡改成可存活的
   （M8-impl §8 item 1，仍然開著、仍然沒人決定），池這一側不必再動一行。
