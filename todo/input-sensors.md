# 輸入與感測器

地理位置與實體按鍵的待辦完整細節，從 `PROGRESS.md`「7. 下一步」的 TODO 移來（原文照錄）。

## 10-28 TODO 5 地理位置

**地理位置（磁力計、GPS、Wi-Fi 唯讀）。**

- **GPS：調查完、暫停（使用者 10-28 指示，晚點回來）。**結論見最上面 10-28 晚續報：J120 上 locationd 不會啟動 GNSS（WiFi 版
  iPad 沒有 `kProviderLocationGps`），要換 J121AP 身分（值已從官方 IPSW 取得）；未解的是 J121 上 locationd 走 gpsd 還是基頻
  QMI。路線：virtio-console 具名 port（NMEA）→ XNU 驅動提供 `/dev/cu.gps` → gpsd＋薄 vendor plugin。
- 磁力計：手機有 mmc56x3x，走第 1 項的 HID 路徑（未做）。
- Wi-Fi 唯讀：survey 過，kernel 沒有 IO80211 family、真驅動是 DriverKit，太重，暫不做。

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
  tap-to-click（libinput 預設關，桌面環境各自決定），要嘛 host 自己判斷「按下」送 BTN_LEFT；Linux 7.1 另有
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
    1 不能按下的 pressure-pad、2 沒有按鍵）、Device Certification Status（0xFF00/0xC5 的 256 位元組；沒有這份報告 Windows
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
