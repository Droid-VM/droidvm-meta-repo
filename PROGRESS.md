# iPadOS on DroidVM（UniXNU guest）：開發進度與交接

更新：2026-10-29。目標：讓 iPadOS 17.7.11（21H461，iPad7,1／iPad Pro 12.9"）在手機（Snapdragon 8 Gen 3、Adreno 750、
Gunyah）上的 DroidVM 裡能日常使用。App Store 不在範圍內。

## 續報（2026-10-28 晚，Claude，手機 5566）：TODO 6 電池完成；TODO 3 音訊整條原廠堆疊通；TODO 5 GPS 調查完、暫停

這條線在 5566（rig `/root/gitrs/UniXNU/droidvm-5566`，裝置 repo worktree `UniXNU-droidvm-audio`，branch `wip/audio`）上做，
和 5567 的 TODO 2 分開。分工原則（使用者 10-28）：**crosvm 提供通用設備（Windows／Linux 也能用）；XNU 讀通用設備、翻譯成
userspace 看得懂的介面；userspace 只負責呈現到 app**。

### TODO 6 電池：完成（實機驗過放電與充電）
- host：crosvm `--battery type=goldfish`，新的通用 backend `power_monitor/src/sysfs.rs` 讀手機 `/sys/class/power_supply`
  （`PowerClient` 要同時實作 `get_power_data` 與 `last_request_timestamp`，否則編不過——曾因 wrapper 吃掉退出碼而部署到舊 binary，
  畫面一直顯示 goldfish 預設 50%）。
- guest：`package/DroidVMBattery.cpp`，直接繼承 `IOPMPowerSource`（開源 IOKit，不必像音訊那樣改 metaclass），~2 s 輪詢 goldfish
  暫存器 → powerd → SpringBoard。**陷阱：先 `init()` 再 `attach()`**，順序反了會在 `attachToParent` data abort。
  ADT：`make-droidvm-adt.py --battery` 從 FDT 的 `google,goldfish-battery` 節點產生 `/arm-io/battery`。
- 驗收：狀態列顯示手機真實電量，放電（1%／未充電）與充電（12%＋閃電圖示）都對。memory [[droidvm-battery]]。

### TODO 3 音訊：原廠堆疊整條通，剩真實 app 播放／錄音的驗收
- guest `IOAudio2Device`（類別名另取、metaclass 掛到原廠 family 下）以 **UID 分裝置**：`Speaker`（→ Device_Speaker_Aspen，可路由
  port，載入 J120 喇叭 DSP）與麥克風；HAL 兩個都開（clients=2）。transport＝guest virtio-snd 驅動 → crosvm vhost-user AAudio
  helper（以 app uid 跑）。
- crosvm 兩個通用修正（virtio-mmio 上的 vhost-user 原本不能用）：activate 不再強求 MSI-X；frontend 尊重
  `VIRTQ_AVAIL_F_NO_INTERRUPT`（輪詢的 guest 不會被一條沒人 ack 的 SPI 灌爆，否則 launchd 卡死）。
- PCM 以 kernel self-test（`droidvm-snd-selftest=N`）＋ crosvm `backend=file` 驗到**逐位元正確**。
- **實際播放已驗（10-28 晚）**：Safari 播一個 MP3，guest 以即時速率送出 period（約 5 s 1100 個），手機 AudioFlinger 上 app uid 的 AAudio
  track 為 active。手機原本沒聲音是因為**手機自己的媒體音量是 0**（`STREAM_MUSIC` speaker index 0，`mutedState: streamVolume`），不是我們的問題；
  經使用者同意用音量鍵調到 40/160 後 `mutedState: none`、`PortMuted false`，track 位置以 48 kHz 前進，**手機喇叭實際播出 guest 的音樂**，之後音量調回 0。
  （`cmd media_session volume --set` 在這支手機上設不進去，要用 `KEYCODE_VOLUME_UP/DOWN`。）
- **錄音還沒在 app 裡驗到**：host 端的 capture stream 一直開著且未被靜音，但 guest 沒收到 input 的 StartIO。Voice Memos 按錄音沒反應（log 裡
  tccd 處理 `voicememod` 時 LaunchServices 回 -10814，麥克風權限可能卡在 app 登記）；改用 Safari 的錄音頁時被下面的 backboardd crash 打斷。
- **已 push（10-28 晚）**：裝置 repo `wip/hackintosh` 8d4d493..3e0d34c（音訊、電池、rig `load-modules.sh`；從 worktree `UniXNU-droidvm-land`
  的 branch `wip/peripherals` 推，**接在原本的遠端 tip 上**，不含 5567 那邊 `main` 上 4 個「not for push」的實驗 commit——已通知那個 session
  下次 push 前先 rebase）；crosvm `wip/virtio-mmio` 與 `wip/hackintosh` 0f2db62ae..8d587f266（vhost-user on mmio＋NO_INTERRUPT、
  `--virtio-mmio-snd`、sysfs 電池）。`board.toml` 的 trust pin 是 5566 rig 自己的，沒 commit。memory [[droidvm-audio]]。
- **5566 的 Metal（Adreno 840）已修好（10-29）**，不用改程式：開機參數改 `vgpu-3d=1` 後 backboardd 仍拿不到 Metal device，原因是
  AMFI 拒絕 `NativeAdrenoMetal.bundle/libvulkan_freedreno.dylib`——5566 的 Data seed 帶的是**舊版 Turnip（cdhash `fe53f4fe`），不在開機
  trust cache 裡**。把 Mac 上目前 build、已被 trust 的 bundle（NativeAdrenoMetal `49ae0dfe`、Turnip `93f89c29`）放進 guest Data 後重開：
  `gpu-3d` 3 個 client、8600+ 次 fenced submission、0 timeout、0 refusal，手機 KGSL 沒有 fault；主畫面、Safari、設定、Notes 都走 Metal。
  下面兩個問題都是軟體 fallback 的症狀，已一起消失。**seed 也換了（10-29）**：audio tree 的 `build/droidvm-data/data-12g-skip-ov.dbr`
  改成只換掉 plugin bundle 的新版（sha `5bd07045`；舊的留在 `data-12g-skip-ov.pre-plugin2.dbr`）。下一次 5566 的 `payload-redeploy.sh`
  會看到 seed 變了，要 `ALLOW_CHANGE=seed`，而且**會重置 5566 的 Data**（先備份 `/private/var/ngpu`）。5567 main tree 的 seed 還是舊的
  （同樣帶未 trust 的舊 Turnip），沒動。memory [[gpu-8e5-support]]。
- （已解決，見上）5566 當時沒有 Metal（`vgpu-3d=0`）時的兩個問題：(a) **backboardd 反覆 SIGBUS**：`CA::OGL::SWContext::set_surface` →
  `__bzero`，多半發生在開 app 的動畫，畫面停住，等 launchd 重啟 backboardd／SpringBoard；(b) **設定 app 開起來一片空白**：主執行緒卡在
  `dispatch_sync`，另外兩條執行緒在等某個 daemon 的同步 XPC 回覆。

### TODO 5 GPS：調查完、**暫停**（使用者 10-28：晚點回來做）
結論都在 memory [[droidvm-gps-plan]]，scratchpad `gnss/`、`ipsw-j121/`。
- 原廠流程：CoreLocation → locationd → gpsd（on-demand）→ 晶片廠 dylib → GNSS 晶片。gpsd 的 `ForceGnssDeviceLibraryName`
  （`/private/var/Managed Preferences/mobile/gpsd.plist`）可讓它 `dlopen` 任意 plugin；plugin 放 `/private/var/ngpu/addons`
  就會出現在 `/System/Library/Extensions`。gpsd 以 `_gpsd` 跑，sandbox 允許讀該 plist、讀寫 `/dev/cu.gps`。
- 已還原的 ABI：`gnss::Device` vtable 59 格、`getGnssDeviceVersion()` 必須回 2502、`gnss::Result::kSuccess=1`、gpsd 在
  `newGnssDevice` 後同步等建構 callback；`gnss::Fix` 0xc8 bytes 的欄位位置與 gpsd 丟棄 fix 的檢查規則（gpsd 內嵌了
  `GnssTypes.proto` descriptor 可對照欄位名）。
- **擋住的地方（L1）**：locationd 只在 `CLPlatformInfo::getProviders() & 0x8`（GPS）成立時建立 GNSS provider，**所有 WiFi 版
  iPad 都沒有這個 bit**，J120 上 GNSS 永遠不會啟動。要換成蜂窩版 **J121AP／iPad7,2**：值已從同一份官方 IPSW 的
  `DeviceTree.j121ap.im4p` 取得（`product-id 61792bce…1a67`、`/product/gps-capable=1`、`compatible-device-fallback iPad6,8`…，
  `/baseband` 節點不加）。
- **未解的風險**：J121 的 GNSS 在 Qualcomm 基頻（`mav16`）裡；locationd 有 gpsd（`CLGnssDaemonDevice`）與基頻 QMI
  （`CLEurekaController`）兩條後端，還不知道 J121 會選哪條。回來時第一步：只換 ADT 身分開機實測（清 MobileGestalt cache；
  注意 CoreMotion 的機型表、CommCenter 雜訊、「無服務」）。
- 設計定案：host＝virtio-console 具名 port 傳 NMEA 0183（RMC/GGA/GSA/GST），資料由 app（Java LocationManager，app uid）寫進
  crosvm 的 console socket；XNU＝virtio-console 驅動，解析 NMEA、在 `/dev/cu.gps` 提供整理好的 fix；userspace 只多一個很薄的
  vendor plugin（GNSS 晶片 plugin 在 Apple 的設計裡本來就在 userspace）。陀螺儀維持 virtio-input。

### 其他
- 5566 在 1% 時手機重開過：模組與 hugepage 池會消失。`gh_hugepage_reserve.ko` 在使用者的 KernelSU 目錄（請使用者 insmod），
  `load-modules.sh` 改成依 `uname -r` 選模組目錄。memory [[droidvm-host-reboot-recovery]]。
- 曾嘗試搬到 5568 後中止（使用者把 5566 接上充電）：5568 留下 app r312、我的 crosvm（備份 `crosvm.bak-579d1a5b`）、UniXNU 映像與
  VM 項目（data-store 已失效）。**教訓：複製 data-store 前一定先停來源 VM**，否則 guest panic「libSystem.B.dylib not loaded」。
  memory [[droidvm-5568-state]]。
- 以上都已 commit 並 push（commit hash 見各項）。這條線的詳細計畫與狀態總表：`plans/TODO3-6_PERIPHERALS_PLAN.md`。

---

## 續報（2026-10-28 下午，Claude）：entitlement 全集盤點（stock 21H461）；UniXNUSetting 改做特權 app（同日晚上再修訂：改為 ownervisor 的 in-app GUI，見下方「決定」）

接續下方 TODO 2 續報。使用者問「entitlement 全集的 list 型別是不是很難枚舉」、並提議「UniXNU 做成特權 app 更好」。從 build Mac 已掛載的 stock 21H461 rootfs（`/private/tmp/dmg.*`，rootfs dmg `044-76040-038.dmg`）＋ cryptex（`044-76034-038.dmg`）用 `scratchpad/entdump.py` 解出全部簽章 binary 的 entitlement。

### 數據
- 2,505 顆簽章 binary，1,595 顆帶 entitlement，**3,658 個不同 key**；其中 **3,309 個是純 bool**（設 true 即可，無枚舉問題）。
- **247 個 list 型 key、8,185 個不同值**，分三類：
  - **sandbox 例外**（`security.exception.*`／`temporary-exception.*`／`seatbelt-profiles`／`sandbox.profile*`）：81 key／4,618 值。**整類丟掉**——no-sandbox 行程不讀；最大的 `mach-lookup.global-name`（1,368 值）就在此類。
  - **身分／行為設定**（`application-identifier`、`container-required`、`application-groups`、`pac.shared_region_id`、`web-browser-engine.*`、`security.message-filter`、`UIKit.vends-view-services`、iCloud／aps…）：74 key／533 值。**絕不能聯集**——這些決定「行程是誰、進哪個 sandbox」，塞進去反而關進 sandbox 或改行為。
  - **權限清單**：175 key／3,034 值。**只有這類需要人工盤點。**
- 權限清單再分：**值域封閉、可從檢查方找齊**（`tcc.allow`、`iokit-user-client-class`＝kernelcache 全部 UC 類別＋我們的 driver、`mobileinstall.allowedSPI`、`lockdown.finegrained-*`、CommCenter、MobileGestalt）；**值域開放、找不齊**（`trial.client` 數字 ID、biome stream、IDS topic、asset type、通知 bundle id、keychain group）——但 stock 聯集已涵蓋所有原廠 consumer，第三方值我們用不到。
- **陷阱**：(a) 有檢查方吃萬用字元（stock 自己用 `com.apple.MobileAsset.*`、`geoservices.map-subscriptions` 的 `*`），但比對規則各異，不可當通則；keychain `*` 需 Security 源碼查證，未驗。(b) 同一 key 型別不一致（`iokit-user-client-class` 有人寫字串、`tcc.allow` 有巢狀陣列），給錯型別＝沒給。(c) 有雜訊（Apple 自己的錯字 `no-sandbox\n`、誤入的 `CFBundleIdentifier`／`MachServices`），所以**聯集 ≠ 真全集**。
- 只取權限類、bool 設 true、清單取聯集 → 候選全集 **3,430 key、約 360 KB XML**（對照「設定」app 585 個）。AMFI／XPC 收不收這麼大一包**未驗**。
- 對 `cap.sys_admin` 計畫的影響：userspace daemon 是自己拿整包、自己查清單裡有沒有某值，所以 kernel 注入那份**仍要逐一列值**；「任何值都算有」只能用在 kernel 端檢查（`IOTaskHasEntitlement`／sandbox）。

### 決定（10-28 晚修訂）：UniXNUSetting＝ownervisor 的 in-app GUI，root 操作交 ownervisor
UniXNUSetting 本質上是幫 ownervisor 做的 app 內 GUI，所以用 ownervisor 不違反「ownervisor 只除錯」。**不做特權 app**：先前「no-sandbox＋bundle 內 persona helper」的方案撤回（persona 提權實測 mobile→root EPERM，見下方驗證結果 1）。
- **要 root 的操作**：交給 kernel 以 root spawn 的 ownervisor（app 經本機 socket 呼叫）。app 本身以 mobile 跑，不簽大 entitlement 集。
- **真正要守的兩件事**（使用者 10-28）：(a) **未經使用者授權的第三方 app 碰不到 ownervisor 和底下的 debug 工具**；(b) **使用中不會不小心把 UniXNUSetting 刪掉**。
- 機制（待實作／驗證，細節 `plans/UNIXNUSETTING.md` §3.1）：(a) app 專用 socket，ownervisor 用對端 audit token 取 cdhash，只認 payload 內建的 UniXNUSetting——**不能只查 entitlement**（AMFI 把任何 entitlement 授予任何 cdhash-trusted binary，含之後 runtime 信任的使用者 IPA）；現有 `ctl.sock`／`control/` spool 沒有對端驗證且 `add` 能以 root 跑任何 trusted binary，維持 root-only；debug 工具目錄 root-only。(b) 當 staged 系統 app 放在唯讀 os.img，不在可刪除清單，SpringBoard 不給刪。
- **TODO 2 (3) 要改**：「開機時 ownervisor 服務重載信任清單」違反原則；改成 **Data 掛上時由 kernel 直接讀已存 cdhash 清單**（`DroidVMTrustCache.c` 已有載入碼）。

### 驗證結果（2026-10-28 實機；細節＋captest 原始輸出見 `plans/UNIXNUSETTING.md` §3/§5）
1. **persona 以 root 啟動 helper → 只在呼叫者已是 root 時可行。** root→root persona override spawn 成功（子 uid=0）；但 euid 降 501、以及純 mobile（ruid=euid=svuid=501）→ spawn root persona **皆 EPERM**。→ **mobile app 無法靠 persona 自力提權**；要 root 的操作改交 **kernel 以 root spawn 的 ownervisor root helper**（app 經 socket 呼叫），persona 只用於「已是 root 的 daemon 要降成特定 uid 跑子行程」。
2. no-sandbox staged app 從主畫面啟動：launch-constraint 半邊已由 `owner-skip-launch-constraints=1` 解除；app-launch 半邊要等 runtime 安裝器（`staged_system_apps` 在唯讀 os.img 上）。**本輪未端到端跑**，仍待安裝器就緒。
3. **~360 KB 全集 AMFI 不收**（實測 SIGKILL「entitlements too large」）；實務上限約 256 KB XML。**改走 curated：109-key 全 lockdownd 除錯集（17 KB）實測 AMFI 100% 授予（109/109）**，遠在限內。→ 不簽 360 KB 全集，curate 即可。

產物：`scratchpad/fullset-candidate.plist`（候選全集）、`scratchpad/ents-21H461.jsonl`＋`ents-21H461-cryptex.jsonl`（逐 binary 原始 entitlement）、`scratchpad/entdump.py`／`entclass.py`（擷取／分類腳本）。memory [[entitlement-fullset]]。

---

## 續報（2026-10-28，Claude）：TODO 2 調查——runtime 信任快取可行、entitlement 可任意授予、機內配對卡在結構阻擋；applebox／UniXNUSetting 設計

**TODO 1（陀螺儀原廠路線）已完成**（見「已完成里程碑」）。本輪主力是 TODO 2（iPadOS 內的 IPA 安裝器／UniXNUSetting）的可行性調查。

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
- **UniXNUSetting** = GUI app（普通 SpringBoard，category 0，sandbox）+ **unixnusettingd**（owner daemon，category 3），本機 socket + JSON。
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

## 已完成里程碑（2026-10-24 ~ 10-29，根因與細節見各 memory 檔與下方參考章節）

- **10-24**：GFXBench 第一次出分；GPU 記憶體 2 GB → 590 MB；發現手機 OPLUS daemon 把大核限頻（跑分要記 `scaling_max_freq`）。
- **10-25**：**drm2kgsl 遷移**——iOS 的 3D 預設改走 virtio-gpu + drm2kgsl（`vgpu-3d=1`），ALU2 22→50 fps；重型 GFXBench（Aztec/Car Chase/T-Rex）都出分；兩種手機 watchdog 當機修好（guest WFE + secondaries 讀 stale boot data）。
- **10-26**：**隨機記憶體破壞根因**——8 位元 ASID + Gunyah vCPU 遷移，改 16 位元 ASID（fork `zzxa-16bit-asid.patch`）後 GFXBench 10/10；GFXBench 破圖修好（Aztec 全黑 = pipeline reflection；T-Rex/Car Chase）；**host 端只剩通用裝置**——droidvm-gpu 退役、drm2kgsl 不再辨識 guest。
- **10-27**：整套 iOS hackintosh 推上 GitHub；開機參數內建進 kernel（`DroidVMBootArgs.c`）；畫面旋轉 + 動作感測器（host 全通用，crosvm `--input motion`）；GFXBench IPA 改用 UIScene 修實機閃退；guest 的 droidvm-gpu 驅動拆除；fps 調校（送出畫面前等 GPU 畫完，修破圖）。
- **10-28**：
  - **介面 fps 22 → 64~92**（旋轉改走 2D 引擎、答案快取、編碼執行緒、mimalloc）；**GFXBench 拉伸修好**（開機 framebuffer blob 補白頁；切換 producer 後重套 transform）。
  - **上游 UniXNU rebase 進來**（元件改名 NativeMetal→AdrenoMetal 等；建置、開機、MetalCheck 29/29、GFXBench 都驗過；強制推送，舊 tip 存 `pre-rebase-20261028` tag）。
  - **wip/vpu 全部 rebase 進 wip/hackintosh**（11 個 repo；crosvm 76 個 VPU commit；app 582 測試過；新 crosvm 實機驗過）。
  - **TODO 1 陀螺儀原廠路線完成**——kernel HID 服務（`DroidVMMotionHid.inc`：加速度計 `{0xff00,3}`、陀螺儀 `{0xff00,9}`、方向 `{0x20,0x8a}`，各帶空 `{0xff0c,3}` + HIDDefaultBehavior，方向事件帶 `{0xff15,2}` 時間戳）→ locationd/CoreMotion → backboardd；ADT 根 compatible 第一項改 `J120AP`（否則 CoreMotion 查不到感測器）；一般 app `CMMotionManager` 讀得到，自動旋轉不靠 orientd。
  - **TODO 6 電池完成**——crosvm goldfish battery（新的通用 sysfs backend）→ guest `DroidVMBattery`（`IOPMPowerSource` 子類別）→ powerd → SpringBoard，狀態列電量與充電圖示跟著手機走。
  - **TODO 3 音訊原廠堆疊整條通**——`IOAudio2Device`（Speaker／Mic 依 UID 分裝置）→ VirtualAudio → HAL → virtio-snd（virtio-mmio 上的 vhost-user AAudio）；Safari 播放經手機喇叭實際出聲，剩 app 內錄音驗收。
- **10-29**：
  - **8 Elite Gen 5（Adreno 840）的 Metal 修好**——5566 的 Data seed 帶的舊 Turnip 不在開機 trust cache；換成已 trust 的 plugin bundle（seed 也換新）後 iPadOS 走 Metal，軟體渲染 fallback 的 backboardd SIGBUS 與設定 app 空白一起消失。
  - **動態 ADT**——DarwinBoot 開機時從 firmware 的 FDT 補上 RAM 與 `/arm-io` 裝置（DarwinBoot b2ad902、device 2c9227e…3f3474d 的 `--dynamic`）；crosvm 裝置或 pool 變動不必再重產 ADT。
  - **iPadOS 的 virtio-media 傳輸層通了**——guest 自檢讀到解碼器的格式（H.264／HEVC／VP9／AV1 → NV12）；crosvm `--virtio-mmio-media`（d5c13c494）、guest `DroidVMVirtioMedia.c`（e66a7b4）。

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
- **電池：** 狀態列顯示手機真實電量與充電狀態（crosvm goldfish battery → `IOPMPowerSource`，2026-10-28，5566 上驗過）。
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
2. **iPadOS 內的 IPA 安裝器 / UniXNUSetting（進行中）。** 見最上面「TODO 2 續報」：runtime 信任快取已證實可行、entitlement 可任意授予。配對先擱著。範圍與動工順序：
   - **(1) shell 環境（先做）＝ 4 個工具，全部簽上 entitlement 全集 + owner-trust，每個 applet/行程都帶滿權限**（AMFI 對 cdhash-trusted binary 授予任意 entitlement，已驗）：
     **applebox**（單一 multicall：Apple OSS `_cmds`（file/text/shell/adv/network…）+ toybox 補缺口（xz/timeout/od…）+ zsh，用 `ld -r` + exported-symbols-list 併一顆）、**dropbear**（ssh，login shell exec applebox-zsh → 滿權限 zsh）、**debugutil**（原 gfxprobe）、**libimobiledevice**（備著，待配對通了才用）。entsh 暫不做（這幾顆滿權限的就是它）。
     `build-applebox.py`：table-driven、per-tool `-Dmain=<t>_main` + `ld -r` localize + 聚合一個 `applebox.json` trust。研究報告見 scratchpad `applebox-research.md`。
     待辦子項：entitlement 全集要盤一份 curated 清單（多數 boolean、少數陣列值如 iokit-user-client-class/finegrained-*；逐步加、個別 restricted AMFI 可能拒要一加一驗）；terminfo db 要一起 stage（less/vim/top/zsh 互動要）；scp/sftp 用 OpenSSH sftp-server。
     **entitlement 全集 → 日後搬進 kernel（`cap.sys_admin` 計畫）**：現在「簽滿」是為了快速把全集盤穩；穩了之後定義一個自定義 entitlement **`cap.sys_admin`**（非 apple 前綴，不受 AMFI restriction 檢查，就是個 dict key），工具只簽它，**patch AMFI 在 exec 附掛 entitlement 時、看到 `cap.sys_admin` 就注入 kernel 內 curate 的全集 dictionary**。這個附掛點**一處同蓋 kernel 端（`IOTaskHasEntitlement`／sandbox／MACF）與 userspace （`SecTask`/`csops` → lockdownd 等）**，因兩層都讀 task 附掛的 entitlements；value 型 entitlement（finegrained-*、iokit-user-client-class）要給值/萬用。`cap.*` 命名留擴充空間（日後 `cap.net_admin`、`cap.pairing`… 各映射 entitlement 子集，做成 capability 風格）。取捨：改全集內容「簽滿」是 re-sign（輕）、`cap.sys_admin` 要重建 kernel（重），所以迭代用前者、穩定用後者。
   - **(2) trust-cache user client（唯一要改 kernel 的一塊）**：讓 userspace 呼叫已驗證的 `load_legacy_trust_cache`（owner-gated）。+ 機內 cdhash 抽取 → **普通 IPA 安裝端到端**（抽 cdhash → runtime 信任 → staged + LaunchServices 登記 → 上主畫面；移除走 SpringBoard 長按）。
   - **(3) 持久化 trust 清單**：裝好的 cdhash 存到 Data；**開機早期由 kernel（`DroidVMTrustCache.c`）在 Data 掛上時直接讀已存清單重載**（不經 ownervisor 服務——見上方 10-28 下午續報的決定；撐過重開機、不用主機、不重建 kernel）。+ **特權 IPA 安裝/移除**（同 (2) + 全集只簽在 helper；移除：刪 bundle + 從清單移除）。
   - **(4) serial-shell 服務**（zsh 掛到指定 serial，getty 式）+ **ownervisor `protected` 旗標**（ssh、serial-shell 可停不可刪）+ **服務管理**（新增/刪除/列表/狀態，GUI 由 (5) 經 app socket 交 ownervisor 執行）。
   - **(5) UniXNUSetting＝ownervisor 的 in-app GUI（10-28 晚修訂，取代「特權 app」與更早的「GUI＋unixnusettingd」）**：staged 系統 app（唯讀 os.img、不可刪）、以 mobile 跑、不簽大 entitlement；要 root 的操作經 app 專用 socket 交 ownervisor 執行，ownervisor 以對端 cdhash 只認 payload 內建的 UniXNUSetting，擋未經授權的第三方 app；debug 工具目錄 root-only。細節 `plans/UNIXNUSETTING.md` §3.1。
   - **配對（獨立 track，擱置）**：USB-mux 模擬 / 無線（設密碼）/ 直接寫 `/var/db/lockdown` 的 pair record（吃 kernel 控制，待逆向格式）。
3. **音訊（喇叭、麥克風）：原廠堆疊已通（2026-10-28，5566）。**guest `IOAudio2Device`（Speaker／Mic 依 UID 分裝置）→ VirtualAudio →
   HAL → virtio-snd → crosvm vhost-user AAudio helper（app uid）；PCM 以 self-test＋`backend=file` 驗到逐位元正確。
   **剩：**iOS 裡實際播放（聽得到）與錄音（`droidvm_snd_rx_periods` 會漲）的驗收；commit。見最上面 10-28 晚續報、memory [[droidvm-audio]]。
4. **VPU（編碼器、解碼器）與相機（含對焦、閃光燈）。**
   - **host＋Linux guest：已完成。**virtio-media 三個裝置（相機、解碼器、編碼器）、vhost-user helper（app uid）、`media_host`／`media_guest`
     池、Linux guest driver（DKMS）、libva-v4l2 都做完，Ubuntu 上出貨組態驗收（Firefox 硬解 H.264／VP9／AV1、ffmpeg 硬體編碼、相機）
     大部分已關；`wip/vpu` 已 rebase 進 `wip/hackintosh`。還開著的：**P-6**（畫面卡死、之後鎖定畫面全黑，blocker，未能重現）、**P-5**
     （硬體編碼 drain 偶發掉尾幀，非決定性）、P-2（low）、P-9 的 12.4 h 實機 soak 沒做。細節 `plans/VPU_DESIGN.md` §7.8。
   - **iPadOS guest：傳輸層第一個里程碑完成（10-29，5566；已 push：crosvm d5c13c494、device e66a7b4／3f3474d、DarwinBoot b2ad902）。**guest 開機自檢讀到
     `droidvm decoder caps 0x4004000 out: H264 HEVC VP90 AV01 cap: NV12`（9 個 command、0 timeout）。
     - crosvm：新增 `--virtio-mmio-media`（media 裝置接在 snd 之後的 virtio-mmio）；VM 加 `--pre-alloc ...,media-host-mb=64`、
       `--virtio-media kind=decoder,uid=10367`（helper 以 app uid 跑，buffer 從 `media_host` pool 配）。
     - guest：`package/DroidVMVirtioMedia.c`（輪詢式 virtio-mmio 傳輸、commandq/eventq、OPEN/CLOSE/IOCTL/MMAP/MUNMAP API）。
       陷阱：`VIDIOC_QUERYCAP` 由 driver 用 config space 自己回答，送給 device 會回 ENOTTY。
     - **動態 ADT（使用者 10-29 提議）**：DarwinBoot 開機時從 firmware 的 FDT（EDK2 `FDT_CLIENT_PROTOCOL`）補上 RAM
       （`dram-base/size` 與 `/pram`、memory-limit、video-memory、`kern.maxvnodes`）和 `/arm-io` 的裝置節點（逐一讀 virtio-mmio
       視窗的 DeviceID 分類，加上 pool 與電池）；`make-droidvm-adt.py --dynamic` 只產靜態部分。加 media pool 讓 RAM 從
       `0x13f200000` 縮成 `0x13b200000`、drm pool 搬家，都自動處理，不用再為了 crosvm 裝置變動重產 ADT。
       驗證：host harness 跑出的結果與 Python 靜態 ADT 逐位元相同（現況與加 media 兩種配置），5566 實機開機正常。
       memory [[droidvm-dynamic-adt]]、[[droidvm-virtio-media-ios]]。
     - 下一步：kernel 自檢跑一次完整解碼往返（S_FMT、REQBUFS MMAP、QBUF 一段 H.264、STREAMON、DQBUF／SOURCE_CHANGE 事件、
       NV12 校驗），再加 encoder／camera；之後才決定怎麼接 VideoToolbox 與相機堆疊（要逆向原廠驅動介面）。
5. **地理位置（磁力計、GPS、Wi-Fi 唯讀）。**
   - **GPS：調查完、暫停（使用者 10-28 指示，晚點回來）。**結論見最上面 10-28 晚續報：J120 上 locationd 不會啟動 GNSS（WiFi 版
     iPad 沒有 `kProviderLocationGps`），要換 J121AP 身分（值已從官方 IPSW 取得）；未解的是 J121 上 locationd 走 gpsd 還是基頻
     QMI。路線：virtio-console 具名 port（NMEA）→ XNU 驅動提供 `/dev/cu.gps` → gpsd＋薄 vendor plugin。
   - 磁力計：手機有 mmc56x3x，走第 1 項的 HID 路徑（未做）。
   - Wi-Fi 唯讀：survey 過，kernel 沒有 IO80211 family、真驅動是 DriverKit，太重，暫不做。
6. ~~**電池**~~ **已完成（2026-10-28）**：crosvm goldfish battery（通用 sysfs backend）→ `DroidVMBattery`（`IOPMPowerSource` 子類別，
   只提供基類就夠）→ powerd → SpringBoard。放電、充電都驗過。memory [[droidvm-battery]]。

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
