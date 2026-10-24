# iPadOS guest 接上 virtio-gpu（drm2kgsl → venus／gfxstream）survey（2026-10-24）

問題：UniXNU（iPadOS 17.7.11）guest 能不能優雅地改走現有的 virtio-gpu 路線？目前它的 3D 走自訂的 `--droidvm-gpu` KGSL proxy，
顯示走 simplefb。先接 drm2kgsl，將來能不能換成 venus 或 gfxstream？

依據：三路源碼的唯讀調查，所有主張都附 file:line。路徑前綴：
- `M`＝本 repo
- `C`＝`M/crosvm`（wip/virtio-mmio）
- `V`＝`M/virglrenderer`
- `Me`＝`M/mesa`
- `U`＝UniXNU 工作區（裝置 repo `UniXNU-droidvm`，fork `orgrepos/UniXNU`，元件 `orgrepos/*`）

---

## 0. 結論

1. **可以，而且有一條乾淨的路：一個通用的 XNU virtio-gpu 驅動，使用者空間的 3D 後端可以替換。**
   - 顯示（2D／blob scanout）和 3D context 放在同一個 virtio-mmio virtio-gpu 裝置上。
   - 使用者空間依路線換後端：
     - drm2kgsl：turnip 的 virtio 後端，加上 `vdrm_iokit`。
     - venus：vn renderer 後端。
     - gfxstream：`platform/darwin` 的 VirtGpuDevice。
   - mesa 已經留好這些接縫：
     - `vdrm_device_funcs` 表，已有 vtest／vpipe 後端（`Me`/src/virtio/vdrm/vdrm.h:28-52、vdrm.c:14-24）。
     - turnip 支援 fd＝-1（`Me`/src/freedreno/vulkan/tu_knl_drm_virtio.cc:1761-1768）。
     - gfxstream 的 VirtGpu 平台層，以 kumquat 為先例（`Me`/src/gfxstream/guest/platform/include/VirtGpu.h:139-228）。
2. **drm2kgsl 是自然的第一步。** 它和 droidvm-gpu 的機制幾乎一樣：
   - guest 頁面 → udmabuf → `GPUOBJ_IMPORT`（IOCOHERENT）→ 在一個 VBO 上 `GPUMEM_BIND_RANGES`。
   - 每個 client／queue 一個 drawctxt，使用 user timestamp。
   - 對照：droidvm_gpu.rs:720-905，`V`/src/drm/drm2kgsl/drm2kgsl_renderer.c:834-855、2257-2290、1228-1231。
   - 差別只在「誰跟主機講話」：droidvm-gpu 是 guest kernel 一個 op 對應一個 KGSL 原語；drm2kgsl 是 userspace 送 msm ccmd，kernel 只負責轉送。
   - 實測三條路線裡 drm2kgsl 最快（ACCEPTANCE_REPORT_R5_20260817.md:12-18；8e：vkmark 8625、Minecraft 74-112 fps）。
3. **顯示現在就能做，不必等 3D：**
   - classic 2D 的 present 和 guest 的 `RESOURCE_FLUSH` 同步；仍須等待 producer GPU 完成，才能避免讀到尚在繪製的畫面。代價是主機上 3 次 CPU 複製。
   - 之後改成 blob（`CREATE_GUEST_HANDLE`）：主機 0 次 CPU 複製、1 次 GPU blit。
4. **venus／gfxstream 的主要代價：**
   - 需要 host-visible 共享記憶體（virtio-mmio 目前沒有 SHM region）。
   - 失去 `VK_EXT_external_memory_host`：IOSurface 零複製目前只有 turnip-darwin 提供。
   - 失去 turnip 端的 pipeline cache 和 builtin pack。

---

## 1. 現況：iOS guest 的 GPU 堆疊（droidvm-gpu）

**Metal 到 Vulkan：**
- NativeMetal frontend 和 metal2vulkan 包在 `NativeAdrenoMetal.bundle` 裡，載入到 GPU client 行程。
- turnip 用自訂的 **darwin KMD** 編譯（`-Dfreedreno-kmds=darwin`）。實作是 `U`/orgrepos/UniXNU/patches/mesa/turnip-darwin-kmd.patch，新增 `tu_knl_darwin.cc`。
- turnip 不發 KGSL ioctl，而是呼叫 NativeAdreno ABI v1 的 16 個方法（`U`/orgrepos/NativeAdreno/NativeAdrenoABI.h:13-35）。

**turnip 到 kernel：**
- 開啟 `IOAcceleratorES`（open type 0x4147），經由一個被允許的 selector 送出 `{'NTNL', method, payload}` 通道（patch:348-389）。
- kernel 端是 `AGXDeviceUserClient::externalMethod`（NativeAdrenoPublish.cpp:487-535）。取 Apple 的類別名稱，是為了讓 sandbox 放行。

**kernel 到主機：** 裝置 repo 的 `package/DroidVMGpu.cpp` 只替換 NativeAdreno 的 Vm／Ring／Timer 三個硬體類別。
- wire op 有 INFO、IMPORT、FREE、BIND、SUBMIT、RETIRED、WAIT、TICKS、CLIENT（DroidVMGpuWire.h:25-33）。
- 單一 virtqueue，以輪詢方式運作，加一把 mutex，逾時 5 s（DroidVMGpu.cpp:94-263）。

**主機端：** `C`/devices/src/virtio/droidvm_gpu.rs 對 `/dev/kgsl-3d0` 下指令：
- IMPORT：udmabuf 包住 guest 物理範圍，再 `GPUOBJ_IMPORT`（720-776）。
- BIND：`BIND_RANGES`（778-827）。
- SUBMIT：`GPU_COMMAND`，帶 timestamp syncpoint；每個 client 一個 drawctxt（829-905）。

**記憶體：**
- BO 就是 guest RAM。預設 512 MiB 連續 pool 一次 import，之後只 BIND；其餘 BO 逐段 import。
- VBO 至少 32 GiB，每個 client 一個 1 GiB 的 VA window（build-droidvm-gpu.py:54-93）。
- IOSurface：frontend 直接 import base address（NativeBridgeMetalFrontend.mm:1329-1337），經 turnip 新增的 `VK_EXT_external_memory_host`，由 `BoImport` pin 住 task 頁面（NativeAdrenoMemory.cpp:162-214）。

**同步：**
- 所有 client 共用一條 u32 序號。
- **每個 `GPU_COMMAND` 都以 syncpoint 等其他 client 最新的提交**，以維持全序（droidvm_gpu.rs:834-858）。
- 跨行程依賴這個全序：app 畫進 IOSurface，render server 才去取樣。

## 2. drm2kgsl 需要的 virtio-gpu 能力（主機端）

**guest 端的流程（vdrm_virtgpu.c）：**
- **context：** capset 6（DRM），`context_type` MSM；`CONTEXT_INIT` 帶 NUM_RINGS=64（`Me`/src/virtio/vdrm/vdrm_virtgpu.c:337-350）。
- **控制 shmem：** 16 KiB，blob_id 0，HOST3D+MAPPABLE（:352-384）。
  - 主機從 `drm2kgsl_host` arena 切出這塊，`MAP_BLOB` 回覆 `VIRTIO_GPU_MAP_INFO_POOL`（padding 欄位帶 pool offset）。
  - 出處：drm2kgsl_renderer.c:2146-2238、protocol.rs:89-91、virtio_gpu.rs:2139-2156。
- **每個 BO：**
  - `HOST3D_GUEST` + `CREATE_GUEST_HANDLE`（0x8），同一個 `CREATE_BLOB` 內嵌 `GEM_NEW` ccmd（vdrm_virtgpu.c:188-199）。
  - 主機只接受帶 `MSM_BO_GUEST_ALLOC` 的請求（drm2kgsl_renderer.c:1348-1373），由 crosvm 用 iovec 建 udmabuf（virtio_gpu.rs:2010-2046）。
- **fence：** ring_idx 對應 submitqueue，完成時走 `TIMESTAMP_EVENT` → drm_timeline（drm2kgsl_renderer.c:1876-1904）。
- **wire op：** NOP、IOCTL_SIMPLE（GET/SET_PARAM、SUBMITQUEUE_NEW/CLOSE）、GEM_NEW、GEM_SET_IOVA、GEM_CPU_PREP、GEM_SET_NAME、GEM_SUBMIT、GEM_UPLOAD、SUBMITQUEUE_QUERY、WAIT_FENCE、SET_DEBUGINFO（msm_proto.h:52-64；handler 在 drm2kgsl_renderer.c:1962-1975）。

**實作與啟動：**
- 翻譯層在 virglrenderer，不在 crosvm（`V`/src/drm/drm2kgsl/）。
- 啟動參數：`--gpu backend=virglrenderer,context-types=virgl2:drm,…,udmabuf=true,pci-bar-size=4294967296 --pre-alloc drm-host-mb=8,gpu-guest-mb=1024`（deploy/drm2kgsl/run_drm2kgsl_nctx.sh:102-118），另需 udmabuf-gki 模組。

**pseudo-unprotected（iOS VM）的情況：**
- guest RAM 是 SHAREd 視窗，`pool_ref_iovecs` 只檢查和 pool 重疊的 iovec（vm_memory/src/guest_memory.rs:808-836），所以任何 guest 頁面（包括 IOSurface）都能當 BO。
- **不需要 `gpu_guest` pool。**

## 3. virtio-mmio 傳輸的缺口（crosvm）

- **`VirtioMmioDevice`（`C`/devices/src/virtio/virtio_mmio_device.rs）：**
  - 支援 virtio 1.x、多 queue、每個 queue 一個 notify ioevent（:74-117、304-339）。
  - **沒有 SHM region：** SHMLen 讀回 -1、SHMBase 讀回 0、SHMSel 的寫入被忽略（:235-237、340）。也從不呼叫 `get_shared_memory_region`。
- **host-visible region 只做在 PCI BAR 上：**
  - PCI 端：virtio_pci_device.rs:833-842、1083-1161；shared memory tube 只在 PCI 路徑建立（linux.rs:1462-1475）。
  - 沒有 mapper 時，非 pool 的 MAP 路徑會 panic（`expect`，virtio_gpu.rs:2274、2334）；pool 內的 map 會先 return，不受影響（:2139-2156）。
- **drm2kgsl 用 pool 就夠了：**
  - 要做的事：加 `--virtio-mmio-gpu`，照 `virtio_mmio_net` 的做法（cmdline.rs:2846、3275；config.rs:1221；linux.rs:1452-1459、1544）。
  - guest 要知道 `drm2kgsl_host` pool 的 base：Linux 從 FDT `/reserved-memory` 讀（droidvm-guest-additions/virtio_gpu/virtgpu_kms.c:56-93）；XNU 要由 make-droidvm-adt.py 另外發佈。
- **venus／gfxstream 需要更多：**
  - 在 mmio 上實作 SHM 暫存器。
  - 在 RM 範圍內配一段 GPA 視窗。
  - 把 `VmRequester` 從 virtio_pci_device.rs 搬出來，加上 VmMemoryTube 和 `set_shared_memory_mapper`／`region`。
  - 或者走 `PARAM_HOST_VISIBLE`＋pool 的路，前提是可行。

## 4. guest 要補什麼

**kernel：一個 IOKit virtio-gpu 驅動（大）。**
- feature：VERSION_1、ACCESS_PLATFORM（pseudo-unprotected 會設，virtio/mod.rs:290-298）、VIRGL、RESOURCE_BLOB、CONTEXT_INIT、CREATE_GUEST_HANDLE。CREATE_GUEST_HANDLE 只在 `udmabuf=true` 時提供（device_constants.rs:115-122）。
- 指令：GET_CAPSET_INFO／GET_CAPSET、CTX_CREATE／DESTROY、CTX_ATTACH／DETACH、SUBMIT_3D（FLAG_FENCE＋RING_IDX）、RESOURCE_CREATE_BLOB（兩種）、MAP_BLOB（只給 shmem 用）、RESOURCE_UNREF。顯示另外需要 2D／blob scanout 指令（第 5 節）。
- user client 鏡射 `drm_virtgpu_*` 和 syncobj 的 ioctl 結構。
- 可直接沿用的部分：
  - 現有的 AGXDeviceUserClient 名稱和 open type，以及 sandbox grant（DroidVMGpu.cpp:820-885）。
  - `NativeAdrenoMemory` 的 pool 和 `importTask`。
  - write-combined 的 CPU view。
  - BO 生命週期修正（build-droidvm-gpu.py:94-231）。
  - virtio-mmio 初始化流程（DroidVMGpu.cpp:153-203）。

**使用者空間：turnip-virtio（中）。**
- 用 `-Dfreedreno-kmds=virtio` 編譯，接一個 `vdrm_iokit` 後端：11 個函式，加上約 14 個 sync provider 函式，以 vpipe 為範本（vdrm_vpipe.c:856-1330）。
- 要取代的 DRM 呼叫：
  - `drmGetCap(SYNCOBJ)`（tu_knl_drm_virtio.cc:1765）
  - `drmSyncobjCreate`／`Destroy`／`Transfer`（:229、257、849）
  - VIRTGPU 的 EXECBUFFER、GEM_CLOSE、RESOURCE_INFO、CREATE_BLOB、MAP＋mmap、WAIT、GET_CAPS、CONTEXT_INIT、GETPARAM、PRIME（vdrm_virtgpu.c 對應行）
- 保留 darwin 的移植 patch：`CTR_EL0`、condattr、匯出 `vkGetInstanceProcAddr`、metal-layer WSI、builtin pack（目前 meson 條件綁在 darwin kmd 上，要改綁平台）。
- **`VK_EXT_external_memory_host` 要在 turnip-virtio 上重做（中）：** 用 `MSM_BO_GUEST_ALLOC` blob 包住已 pin 的 IOSurface 頁面。這是 IOSurface 零複製的基礎。

## 5. 顯示：virtio-gpu scanout

**classic 2D：**
- `ATTACH_BACKING` 不複製。
- `TRANSFER_TO_HOST_2D` 是第 1 次複製（rutabaga_2d.rs:196-250）。
- `RESOURCE_FLUSH` 用 `transfer_read` 做第 2、3 次複製：先到 staging，再到 Android 視窗並交換 R/B（virtio_gpu.rs:900-972）。
- 全部同步完成才回覆，`ANativeWindow_lock` 會把 guest 的節奏拉到和 SurfaceFlinger 一致；這只涵蓋消費端，來源的 GPU 完成依賴仍須由 guest 保證。

**blob scanout（`SET_SCANOUT_BLOB`）：**
- 只接受 XR24、AR24、AB24（mod.rs:872-880）。
- `CREATE_GUEST_HANDLE` blob 走 udmabuf import 加 `flip_to`：0 次 CPU、1 次 GPU blit（virtio_gpu.rs:1026-1095）。原實作 25 ms 後強制完成 fence（mod.rs:478、1002-1077）；2026-10-24 實測發現會破壞來源頁面重用順序，本輪已移除此假完成路徑。
- 沒有 handle 的 guest blob 不能用（:670-674）。
- 2D 後端（Rutabaga2D）目前沒有 `create_blob`：要在 `udmabuf=true` 時開放 `RESOURCE_BLOB`＋`CREATE_GUEST_HANDLE`，改動不大。

**同一個裝置同時做 2D 和 3D：**
- `backend=2d` 時沒有 capset，只有 EDID（mod.rs:2348-2369）。
- virglrenderer 下 classic 2D 由 vrend 處理；gfxstream 下交給 Rutabaga2D（rutabaga_core.rs:768-785、1462-1476）。

**2D 的坑：**
- 資源寬度要等於 IOSurface stride／4，例如 1376。2D 的 src stride 固定是寬×bpp（rutabaga_2d.rs:224）。
- 顯示 surface 的大小取自 `SET_SCANOUT` 的 rect（virtio_gpu.rs:464-529），1366×1024 會正確裁切。
- rect 的 x／y 被忽略。
- `TRANSFER_TO_HOST_2D` 的 offset 會被重複計算（rutabaga_2d.rs:52、225）→ **一律送 offset=0**。
- 格式用 B8G8R8X8。

**app 端：**
- `display_backend` 是已經沒作用的舊欄位（VMScreenConfig.java:543-597）；真正決定的是 `screens.gpu-0`／`screens.simplefb` 的 enabled 和 exporter（CrosvmBackendInstance.java:765-939）。
- `gpu-0` 要設成 NATIVE、1366×1024、`GPU_2D`。`gpu_mode` 不可以是 NATIVE／VULKAN，否則會加上 `context-types=drm`（:825-849）。
- 輸入裝置名稱會變成 `(gpu-0)`，guest 不依賴名稱。
- `--virtio-mmio-*`、`--droidvm-gpu` 來自 `extra_options`。

**開機畫面：**
- 刻意沒有 simplefb→gpu-0 的接手機制（DISPLAY_PIPELINE_DECOUPLING.md:321-344）。guest 驅動第一次 flush 之前，gpu-0 是黑的。
- simplefb 裝置要保留：它佔 RAM 頂端，dram_size 和 panic region 都依賴它。exporter 設成 NONE，或者用 VNC 除錯。
- 解法：guest 驅動一起來，就用 simplefb 的頁面建一個 2D 資源（pitch 1376）定期 flush，直到 compositor 第一次 swap；panic 時也這樣做。
- 風險：edk2 的 GunyahVirtioGpuDxe 會綁 virtio-mmio 的 GPU（DriverBinding.c:200-250、586-633），從未在 mmio 上測過。要確認 DarwinBoot 拿到的是 simplefb 的 GOP。

## 6. 風險與待確認

- **跨行程順序：** drm2kgsl 沒有 syncpoint，而 droidvm-gpu 加上 syncpoint 正是為了修實際發生過的畫面錯亂。要以 opt-in 的方式搬進 drm2kgsl 的 GEM_SUBMIT。
- **WebKit GPU 行程的 sandbox 擋 `IOConnectMapMemory`：** vdrm 的 shmem 需要它。
- **一致性：** `__ARM_COHERENT_IO__` 讓 `flush_dcache` 變成 no-op（所以有 pmap flush patch）；drm2kgsl 的 guest-pool fence 需要 `tu_bo_sync_cache`，它依賴 EL0 的 DC 指令。
- **VA 預算：** 32 個以上的 context × 2 GiB slice 需要 VBO ≥ 64 GiB（SM8650 給 128 GiB）。
- **u32 timestamp 繞回：** droidvm_gpu.rs 的 `retired()` 沒處理。
- **文件落差：**
  - SETUP.md:107 和 NATIVE_CONTEXT_PLAN.md 寫的是 host-alloc BO，程式碼已經只剩 guest-alloc。
  - DroidVMGpuWire.h:15-16 仍寫「single KGSL context」，實際是每個 client 一個 context。

## 7. 建議路線（依序）

| 步驟 | 內容 | 規模 |
|---|---|---|
| 1 | crosvm `--virtio-mmio-gpu`（2D 後端）；app 的 gpu-0 設定 | 小 |
| 2 | XNU virtio-gpu 驅動核心：transport、控制 queue、fence、資源管理；顯示 client 接上 NativeLegacyDisplay 的 GPU 交付 hook（`native_legacy_gpu_offer` → flush fence → retire swap）→ 不撕裂，也去掉 guest 端 56 ms 的複製 | 中 |
| 3 | 2D 後端提供 `CREATE_GUEST_HANDLE` blob；guest 改用 blob scanout | 小 |
| 4 | 主機：drm2kgsl 加 syncpoint；`drm2kgsl_host` pool 發佈到 ADT；裝置改成 virglrenderer＋`virgl2:drm` | 小～中 |
| 5 | XNU 驅動加上 context、blob、`SUBMIT_3D`，以及鏡射 virtgpu ioctl 的 user client | 大 |
| 6 | turnip-virtio＋`vdrm_iokit`；`external_memory_host`；用 boot-arg 和 droidvm-gpu 做 A/B（Settings、widgets、wallpaper、Safari） | 中 |
| 7 | 退役 droidvm-gpu 和 Vm／Ring／Timer 的替身類別 | 小～中 |
| 8 | venus 或 gfxstream：mmio SHM region、各自的使用者空間後端；`external_memory_host` 改成模擬（複製） | 各為大 |

**為了不白做：** 第 2 步的驅動要拆成兩層：通用 transport（virtqueue、命令＋fence、資源表），和顯示 client。第 5 步的 3D user client
直接重用同一套 queue 和 fence。

## 8. 實機更新（2026-10-24）

使用者改為直接做 drm2kgsl 3D，並移除 simplefb device。無 simplefb 開機與 blob 顯示已完成基本 bring-up；
DarwinBoot 為 BLT-only GOP 配置普通 RAM，guest 以同一 virtio-gpu 裝置接管。3D 目前仍使用原 KGSL proxy。

動畫測試揭露本 survey 原本漏掉的 producer/acquire fence：framebuffer 交付並不等於 GPU 已完成這幀。
全域 guest GPU timestamp 的等待開關 A/B，與移除 host 的 25 ms 假完成，詳見 `PROGRESS.md`「動畫閃爍調查」。
正式條件必須是 producer 完成後才開始 blit，blit 完成後才 retire；單有 RESOURCE_FLUSH completion fence 不足。
