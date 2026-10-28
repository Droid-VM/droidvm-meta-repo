# iPadOS on DroidVM（UniXNU guest）：開發進度與交接

更新：2026-10-28。目標：讓 iPadOS 17.7.11（21H461，iPad7,1／iPad Pro 12.9"）在手機（Snapdragon 8 Gen 3、Adreno 750、
Gunyah）上的 DroidVM 裡能日常使用。App Store 不在範圍內。

## 續報（2026-10-28，Claude）：TODO 2 調查——runtime 信任快取可行、entitlement 可任意授予、機內配對卡在結構阻擋；applebox／DVMSetting 設計

**TODO 1（陀螺儀原廠路線）已完成**（見「已完成里程碑」）。本輪主力是 TODO 2（iPadOS 內的 IPA 安裝器／DVMSetting）的可行性調查。

### 關鍵實驗結果（實機）
- **runtime 信任快取：可行（path A 成立）。** XNU patch `zzyd-owner-runtime-trust-cache.patch` + 開機參數 `owner-runtime-trust-cache=1`
  讓 `load_legacy_trust_cache` 在 runtime 可用。self-test（`package/DroidVMTrustCache.c`，`owner-tc-selftest=1`）實測：載入前該 cdhash
  `KERN_NOT_FOUND`，載入 version-2 模組 `KERN_SUCCESS`，載入後立即被信任。→ **裝完 app 可當場信任、不用重開機、不用主機。**
- **entitlement 可任意授予。** AMFI 把任何 entitlement（含 `com.apple.private.iamlockdown`、`PairingManager.Write` 等私有）授予
  我們 cdhash-trusted 的 binary（實測 gfxprobe 帶這些 entitlement 正常啟動）。→「動態／萬能 entitlement」= 在一顆 trusted binary 塞
  entitlement 全集 + 一個 `grant`（re-sign + runtime-trust）util。沒有單一萬能字串，但我們能授予任意集合。
- **機內 lockdownd 配對：卡在結構阻擋（不是 entitlement）。** `/var/run/lockdown.sock` 服務 GetValue/SetValue，但 QueryType/
  StartSession/Pair 一律被關（value-only 端點）；TCP 62078 在聽但是 TLS/wireless 閘（「Wireless pairing requires a passcode」，VM 沒設密碼）。
  加再多 entitlement 也一樣。→ **「不碰 USB、走協定」的配對 OUT。** 剩下的配對路：USB-mux 模擬 / 無線（設密碼）/ 直接寫 pair record
  （吃我們的 kernel 控制，待逆向 `/var/db/lockdown` 的 record 格式 + crypto）。

### 設計（討論定案，未實作）
- **DVMSetting** = GUI app（普通 SpringBoard，category 0，sandbox）+ **dvmsettingd**（owner daemon，category 3），本機 socket + JSON。
  功能：裝普通 IPA（移除走 SpringBoard 長按）、裝/移除特權 IPA、SSH（開關 + auth_keys）、serial-shell（zsh 掛到指定 serial）、
  服務管理（新增/刪除/列表/狀態；ssh 與 serial-shell 是 protected，可停不可刪）、lockdownd pairing + debug bridge。持久化裝好的 cdhash
  到 Data，開機由一個 trust-loader 服務重載（撐過重開機、不用主機）。
- **applebox** = 單一 multicall binary，取代現在的 toybox-only shell 環境：Apple OSS 的 `_cmds`（file/text/shell/adv/network…）優先、
  toybox 補缺口（xz、timeout、watch、od…）、+ libimobiledevice（靜態 OpenSSL）+ dropbear + zsh，全部用 `ld -r` + exported-symbols-list
  把符號 localize 併成一顆（一個 cdhash、一組 entitlement）。研究報告在 scratchpad `applebox-research.md`、`libimobiledevice-path-research.md`。
- **debug bridge / USB**：ACM = serial only；要 host 經 USB 碰 VM，走 **NCM（USB Ethernet gadget）** 把 PC 橋到 guest en0；真 usbmux 要 FunctionFS。

### 狀態（全部本機 WIP，未 push）
- XNU fork 的 `zzyd` patch；裝置 repo 的 `DroidVMTrustCache.c`/`DroidVMStubs.c`/`DroidVMBootArgs.c`（`owner-runtime-trust-cache=1` +
  暫時的 `owner-tc-selftest=1`）；gfxprobe 的 `lockdown` 探測子命令 + 一堆實驗 entitlement。**定案前要把 self-test 的 boot arg 和實驗 entitlement 收掉。**
- 下一步待使用者定：(1) 起 build-applebox 骨架 /(2) 試無線配對 /(3) 逆 pair record 格式（走 kernel 注入）。

---

## 已完成里程碑（2026-10-24 ~ 10-28，根因與細節見各 memory 檔與下方參考章節）

- **10-24**：GFXBench 第一次出分；GPU 記憶體 2 GB → 590 MB；發現手機 OPLUS daemon 把大核限頻（跑分要記 `scaling_max_freq`）。
- **10-25**：**drm2kgsl 遷移**——iOS 的 3D 預設改走 virtio-gpu + drm2kgsl（`vgpu-3d=1`），ALU2 22→50 fps；重型 GFXBench（Aztec/Car Chase/T-Rex）都出分；兩種手機 watchdog 當機修好（guest WFE + secondaries 讀 stale boot data）。
- **10-26**：**隨機記憶體破壞根因**——8 位元 ASID + Gunyah vCPU 遷移，改 16 位元 ASID（fork `zzxa-16bit-asid.patch`）後 GFXBench 10/10；GFXBench 破圖修好（Aztec 全黑 = pipeline reflection；T-Rex/Car Chase）；**host 端只剩通用裝置**——droidvm-gpu 退役、drm2kgsl 不再辨識 guest。
- **10-27**：整套 iOS hackintosh 推上 GitHub；開機參數內建進 kernel（`DroidVMBootArgs.c`）；畫面旋轉 + 動作感測器（host 全通用，crosvm `--input motion`）；GFXBench IPA 改用 UIScene 修實機閃退；guest 的 droidvm-gpu 驅動拆除；fps 調校（送出畫面前等 GPU 畫完，修破圖）。
- **10-28**：
  - **介面 fps 22 → 64~92**（旋轉改走 2D 引擎、答案快取、編碼執行緒、mimalloc）；**GFXBench 拉伸修好**（開機 framebuffer blob 補白頁；切換 producer 後重套 transform）。
  - **上游 UniXNU rebase 進來**（元件改名 NativeMetal→AdrenoMetal 等；建置、開機、MetalCheck 29/29、GFXBench 都驗過；強制推送，舊 tip 存 `pre-rebase-20261028` tag）。
  - **wip/vpu 全部 rebase 進 wip/hackintosh**（11 個 repo；crosvm 76 個 VPU commit；app 582 測試過；新 crosvm 實機驗過）。
  - **TODO 1 陀螺儀原廠路線完成**——kernel HID 服務（`DroidVMMotionHid.inc`：加速度計 `{0xff00,3}`、陀螺儀 `{0xff00,9}`、方向 `{0x20,0x8a}`，各帶空 `{0xff0c,3}` + HIDDefaultBehavior，方向事件帶 `{0xff15,2}` 時間戳）→ locationd/CoreMotion → backboardd；ADT 根 compatible 第一項改 `J120AP`（否則 CoreMotion 查不到感測器）；一般 app `CMMotionManager` 讀得到，自動旋轉不靠 orientd。

## 1. 現況

**能用：**
- **開機：** edk2-gunyah → UniXNU → DarwinBoot → XNU（我們自己編的 DEVELOPMENT_ARM64）→ iPadOS userland。
- **畫面：**
  - 鎖定畫面、主畫面、Dock。
  - 小工具：時鐘（即時）、備忘錄、行事曆、新聞、天氣。
  - 設定 app 的所有頁面。
  - 桌布：包括動態的萬花筒、天文、天氣、Emoji、顏色，以及「新增桌布」圖庫。
- **Safari：** 網頁正常顯示、可以打字、搜尋建議會出來。
- **輸入：** 觸控，加上實體鍵盤（app 的 virtio 鍵盤）和螢幕鍵盤。
- **網路：** en0，DHCP IPv4／IPv6，走 app 的 br-wifi。
- **Metal：** 經 virtio-gpu＋drm2kgsl 到主機 KGSL（droidvm-gpu 已在 2026-10-26 退役）。GFXBench 的 Metal 測試都能跑到出分。
- **旋轉：** 面板是直式 1024×1366；陀螺儀（crosvm `--input motion`）讓 iPadOS 自然旋轉，app 可以轉 Display、鎖 Screen。
- **Data volume：** 12 GiB，會持續保存。
- **owner 工具：** 可以 ssh 進 guest；有 ownervisor 服務管理、toybox、zsh、lsdiag、gfxprobe。

**已知問題（目前開著的）：**
1. **render server 的 DeviceLost（偶發）：** host KGSL hang → backboardd client 0 EDEADLK → 畫面閃爍到重開機，沒有自動恢復（人工重啟 backboardd 可重開 context）。Maps 因此刻意不放進 GPU client 名單。
2. **偶發文字破圖：** 少數情況仍會出現錯位條紋，等重繪才恢復，無法照指令重現（常見那種已修，見 memory [[droidvm-garbled-text]]）。
3. **健康檢查的 fence waits timed out 計數持續增加**（見第 7 節其他待辦）。
4. **一次性系統卷讀取失敗（原因未明）：** 陀螺儀那版某次開機約 4 分後 `/dev/disk3s1` 讀取全 EIO、backboardd 崩潰循環；重開後 6+ 分鐘正常，未再現。

## 2. 架構

**手機端：**
- Android，root（KernelSU），Gunyah。
- DroidVM app（`cn.classfun.droidvm`）＋ droidvmd。
- crosvm fork。
- 大頁模組 `gh_hugepage_reserve`：guest RAM 只從這裡來。
- `gunyah_share`：pseudo-unprotected VM 的 RAM 共享。

**crosvm 裝置**（VM 的 `extra_options` 加上 app 自動產生的部分）：

| 裝置 | 用途 | guest 端 |
|---|---|---|
| `--block droidvm-disk.img`（ro） | FAT ESP：UniXNU 設定、kernel、ADT、trust cache、**打包的 Data seed** | edk2／DarwinBoot |
| `--virtio-mmio-block os.img`、`systemos.img`（ro） | iPadOS 系統，有驗證 | NativeVirtioBlock |
| `--virtio-mmio-block data-store.img` @0x0a002000 | Data 的持續層：16 GiB 檔案，裡面是一個視窗 | `package/DroidVMDataStore.c` |
| `--virtio-mmio-input` @0x0a003000-0x0a006000 | 觸控、平板、鍵盤、滑鼠 | `package/DroidVMVirtioInput.c` → NativeHidInput |
| `--droidvm-gpu` @0x0a007000 | 自訂的 KGSL proxy（wire 3） | `package/DroidVMGpu.cpp` ＋ NativeAdreno |
| `--virtio-mmio-net` @0x0a008000 | en0 | `DroidVMVirtioNet.c`／`DroidVMVirtioEthernet.cpp` ＋ IONetworkingFamily-177（從原始碼編） |
| `--virtio-mmio-gpu` @0x0a009000 | 顯示（2026-10-24 起取代 simplefb）：guest-handle blob scanout，主機 udmabuf GPU blit | `package/DroidVMVirtioGpu.cpp`＋`DroidVMVirtioGpuDisplay.cpp`，經 NativeLegacyDisplay 的 `native_legacy_gpu_offer` |

**guest kernel：**
- UniXNU fork 的 XNU，加上 `patches/xnu/*.patch`。我們加的 patch 都以 `zz*` 開頭：

| patch | 作用 |
|---|---|
| `zzt` | 讓 sandbox 內也能讀 hw.pagesize |
| `zzu` | 沒有 cprotect 時仍保存 data protection class |
| `zzw`／`zzwb` | GPU client 的 sandbox 授權 |
| `zzx` | pmap 的 cache flush，以及 user mapping 計數 |
| `zzy` | bindfs vget（讓可刪除的系統 app 和它們的小工具能註冊）、staged apps、GPU addon 掛載 |
| `zzz` | 開機進度 |

- 板子的程式碼在裝置 repo 的 `package/`，在 tree 裡以 `kits/droidvm` symlink 編進 XNU。重要的開機參數在 `board.toml` 的 `kernel_args`：
  - `droidvm-data-persist=2`
  - `owner-dataprotect=1`
  - `droidvm-gpu-clients=…`（支援 `*X*` 和 `X*` 樣式）
  - `armcpu-self-ipi=1`、`armcpu-spi-ipi=1`：Gunyah 會丟掉 guest 的 SGI，沒有這兩個就完全沒有 IPI。
  - `droidvm-disable-jobs=…`

**GPU userland：**
- `/private/var/ngpu/addons/NativeAdrenoMetal.bundle` 包含三層：NativeMetal frontend、metal2vulkan（Metal→Vulkan）、turnip。
- turnip 用 darwin KMD，基於 Droid-VM/mesa 的 droidvm 分支，加上 fork 的 `patches/mesa/`。
- metal2vulkan 依 pin 版本，加上 fork 的 `patches/metal2vulkan/`。

**owner userland：** 在 `/private/var/ngpu/bin`。
- kernel 在開機時直接 spawn ownervisor，它再管理 dropbear 等服務。launchd overlay 的做法行不通。
- 其他工具：toybox、zsh、lsdiag、gfxprobe。

## 3. Repo 與分支

**只推各 repo 的 XNU wip 分支，合併由使用者決定。** commit 作者用 `HuJK <gh@hujk.org>`。

| Repo | 本機位置 | 分支 → 推送 |
|---|---|---|
| DroidVM meta repo（本 repo） | `DroidVM_wip_gpu` | `wip/hackintosh` → `git push https://github.com/Droid-VM/droidvm-meta-repo.git wip/hackintosh:wip/hackintosh`（origin 是 SSH，不能用；**絕不推 `droidvm`**） |
| UniXNU 裝置 repo | `UniXNU/UniXNU-droidvm` | `main` → `git push droidvm main:wip/hackintosh`；推之前先跑 rig 的 `scrub_rig.py` |
| UniXNU fork | `UniXNU/orgrepos/UniXNU` | `droidvm` → `git push droidvm droidvm:wip/droidvm`（不推 origin） |
| crosvm | 本 repo的 `crosvm/` | `wip/virtio-mmio` → Droid-VM/crosvm 的 `wip/virtio-mmio` **和** `wip/hackintosh`（後者是 build 腳本的分支鏈會拿的） |
| Virtualization（display client，連結進 crosvm） | 本 repo 的 `Virtualization/` | `droidvm` → `git push droidvm HEAD:wip/hackintosh`；改完要重建 crosvm |
| virglrenderer（drm2kgsl） | 本 repo 的 `virglrenderer/` | `droidvm` → `git push droidvm droidvm:wip/hackintosh` |
| Banners-Turnip（host Turnip） | 本 repo 的 `turnip/banners-turnip`（detached HEAD） | `git push origin <commit>:refs/heads/wip/hackintosh` |
| fork 的 Droid-VM submodule（AdrenoMetal＝Droid-VM/NativeMetal、Adreno740＝NativeAdreno、GopFramebuffer＝NativeMobileDisplay、DarwinBoot；10-28 起用上游的新目錄名） | fork 的 `drivers/` | `git push droidvm HEAD:wip/hackintosh`；先推 submodule 再推 fork |
| DroidVM app | `DroidVM-display-fix` worktree | `git push origin HEAD:wip/hackintosh` |

2026-10-24 最初交接時的head（歷史；最新commit見文件頂端）：
- meta：本 commit
- 裝置 repo：`512350a`（rig 工具）
- fork：`0fecbc8`
- crosvm：`61c47a469`

元件（NativeMetal、NativeAdreno、NativeMobileDisplay…）是 fork 的 `drivers/` submodule，先找各自的 dev 分支，再用 org 的穩定 droidvm 分支。
上游 UniXNU 每天有幾十個 commit。2026-10-28 把 fork rebase 到上游 `120067c`（元件改名，見 10-28 06:00 續報）。上一次 merge 是 fork 的 a3412ef（2026-10-23），重點：
- 在獨立的 worktree 試合併。
- 用 bundle 把 Mac 的 checkout 搬過去。
- patch 名稱改了要 reset `.cache/xnu-work`。
- defconfig 要 `CONFIG_XNU_BUILD_ARCHIVES=y`。

## 4. 建置與部署

建置在 build Mac 上（`BUILD_HOST`，UniXNU checkout 的 `out/droidvm` 就是 `BUILD_OUT`），部署和測試在這台 Linux 上用 rig 做：
- 工具在裝置 repo 的 `tools/rig`。
- 私有設定放旁邊的 `rig.env`，不進 git。
- 變數表見 rig README。

| 改了什麼 | 怎麼做 |
|---|---|
| XNU patch | 在 Mac 的 `out/droidvm/tree/.cache/xnu-work` 改 → tree 裡跑 `scripts/save-xnu-patch.py NAME FILE` → 把 patch 複製回本機 fork。要換掉已套用的 patch，先用**絕對路徑**的 `git apply --reverse` 退掉舊版 |
| kernel 或板子程式碼（`package/*.c`） | 同步裝置 repo 的 `package/` **和 `scripts/`** 到 Mac → Mac 上 `PATH=/opt/homebrew/bin:$PATH ./unixnu build kernel` → rig 的 `deploy.sh` → `vm.sh restart`。編譯失敗後缺物件時，刪掉 `build/xnu/ios-obj/.../osfmk/DEVELOPMENT/startup.o{,.json}` 讓它跑 bootstrap pass |
| Metal 外掛（frontend、bridge、turnip） | `tools/rig/plugin-redeploy.sh`（`FORK` 指向本機 fork）。Mesa 的 patch 清單（`scripts/data/adreno-compiler-inputs.json` 的 `patches`）改了，就把 Mac 的 `.cache/mesa-work` reset 回 pin，再照順序 `git apply`。metal2vulkan 的 patch 由 AdrenoMetal 的建置自己堆疊套用，原始碼只要停在 pin |
| owner 工具或 trust | 在 Mac 跑 `build-droidvm-*.py`，然後 `tools/rig/payload-redeploy.sh [TOOL…]`。新的 binary 要 reseed；只是新增一個服務用已信任的 binary 不必 |
| crosvm | 本 repo 的 `./2_build_crosvm.sh`（約 10 分鐘）→ `vm.sh stop` → `CROSVM_BIN=… tools/rig/crosvm-deploy.sh` → `vm.sh start`。guest 的 `DroidVMGpuWire.h` 和 `droidvm_gpu.rs` 的 wire 版本必須一致 |
| Data seed | `seed-data-grow.py`、`add-*-data.py` 產生新的 `.dbr`，再 `DATA_SEED=… payload-redeploy.sh`。**換 seed＝Data 重來**（第 6 節） |
| 只改開機參數 | 改 rig 的 `out/unixnu.toml` → `MTOOLS_SKIP_CHECK=1 mcopy -o -i out/droidvm-disk.img out/unixnu.toml ::/EFI/UniXNU/unixnu.toml` → adb push。下一次 `deploy.sh` 會蓋掉它 |
| VM 設定（螢幕、extra_options） | daemon IPC `vm_modify`；rig 本機的 `unixnu-vm.config.json` 給 `daemon-recover.sh` 用 |

**目前的 Data seed 是 `data-12g-skip-ov.dbr`，任何 payload 重建都必須用它。** 它是 `data-2g-skip-ov.dbr` 經 `seed-data-grow.py --gib 12` 長出來的，`payload-redeploy.sh` 預設就用它。
如果 payload 用回 2 GB 的 seed，Data 會被悄悄重設，然後在 2 GB 滿掉時開不了機：panic 訊息是 `board launch policy failed: 28`，也就是 ENOSPC。

## 5. 除錯流程

- **開關 VM：** 一律用 `vm.sh`：stop → 等 10 s 讓大頁池回收 → 確認池滿才 start。同時一定要開著 `hostwatch.py` 監視，它會回報主機重開、crosvm 死掉、開機失敗。
- **每次開機後：** 先看 `health.py`。kernel panic 不會讓 VM 停下來，所以要用 `panic.py`（或 `peek.py kernel_debugger_entry_count`）確認。新的 crash 用 `crashes.py` 看。
- **進 guest：** `guest-ssh.sh "toybox …"`。Data 重設之後先跑 `guest-ssh.sh --key`。guest 的 zsh 不能在 data vault 裡用 glob。
- **log：**
  - 快速看：`guest-newlogs.sh 2`，最新的 tracev3 解析成 JSON lines。
  - 完整：`logarchive.py` 做鏡像後用 `unifiedlog_iterator` 解析，或在 Mac 上用 `logs.sh`（macOS 的 `log show`）。
  - 換 seed 後要重新做鏡像。
- **畫面：**
  - `fbgrab.sh`：截圖。
  - `frame-burst.sh`：動畫中連拍。
  - `input.py`：tap／swipe／unlock／text，座標用 guest 的。
  - 手機上的畫面凍住時，用 `show-vm.sh` 恢復。
- **kernel 狀態：** `peek.py SYMBOL`。常用的有：
  - `native_adreno_client_log 352`：每個名稱的 opens／refused。
  - `droidvm_gpu_lost`
  - `native_adreno_kept`
  - `native_legacy_copy_{n,last,max,sum}`：顯示複製的時間，單位是 19.2 MHz tick。
  - `armcpu_ipi_sent`
  - `droidvm_store_*`
- **行程：**
  - `trace.py --focus NAME --symbolize`：看卡住的行程在哪。
  - `lsdiag procs`：取代 ps。
  - `lsdiag app|ext|rebuild|relink|protect|copy|image`：查 LaunchServices、data protection、ATX 圖檔。
  - `gfxprobe sync|cg|box|coherence`。
- **crash 符號化：** 在 Mac 上用 `dsc_sym.py`、`dsc_dis.py`（`PATH=/opt/homebrew/bin`）。`dsc_dis.py` 顯示的 adrp 立即值大約差一頁，要自己解原始指令。

## 6. 陷阱（每個都花過至少一輪）

**Data 與部署：**
- **Data 重設：** 換 seed 時 store 會從頭開始。重設前先把 `/private/var/ngpu` 備份出來：
  `guest-ssh.sh "toybox tar cf - -C /private/var ngpu" > ngpu.tar`，再存一份 md5 清單。
  重設後要還原有差異的檔案：外掛 bundle、`bin/gfxprobe`、`bin/lsdiag`、`wallpaper/*`。
  - 每個檔案先寫成 `NAME.new` 再 `mv -f`，不要直接覆蓋正被 map 的 dylib。
  - 接著 `gfxprobe sync`，然後重開機。
  - toybox 的 `mkdir -p` 在 `/private` 上會回 EROFS，只能 mkdir 最後一層。
- **放檔案進 guest 之後不能馬上停 VM。** 曾經截斷 21 MB 的外掛，SpringBoard 在 dyld 階段 crash loop。要先 `gfxprobe sync` 再等一下。
  另外，不要往已經 panic 的 guest 放檔案：`export.py put` 會默默失敗。
- **外掛部署被中斷**會留下半份 bundle，結果是黑畫面加 crash loop：重跑 `plugin-redeploy.sh`。
- **VM 停下後 daemon 偶爾會死**（hostwatch 報 BOOT FAILED）→ `daemon-recover.sh`，再 `vm.sh start`。

**GPU：**
- **dmesg 裡的「Sandbox deny iokit-open-user-client AGXDeviceUserClient」是雜訊**，是 NativeAdreno 自己的診斷呼叫印的。真正的資料看 `native_adreno_client_log`。
- **GPU client：**
  - 名單是 `board.toml` 的 `droidvm-gpu-clients`。
  - 沒有 GPU 裝置的行程讀不了已 twiddle 的 ATX，所以設定 app 必須是 GPU client。
  - 每個名稱的開啟次數用 token bucket 限制：8 次，每 30 秒補 1 次。

**顯示與快取：**
- **MobileGestalt 會快取 ArtworkDisplayGamut。** 舊的 Data 要刪一次 `systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist`，`--display-gamut sRGB` 才會生效。
- **ReportCrash 每個行程每天最多 25 份報告**，換 seed 會重置這個上限。
- **guest 給 host 顯示的 blob 至少要 `stride × align(height, 4)`。**少一點點，host Turnip 就拒絕匯入，那一幀改走 CPU 複製（7～10 ms），
  crosvm 也會切換 ANativeWindow 的 producer。匯入點只有 `DroidVMVirtioGpuDisplay.cpp` 的 `create()`（surface 和開機 framebuffer）。
- **crosvm 的 C++ log（display client）只進 logcat**，而手機的 logcat 幾分鐘就被系統訊息洗掉；stderr 檔（app 的
  `cache/console_<vm>_stderr.log`）只有 Rust 的 log。要抓就先在手機背景錄：
  `logcat -v time -T 1 crosvm:V BufferQueueProducer:D '*:S' > /data/local/tmp/crosvm-logcat.txt &`。
- **檢查手機上的旋轉：**`dumpsys SurfaceFlinger` 找 VMNativeDisplayActivity 的 SurfaceView（BLAST）層：Display 轉過時
  `geomBufferTransform` 應該不是 0，`toDisplayTransform` 的 x、y 縮放應該相同。

**owner 工具：**
- **每個 owner 工具都要 ad-hoc 簽，而且要帶 `com.apple.private.security.no-container`**，否則會被 launch constraint 擋下。
- **lsdiag 要用 manual RC**（`-fno-objc-arc`）。
- **IONetworkingFamily 的子類別一定要 `-D__PRIVATE_SPI__`**，否則 MAC 位址會是 0。

**主機：**
- **Mac 的 `hdiutil attach` 在 `/Volumes/DATA` 上 over ssh 會被拒**，seed 相關的腳本要從 `/tmp` 的 root 跑。
  `seed-data-grow.py` 的磁碟辨識 bug 已在 fork `0fecbc8` 修好。
- **主機當機**都是 watchdog bite，而且都發生在 stop 之後立刻 start、大頁池還沒回收完的時候 → 一律照 `hugepage-harness.md` 做。
- **手機重開機後，先跑 `load-modules.sh` 再 `vm.sh start`。**沒有 `/dev/udmabuf` 時 crosvm 一啟動就 panic
  （「failed to open udmabuf driver」，hostwatch 報 UNEXPECTED＋BOOT FAILED）。大頁池被系統拿回、補不滿時，重開手機能拿回整池。
- **host Turnip 的建置目錄編的是另一份原始碼**（`turnip/banners-turnip/turnip_workdir/mesa/build-android-aarch64` 用相對路徑指到
  `DroidVM_meta_repo/turnip/...`）：要改那一份，改完用 llvm-objdump 確認。

**量測：**
- 手機廠商會動態限制大核頻率（1.36～2.57 GHz 之間都看過），每個效能數字都要記 `scaling_max_freq`。
- 主機上 vCPU 執行緒的 CPU% 沒有參考價值（96% 在 Gunyah 的 hvc 裡，包括 guest 的 WFI）；看 guest 的 `gfxprobe cpu`。
- 主畫面從不閒置：時鐘小工具約 20 fps、時鐘 app 圖示約 10 fps。量手勢 fps 要扣掉前後的這些幀。
- 用 `lsdiag launch-args` 啟動 GFXBench 偶爾會卡在 dyld（suspended），kill 後重新啟動。

## 7. 下一步

### TODO（使用者 2026-10-28 指定，依序）

原則：
- **ownervisor 只用來除錯。**整個拿掉也不能影響 iPadOS 的使用；使用者會用到的功能都要走 iPadOS 原廠的機制
  （launchd、IOKit、HID、locationd 等），不能依賴 ownervisor 底下的服務。要先盤點目前哪些功能靠它（例如旋轉的 orientd）。
- **外設通用性（host 端）：**
  - 最後推送的 host 端（crosvm、virglrenderer／drm2kgsl、DroidVM app）相對 DroidVM 原本只能多出**通用的虛擬裝置**
    （virtio、virtio-mmio 這類標準傳輸）。不加只給 iOS 用的裝置（droidvm-gpu 就是因此在 2026-10-26 退役）。
  - host 程式**不辨識 guest**：不依 guest 名稱、context 名稱分支（drm2kgsl 的 `xnu:` 判斷已改成對所有 guest 一樣）。
    真的要不同時，用 guest 自己宣告的 capability。
  - guest 特有的行為放在 guest 端（裝置 repo、UniXNU fork）；例如 guest 頁面的生命週期歸 guest 管。
  - 共用的 crosvm／drm2kgsl 改動要 opt-in，或證明對 Linux guest 沒有影響，並在 Ubuntu VM 上實際驗過。
  - 每加一段 host 程式先問：Linux guest 能不能原封不動地用它？
- **外設的架構**（`plans/HOST_PERIPHERALS_SURVEY.md`「建議架構」）：同一個 Android 資料來源與共同協定，經標準虛擬裝置送進 guest，
  再由各 guest（iOS、Windows、Linux）自己的 provider 接到原生 API。線上協定不帶 IOKit selector、Objective-C 物件、Apple struct
  或 host 指標。傳輸能通只代表資料送得到 guest，不代表系統 API 已經接上（例如陀螺儀現在進得了 guest，app 卻讀不到）。

1. ~~**陀螺儀：原廠路線**~~ **已完成（2026-10-28）**：kernel HID 服務（`DroidVMMotionHid.inc`）→ locationd/CoreMotion → backboardd；ADT 根 compatible 改 `J120AP`；一般 app `CMMotionManager` 讀得到，自動旋轉不靠 orientd。詳見最上面續報與 memory [[droidvm-motion-sensors]]。待補：陀螺儀單位、動態轉動的實機驗證。
2. **iPadOS 內的 IPA 安裝器 / DVMSetting（進行中）。** 見最上面「TODO 2 續報」：**runtime 信任快取已證實可行**（裝完當場信任、不用重開機/主機）、**entitlement 可任意授予**。架構＝ DVMSetting（GUI app + owner daemon）+ applebox（單一 multicall debugutil）。配對走原廠 lockdownd，但機內協定被結構阻擋，剩 USB-mux 模擬 / 無線 / 直接寫 pair record 三條。下一步待定。
3. **音訊（喇叭、麥克風）。**host 已有：DroidVM 的喇叭／麥克風設定、crosvm virtio-snd 的 `backend=aaudio`。guest 缺驅動：
   調查 IOAudio2 family 或原映像的 HAL plug-in 能否接 virtio-snd（survey 表格；`plans/VIRTIO_SND_PROTECTED_VM.md`）。
4. **VPU（編碼器、解碼器）與相機（含對焦、閃光燈）。**host 端有 `wip/vpu` 分支與 `android_camera`（Camera2）基礎，但沒有完成的
   guest virtio-media 裝置（`plans/VIRTIO_MEDIA_PLAN.md`）。iPadOS 端要讓 VideoToolbox 用得到編解碼，相機要接上 camera 堆疊：都需要逆向原廠驅動的介面。
5. **地理位置（磁力計、GPS、Wi-Fi 唯讀）。**和第 1 項共用：locationd 要先能跑。手機有 mmc56x3x 磁力計，走第 1 項的 HID 路徑；
   GPS 的最小探針是 `com.apple.locationd.simulation`（私有 SPI，未驗證），之後再做原生 provider；
   Wi-Fi 只讀掃描結果（host WifiManager 掃描快取 → wifid／IO80211 → locationd）。過期的位置要標 age／invalid。
6. **電池。**host BatteryManager → guest 的 IOPMPowerSource 子類別＋powerd（真機是 AppleSmartBattery／AppleARMPMUPowerSource，
   要確認只提供基類夠不夠）。驗收：電量變化、插拔電源、充電／充滿，`UIDevice` 都讀得到。

### 其他待辦

1. **介面流暢度（2026-10-28 的狀態見最上面的續報）：**瓶頸是 metal2vulkan 每個 draw 約 27 µs。兩條路還沒決定：
   - A1：一般 draw 的快速路徑（依 pipeline 快取要檢查的功能），工程較大，預估每個 draw 省 30～50%；
   - A2：零星小修（例如 `render.rs` 的 `sampler_maps` 每個 draw 掃一遍所有 texture），約 5%。
   另外待查：外掛裡閒置吃 19% CPU 的執行緒（省電）；健康檢查的「fence waits timed out」計數一直增加；
   把 GPU 頻率拉高能讓顯示階段減半，但屬於耗電策略，要使用者同意。
2. **GFXBench：**全部 Metal 測試都能跑到出分（這版 iOS 建置沒有 Tessellation 測試）。待辦：把改過的 `libvirglrenderer.so` 正規打包進 APK。
   - 已完成：記憶體破壞（16 位元 ASID）、持久化 shader 快取（NativeMetal 3eb5926：Car Chase 232 → 133 秒；`NATIVE_METAL_NO_SHADER_CACHE=1` 關閉；
     GFXBench 的 container 在 `/private/var/mobile/Containers/Data/`，root ssh 列不出來）。
3. **Metal Check：**host／guest 均 28 PASS、0 FAIL、0 SKIP，三項 benchmark PASS；最後 20 輪 API／counters PASS 但視覺 FAIL（見上文），
   不是完整的 Metal 或 display conformance。
4. **GPU 恢復與文字破圖：**尚無自動 GPU 恢復；若文字破圖重現，立即截圖並記錄 backboardd 的 IOSurface 資訊。
5. ~~3D 改走 drm2kgsl~~：已完成（2026-10-25 起預設）；venus／gfxstream 之後再評估。

使用者允許 Luna（max）承接明確、機械性的工作；Sol承接大範圍程式碼／文檔粗篩，由主agent細讀。

## 8. 文件索引

- `hugepage-harness.md`：VM 開關與主機當機的除錯流程（必讀）
- `plans/IOS_VIRTIO_GPU_SURVEY.md`：iOS guest 改走 virtio-gpu 的 survey 與路線
- `plans/NATIVE_CONTEXT_PLAN.md`、`plans/VENUS_SURVEY.md`、`plans/VENUS_BRINGUP.md`、`plans/GFX_SHIP_PLAN.md`：Linux guest 的三條 3D 路線
- `plans/DISPLAY_PIPELINE_DECOUPLING.md`：crosvm 的 screen／frame／exporter 模型
- `plans/HOST_PERIPHERALS_SURVEY.md`：Android host 外設來源及 iOS／Windows／Linux guest 接入方案（尚未實作）
- 裝置 repo `tools/rig/README.md`：rig 工具與變數
- 裝置 repo `board.toml`：開機參數；每一項都有註解說明為什麼要加
- 各 repo 的 commit message：每個修正的根因都寫在 commit 裡，這是最完整的歷史
