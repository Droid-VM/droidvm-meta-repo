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
