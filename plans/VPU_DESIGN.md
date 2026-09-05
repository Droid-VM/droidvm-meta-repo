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
| 池的交接 | `--pool-gpa <gpa>` 一個數字 + `--pool-slice (offset, len)`（`MediaBackendParams.pool_slice`，`serde(default)`）；backend 在第一次 `start_queue`（mem table 已到）時從 region 表重建 `MediaPoolHandle`，allocator 懶初始化，**但只在自己那一片切片內配置**。切片的規則見下方「池切片交接」——原本這一格只寫「allocator 懶初始化」，那就是 D49 的洞 |
| Bar 模式 out-of-process | **不支援**。`uid=` 且無 `media_host` 池 → 裝置建立時拒絕（訊息說明）。Gunyah 與有池的 KVM 都走池模式 |
| host 存取的重新閘門 | VMM 從自己的 `GuestMemory`（有 purpose、有 protected）算出「host 可碰的 GPA 視窗」清單（所有池、`StaticSwiotlbRegion`、`SharedGuestRam`、`ShimHandoff`、`SharedFramebuffer`；非保護 VM 則整段 RAM），放進 JSON config；backend 的 `GuestMemoryMapper` 以 `HostAccessPolicy::Windows` 對每條 SG entry range-check，越界回 `EFAULT`。in-VMM 用 `HostAccessPolicy::GuestMemory`（今天的 `check_host_access`）。同一個 trait，兩個實作 |
| 兩條 queue | stash-and-start：兩條都 `start_queue` 後才起 `Worker` 執行緒（與 in-VMM 同一個 `Worker`，抽成共用） |
| 執行緒 | `Worker` 仍是獨立 OS thread（executor 只管 vhost-user 控制面）；相機（M4）另有自己的擷取執行緒 + eventfd 餵 `poll_fd` |
| `access_platform` | VMM 依 `ProtectionType` 蓋進 params，backend 據此加 `VIRTIO_F_ACCESS_PLATFORM`（不重蹈 virtio-snd lent-memory 事故） |
| udmabuf | helper 內 `/dev/udmabuf` 開不了（0600 root）→ `dmabuf()` 回 Err；v1 無消費者，維持 |
| 啟動 | `snd_helper.rs` 泛化為 `device_helper::launch(subcommand, params_json, uid, gid, supp_gids)`；exec 不 fork；`PR_SET_PDEATHSIG`；pid 進 `worker_process_pids` 與 `pid_debug_label_map`（crash log 才有名字） |

**池切片交接（2026-09-06 依 `logs/vpu_wp/F12-encoder.md` 補；缺陷 D49）。**
`pool.rs` 自己寫著這個不變式：池「必須是整個 VM 共用的 —— 兩個各自持有私有 allocator 的裝置在同一個視窗上都會發出
offset 0、0x1000、…，guest 就把同一段實體記憶體映射成兩個互不相干的 buffer」。共用的 `MediaPool` 對 **VMM 內**的裝置
確實保證了這件事；但相機、解碼器、編碼器三個都是 `HelperOnly`，各自是一個 `crosvm device media` 行程，
`vhost/user/device/media.rs::start()` 各自 `pool_handle_at(&mem, pool_gpa)` → `MediaPool::new(handle)`，
於是三個行程在**同一個 256 MiB 視窗**上各建一個從 0 開始的 allocator ——
正是本節上一版寫的「allocator 懶初始化」。實測後果：相機 → `v4l2h264enc` 3840x1644 時，編碼器的 CAPTURE（位元流）
buffer 落在相機 raw buffer 內部，每寫一張編碼幀就塗掉一塊，139 張裡 9 張出現一條「把位元流當成像素讀」的雜訊帶，
起點正好對齊 page、長度正好是一張編碼幀（B9 §4、F12-encoder §1.2–1.3）。單一 helper 的每一個對照組都是乾淨的，
因為那時只有一個 allocator。

**規則**：VMM 在建立裝置前，依設定順序對整個池的 offset 空間切一次（`pool.rs::carve_slices(size, weights)`，
page 對齊、完全覆蓋、餘數給最後一個會配置的切片），把 `(offset, len)` 隨 params 交給每個 helper；
helper 以 `MediaPool::with_slice` 只在切片內配置，越界就是 `ENOMEM`，不會是鄰居的位元組。
guest 可見的契約不變（offset 仍在 `[0, pool.size)`，guest 仍映射 `media_host base + offset`）。
只有一個會配置的媒體裝置時不切，行為與今天相同（`pool_slice` 是 `Option`，舊 VMM 的 JSON 也照舊）。
VMM 內若同時存在 pool 使用者，它們合佔一片，否則未來的 in-VMM 裝置又會和 helper 互疊。

**權重是政策，不是量測**：目前解碼器 2、相機 1、編碼器 1（解碼器的 CAPTURE 側要壓著一整排已解碼的幀），
256 MiB 池上就是相機 `0x0+0x4000000`(64 MiB)、解碼器 `0x4000000+0x8000000`(128 MiB)、編碼器 `0xc000000+0x4000000`(64 MiB)。
這組數字涵蓋 B9/B10 量到的一切，但**一個切片有可能比從前「看起來能用」的整池小**：ffmpeg 的 v4l2m2m 解碼會要約 20 個
CAPTURE buffer，4K 下約 190 MiB > 解碼器的 128 MiB。真的撞到時是一行 `media_host pool exhausted for "<card>"`
的 `ERROR` 加客戶端的 `ENOMEM`——吵、可歸因，而不是從前那種安靜的踩踏；處置是調權重或把 `media-host-mb`（app `VpuConfig`，預設 256）加大。
4K 這條至今未量（B10 全程 0 次 exhausted），列為觀察項。切片在 log 裡兩行可見：VMM 的
`launched media helper: ... pool slice 0x4000000+0x8000000` 與 helper 自己的
`serving MMAP buffers from the media_host pool slice ...`（`deploy/vpu/README.md`）。

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
  mime ↔ V4L2 OUTPUT fourcc：`video/avc`→`H264`、`video/hevc`→`HEVC`、`video/x-vnd.on2.vp9`→`VP90`、`video/av01`→`AV10`、`video/x-vnd.on2.vp8`→`VP80`。
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
  * **`v4l2-compliance` 的預期值**（2026-09-06 依 `logs/vpu_wp/B10-acceptance.md` §2 改寫成 B10 在修好 D48/D50 的
    版本上實測到的數字；先前這裡寫的是 B9 的量測加一個「D50 修好之後應回到 48 / 47 / 1」的預測，**那個預測被 B10 證偽**）：

    | 節點 | 呼叫 | Total / Succeeded / Failed | 失敗的來由 |
    |---|---|---|---|
    | 解碼器 `/dev/video1` | 不帶 `-s` | **48 / 46 / 2** | **D30**（`VIDIOC_G/S_PARM`，接受）與 **D54**（見下）|
    | 解碼器 `/dev/video1` | 帶 `-s` | **跑不完**：1500 s `rc=124`，停在 `Frame #002` | **D56** |
    | 編碼器 `/dev/video2` | 不帶 `-s` | **48 / 48 / 0** | — |
    | 編碼器 `/dev/video2` | 帶 `-s` | **55 / 50 / 5** | 一個根因 `v4l2-test-buffers.cpp(398): !g_bytesused(p)` 加四條連鎖 = **D43**，接受 |
    | 相機 `/dev/video0` | 帶 `-s` | **59 / 56 / 3** | §7.1 那三條，接受 |

    解碼器不帶 `-s` 的分數沒動，但**失敗的那一條換了人**：D50 修好以後訂閱迴圈確實過了
    （`v4l2-test-controls.cpp(1128)` 那行不見了），測試往下走到同一個子測試的 `(1180)` —— `testEvents` 的分類斷言。
    它會炸是因為節點**沒有被認成 stateful decoder**卻帶著 D29 給的 `V4L2_CID_MIN_BUFFERS_FOR_CAPTURE`：
    `determine_codec_mask()` 走 `ENUM_FMT`，碰到第一個它不認得的壓縮格式就 `return`，於是 `codec_mask = 0`。
    那個格式是 AV1：本節上面的對照表把 `video/av01` 對到 **`AV10`**，而 `videodev2.h` 的
    `V4L2_PIX_FMT_AV1` 是 **`AV01`**。這是 **D54**，一個寫錯的線上常數（四個站點：`android.rs:173`、
    `android_encoder.rs:189`、fork 的 `fourcc_description` 兩處），順帶讓任何以 fourcc 比對的客戶端看不到 AV1。
    修好它以後這一格應該是 **48 / 47 / 1**（只剩 D30）——**這句是預測，不是量測**。
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

## 8. app / daemon（WP-A1）

* `CrosvmBackendInstance.buildCommand` `:322-402`：三條 GPU 路線各自組 `--pre-alloc` 改成整台 VM 一個 `StringBuilder`；`appendMediaPoolOptions(sb, item, pvm)`：`vpu_enabled` 才加，`media-host-mb=<vpu_host_pool_mb>`，`media-guest-mb=<VpuConfig.guestPoolMbFor(..)>`（>0 才加）；**VPU-only VM（無 GPU）也要出**。`protected_vm` 讀取要提前到 `:346` 之前。
* `VpuConfig.guestPoolMbFor` 加 `isEnabled` 判斷（今天不看 `vpu_enabled`，`app-daemon.md` §6.1）。
* `PoolPreflight.neededPages` 加 media_guest。
* `buildPeripheralCommand` `:1323`：`VIRTIO_CAMERA` → `--virtio-media kind=camera,camera_id=<host_device>,card=...,uid=<appUid>`（M4 才啟用；先做成 `PeripheralType.VIRTIO_CAMERA.available` 仍為 false 時不出）。
* udmabuf `size_limit_mb` 的 sysfs 提高（`:1156-1158`）對 `vpu_enabled` 的 VM 也做。
* `droidvm up <vm_id|name>` CLI 動詞（`app/src/main/cpp/console/commands/`，送 `vm_start`）— 開發迭代必需。
* Java 與 crosvm 必須一起上裝置（`deny_unknown_fields`，`config.rs:755-756`）。

---

## 9. 開發環境與流程（WP-D1）

* `deploy/vpu/` 新 rig：
  * `push_crosvm.sh`：`crosvm_out/` → `/data/local/tmp/crosvm_vpu.new` → `su cp` 到 `/data/data/cn.classfun.droidvm/usr/bin/crosvm`（先備份 `crosvm.bak.<date>`），逐檔 md5 驗證（`deploy/SETUP.md` 的 adb push 陷阱）。
  * `vm.sh start|stop|status|argv|log <name>`：讀 `run/droidvmd-port.txt` + token，走 IPC（`logs/vpu_survey/raw-5566-vm/dvmipc.py` 的形狀，改成 repo 內腳本）；daemon 沒起就用 `DaemonHelper.java:138-151` 的指令拉起（記得 `>/dev/null 2>&1 </dev/null`）。
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
