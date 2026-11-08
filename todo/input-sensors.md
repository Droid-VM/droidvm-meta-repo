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
  Safari 那邊的比例照理不變，但 5567 目前沒有網路，沒有重量 Pointer Events。

**橡皮擦端（未做）。** pen.py `--eraser`（BTN_TOOL_RUBBER → 報告的 Eraser 位元）在 Notes 裡照樣畫線。iPadOS 沒有「橡皮擦端」
這種 touch（Apple Pencil 沒有，UIKit 的 stylus 事件也沒看到對應欄位）。可能的路線：橡皮擦端接觸時，改送 Apple Pencil 的雙擊或
squeeze 事件，讓 Notes 自己切到橡皮擦工具，抬起後再切回來。5567 的 OnePlus Pencil Pro（`touchpanel_pen`）只有
BTN_TOOL_PEN、BTN_TOUCH、BTN_STYLUS／2，沒有橡皮擦端，這條只影響有橡皮擦端的筆。
