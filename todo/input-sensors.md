# 輸入與感測器

地理位置與實體按鍵的待辦完整細節，從 `PROGRESS.md`「7. 下一步」的 TODO 移來（原文照錄）。

## 10-28 TODO 5 地理位置

**地理位置（磁力計、GPS、Wi-Fi 唯讀）。**

- **GPS：調查完、暫停（使用者 10-28 指示，晚點回來）。**結論見最上面 10-28 晚續報：J120 上 locationd 不會啟動 GNSS（WiFi 版
  iPad 沒有 `kProviderLocationGps`），要換 J121AP 身分（值已從官方 IPSW 取得）；未解的是 J121 上 locationd 走 gpsd 還是基頻
  QMI。路線：virtio-console 具名 port（NMEA）→ XNU 驅動提供 `/dev/cu.gps` → gpsd＋薄 vendor plugin。
- 磁力計：手機有 mmc56x3x，走第 1 項的 HID 路徑（未做）。
- Wi-Fi 唯讀：survey 過，kernel 沒有 IO80211 family、真驅動是 DriverKit，太重，暫不做。

## 11-10 GNSS 接收器（host＋Linux guest）

使用者 11-10 排定：GPS → 磁力計 → 震動馬達，先做 host（app 定位權限、卡片、crosvm 串接）與 Linux guest，iOS 晚點。

**設計**
- guest 看到一顆 GNSS 接收器：virtio-console 具名 port `org.droidvm.gnss.0`，每秒一個 NMEA 0183 4.11 epoch，所有星系一條串流：
  RMC／GGA／GST 用 `GN`（一個合算解）；GSA 每個系統一句，最後一欄是系統 ID；GSV 依系統＋頻點分組（`GP GL GA GB GQ GI`，帶 signal ID）。
- 來源由卡片選（`GnssSource`）：
  - 手機 GNSS 晶片：GPS provider 的 fix（帶 GNSS 時間）加 GnssStatus 的衛星（星系、svid、C/N0、仰角方位角、是否參與、頻點），
    DOP 由參與定位衛星的幾何算。VM 執行期間晶片一直開著。
  - 僅位置：fused provider，每秒以現在時間報告、最多保留 60 s，搭配 8 顆固定的合成 GPS 衛星，GST 帶真實精度。
  - 自動：daemon 依 `FEATURE_LOCATION_GPS` 決定。另有「標成模擬」開關（GGA 品質 8、RMC 模式 S）。
- 高度要有垂直精度才報（fused 的 0 m 是佔位值），用 AltitudeConverter 換成海平面高度；沒有就留空，不拿橢球高充數。

**分工**
- crosvm 91724fac2（兩個 wip 分支都推了）：`--serial ...,name=X` 的 virtio-console 改成 multiport（名字只能經 control queue 送），
  guest 沒開 port 時丟棄輸入（否則無上限累積、開啟時讀到舊資料）。沒名字的 console 與 vhost-user console 不變。
- app 6e38a07（本地）：`PeripheralType.VIRTIO_GNSS`（前景服務型別 location）、卡片（來源、說明、標成模擬）、`LocationPermission`
  （新增卡片時要權限，精確與大概一起問，拒絕就不加）。`PeripheralForegroundService` 帶 location 型別時跑 `GnssFeeder`（app uid）
  → `gnss_feed` → daemon 的 `GnssHub` 寫每台 VM 一個非阻塞 pipe（`--serial type=sink,hardware=virtio-console,name=...,input=/proc/self/fd/N`）。
  沒有權限時服務只拿掉 location 型別，不連累相機。feeder 每 5 s 心跳，daemon 15 s 沒聽到就重新拉起服務（退避到 5 分鐘）。
- guest additions 5c5f270（`wip/hackintosh`）：udev 規則（dialout、`/dev/gnss-droidvm`、`gpsdctl@`）；在 gpsd 的
  `local/usr.sbin.gpsd` 加 `/dev/vport*` 的 AppArmor 規則（有標記，移除套件時只拿掉自己那段）。

**驗證**
- 5567（沒有 GNSS 晶片）的 Ubuntu：卡片「自動」顯示「這支手機沒有 GNSS 接收器」；新增時跳出系統定位權限；guest 有
  `/dev/virtio-ports/org.droidvm.gnss.0`；gpsd 開機經 udev 自動接上（NMEA0183、TPV 2D、eph 來自 GST）；殺掉 app 進程 11 s 後恢復。
- 5566（Qualcomm 雙頻）真實晶片模式：GSV 有 GPS 13、GLONASS 7、Galileo 13、北斗 15、QZSS 3（星曆位置）；室內沒有訊號、沒有 fix。
- `NmeaTest`（82 字元上限、checksum、編號、signal ID、DOP、GST sigma）；guest additions 的 `test-hooks.sh` 新增 6 項通過（原本那 1 項失敗不變）。
- 測試後的狀態：5567 的 Ubuntu VM 留著 GNSS 卡片，guest 裝了 gpsd（gpsd-clients 下載到一半被我中止，沒裝上）；5566 的 Ubuntu
  設定已還原、定位權限已撤銷，app 與 crosvm 維持新版，UniXNU 27 已重新開機。

**陷阱**
- Ubuntu 的 gpsd AppArmor profile 只允許 tty／pps／rfcomm，開 `/dev/vport*` 是 EACCES；symlink 沒用（AppArmor 看實際節點）。
- OPLUS 的 FreezeControl 會凍結「靜止、判定在室內」的手機上 app 的 GPS listener（`dumpsys location` 有 `freezed(gpsListener: 1)`）。
- 編輯頁存檔只寫 app 的 `vms.json`；從 app 啟動 VM 時才以 `vm_modify` 推給 daemon（只用 IPC `vm_start` 的話 daemon 沒有新設定）。
- `test-hooks.sh` 有案例不經 `run_case` 直接 source hooks：新的路徑覆寫要 export，否則會寫到跑測試那台機器的 `/etc`（發生過一次，已清掉）。

**還沒做**
- 戶外實測真實晶片的 fix；星系勾選（現在送 host 有的全部）；guest 開 port 才開晶片（crosvm 已追蹤 port 開關，還沒告訴 daemon）。
- iPadOS：J120 的 locationd 不啟動 GNSS → 換 J121AP；port → XNU → gpsd 外掛（見上面 10-28）。
- Windows：沒有內建 NMEA 驅動，要另寫 GNSS driver。rpm（Fedora）的 SELinux 沒處理。

## 11-10 磁力計（host＋Linux guest）

**設計**
- 沿用 motion 這個 virtio-input 裝置（同一幀有重力向量，guest 才能做傾斜補償；app 的畫面校正也一起轉）。crosvm
  `--input motion[...,magnetometer=true]` 多宣告四個軸：磁場 `ABS_HAT0X/HAT0Y/HAT1X`（每 µT 16 單位，±2048 µT）、
  航向 `ABS_HAT1Y`（從磁北到裝置 Y 軸、順時針、傾斜補償，0.01°）。evdev 沒有磁場的碼，hat 是加速度計不會有的軸，讀者
  分得出來；語意等同 HID Compass 3D（磁場＋航向）。
- 航向用 Android `SensorManager.getRotationMatrix`／`getOrientation` 的算法（east＝磁場×反作用力、north＝反作用力×east）。
  crosvm 用最新的加速度算；app 的 console 覆寫時，用轉過的磁場與加速度重算（畫面轉了，guest 面板的航向就不是手機的）。
- Linux：guest additions 第四個 DKMS 模組 `droidvm-compass`：input handler 綁「加速度計＋四個 hat 軸」的裝置，發佈成
  IIO 磁力計，通道比照 hid-sensor-magn-3d（`in_magn_{x,y,z}` 高斯、`in_rot_from_north_magnetic_tilt_comp` 度），
  triggered buffer＋名為 `<name>-dev<N>` 的 trigger（iio-sensor-proxy 就是這樣找 trigger）。udev 依 modalias 自動載入。

**commit**：crosvm cee8d210a（兩個 wip 分支）、app 4ed9a06（本地；GyroScope 卡片加「磁力計」開關，新列與舊列預設開）、
guest additions b21673b（`wip/hackintosh`）。

**驗證（5567 Ubuntu）**：motion 裝置 `ABS=f003f`（多了 HAT0X–HAT1Y）；模組在裝置加入時自動載入，`iio:device0 droidvm-compass`、
trigger `droidvm-compass-dev0`；iio-sensor-proxy 標成 `iio-buffer-compass`，`monitor-sensor --compass` 每次變化都報航向；
磁場與手機 mmc56x3x 自己的讀數一致到 0.01 µT（這台平板周圍磁鐵很強，|B| 約 850 µT）。航向公式以四個已知方向測過。
XNU 只收 ABS_X..ABS_RZ、motion HID 服務每 10 ms 輪詢，所以 iPadOS VM 多了這些軸不受影響。

**還沒做**
- console 覆寫路徑（HostMotionSensor 送磁場＋航向）與卡片開關沒有上機看過：5567 鎖著（有 PIN），這次的列是 IPC 加的。
- 完整套件安裝（dkms 一次編四個模組、重建 initramfs）沒跑，只在 guest 單獨編了這個模組。
- iPadOS：XNU 把這四個軸轉成 compass HID 服務（CoreMotion／locationd 的 heading）；Windows：HID Sensor Compass 3D。

## 11-10 震動馬達（host＋Linux guest）

**設計**
- crosvm `--input vibrator[path=,name=]`：只聽不報的 virtio-input 裝置，宣告 `EV_FF`/`FF_RUMBLE`，ids `BUS_VIRTUAL 4456:0001`。
  guest 經 status queue 每次變化送一個事件：`EV_FF`、code `FF_RUMBLE`、value 高 16 位元 strong、低 16 位元 weak（都 0 是停）。
  計時由 guest 做（Linux memless），host 只照著強度。crosvm 本來就把 EV_MSC 以外的 status 寫回 socket。
- daemon：input bridge 多一個 VM 層級的 channel `VIBRATOR`（`_vib.sock`），讀回的紀錄交給 `HostVibrator`：取所有 VM 中最強的
  強度，以 `USAGE_PHYSICAL_EMULATION`（手把震動；背景也允許）在預設馬達上播 one-shot（最長 5 s，每次變化重發，guest 停止
  說話也不會一直震）；VM 停止時一併停。root 呼叫 VibratorManagerService 不檢查 package。不需要前景服務。
- Linux：stock virtio_input 只回送 LED 與聲音、不給 FF，所以 guest additions 第五個模組 `droidvm-vibrator`：綁 4456:0001，
  註冊 "DroidVM Vibrator"（4456:0002，避免綁到自己）帶 memless FF_RUMBLE，播放時經 host 裝置自己的 event callback 送出
  （input_inject_event 會丟掉 EV_FF）。udev 規則標 `FEEDBACKD_TYPE=vibra` 給 feedbackd。
- 只在有輸出畫面的 VM（有 input bridge）才有；卡片說明手機有沒有馬達。

**commit**：crosvm f82707d2c（兩個 wip 分支）、app 902fa32（本地）、guest additions ed96a62（`wip/hackintosh`）。

**驗證**：5566（PLK110）Ubuntu：開機依 modalias 自動載入；EVIOCSFF rumble 0xc000 → 振幅 0.749、播 1500 ms 後停，0xffff → 1.0、
700 ms（vibrator HAL log；dumpsys 記為 uid 0 的 PHYSICAL_EMULATION）；rmmod／modprobe 後仍只有一個 rumble 裝置；
`FEEDBACKD_TYPE=vibra`。5567（沒有馬達）：daemon 記一次「沒有震動器」。

**陷阱**
- crosvm 的 `virtio_input_device_ids::new` 參數順序是 `(bustype, product, vendor, version)`（第一版 vendor/product 反了）。
- input handler 的 connect／disconnect 持有 input core 的鎖，裡面呼叫 `input_(un)register_device` 會卡住（第一版 insmod 卡死，
  只能 kill）；改由 ordered workqueue 註冊／移除。

**還沒做**：卡片沒上機看過；Windows（HID haptics 或 XInput 震動）；iPadOS 不需要（iPad 沒有 Taptic Engine）。

## 11-10 晚 三項的上機驗證（5566，畫面解鎖）

- **卡片與權限（繁中 UI）**：GNSS 卡片拒絕權限 → 提示「未授予位置權限，因此沒有新增 GNSS 接收器」、不加卡片；第二次先出現
  我們的說明對話框再到系統對話框；只給大概位置 → 提示「只允許了大概位置…」並加上卡片。來源選單（自動／GNSS 接收器／
  僅位置）會換說明；「標成模擬」開關；GNSS 與 Vibrator「只能有一個」；GyroScope 的「磁力計」開關預設開；Vibrator 卡片
  說明手機有馬達。存檔寫進 vms.json，重開編輯頁還在；從清單啟動時 crosvm 參數帶齊三個裝置；刪卡片也正常。
- **console 覆寫**：console 在前景、畫面方向 0 時，guest 的磁場等於手機 ak0991x 的讀數；畫面右轉一格後 guest 收到
  (x, y) → (−y, x)、航向 +90°（227° → 318°），手機自己的讀數不變 → 是 app 轉過再送的。
- **guest additions 整包安裝**（r25 → r29 deb，`dpkg -i`）：80 s，dkms 對兩個 kernel 都編好五個模組；重開機後 droidvm-compass、
  droidvm-vibrator、virtio_gpu、gunyah_guest 從 updates/dkms 載入（virtio_media 沒載是因為這台沒開 VPU），桌面正常；
  兩條 udev 規則、gpsd AppArmor 那行都在。震動用套件裡的模組：0x6000 → 振幅 0.376、900 ms。
- **找到並修好（app 1d02de6）**：只給大概位置時 Android 把 fused 的 1 s 請求改成每 10 分鐘一次（`@+10m LOW_POWER`），最後已知位置
  又可能是空的 → 開機要等最多 10 分鐘才有 fix，之後每次更新 60 s 就掉。現在啟動時取各 provider 最新的最後位置並
  `getCurrentLocation` 一次，僅位置模式保留 15 分鐘。驗證：開機 30 s 內有 fix（GGA 品質 8、RMC 模式 S、GST σ 約 1.3 km），撐過 60 s。
- **真實晶片（精確位置、app 在前景）**：開始時 guest 收到 14 顆有 C/N0 的衛星，五個系統都有（晶片報 49 顆）；約 1 分鐘後 OPLUS
  的定位省電 `NavigationStatusLightMonitor`（靜止＋光感 0 lux）`stopNavigating`，之後天空變空。管線是通的；fix 要在戶外、
  手機不在靜止＋暗處時才看得到（還沒做到）。

## 10-30 TODO 7 電源鍵與音量鍵

**電源鍵、音量鍵（使用者 2026-10-30 加；DroidVM app 目前沒有這些按鍵）。**

- iPadOS 上它們不是鍵盤頁（0x07）的鍵，而是 Consumer page（0x0C）的 HID 按鍵事件：Power／Lock 0x30、Volume+ 0xE9、
  Volume− 0xEA（另有 Mute 0xE2、Home＝Menu 0x40）。backboardd／SpringBoard 依 usage page＋usage 分辨。
- 現況：`package/DroidVMVirtioInput.c` 只把 Linux keycode 轉成 boot keyboard 的 report 1，表裡沒有 `KEY_MUTE`(113)、
  `KEY_VOLUMEDOWN`(114)、`KEY_VOLUMEUP`(115)、`KEY_POWER`(116)，app 送了也會被丟掉。`NativeHidInput` 的 report 2 已是
  Consumer Menu（Home），但只有 rig 的 `tools/rig/home.py` 在用；上游給 sheng ButtonProbe 的 `native_buttons_set_sink`
  在 DroidVM 是空 stub（`package/DroidVMStubs.c`）。
- 做法：host（app）在 virtio keyboard 上（或另開一個通用的 virtio-input 按鍵裝置，類似 gpio-keys）送標準 Linux keycode，
  Linux guest 不用改就能用（logind 處理電源鍵）；XNU 把這幾個碼分出來、改送 Consumer report（擴充 report 2，或實作
  `native_buttons_set_sink`），Home 一併接到 app。
- 電源鍵要送真實的按下／放開與按住時間（長按叫 Siri／關機畫面、電源＋音量截圖都靠時序）。待驗：SpringBoard 的鎖定
  是否要求按鍵服務帶 `Built-In`。

## 11-08 觸控筆壓感與橡皮擦端

**壓感（已修，device de1061a）。** 用力畫 Notes 的筆畫也不會變粗。逆向 iPadOS 27（24A446）的結果：

- UIKit：`__startNewUITouch` 把 stylus 事件的 `kIOHIDEventFieldDigitizerPressure` 原值存進 `_pressure`；
  `-[UITouch _unclampedForce]` ＝ `_pressure / (120 × _AXSForceTouchSensitivity())`（觸控筆是 120，其他 touch 是 60，預設靈敏度 1.0），
  `maximumPossibleForce` ＝ backboardd 給的 `maximumForce`（裝置的 `AccurateMaxDigitizerPressureValue`）÷ 同一個數。
- PencilKit：`InputPoint.inputPointForTouch` 只用 `maximumPossibleForce > 0` 判斷有沒有壓力，墨水寬度直接吃 `touch.force` 的絕對值。
- 原本壓力 0..1、最大值 1，force 永遠小於 0.01，PencilKit 當成極輕的筆壓，畫出最細的線。Safari 的 Pointer Events
  是 force ÷ maximumPossibleForce，比例對，所以 11-04 驗證時看不出來。
- 修法：壓力送 0..500、`AccurateMaxDigitizerPressureValue` 500，`maximumPossibleForce` 變成 4.17，和 Apple Pencil 一樣。
  5567 用合成筆實測：0.1 畫 12 px、1.0 畫 38 px（修之前兩者都是 10 px），0.05 → 1.0 的一筆由細變粗。
  Safari 那邊的比例照理不變，但 5567 目前沒有網路，沒有重新量 Pointer Events。

**橡皮擦端（未做）。** pen.py `--eraser`（BTN_TOOL_RUBBER → 報告的 Eraser 位元）在 Notes 裡照樣畫線。iPadOS 沒有「橡皮擦端」
這種 touch（Apple Pencil 沒有，UIKit 的 stylus 事件也沒看到對應欄位）。可能的路線：橡皮擦端接觸時，改送 Apple Pencil 的雙擊或
squeeze 事件，讓 Notes 自己切到橡皮擦工具，抬起後再切回來。5567 的 OnePlus Pencil Pro（`touchpanel_pen`）只有
BTN_TOOL_PEN、BTN_TOUCH、BTN_STYLUS／2，沒有橡皮擦端，這條只影響有橡皮擦端的筆。

## 11-08 Linux 與 Windows guest 的 stylus 支援

crosvm `--input stylus`（c9e24ed54）對 guest 是一個標準的 evdev 筆型數位板：INPUT_PROP_DIRECT、BTN_TOOL_PEN／RUBBER、BTN_TOUCH、
BTN_STYLUS／2、ABS_X/Y（0..0x7FFF，解析度 0）、ABS_PRESSURE 0..4095、ABS_DISTANCE 0..255、ABS_TILT_X/Y ±90（57 單位／弧度）。
app 對每個原生輸出的畫面都加這個裝置，不分 guest（Linux、Windows 走 PCI，iPadOS 走 MMIO）。

**Linux：kernel 認得，桌面（libinput）不收。**
- `drivers/virtio/virtio_input.c` 把 EV／KEY／ABS 位元、absinfo（含 res）和 INPUT_PROP 照抄成 input_dev，不用改；udev 標成
  `ID_INPUT_TABLET=1`。
- libinput（GNOME、KDE、wlroots、Xorg 的 xf86-input-libinput）要求平板的 ABS_X/Y 有解析度（`tablet_reject_device`），沒有就整個忽略。
  在 host 上用 uinput 做一個能力相同的裝置，讓 libinput 1.25 判一次（scratchpad 的 pentab.c）：
  - 解析度 0（現況）：`libinput bug: missing tablet capabilities: resolution. Ignoring this device.`，裝置沒加進來。
  - 解析度 128（單位／mm）：加進來，是 tablet-tool。
- Android guest 的 InputReader 不需要解析度，應該直接能用（沒實測）。
- 修法（host 通用）：crosvm stylus 的 ABS_X/Y 填解析度＝範圍 ÷ 畫面實際的公釐數。app 知道 guest 畫面在手機上佔多少 px，也知道手機的
  xdpi／ydpi，可以算好傳給 crosvm（例如新增 `width-mm`／`height-mm` 參數）。iPadOS 不看這個值；觸控（multi-touch）不需要。

**Windows：vioinput 認得，但只剩位置、筆尖和一顆側鍵。**
- 分類（`vioinput/sys/Hid.c` 的 `VIOInputBuildReportDescriptor`）：滑鼠只收 BTN_MOUSE 範圍的按鍵、搖桿只收 BTN_JOYSTICK 範圍，
  這個裝置都沒有，所以落到 `HidTablet.c` 的單點（ST）路線。
- 產生的 HID：頂層 collection 是 Digitizer（0x0D/0x01，外接數位板），不是 Pen（0x02）；logical collection 是 Stylus，欄位只有
  Tip Switch、In Range、Barrel Switch、X、Y，另外帶著觸控才用的 Contact ID、寬高、Contact Count／Max。
- 事件（`HIDTabletEventToReport`）：BTN_TOUCH → Tip＋In Range（只有碰到時才 in range，沒有懸停），BTN_STYLUS → Barrel。
  BTN_TOOL_PEN（懸停）、BTN_TOOL_RUBBER（橡皮擦）、BTN_STYLUS2、ABS_PRESSURE、ABS_TILT_X/Y、ABS_DISTANCE 全部丟掉。
- 小 bug（upstream 也有）：`HIDTabletProbe` 收按鍵的迴圈拿 `pAxes` 的 bitmap 解碼（應該是 `pButtons`），按鍵沒從 KeyData 拿掉；
  BTN_* 不在鍵盤表裡，所以目前沒有多出一個鍵盤裝置。
- Windows 會不會把 0x01 Digitizer 當成筆（Windows Ink），沒在 Windows guest 上實測。
- 修法（guest 驅動，我們的 fork gunyah-guest-drivers-windows）：有 BTN_TOOL_PEN 的單點裝置另走一條 Pen 路線：頂層 Pen（0x02）；
  Tip Switch、Barrel（BTN_STYLUS）、Secondary Barrel（0x5A，BTN_STYLUS2）、In Range（BTN_TOOL_PEN／RUBBER）、Invert（0x3C，
  橡皮擦端在範圍內）、Eraser（0x45，橡皮擦端接觸時取代 Tip）、X、Y、Tip Pressure（0x30）、X／Y Tilt（0x3D／0x3E，單位度）；
  不帶 Contact ID 這些觸控欄位。要開 Windows VM 實測。

## 11-09 觸控板 Linux 與 Windows 用哪些值

計畫把 app 的相對滑鼠模式改成真的觸控板（多指位置、壓力）。crosvm 已有 `--input multi-touch-trackpad`（upstream）：
INPUT_PROP_POINTER＋BUTTONPAD；BTN_TOUCH、BTN_TOOL_FINGER..QUADTAP（沒有 QUINTTAP）、BTN_LEFT；ABS_MT_SLOT 0..10（11 個 slot）、
TRACKING_ID、MT_POSITION_X/Y、MT_TOOL_TYPE、MT_PRESSURE／PRESSURE 0..255、MT_TOUCH_MAJOR/MINOR 0..4095、ABS_X/Y，全部沒有解析度。

**手機能給什麼。** 三台手機的手指觸控面板（getevent -lp、dumpsys input）：

| 手機 | 壓力 | 接觸大小 | Android 的換算 |
|---|---|---|---|
| OnePlus PLK110 | `ABS_MT_PRESSURE` 0..0 | TOUCH_MAJOR、MINOR 0..255 | size GEOMETRIC，pressure none |
| OnePlus OPD2404 | `ABS_MT_PRESSURE` 0..0 | TOUCH_MAJOR 0..255（沒有 MINOR） | size GEOMETRIC，pressure none |
| Lenovo TB322FC（Novatek） | `ABS_MT_PRESSURE` 0..1 | TOUCH_MAJOR 0..255（沒有 MINOR） | size GEOMETRIC，pressure physical |

- 沒有一台的手指有壓力。範圍 0..0 的軸 EventHub 當成不存在，`MotionEvent.getPressure()` 觸碰時固定 1.0；0..1 那台只有 0 或 1，
  等於「有沒有碰到」。
- 接觸大小也不是每台 Android 都有：Linux 多點觸控協定只要求位置，TOUCH_MAJOR／WIDTH_MAJOR 都是選填。沒有的話 Android 的
  `touch.size.calibration` 是 none，`getTouchMajor()`、`getSize()` 都是 0。
- 有的話單位也不可靠：三台都沒有 IDC 檔，GEOMETRIC 假設大小和位置同單位、照螢幕比例縮放，但位置是 0..21199 而大小只有 0..255，
  換成畫素最多約 36 px（OPD2404，3000 px 寬），一根手指約 80 px。所以 app 只能把它當相對值（`getSize()`＝原始值／最大值），
  不能當公釐。
- 範圍是驅動宣告的；實際手指送出多少（會不會只有幾個固定值）要有人摸螢幕才量得到，還沒量。
- 結論：guest 要的「壓力」只能由接觸大小推算，或乾脆不給；連接觸大小都要當成「可能沒有」。

**Linux（libinput）：現在的裝置就能用，kernel 不用改。** 在 host 上用 uinput 做 crosvm 裝置的雙胞胎，讓 libinput 1.25 吃多指滑動
（scratchpad 的 trackpad.c）：
- udev 標成 `ID_INPUT_TOUCHPAD=1`；virtio_input 依 ABS_MT_SLOT 的最大值 `input_mt_init_slots`。
- 單指 → 游標移動，雙指 → 捲動（scroll finger），三指、四指 → swipe gesture（finger count 3／4），五指 → 沒有任何 gesture（libinput
  最多四指；有沒有 QUINTTAP 都一樣）。
- 沒有解析度：`no resolution or size hints, assuming a size of 69x50mm`，照常運作，但速度、加速度和以公釐算的門檻（捲動距離、邊緣
  palm 區、thumb 區）都照假尺寸算。給 12 單位／mm（106x85 mm）後同一筆滑動的 dx 從 227 變 342。
- 壓力只用在兩件事，不會交給應用程式：
  - 判觸碰：`using pressure-based touch detection (25:30)`（範圍的 10%／12%）。實測 0、20 沒有觸碰，40、120 正常。
  - 判手掌：`palm: pressure threshold is 130`。實測 140、255 被當成手掌整個丟掉。
  - 裝置不宣告壓力軸：用 tracking ID 判觸碰，一到四指都正常。
  - 所以 host 若宣告壓力，就必須送合理的值：送 0（手機沒有壓力時最容易犯）手指全部不算，送太大變手掌。
- TOUCH_MAJOR／MINOR 預設不用（只在 quirks 設了 AttrTouchSizeRange／AttrPalmSizeThreshold 時）。
- BTN_LEFT＋BUTTONPAD 是 clickpad（整片按下＝左鍵，雙指按下或右下角＝右鍵）。手機螢幕按不下去：要嘛靠 guest 的
  tap-to-click（libinput 在裝置有 BTN_LEFT 時預設關、沒有時預設開，桌面環境可改），要嘛 host 自己判斷「按下」送 BTN_LEFT；Linux 7.1 另有
  INPUT_PROP_PRESSUREPAD（「壓力觸發點擊」，libinput 1.25 只有 ModelPressurePad quirk）。
- 應用程式拿不到每根手指（Wayland 只有 pointer、scroll、swipe／pinch／hold gesture）。

**Windows：vioinput 現在不支援觸控板，要另寫 Precision Touchpad。**
- 分類（`Hid.c`）：滑鼠探測先跑，有 BTN_LEFT 又有 ABS_X/Y，`EXPOSE_ABS_AXES_WITH_BUTTONS_AS_MOUSE`（vioinput.h 預設開）就把它做成
  「絕對座標滑鼠」。那段迴圈用 `DecodeNextBit` 解碼並清掉 AbsData 的**每一個**位元，認不得的軸（多指那些）也清掉，所以後面的
  tablet 探測根本不會跑：碰觸控板會讓游標跳到對應的絕對位置。
- 就算走到 `HidTablet.c` 的多指路線，產生的也是 Touch Screen（0x0D/0x04），不是 Touch Pad（0x05）。
- Precision Touchpad 規格（Microsoft，"Windows Precision Touchpad Collection" 與 "Configuration Collection"）：
  - 頂層 Touch Pad（0x0D/0x05）。每個 contact 必填：Contact ID（0x51）、Tip（0x42）、Confidence（0x47，手掌時清掉；寬或高
    超過 25 mm 必須是 off）、X、Y（logical ≥ 300 DPI，要有 physical 範圍和單位）。選填：Width（0x48）、Height（0x49）、
    Pressure（0x0D/0x30，範圍不限）、Azimuth（0x3F）。
  - 報告層必填：Scan Time（0x56，單位固定 100 µs，16 位元會繞回）、Contact Count（0x54）；選填 Button 1（整片按下）、
    Mechanical Force（0x20/0x494，＝各指壓力總和，單位要和 Pressure 一樣）。
  - Feature：Contact Count Maximum（0x55，3..5；超過這個數的一幀整個被丟掉）、Pad Type（0x59：0 可按下的 click-pad、
    1 不能按下的 pressure-pad、2 表面不能按、另有獨立按鍵的 discrete-pad）、Device Certification Status（0xFF00/0xC5 的 256 位元組；沒有這份報告 Windows
    不碰這個裝置，Microsoft 公布了一份預設 blob 可用）、選填 Latency Mode（0x60）、Button Press Threshold（0x0D/0xB0，
    Windows 11 26027 起讓使用者調點擊力道）。
  - 另一個頂層 Configuration（0x0D/0x0E）：Input Mode（0x52，0＝滑鼠、3＝PTP）、Surface Switch（0x57）／Button Switch（0x58）。
  - 手勢（點擊、捲動、三／四指、防誤觸）都由 Windows 自己做；壓力在標準功能裡用不到，pressure-pad 是裝置自己在約 150 g 時報 Button。
- 要做的事（我們的 fork gunyah-guest-drivers-windows）：INPUT_PROP_POINTER＋MT 的裝置不走滑鼠，改走新的 PTP class：
  slot → Contact ID，tracking ID ≥ 0 → Tip，MT_TOOL_TYPE＝PALM 或 TOUCH_MAJOR 過大 → Confidence off，MSC_TIMESTAMP → Scan Time，
  BTN_LEFT → Button 1，Contact Count Maximum 取 min(slot 數, 5)，Pad Type 依 BUTTONPAD／PRESSUREPAD，附預設 blob 和
  Configuration collection；也順便修絕對滑鼠那段清掉所有軸的迴圈。要開 Windows VM 實測。

**host 裝置建議（通用，Linux 原生語意）。** crosvm 新增或擴充 trackpad 參數：
- ABS_X/Y、MT_POSITION_X/Y、TOUCH_MAJOR/MINOR 帶解析度（app 用手機 dpi 和觸控板區域的大小算），Linux 用真尺寸，Windows 的 physical
  範圍也從這裡來。
- slot 數 5、加 BTN_TOOL_QUINTTAP（Windows 最多 5 點）。
- 送 MSC_TIMESTAMP（virtio 會成批送達，guest 要用裝置時間算速度；Windows 的 Scan Time 也從這裡來）。
- 手指沒有壓力就不宣告 ABS_MT_PRESSURE；手機有接觸大小（InputDevice 有 AXIS_SIZE 的範圍）才宣告 TOUCH_MAJOR/MINOR，照實送
  （正規化成 0..1 再換成裝置範圍，不用 Android 換算出的畫素）。macOS／iPadOS 要的壓力或接觸強度，由 guest 驅動從接觸大小推算，
  沒有接觸大小就給固定值；host 不造假。
- 「按下」由誰決定要先定：guest tap-to-click，或 app 判斷（例如長按或重按）送 BTN_LEFT，後者對應 Linux 的 PRESSUREPAD、
  Windows 的 Pad Type 1。

## 11-10 三個層次的觸控板能力：手機、虛擬裝置、各 guest

**手機（Android MotionEvent）。** 一定有：每個觸點的 pointer id、x/y（浮點）、事件時間（一幀內的歷史樣本）、按下／放開／取消
（取消或 FLAG_CANCELED 表示系統判成誤觸）。選填：接觸大小、壓力、方向、工具類型。三台手機：接觸大小有（單位不明，只能當相對值），
壓力沒有，方向沒有，TOUCH_MINOR 只有 PLK110；OnePlus 最多 10 點。

**虛擬裝置（crosvm virtio-input，evdev 語意）。**
- 一定送：slot、tracking ID、MT_POSITION_X/Y 和 ABS_X/Y（帶解析度）、BTN_TOUCH、BTN_TOOL_FINGER..QUINTTAP、MSC_TIMESTAMP。
- 手機有才送：TOUCH_MAJOR/MINOR（正規化）。Android 判成誤觸的觸點送 MT_TOOL_PALM（libinput 當手掌、Windows 清 Confidence）。
- 不送：壓力（手機沒有；Linux 收到 0 會忽略手指、≥130 當手掌）。
- 點擊要選一種：
  - 不宣告 BTN_LEFT：Linux 自動開 tap-to-click（實測），Windows PTP 用 Pad Type 2 不報按鍵（tap 由 Windows 自己做）。
  - 宣告 BTN_LEFT（BUTTONPAD，或 Linux 7.1 的 PRESSUREPAD）＋app 判斷「按下」：Linux 的 tap 要使用者自己開；Windows Pad Type 0／1；
    macOS 可以拿這個按下當 Force Click。

**只有位置時 Linux 能做什麼（uinput 實測，scratchpad 的 tapdrag.c，libinput 1.25，裝置只有位置、沒有壓力和大小）：**

| 動作 | tap 關（有 BTN_LEFT 時的預設） | tap 開（沒有 BTN_LEFT 時的預設） |
|---|---|---|
| 單指輕點 | 沒反應 | 左鍵 |
| 雙指／三指輕點 | 沒反應 | 右鍵／中鍵 |
| 點一下，64 ms 內再按住移動 | 只有移動 | 拖曳（左鍵按住，抬手就放開） |
| 點一下，400 ms 後再按住移動 | 只有移動 | 一次點擊，再移動 |
| 按著 BTN_LEFT 移動 | 拖曳 | 拖曳 |
| 開 drag lock，拖曳中抬手 120 ms 再拖 | — | 同一次拖曳（最後抬手約 300 ms 後才放開） |

三指拖曳要 libinput 1.28 以上。libinput 沒有 force click；接觸大小預設不用；壓力只拿來判觸碰和手掌。

**各 guest：**
- iPadOS：游標、輕點即點擊（設定）、點住再滑＝拖曳、雙指捲動和次要點按、捏合、三指回主畫面／切 app；輔助使用的
  「指標控制」有點兩下拖移（版本間有出入，要在 guest 裡確認）。Apple 的 iPad 手勢表沒有 Force Click，觸控板上的「重按」就是點住不放，
  所以不需要力度。要哪種裝置（Apple multitouch 或通用 HID Touch Pad）還沒逆向。
- macOS：手勢只走 Apple 自己的 multitouch 驅動（黑蘋果用 VoodooInput 模擬 Magic Trackpad 2）。Force Touch 的模擬方式
  （VoodooPS2）：1 按下＝Force Click、輕點＝一般點擊；2 接觸面積變大＝Force Click；4 依公式送壓力（3 直接送原值，不建議）。
  VoodooRMI：按下加面積門檻，或只看面積。沒有面積就用 1；查詢與資料偵測器也可改成三指輕點。拖曳（按住拖、點兩下拖、三指拖）
  都只要位置。
- Linux：見上表。
- Windows：現在的 vioinput 把它當絕對座標滑鼠，沒有任何手勢。有 PTP class 之後，點擊、點兩下拖曳、雙指右鍵、三／四指手勢都是 Windows
  自己做，只要 Contact ID、Tip、Confidence、X/Y、Scan Time、Contact Count；Width/Height 選填（不能送 0，沒有就不宣告），
  Pressure 選填。Windows 沒有 Force Click；pressure-pad 是裝置自己判斷「按下」送 Button。

## 11-10 trackpad 裝置與 app 切換

使用者決定：點擊用方案 A（裝置沒有按鍵，guest 輕點即點擊）；原本的模擬滑鼠保留；新的通用裝置叫 trackpad，XNU 內映射成 Magic
Trackpad，Windows 之後實作 Precision Touchpad。

**crosvm（23ed5ac72，wip/virtio-mmio 與 wip/hackintosh）。** 沿用 `trackpad` 這個種類，加 `contacts` 就變成多指觸控板，不加維持原本
的單指觸控板（左右鍵）：
- `trackpad[path,width,height,name,contacts=N,res=R,touch-size=BOOL]`
- INPUT_PROP_POINTER、沒有按鍵；BTN_TOUCH、BTN_TOOL_FINGER..（依 N，最多 QUINTTAP）；ABS_MT_SLOT 0..N-1、TRACKING_ID、
  MT_POSITION_X/Y 和 ABS_X/Y（解析度 R 單位／mm）、MT_TOOL_TYPE（0..2，2＝手掌）；touch-size 時加 MT_TOUCH_MAJOR/MINOR 0..255
  （面板範圍的比例，不是長度）；EV_MSC MSC_TIMESTAMP。

**app（33d0a76，本地）。**
- 新通道 TRACKPAD＝6（VM 全域，socket `dvmin_<vm>_tp.sock`），裝置名 "DroidVM Trackpad"，排在所有輸入裝置最後（MMIO 位址不動）。
- daemon：邊長＝手機螢幕長邊的 mm×20（DisplayManager real metrics；5567 是 5020＝251 mm）；`touch-size` 由 `getevent -lp`
  判斷（有 INPUT_PROP_DIRECT、MT_POSITION_X、MT_TOUCH_MAJOR 且 max>min），不用 InputManager，因為螢幕關著時 Android 不給範圍。
- 選單的滑鼠按鈕：從觸控／手寫板按 → 相對滑鼠；在滑鼠或觸控板時再按 → 切到另一個，圖示跟著換（InputModeToggle，原生顯示和 VNC
  共用）。模式 ordinal：TRACKPAD＝3。
- TrackpadEncoder：每個事件送整幀（所有手指位置），第 6 指起整段忽略；位置＝view px × 20×25.4/dpi；接觸大小＝getTouchMajor／
  該裝置 AXIS_TOUCH_MAJOR 範圍上限 × 255；FLAG_CANCELED 的 UP 和 ACTION_CANCEL 先標 MT_TOOL_PALM 再放開；MSC_TIMESTAMP 用事件
  時間（µs）；手指停著時每 50 ms 送 keepalive；離開觸控板模式時放開所有手指。硬體滑鼠在觸控板模式仍走相對滑鼠。

**5567 實測。** 裝 APK 後 root daemon 還是舊的，要停 VM、依 pid 結束 daemon、`daemon-recover.sh` 重啟才會帶新參數。crosvm 參數
`trackpad[...,width=5020,height=5020,res=20,contacts=5,touch-size=true,name=DroidVM Trackpad]`，VM 正常開機。選單切換：
觸控(0) → 滑鼠(1) → 觸控板(3) → 滑鼠(1) → 觸控板(3)，圖示變成觸控板；觸控板模式滑動沒有錯誤。iPadOS guest 目前把這個裝置判成
KIND_NONE（MT 位置但沒有 INPUT_PROP_DIRECT），所以還沒有作用；測完切回觸控。

**XNU：映射成 Magic Trackpad 要什麼（11-10 調查）。**
- guest 的 kernel collection 只有 32 個 kext（profile 的 `roots`，再和我們的 XNU 重新配對；`fileset-reviewed.json` 補人工配對），
  沒有多點觸控驅動。Apple 原版 24A446 kernelcache（308 個）有 AppleMultitouchDriver、AppleActuatorDriver、AppleMultitouchSPI、
  AppleHIDTransport*（MultitouchSoftware-10100.44）。
- AppleMultitouchDriver 的比對規則（原版 prelink）：AppleMultitouchHIDService 接 IOHIDInterface，Manufacturer "Apple" 的
  0x0D/0x00、0x0D/0x04、0x0D/0x20（內建螢幕和筆，MT Built-In、parser-type 1／4、IOCFPlugInTypes → MultitouchHID.plugin），
  以及 **MTUserDevice**：usage page 0xFF60 usage 7，不限製造商。kernel 裡沒有藍牙 Magic Trackpad 專用驅動：iOS 的藍牙 HID 在
  userspace（bluetoothd），推測它為 Magic Trackpad 建一個 FF60/7 的 IOHIDUserDevice，交給 AppleMultitouchHIDService →
  AppleMultitouchDevice → userspace 的 MultitouchHID.plugin／MultitouchSupport 解析（待逆向確認）。
- 相依：AppleMultitouchDriver 要 AppleARMPlatform（已有）、AppleInputDeviceSupport（沒有）、IOHIDFamily、IOReportFamily。
- 計畫：
  1. profile roots 加 AppleMultitouchDriver＋AppleInputDeviceSupport，配對缺的 kernel 符號，開機確認。
  2. 逆向 bluetoothd 為 Magic Trackpad 建的 user device：report descriptor、屬性（parser-type、Family ID、感測面尺寸等）、
     frame 格式（應是 Magic Trackpad 2 的原始報告，Linux hid-magicmouse 解的那種：每指 9 bytes，X/Y 13 位元）。
  3. DroidVMVirtioInput 加 KIND_TRACKPAD（MT 位置、INPUT_PROP_POINTER），NativeHidInput 發佈 FF60/7 裝置，把 virtio 的幀轉成
     Magic Trackpad 2 的幀（mm → MT2 座標，接觸大小 → size／pressure）。
  4. 5567 實測：游標、輕點、雙指捲動、三指手勢。

**還沒做。** 見下一節。
- Windows：vioinput 的 Precision Touchpad class（之後）。
- Linux guest 端到端（libinput 行為已用 uinput 雙胞胎驗過）。

## 11-10 XNU：觸控板發佈成 Magic Trackpad 2（device 0c3fa5d）

**iPadOS 怎麼接 Magic Trackpad（逆向結果，修正上一節的推測）。**
- bluetoothd 的 TrackpadInputDevice 為一個 MT2 建四個 IOHIDUserDevice，描述格式寫死在程式裡：管理（0xff00/0x0b）、觸控板、
  致動器（0xff00/0x0d）、第四個（0xff00/0x03）。觸控板的描述格式（110 bytes）和 acidanthera VoodooInput 模擬 MT2 用的
  **完全相同**：mouse report 2、Digitizer/Touch Pad（0x0d/0x05，report 0x3f）、vendor 0xff00/0x0c（report 0x44，1387 bytes）。
- 比對它的是 AppleTopCaseDriverV2 的 personality "Magic Trackpad BT iOS/tvOS Event Driver - TopCase - 613"（VendorID 76、
  ProductID 613、usage 1/2）→ AppleTopCaseHIDEventDriver 的 AppleMultitouchTrackpadHIDEventDriver → AppleMultitouchDevice
  （DefaultMultitouchProperties：HSTouchHIDService）→ backboardd 的 HSTouchHIDService.plugin。MTUserDevice（0xff60/7）不是這條路。
- 幀格式：report 2，12 bytes 表頭（[1] 按鍵、[7] 3 有手指／2 沒有、[8] 0x31、[9..11] 毫秒時間戳 `ms<<3|4`）＋每指 9 bytes
  （X、Y 各 13 位元有號、手指種類 3 位元、狀態 3 位元：3 落下、4 接觸、7 抬起；major、minor、size、pressure；id 4 位元＋角度）。
- 驅動會讀 feature report：Family ID（0xd1，0x81）、Sensor Rows/Columns（0xd3）、Sensor Region（0xd0、0xa1）、Sensor Surface
  Width/Height（0xd9，0.01 mm），回答照 VoodooInput。

**實作。**
- DroidVMVirtioInput.c：kind 6 trackpad（MT 位置、INPUT_PROP_POINTER、沒有 DIRECT），每幀把落下的和這幀抬起的手指交給 sink，
  座標換成 0.01 mm。
- DroidVMTrackpadHid.inc：DroidVMTrackpadHIDDevice，描述格式、VendorID 76／VendorIDSource 1／ProductID 613、Transport
  Bluetooth、ExtendedData 都照 bluetoothd；不設 HIDDefaultBehavior（不讓通用的 IOHIDEventDriver 當成滑鼠搶走）。表面大小用
  virtio 的解析度算（5567：251.05 mm 見方）。送幀節奏 8 ms（MT 裝置的 ReportInterval），中間來的幀合併；時間戳嚴格遞增。
  沒按鍵：點擊要靠 iPadOS 的「點一下來按一下」（預設關，ApplePreferencesDefaultPreferences Clicking=0）。
- board.toml `[kernel.prelink] roots` 加 AppleTopCaseDriverV2、AppleTopCaseHIDEventDriver；相依的 AppleMultitouchDriver、
  AppleInputDeviceSupport、AppleMultitouchSPI、AppleHIDKeyboard、IOSlaveProcessor 自動帶進（非 root 的比對規則會被丟掉）。
  它們的 __DATA 都在 Libm 之後，native __DATA 空間不變。fileset-reviewed 加兩組配對：os_log_info_enabled、
  IOBufferMemoryDescriptor::inTaskWithGuardPages（原本會變成未配對的 stub）。

**5567 實測。**
- 整條鏈接起來了：DroidVMTrackpadHIDDevice → IOHIDInterface → AppleMultitouchTrackpadHIDEventDriver → AppleMultitouchDevice
  （Family ID 129、parser-type 1001、Sensor 22×30、有 user client）。backboardd 的 HSTouch 解析手指（"[TP] Dispatching digitizer
  event"），BKMousePointerController 把它當指標裝置（HIDTrackpadAcceleration），pointeruid "Unhiding pointer: definitive
  trackpad interaction"。
- 坑：adb `input swipe` 是忙迴圈，一毫秒好幾幀 → "Frame interval is zero!"、速度歸零，backboardd 佇列 overrun（"Pointer event
  dropped"）→ 加了 8 ms 合併。
- 設定 → 一般 出現 **Trackpad** 頁（追蹤速度、自然捲動、點一下來按一下、兩指輔助按一下）；5567 上已打開「點一下來按一下」。
- 游標位置是對的：左右滑動游標跟著走、推到邊緣停住；SpringBoard／App 收到 hover（log 的 "Entered region"：狀態列、
  小工具 376×180、圖示 87.5×87.5；視窗化 App 右下角的縮放角、側欄邊緣提示都會出現）。
- **游標本身沒畫出來（11-10 修好，根因和修法見本段最後的「根因」）。** pointeruid "Unhiding pointer"、狀態 Visible，但游標在畫面中間時截圖差異找不到；
  輔助使用 → 指標控制 打開「增加對比」、最大尺寸、關掉自動隱藏也一樣；@1x（1024×1366）和 @2x（2048×2732）都一樣。
  - @1x 另有比例不一致：backboardd "StartWindowServer: MG scale:2 display preferredScale:1"，window server display 是
    scale 2，游標區域 512×683（ffeb241 的 fixup 只改 preferredScale；MG main-screen-scale 仍是 2）。@2x 時區域 1024×1366。
  - 游標的承載：pointeruid 的 pointerRenderingScene 放在 SpringBoard presentation binder 的 level -1000（來源），
    systemPointerScene 在 level 10000015.5，各自裝在一個 SBFSecureTouchPassThroughWindow 裡。（更正：兩邊的 scene 最後都是
    ready，之前寫「一直 preparing」是看了被截斷的輸出。）跟觸控板無關，換成滑鼠也會遇到。
  - 11-10 下午追到的（gfxprobe 新指令：`casnap`、`cadebug N V`、`cafilter`、`cahost`、`cabackdrop`，見 gfxprobe.m 開頭）：
    - 游標不是硬體游標：顯示只宣告 1 層，swap 永遠只有第 0 格（拒絕 0 次），virtio-gpu 的游標平面沒被用到。
    - 濾鏡（blur、alphaThreshold、plusL、colorMatrix、opacityPair）、secure context、disableUpdateMask 0x20 都畫得出來。
    - CAPortalLayer：同一 context 正常；portal 所在的頂層 context 比來源高時是空的（加 crossDisplay=1 就有），兩邊都被
      CALayerHost 承載時正常。CA 的 prepare_layer0 只在這次 update 已準備好的 LayerNode 裡找來源（找不到會標記 dependence）。
    - 但游標本身的 portal 有找到來源：`gfxprobe cadebug 209 1`（CA_PRINT_PORTALS）後 log 有 "Portal … found source … from
      context <pointerRenderingWindow>"，沒有 "cannot find"。
    - 截圖差分：自由移動的游標畫面完全不變；游標吸附到 Home 指示條時外框有出現；推到邊緣時出現一排稀疏的水平條紋。
    - render tree（`cadebug 5 1`＝CA_PRINT_TREE；guest 的 /private/var/preferences/Logging/Subsystems/
      com.apple.coreanimation.plist 和 com.apple.PointerUI.plist 設 Default-Privacy-Setting Public，重啟 logd 後才不會被遮；
      每則最多 32 KB）：游標是 CABackdropLayer＋游標形狀 mask＋PointerUI 的 vibrant colorMatrix，外層 opacity 0.85，
      "3 passes (offscreen-flags [backdrop-copy mask])"。matrix 的 alpha 列 = 0.208r+0.232g+0.045b+a−0.403：backdrop 取到
      全透明時 alpha 夾成 0，游標就完全看不見 → 嫌疑是 backdrop-copy（離屏、有 mask、經 portal）在 metal2vulkan 上取到空的。
    - 下一步：`gfxprobe cabackdrop` 逐步重現（backdrop、加 matrix、加 mask、加 0.85 群組、經 portal），找出哪一步變透明。
    - **根因方向（11-10 晚）：只有橫向介面看不到。** `gfxprobe orient 1`（直向，不旋轉）後游標正常出現（灰色箭頭＋紅框，會跟著
      移動）。橫向時 iPadOS 把整個介面轉 90° 畫在直向的 1024×1366 framebuffer 上，pointeruid 的視窗根層帶旋轉；游標的離屏群組
      （backdrop-copy＋mask）在旋轉下畫不出來，推到邊緣才畫出條紋。我的未旋轉測試方塊（cabackdrop 0–11）都正常，滑鼠模式也一樣
      看不到 → 跟觸控板無關。CA_PRINT_OFFSCREENS（cadebug 31）：橫向時游標在中間的幀幾乎沒有它的 mask／backdrop-copy pass。
    - **根因（11-10 晚，修好）：CoreAnimation 自己在「GPU 旋轉 framebuffer」這條路上的路徑覆蓋率算錯，不是 metal2vulkan。**
      - 重現：`gfxprobe cabackdrop` 第 12、13 格用游標的箭頭路徑（三次曲線）當 mask，一格紅色圖層、一格 backdrop。直向畫得出來，
        橫向兩格都空 → 不需要 backdrop／portal，任何曲線路徑的 shape mask 在橫向都會消失。
      - 橫向時 framebuffer 紋理是 rot3（frame 1366×1024，存成直向 1024×1366 的 IOSurface）。路徑的 pass：path_clear／path_rect／
        path_cubic 把覆蓋率累加進 memoryless R32Float（c2），path_blit 用 framebuffer fetch 讀回。path_*_frag 拿 `[[position]]`
        跟 vertex shader 算的像素座標比，而 vertex shader 用一個「viewport」uniform（vertex buffer 5）把 NDC 換成像素：CA 傳的是
        `1024 1366`（surface 未轉的尺寸），pass 的 frame／viewport 卻是 1366×1024 → 覆蓋率幾乎全 0，只在兩套座標剛好重疊的邊緣有值
        （= 推到邊緣看到的條紋）。QuartzCore：`PathFiller` 建構子讀 `context->surface(+0x2d0)` 的 +0x30／+0x34，而
        `MetalContext::get_surface` 把 WindowServer surface 的寬高（+0x38，IOSurface 的 1024×1366）原樣放進 +0x30，轉過的寬高另存。
      - 不是 metal2vulkan：`gfxprobe rotfetch W H ROT FLAGS`（旋轉 fbonly c0＋memoryless R32Float c2，清除／加覆蓋率／fetch 讀回）
        在 rot 0／1／3 各種組合都對（4720/4800）。Mac M4 上真的 Metal（scratchpad ptr/rotpos.m）：旋轉 target 的 `[[position]]` 是
        frame 座標，CA 的公式用 vp 1366×1024 → 5103 個紅點，用 1024×1366 → 只剩 1449。也就是這條路在 Apple 硬體上一樣會壞。
      - 為什麼會走到這條路：backboardd 的 `UpdateMirroredDisplayOrientationWithInterfaceOrientationForSource:` 依介面方向對 CA
        顯示器 `setOrientation:`（log "Updating external display interface orientation from portrait to landscapeLeft"；來源 UUID
        空時取 `[CADisplay mainDisplay].uniqueId`，所以轉的就是主顯示器）。顯示器能旋轉掃描輸出時（`display_supports_rotation_p`：
        IOMFB 的 IOMFBSupportsRotation＋壓縮過的 framebuffer surface），CA 交給顯示器轉；否則它用 Metal 的 rotation 自己轉。
        真機的 DCP 吃 AGX 壓縮 framebuffer，不會走 GPU 旋轉；我們沒有壓縮格式，只能走它。
      - 試過但沒用：kernel 顯示驅動加 IOMFBSupportsRotation=YES（log 變 "Rotation Support Enabled: YES"，swap 全部接受），
        framebuffer 照樣是 rot3、箭頭還是空的 → 已還原，沒提交。
      - **修法（device 8d8f023）：backboardd 設定 `BKForceMirroredOrientation = portrait`**（mobile 的 com.apple.backboardd；BKSDefaults
        forceMirroredOrientation：backboardd 開機時把顯示器設成它，之後忽略鏡像方向更新）。CA 顯示器維持 rot0，畫面像素一樣（GPU
        旋轉本來就是轉進 frame 再存回去），路徑 mask 正確，也省掉每個 pass 旋轉 framebuffer 的進出複製。5567 實測：橫向鎖定畫面／
        主畫面正確，第 12、13 格箭頭畫出來，觸控板游標（灰色箭頭＋紅框）在橫向跟著移動。
        - 新 seed：`build-droidvm-data-seed.py` 的 PREFS 加上這一項。既有 VM（新 seed＝新 Data UUID，不要重做）：
          `tools/rig/guest-pref.py mobile com.apple.backboardd BKForceMirroredOrientation=portrait --restart backboardd`。
        - 副作用：CADisplay currentOrientation 永遠 rot0；只影響鏡像到外接顯示器（AirPlay）時的方向，這台沒有。
  - 多指注入工具（scratchpad xnu-tp/mt：mtinject.c 靜態 aarch64、mtgesture.py）：直接寫 5567 的 /dev/input/event6，Android
    收到真的多指 MotionEvent。座標：畫面 x = raw y/10、y = 2120 − raw x/10。注意：點到 app 工具列返回鍵會離開顯示頁，再打開
    就是 "Failed to start native display"，要 vm.sh 重開。
  - 手勢實測（11-10，5567）：雙指捲動 ✅（主畫面翻頁）、三指上滑回主畫面 ✅（鎖定畫面直接解鎖；App 裡也行，前景有對話框時被
    擋）、點一下來按一下 ✅（游標停在圖示上 hover 浮起後輕點打開 App）。三指上滑停住 → App 切換器 ✅
    （11-10 晚重測：之前是我注入的上滑太長，卡片推到頂、放開就回主畫面；上滑約 250 px 再停 1.5 s 就停在切換器格狀畫面）。
    雙指捏合 ✅（Safari 頁面放大，文字上的游標變 I 形）。雙指輕點（次要按鍵）✅：游標停在 Safari 起始頁的書籤圖示上兩指輕點，
    約 1–1.5 s 後跳出右鍵選單（拷貝／在背景打開／編輯／分享／刪除）。第一次以為沒反應是 2 s 內截圖太早；延遲比真機長，之後可再看。
  - BKForceMirroredOrientation 的副作用檢查：介面方向照樣跟著裝置（App 版面、主畫面橫排、另一個橫向會翻過來），只是 CA 顯示器
    的 currentOrientation 固定 rot0。橫向截圖（⌘⇧3）存成 1366×1024、方向正確，跟修之前的截圖一樣。
  - 四個方向（11-10，用 app 選單的「Display 轉向」按鈕：轉畫面、也轉餵給 guest 的重力）：轉向值 0／1／2／3 對到
    portrait／landscapeRight／portraitUpsideDown／landscapeLeft（backboardd log），每個方向主畫面版面都是正的、游標畫得出來，
    觸控板手指往右／往下游標就往右／往下（截圖差分量位移）。工具：scratchpad xnu-tp/mt/approtate.sh（先看選單開了沒再按，
    取樣點要在 guest 畫面外：(2900,1830)），mode.sh 同樣改了，ptrmove.py（兩張截圖差分找紅框游標）。
  - 待查：一次 App 切換器開著時轉向，切換器卡片排成新方向，但 Dock 和卡片快照停在舊方向（之後轉回主畫面就正常）。還沒重現第二次，
    也還不知道跟 BKForceMirroredOrientation 有沒有關係（要 A/B）。
  - device fe3b622：手指停著時每 8 ms 重送（真的 MT2 一直送；app 端停著只每 50 ms 送）：停 2 秒 45 → 222 份 report。
  - 既有的雜訊：swap_wait 0xe00002d5（觸控板之前就有）、sharingd／AttentionAwareness 監看連線 overrun。
- 驗證工具：`gfxprobe ioreg CLASS`（guest-run.sh）、`guest-newlogs.sh` 後篩 com.apple.Multitouch／PointerUI／BKSendHIDEvent；
  peek：droidvm_input_kinds、native_hid_trackpad_load_status、droidvm_trackpad_hid（送出、feature 次數、set 次數、丟棄）。

**還沒做。**
- 游標的合成（見上）；手勢（雙指捲動、三指上滑、捏合）要多指輸入（adb 只能單指，考慮手機端 uinput 觸控裝置）；
  @1x 的 MG scale；接觸大小目前固定（VoodooInput 的值），手機有接觸大小時之後再接上。
