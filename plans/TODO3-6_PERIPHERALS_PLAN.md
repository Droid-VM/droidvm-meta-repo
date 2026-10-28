# TODO 3～6（音訊、VPU／相機、定位、電池）＋ 8 Elite Gen 5 的 3D：調查結論與推進方式

2026-10-28 起，Claude；2026-10-29 更新。依據：stock 21H461 映像（rootfs、SystemOS cryptex、dyld cache 抽出檔）的分析，與在第二支測試手機上的實機驗證。
原則照 PROGRESS.md 第 7 節：使用者功能走 iPadOS 原廠機制，ownervisor 只除錯；host 端只加通用虛擬裝置。
分工（使用者 10-28）：**crosvm 提供通用設備（Windows／Linux 也能用）；XNU 讀通用設備，翻譯成 userspace 看得懂的介面；userspace 只負責呈現到 app。**

## 狀態總表

| 項目 | 狀態 | 剩下的 |
|---|---|---|
| TODO 3 音訊 | 原廠堆疊整條通；Safari 播放經手機喇叭實際出聲（10-28） | app 內錄音驗收 |
| TODO 4 VPU／相機 | host＋Linux guest 完成；iPadOS 傳輸層里程碑 1 完成（10-29） | 解碼往返、encoder／camera、接 VideoToolbox／相機堆疊 |
| TODO 5 定位 | GPS 調查完、**暫停**（使用者 10-28） | J121AP 身分實測 |
| TODO 6 電池 | 完成（10-28） | — |
| 8e5 的 3D（Adreno 840） | 完成（10-29），seed 已換新 plugin | 5567 main tree 的 seed 同樣陷阱 |
| 動態 ADT | 完成（10-29），5566 rig 開機碟上使用 | payload build 改用（要協調 fork 的 DarwinBoot pin） |

## 測試環境（與 TODO 2 隔離）

TODO 2 在原本的手機上進行；本項改在第二支手機（SM8850／Adreno 840，Android 16，kernel 6.12）：
- 本機：device repo worktree `UniXNU-droidvm-land`（分支 `wip/peripherals`，接在 `droidvm/wip/hackintosh` 上，不含 TODO 2 的本機實驗 commit；
  10-29 前用的是 `UniXNU-droidvm-audio`／`wip/audio`）、rig 目錄 `droidvm-5566`（rig.env 指向這支手機與 Mac 上獨立的輸出目錄）、
  `guest-run.sh`（經 export.py 走 ownervisor 的 control spool 在 guest 內以 root 執行指令，不需要網路）。
- Mac：獨立的 BUILD_REPO worktree（`/Volumes/DATA/UniXNU/audio/UniXNU-droidvm`，用 git bundle 切到 `wip/peripherals`；5566 的 trust pin 以未 commit
  的 board.toml 修改保留）與 `UNIXNU_OUT=/Volumes/DATA/UniXNU/audio/out`。kernel：把改過的檔案 rsync 過去，從 fork 跑
  `UNIXNU_OUT=... ./unixnu build kernel`。從零建置會缺 audit 用的 reference-candidate 等中間產物，要先從主 tree 複製。
- DarwinBoot 獨立建置（Mac 的 fork checkout 是兩個 session 共用的）：本機 `orgrepos/DarwinBoot-rebase` rsync 到 `audio/DarwinBoot`，另建小 tree
  `audio/dbtree/tree`（`drivers/DarwinBoot` 指向它、`package` 指向 fork 的 package；Conf 與 toolchain 從主 out 複製），
  `build-darwinboot-efi.sh dbtree/tree audio/out/feeds/mu_basecore-89034cbb DEBUG`，產物直接 mcopy 進 rig 開機碟。
- 手機：app r312、本 fork 的 crosvm、os/systemos/edk2 映像、新的 Data store、VM 寫進 vms.json。**只用 IPC 的 `vm_modify` 改設定不會存進 app 的
  `files/vms.json`**（daemon 重啟或 app 按 ▶ 就被蓋回），要同時改 vms.json（保留 owner、權限、SELinux label、4 格縮排）與 rig 的 `unixnu-vm.config.json`。
- 陷阱：`deploy.sh --kernel-only` 推的是 rig 裡整顆 boot disk，不只 kernel；兩個 session 共用一個 rig 時會把對方的 trust cache 蓋回去。
- 手機重開後模組與 hugepage pool 會消失：`gh_hugepage_reserve.ko` 在使用者的 KernelSU 目錄（請使用者 insmod），`load-modules.sh` 依 `uname -r` 選模組目錄。

## TODO 3 音訊：IOAudio2Device ＋ virtio-snd

- **設計**：CoreAudio 的 HAL（audiomxd 的 HALS_IOA2Manager）只認經 `IOAudio2DeviceUserClient` 開啟的 `IOAudio2Device`。這兩個類別名稱已被
  prelink 的閉源 IOAudio2Family 佔用，所以 `package/DroidVMAudio.cpp` 用自己的類別名稱、自己實作 user client ABI（registry key、status 頁、ring、
  selector、hog mode），在 attach 時把 metaclass 接到原 family 的 metaclass 底下（IOService matching 與 IOObjectConformsTo 只看這個）。
- **依 UID 分裝置**：VirtualAudio 的 DeviceFactory_Aspen 依 device UID 選單一換能器類別：`Speaker` → 可路由的喇叭 port（並載入 J120 的喇叭 DSP），
  `Mic` → 內建麥克風 port。`Codec` 需要聲學資料庫、做不出可路由 port。clock domain 不能是 0。
- **傳輸**：`package/DroidVMVirtioSnd.c`，輪詢式 virtio-snd（48 kHz S16、輸出立體聲、輸入單聲道、5 ms period），ADT `/arm-io/virtio-snd`。
  crosvm：`--virtio-mmio-snd`（card 接在 virtio-mmio）、vhost-user frontend 在沒有 MSI-X 時改用共用中斷、並尊重 `VIRTQ_AVAIL_F_NO_INTERRUPT`
  （否則輪詢的 guest 被沒人 ack 的 level SPI 灌爆，launchd 卡死）。
- **驗收**：self-test（`droidvm-snd-selftest=N`）＋ crosvm `backend=file` 逐位元正確；Safari 播 MP3 以即時速率送到手機 AudioFlinger，
  音量調到 40/160 後手機喇叭實際出聲（手機原本媒體音量 0；`cmd media_session volume --set` 在這支手機設不進去，要用音量鍵 keyevent）。
- **剩**：app 內錄音。Voice Memos 按錄音沒反應（tccd 為 `voicememod` 建身分時 LaunchServices 回 -10814，麥克風權限多半卡在 app 登記）。
- 已 push：device `wip/hackintosh` 1f57203、crosvm 8871a821f／cc88041e5。

## TODO 4 VPU／相機

### host＋Linux guest：完成
三個 virtio-media 裝置（相機、解碼器、編碼器）、vhost-user helper（app uid）、`media_host`／`media_guest` pool、Linux guest driver（DKMS）、
libva-v4l2 都完成，出貨組態驗收大多關閉；細節與仍開著的 P-5／P-6 見 `plans/VPU_DESIGN.md` §7.8。

### iPadOS guest：傳輸層
目標順序（使用者 10-29：先做傳輸層）：1. 傳輸層通（列出裝置與格式）→ 2. kernel 自檢跑完整解碼往返 → 3. encoder、camera 裝置 →
4. 決定怎麼接原廠 VideoToolbox 與相機堆疊（XNU 翻譯成原廠 userspace 看得懂的介面；需要分析原廠驅動介面，另行討論）。

**里程碑 1 完成（10-29，5566）**：guest 開機自檢 `droidvm decoder caps 0x4004000 out: H264 HEVC VP90 AV01 cap: NV12`（9 個 command、0 timeout）。
- crosvm：`--virtio-mmio-media`，把 `--virtio-media` 裝置接在 virtio-mmio、snd 之後（加一個不會讓既有視窗重新編號）。帶 uid 的裝置仍是
  vhost-user helper，MMAP buffer 從 `media_host` pool 配，不需要 SHM（crosvm 的 virtio-mmio 沒有 SHM region）。欄位有字母序 lint。
- VM：`--pre-alloc drm-host-mb=8,media-host-mb=64`、`--virtio-media kind=decoder,uid=<app uid>`、`--virtio-mmio-media`。Gunyah 上沒有
  `media-host-mb` crosvm 會拒絕建 virtio-media。`media_host` 是 `consume_system_mem`：pool 疊在 RAM block 上方，block 會變短
  （RAM `0x13f200000` → `0x13b200000`，drm pool 搬到 `0x1bb800000`，media pool 在 `0x1bc000000`）——由動態 ADT 自動處理。
- guest：`package/DroidVMVirtioMedia.c`，每個 `/arm-io/virtio-media-N` 一份輪詢式 virtio-mmio 傳輸（VERSION_1＋ACCESS_PLATFORM、commandq／eventq、
  16 個 event buffer、每個裝置一次一個 command），API：`droidvm_media_open/close/ioctl/mmap/munmap`（mmap 回 pool 內的絕對 GPA）。
  協定：commandq 的 IOCTL 帶 `_IO*` 編號與 payload（W 類送出、R 類寫回、WR 共用同一塊）；eventq 送 DQBUF／EVENT／ERROR。
  **陷阱**：`VIDIOC_QUERYCAP` 是 driver 用 config space（`device_caps`、`device_type`、`card[32]`）自己答，送給 device 會回 ENOTTY（25）。
- 狀態變數（peek.py）：`droidvm_media_found/up/stage/commands/timeouts/events`、`droidvm_media_status[N]`。

**里程碑 2（下一步）**：自檢裡跑一次解碼：S_FMT（OUTPUT＝H.264）、REQBUFS(MMAP)、QUERYBUF＋MMAP（pool 內的 GPA）、QBUF 一段小的 H.264、
STREAMON、處理 SOURCE_CHANGE 事件後配 CAPTURE、DQBUF 事件、NV12 校驗（與軟解比對）。

## 動態 ADT（使用者 10-29 提議）

問題：ADT 原本在 Mac build payload 時由 `make-droidvm-adt.py` 從「上一次開機 dump 的 FDT」產生；crosvm 裝置或 pool 一變就要先開機 dump、重產、
再開機，`dram-size` 對不上 shim 的 `/memory` 就出事。

做法：ADT 拆兩半。
- **靜態**（payload，`make-droidvm-adt.py --dynamic`）：iPad 身分、`/product`、`/buttons`、`/chosen` 的 security 值、memory-map 佔位、cpus、GIC 等；
  `/chosen darwinboot-fdt`＝3 表示要 DarwinBoot 補哪些，裝置節點全部省略（不需要 `--data-store-mmio`、`--input-mmio`、`--net-mmio`、
  `--virtio-gpu-mmio`、`--snd-mmio`、`--media-mmio`、`--battery`）。
- **動態**（DarwinBoot `DarwinBootPkg/Driver/FdtAdt.c`，讀完 ADT 後、找佔位前）：經 EDK2 的 `FDT_CLIENT_PROTOCOL`（EmbeddedPkg FdtClientDxe；
  不論 ACPI 或 DT 模式都在，config table 只有 DT 模式才裝；Mu basecore 沒有 EmbeddedPkg，GUID 與函式表在本地定義）。
  - bit0 RAM：shim 把整個 RAM 視窗放在 `/memory` 第一個 range → `dram-base/size`；`/pram`、`darwinboot-memory-limit`、`darwinboot-video-memory`、
    `kern.maxvnodes` 依 `make-droidvm-adt.py` 的公式原地重算。
  - bit1 裝置：逐一讀 FDT 每個 `virtio,mmio` 視窗的 DeviceID（2 block：`VIRTIO_BLK_F_RO` → `virtio-mmio-N`、第一個可寫的 → `data-store`；18 →
    `input-N`；1 → `net`；16 → `virtio-gpu`＋`drm-host-pool`；25 → `virtio-snd`；48 → `virtio-media-N`＋`media-host-pool`），pool 取 `droidvm,pool`
    節點的 `droidvm,pool-name`，`google,goldfish-battery` → `battery`；接在 `/arm-io` 原有子節點之後。
  - 沒有 `darwinboot-fdt` 的舊 ADT 行為不變（相容）。
- 驗證：host harness（EDK2 stub header、自寫 FDT parser 當 FdtClient、在 `0x0a000000` 以 MAP_FIXED 放假 virtio 暫存器、ASan／UBSan）
  補完的 ADT 與 Python 靜態 ADT 逐位元相同（現況、加 media 兩種配置）；5566 實機：`DARWINBOOT: FDT RAM 0x80600000+0x13B200000`、
  `FDT devices: 2 disk(s) + data store, 5 input, net, gpu, snd, 1 media, pools ...`，開機完整。
- 尚未：board.toml `[payload.adt]` 改 `--dynamic` 必須與新版 DarwinBoot 一起進 payload（舊 DarwinBoot＋dynamic ADT 會沒有裝置），
  要更新 fork 的 `drivers/DarwinBoot` pin，影響兩個 session 的 build，需協調。目前 5566 rig 的開機碟手動替換（備份 `out/DarwinBoot.running.efi`、
  `out/droidvm-disk.pre-fdt.img`）。

## TODO 5 定位：調查完、暫停

- 原廠流程：CoreLocation → locationd → gpsd（on-demand）→ 晶片廠 dylib → GNSS 晶片。gpsd 的 `ForceGnssDeviceLibraryName`
  （`/private/var/Managed Preferences/mobile/gpsd.plist`）可讓它載入任意 plugin；plugin 放 `/private/var/ngpu/addons` 就出現在
  `/System/Library/Extensions`。gpsd 以 `_gpsd` 跑，sandbox 允許讀該 plist、讀寫 `/dev/cu.gps`。
- plugin 介面已整理：`gnss::Device` vtable 59 格、`getGnssDeviceVersion()`＝2502、`gnss::Result::kSuccess`＝1、gpsd 在 `newGnssDevice` 後同步等建構
  callback；`gnss::Fix` 0xc8 bytes 的欄位位置與 gpsd 丟棄 fix 的檢查規則（gpsd 內嵌 `GnssTypes.proto` descriptor 可對照欄位名）。
- **擋住的地方**：locationd 只在 `CLPlatformInfo::getProviders() & 0x8` 時建立 GNSS provider，WiFi 版 iPad 都沒有這個 bit → 要換 J121AP／iPad7,2。
  值已從同一份官方 IPSW 的 `DeviceTree.j121ap.im4p` 取得（`product-id 61792bce…1a67`、`/product/gps-capable=1`、`compatible-device-fallback iPad6,8`…，
  `/baseband` 節點不加）。**未解**：J121 的 GNSS 在 Qualcomm 基頻（`mav16`）裡，locationd 有 gpsd 與基頻 QMI 兩條後端，不知道會選哪條。
- 設計：host＝virtio-console 具名 port 傳 NMEA 0183（RMC／GGA／GSA／GST），由 app 以 app uid 讀 LocationManager 寫進 crosvm；XNU＝virtio-console
  驅動，解析 NMEA、在 `/dev/cu.gps` 提供整理好的 fix；userspace 只多一個很薄的 vendor plugin。陀螺儀維持 virtio-input。
- WiFi 定位：kernel 沒有 IO80211 family、真驅動是 DriverKit，太重，不做。
- 回來時第一步：只換 ADT 身分開機實測（清 MobileGestalt cache；注意 CoreMotion 的機型表、CommCenter 雜訊、「無服務」）。

## TODO 6 電池：完成

crosvm `--battery type=goldfish`，新的通用 sysfs backend（`power_monitor/src/sysfs.rs`，讀 `/sys/class/power_supply`）→ guest `DroidVMBattery.cpp`
（直接繼承 `IOPMPowerSource`；**先 init() 再 attach()**）→ powerd → SpringBoard。放電、充電都驗過。已 push：device 8b2cf84、crosvm 8d587f266。

## 8 Elite Gen 5（Adreno 840）的 3D：完成

- host（drm2kgsl）與 guest Turnip（Droid-VM/mesa `droidvm`）本來就支援 a840；5566 只是開機參數 `vgpu-3d=0`。
- 改成 `vgpu-3d=1` 後仍沒有 Metal device：AMFI 拒絕 `NativeAdrenoMetal.bundle/libvulkan_freedreno.dylib`——**Data seed 帶的是舊版 Turnip
  （cdhash `fe53f4fe`），不在開機 trust cache**（plugin-seed.json 只 trust 了 seed 的 NativeAdrenoMetal）。換成 Mac 上目前 build、已 trust 的 bundle
  （NativeAdrenoMetal `49ae0dfe`、Turnip `93f89c29`）後：`gpu-3d` 3 client、8600+ fenced submission、0 timeout；backboardd 在軟體 fallback 路徑上
  反覆 SIGBUS 與設定 app 空白一起消失。
- seed：audio tree 的 `data-12g-skip-ov.dbr` 換成只替換 bundle 的新版（`refresh-seed-plugin.py`；`add-gpu-plugin-data.py` 會把 `ngpu/bin`、`ngpu/daemons`
  清空重建，不能套在最終 seed 上；ssh 裡 `hdiutil attach` 位於 /Volumes/DATA 的映像會被拒，工作目錄放 /tmp）。下一次 5566 payload-redeploy 要
  `ALLOW_CHANGE=seed` 並會重置 Data。**5567 main tree 的 seed 同樣是舊 Turnip**，沒動。
