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

* 新 vhost-user 裝置 `crosvm device media --fd N --config-json ...`（`devices/src/virtio/vhost/user/device/media.rs`）：
  用同一個 `VirtioMediaDeviceRunner` + `Worker`，queue 由 vhost-user 框架給；shm region 由 backend request 連線映射（gpu 先例）；池 handle 由 `--pool-fd/--pool-gpa/--pool-size` 傳入（fd 繼承）。
* frontend：`--vhost-user type=media` 支援（`DeviceType::Media`、2 條 queue、shm region 轉發）。
* `snd_helper.rs` 泛化為 `device_helper::launch(kind, params)`，camera / decoder / encoder 帶 `uid=` 時走它；**exec 不是 fork**（binder 狀態不過 fork，`snd_helper.rs:15-19`）。
* backend 一律 `base_features(protection_type)`（不要學 `snd.rs:95` 寫死 `Unprotected`，否則 pVM 下 virtqueue 落 lent RAM，`VIRTIO_SND_PROTECTED_VM.md`）。
* `/dev/udmabuf` 是 `0600 root`：helper 內的 `dmabuf()` 會失敗，屆時走 backend request 請 VMM 代建；v1 無消費者，先不做。

---

## 7. 相機與編解碼（沿用舊 plan §3–§5，修訂如下）

* 相機裝置（`vmedia/device/src/devices/camera.rs`）：CAPTURE-only、MPLANE NV12（host 從 NV21 swap chroma，舊 plan D33）、`poll_fd` = eventfd 由 `AImageReader` callback 觸發、`process_events` 把幀拷進池內 CAPTURE buffer 並發 DQBUF。`Camera` 是 `!Send`（raw pointers）→ 在 worker thread 內開、關。
* `android_camera` 要補：`ACaptureRequest_setEntry_i64`、AF_TRIGGER / 各 AVAILABLE_* 特性讀取、rational 讀取（AE compensation step）、capture-result callback（A3）、`open()` 錯誤路徑的資源釋放（今天會漏，`android-camera-crate.md` §1.13）。
* **stream use case 沒有 NDK API**（只有 Java `OutputConfiguration#setStreamUseCase`）→ 舊 plan D18(2) 改列為「待 JNI 或放棄」。
* 數值 ABI：5566 曝光下限 85 µs < 舊 plan 的 100 µs 單位；ISO 上限 16000。→ §11 Q4。
* codec：`AMediaCodecStore` API 36 在 5566 上齊全（含 `findNext*ForFormat`、`AMediaCodecInfo_getVideoCapabilities`）；`AMediaCodec_getOutputImage` **不存在**，YUV 版面要靠 `getOutputFormat` 的 `stride`/`slice-height`（+ 以字串鍵讀 `"image-data"`）。Store 的名字要用 `AMediaCodecInfo_getCanonicalName()` 再 `createCodecByName`。色彩格式與 profile/level 清單 NDK 不給，用 `AMediaCodecInfo_isFormatSupported` 探測固定候選集。
* 軟體 codec（VP8、AV1 編）：預設過濾 `HARDWARE_ACCELERATED`，以 `--virtio-media` 參數 `allow_sw=true` 打開。→ §11 Q5。

---

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
