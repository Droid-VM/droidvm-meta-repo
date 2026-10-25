# iPadOS guest 的 3D 遷移到 virtio-gpu＋drm2kgsl（2026-10-25）

使用者決定 iOS guest 的 3D 不再走自訂的 `--droidvm-gpu` KGSL proxy，改走和 Linux guest 相同的 virtio-gpu＋drm2kgsl。
背景與各元件的 file:line 依據在 `IOS_VIRTIO_GPU_SURVEY.md`。本文件是執行計畫：每一步要交付什麼，以及怎樣算完成。

## 0. 現況盤點（2026-10-25 04:30 實機）

**主機端已經準備好。** 現在的 VM 就是用下面的參數跑的：
- `--gpu virglrenderer,…,context-types=drm,udmabuf=true` 加 `--virtio-mmio-gpu`。
- 開機時 crosvm log 有 `drm2kgsl_renderer_probe`：
  - KGSL chip 0x43051401（gpu_id 6770）。
  - VBO 128 GiB，切成 64 個 2 GiB 的 VA slice。
- 顯示走 pool-scanout udmabuf（`drm2kgsl 1-gpu-copy`）。

**主機端還缺：**
- `--pre-alloc drm-host-mb=…`：vdrm 的 16 KiB 控制 shmem 由這個 pool 切出，`MAP_BLOB` 回的是 pool offset。目前的 VM 沒帶這個參數。
- 跨 context 的 syncpoint：droidvm-gpu 用它維持各 client 提交的全序，IOSurface 的跨行程順序靠這個。要做成 opt-in，不能改變 Linux guest 的行為。

**guest 端：**
- `package/DroidVMVirtioGpu.cpp` 是 Codex 做的 transport，只供顯示用：
  - 單一控制 queue，一次只送一個命令，有一把全域鎖。
  - 用 `IOSleep(1)` 輪詢，每個命令至少 1 ms。
- 已協商 VIRGL、RESOURCE_BLOB、CONTEXT_INIT、CREATE_GUEST_HANDLE。
- 還沒有 3D context、capset、`SUBMIT_3D`、user client。

**droidvm-gpu 路線的 baseline（之後 A/B 的比較基準）：**
- GFXBench ALU 2：684–716 frames（22.8–23.9 fps）。
- MetalCheck：41 項全過。
- 一個 4-byte fill 從 commit 到完成 2.3 ms。

## 進度（2026-10-25 05:10）

- **M0 完成**（device `a65f143`）：VM 的 `extra_options` 加了 `--pre-alloc drm-host-mb=8`。
  - pool 在 0x1bf800000（8 MiB），從 `--mem` 扣除。
  - RAM window 變成 0x80600000+0x13f200000，`dram_size` 跟著改。
  - ADT 的 `/arm-io/virtio-gpu` 有 `drm-host-pool`。
- **M1 完成**（device `584c038`）：transport 改成 64 個 slot 同時在途，提供 `post`/`poll`/`wait`，顯示照舊。
  - 實測 3747 個命令，0 錯誤、0 逾時。
- **M2 完成**（device `c5b8cd3`）：開機自測（`vgpu-selftest=1`）全部通過。
  - capset 6（MSM，GPU 6770）→ CTX_CREATE → shmem blob 經 pool 對映（offset 0x200000）→ `SUBMIT_3D` 送 GET_PARAM(GPU_ID) → 在 shmem 讀回 6770。
  - 踩到的坑：host 只會複製回 guest 事先寫在 response 開頭的長度（防 TOCTOU），所以送出前要先寫 `rsp->len`，vdrm_alloc_rsp 也是這麼做的。
- **M3 完成**（device `f53dcb5`、NativeAdreno `e1272b7`、fork `c08168a`）：user client 已可用。
  - ABI 在 `package/DroidVMVirtgpuABI.h`。method 0x7200 起，透過 tunnel 呼叫；open type 0x4149 專給 virtgpu，不占 KGSL slot、拿不到 scanout，sandbox 授權方式和 plugin 一樣。
  - `gfxprobe virtgpu` 實測：
    - 建 context；shmem 對映進行程；ccmd 0.3 ms 回應。
    - guest-alloc BO（GEM_NEW 加 HOST3D_GUEST）寫入後讀回正確。
    - fenced NOP 0.2–1 ms signal；關閉後資源都釋放。
  - 超過 4096 bytes 的輸入走 OOL descriptor，tunnel 已支援，上限 64 KiB。
  - NativeAdreno 改從 Droid-VM fork 取（`.gitmodules`）。
- **M4 大致完成**（UniXNU `7d9c845`、device `6153420`、`a1a729e`）：做法和原計畫不同，沒有另寫 `vdrm_iokit`。
  - turnip 的 darwin 後端加了 `tu_knl_darwin_virtgpu`（`TU_DARWIN_VIRTGPU=1` 才啟用），把原本 KGSL 式的 NativeAdreno 呼叫轉成 virtgpu：
    BoAlloc/BoMap → GEM_NEW 加 HOST3D_GUEST blob；Submit → GEM_SUBMIT；WaitFence → WAIT_FENCE（ring 1）。
  - guest blob 改成每塊最多 4 MiB 的實體連續區塊，否則大於 16 MiB 的 BO 會超過 entry 上限而被拒絕。
  - MetalCheck 在新後端 31/41。剩下的 10 項（28、29、31、32、35–40）全部是 no-copy buffer 和 IOSurface，也就是 M5。
  - 舊後端（droidvm-gpu）同一版 41/41，GFXBench ALU 2 680、660 frames。
- **M5 完成**（NativeAdreno `6173fc8`、device `3b55fb7`／`87ed075`、UniXNU `9e7c605`）：kernel 加了 `CREATE_BLOB_USER`，把呼叫者的頁面 wire 住當成 guest blob。
  - wire 的方式照 NativeAdreno 的 import：`kIOMemoryPersistent`、`kIOMemoryMapperNone`，不能寫入時改成唯讀。
  - turnip 的 shim 回報 HostImport；`vkGetMemoryHostPointerPropertiesEXT` 在 GPU 是 IO-coherent 時也回報 cached-coherent 類型。
  - MetalCheck 在 virtio-gpu 路徑 41/41，IOSurface 和 no-copy 都過。
- **M6 完成**（UniXNU `3bf3dec`、device `87ed075`）：boot-arg `vgpu-3d=1` 讓所有 Metal client 預設走 virtio-gpu。
  - turnip 沒設 `TU_DARWIN_VIRTGPU` 時，會用 GETPARAM 0x101 問 kernel；設 `=0` 可強制走 droidvm-gpu。
  - A/B 結果：MetalCheck 兩邊都是 41/41；GFXBench ALU 2 在 virtio-gpu 是 1527、1499 frames（約 50 fps），droidvm-gpu 是 680、660（約 22 fps）；主畫面、widgets、桌布都正常。
  - 原計畫的 drm2kgsl opt-in syncpoint 沒有做，目前用不到。
- 下一步是 M7：再觀察一段時間沒有退步後，退役 droidvm-gpu。

## 1. 里程碑

| # | 內容 | 完成條件 |
|---|---|---|
| M0 | 主機：VM 的 `extra_options` 加 `--pre-alloc drm-host-mb=8`；`make-droidvm-adt.py` 從 crosvm FDT 的 `/reserved-memory` 把 drm-host pool 的 base 和 size 發佈到 ADT | guest 讀得到 pool；Linux guest 的啟動參數不變 |
| M1 | guest transport 改成非同步：多個命令同時在途，用 worker 輪詢或中斷收完成；顯示仍用阻塞式 API；fenced 命令依 (ctx, ring) 記錄 fence 序號 | 顯示與現在一致（screen-check PASS）；fenced `SUBMIT_3D` 等待時，顯示 flip 不會被擋 |
| M2 | guest 3D：`GET_CAPSET_INFO`/`GET_CAPSET`（capset 6）、`CTX_CREATE`（context_init DRM、64 rings）／destroy、`RESOURCE_CREATE_BLOB`（shmem 用 HOST3D+MAPPABLE；BO 用 HOST3D_GUEST+CREATE_GUEST_HANDLE，帶 guest 頁表，前面先送 `GEM_NEW` ccmd）、`MAP_BLOB`（只給 shmem，回 pool offset）、`SUBMIT_3D`（FENCE+RING_IDX）、`RESOURCE_UNREF` | kernel 自測：建 context、建 shmem，送 NOP 和 GET_PARAM ccmd，讀回 gpu_id 6770 |
| M3 | user client：沿用 AGXDeviceUserClient 的名字和 sandbox grant；方法對應 `DRM_IOCTL_VIRTGPU_*`：GETPARAM、GET_CAPS、CONTEXT_INIT、RESOURCE_CREATE_BLOB、MAP（IOConnectMapMemory）、EXECBUFFER（ring_idx，回傳 fence 序號）、WAIT、RESOURCE_INFO、GEM_CLOSE；以 fence 序號等待取代 syncobj | 一支 CLI（gfxprobe 新指令）在 guest 跑完 context→BO→submit→wait |
| M4 | userspace：turnip 用 `-Dfreedreno-kmds=virtio` 編譯，新寫 `vdrm_iokit` 後端（以 vpipe 為範本，約 11 個函式加 sync provider）；保留 darwin 的移植 patch；NativeMetal plugin 用 boot-arg 或環境變數選後端 | MetalCheck 在新後端 41 項全過 |
| M5 | `VK_EXT_external_memory_host` 在 virtio 後端重做：把已 pin 的 task 頁面包成 `MSM_BO_GUEST_ALLOC` blob（IOSurface 零複製） | MetalCheck 的 IOSurface 與 no-copy case（28、32、36–40）全過 |
| M6 | drm2kgsl 加 opt-in syncpoint；A/B 驗收：主畫面、設定、widgets、桌布、Safari、GFXBench ALU 2 | screen-check PASS；ALU 2 分數可以和 baseline 比較 |
| M7 | 退役 droidvm-gpu 和 Vm／Ring／Timer 替身類別，以及 crosvm 的 `--droidvm-gpu` | 新後端成為預設 |

## 2. 原則

- **共用程式碼要 opt-in。** drm2kgsl 和 crosvm 的 virtio-gpu 是 Linux guest 也在用的。iOS 需要的改動（syncpoint、pool 發佈）預設關閉，Linux 的行為不變。
- **用 A/B 驗收。** M4 起兩個後端並存，由 boot-arg 切換，同一套 MetalCheck、screen-check、GFXBench 兩邊都要跑。
- **droidvm-gpu 只修讓它壞掉的問題，不再優化。**
- **Vulkan 以上都保留。** NativeMetal、metal2vulkan 的修正、`newLibraryWithSource:`、IOMFBNumLayers 和後端無關。

## 3. 風險

- **WebKit GPU 行程的 sandbox 擋 `IOConnectMapMemory`。** vdrm 的 shmem 需要把它 map 進行程。備案：在 user client 裡複製回應，不做 map。
- **一致性。** `tu_bo_sync_cache` 依賴 EL0 的 DC 指令，而 `__ARM_COHERENT_IO__` 讓 flush 變成 no-op（參考既有的 pmap flush patch）。
- **完成延遲。** 現在的 transport 每個命令至少等 1 ms（`IOSleep(1)`）。M1 要做到次毫秒，否則每個 submit 都要多付這段延遲。
- **u32 seqno 繞回**（drm2kgsl 的 timestamp）。
- **VA 預算。** 64 個 slice 各 2 GiB；iOS 的 GPU client 數量要在這個範圍內。
