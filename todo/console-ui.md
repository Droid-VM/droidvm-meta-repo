# VM 操作介面（console）重構

## 11-11 規劃：輸出與輸入解耦

使用者 11-11 提出：VNC 的「在外部顯示器」控制頁整個拿掉，融入 VM 操作介面；VNC、native display（與之後的後端）都能按
「在外部顯示器顯示」，之後 app 內原本的位置只留深色色塊。輸出（本機／外部螢幕）與輸入區解耦；平板投到外螢幕時，鍵盤放上半部、
下半部是觸控板加左右鍵，像筆電的 C 面。

**現況（三份盤點，11-11）**
- VNC 投放是另一個 activity（`VMVncPresentationActivity`）：`DisplayManager.getDisplays(ALL_INCLUDING_DISABLED)` 列出所有
  顯示器（含手機本身）讓使用者選，在選中的顯示器上開 `android.app.Presentation`（ImageView 收 RFB、TextureView 收 H.264）；
  手機上是「Touchpad」控制頁（觸控板＋左中右鍵、USB HID 直通）。它自己開一條 RFB 連線，原本的顯示頁還留著另一條；
  Presentation 綁在這個 activity 上，activity 結束畫面就跟著消失。
- Native display：crosvm 自己把畫面畫進 app 用 binder `setSurface` 交過去的 Surface；每個螢幕一個主畫面槽＋一個游標槽，
  協定允許執行中換 Surface。沒有任何外部顯示器支援。觸控換算全部讀 SurfaceView 自己的幾何（反算 `getMatrix()`）。
- 輸入：TOUCH／TABLET／MOUSE／TRACKPAD 四種模式（整個 app 一個設定）；觸控筆不是模式，任何模式都送 PEN；鍵盤三種
  （無／系統 IME／全鍵盤）永遠停在下方；選單沒有長按；`DisplayTouchPadPanel`（觸控板＋按鈕）只有投放頁用；兩個顯示
  activity 的觸控路由、手勢、選單、鍵盤模式各寫一份；`DisplayInputBackend` 有介面沒有實作。

**外部顯示器能用哪些（沿用 Presentation）**：任何 Android 開成獨立 Display 的螢幕都行——有線 USB-C DP／HDMI、無線的
Miracast（Wi-Fi Display；5566 有這個功能，目前關著）、開發者選項的「模擬次要螢幕」（`overlay_display_devices`，在手機上開
一個浮動視窗當第二螢幕：沒有外接螢幕時就用它測）。不行的：Chromecast／Google Cast 與多數「整機投屏」，那些是鏡像整個手機
畫面，不會產生獨立的 Display。5566 也有 `activities_on_secondary_displays`。

**模型**
- 輸出目標以「VM 的每個螢幕」為單位，同時只有一個擁有者：本機，或某個外部顯示器（`VmOutputRouter`，app 程序層級）。
- 手機畫面 = 工具列＋工作區；工作區 = 鍵盤區（無／IME／全鍵盤，位置上或下）＋指標區（其餘全部）。
- 指標區裡的「虛擬螢幕框」依 guest 比例 letterbox：輸出在本機時就是畫面，在外部時是深色色塊，只給使用者對照。

| 模式 | 對應範圍 | 左右鍵按鈕列 |
|---|---|---|
| 觸控螢幕、繪圖板 | 虛擬螢幕框（框外貼齊邊緣，維持現狀） | 無 |
| 滑鼠、觸控板 | 整個指標區 | 長按滑鼠切換顯示 |

真的觸控筆維持現狀：任何模式都送 PEN，經虛擬螢幕框對應（使用者 11-11：stylus 不做成模式）。座標換算改成用虛擬螢幕框
算，本機和外部兩種輸出同一份程式（框外貼齊也只寫一份）。

**外部顯示器**
- 選單：所有後端同一個「在外部顯示器顯示」；清單排除手機本身；投放中改成「拉回本機」。
- app 到背景、切到 app 其他頁、關掉操作頁，外部畫面都保持；再開操作頁只當輸入端＋深色色塊，不搶回畫面。
- 投放狀態記住（使用者 11-11）：app 重開、VM 重開時，那個顯示器在就自動投過去。
- 前景服務通知放「拉回本機／停止投放」；顯示器被拔掉自動回本機。
- Presentation 要改由前景服務持有，不能綁在 activity 上（activity 結束就消失）：用 window context，可能要「顯示在其他應用
  程式上層」權限（root daemon 可用 appops 授權）。這是第 0 階段要先在手機上確認的。
- Native：外部宿主帶自己的 SurfaceView 和游標 SurfaceView，router 把 crosvm 的槽交給它，本機的 SurfaceView 不再自動
  `setSurface`。VNC：`VncClient`／H.264 管線從 activity 拆到程序層級的 `VncSession`，只剩一條連線；投放期間由前景服務保住程序。

**鍵盤與選單**
- 長按「鍵盤」：鍵盤區上／下切換。系統 IME 是 Android 畫的、一定在最下面，選「上」時只有 Extra／FNx 列移上去。
- 長按「滑鼠」：左右鍵按鈕列顯示／隱藏（只在滑鼠、觸控板模式）。
- 長按後 toast 說明新狀態，按鈕上加小標記；兩個 activity 用同一個選單建構器。

**USB 直通取代 USB HID 直通（使用者 11-11）**
- 舊的 `UsbHidInput`（VNC 投放頁用 USB Host API 搶走 USB 鍵鼠、讀 boot protocol 報告、轉 keysym 送 VNC）拿掉。
- 改成操作介面裡的「USB 直通」彈窗：列出現在插著的裝置可選（直通給這台 VM 的 xHCI），再加兩個 meta 裝置：
  - everyone：所有裝置＝規則的 ANY 層指向這台 VM；
  - hid：所有 HID 裝置（鍵盤、滑鼠）＝新的「類別」層（介面類別 0x03），daemon 的 `UsbRules` 要新增這一層。
- 寫進同一份 USB 直通規則（`UsbRules`，規則頁 `UsbRulesActivity` 看得到、改得了），不是另一套狀態。

**分階段**（每階段在 5566 手機、5567 平板驗過再 commit）
0. 實測：模擬次要螢幕上，服務持有的 Presentation 在背景、切頁、關螢幕、app 重開下撐不撐得住；crosvm 在兩個 Surface 間
   來回 `setSurface`。
1. Native 外部輸出：router、可換目標的 `NativeDisplaySession`（從 `DisplayProvider` 拆出）、外部宿主、深色色塊、拉回本機、
   拔線回退、記住狀態。
2. VNC 外部輸出：`VncSession` 拆出 activity，刪 `VMVncPresentationActivity`、`activity_vm_vnc_presentation.xml`、
   `menu_vnc_presentation_menu.xml`、`UsbHidInput`。
3. 版面解耦：`WorkspaceLayout`（鍵盤區上下、指標區）、虛擬螢幕框座標換算、相對模式整區當觸控板、按鈕列（`DisplayTouchPadPanel`
   拆成按鈕列與捲動條重用）。
4. 選單：兩個長按、外部顯示項目、USB 直通彈窗（含 everyone／hid 與 daemon 的類別層）、共用選單建構器。
5. 收斂重複：`DisplayInputBackend` 給 native 與 VNC 各一份實作，兩個 activity 共用輸入控制器。

**未定**
- 鍵盤獨占（`PhysicalKeyboardGrab`，daemon 的 `EVIOCGRAB`）現在離開前景就放開；投放中要不要繼續獨占（傾向：繼續，通知上
  可放開）。
- 觸控板點擊、左右鍵按下時由 app 讓手機短震（不經 guest）要不要做成開關。

## 11-11 第 0 階段：服務持有的 Presentation（app db2c8da，本地）

- `ui/vm/display/external/ExternalOutputService`：前景服務（type specialUse），在服務自己的 window context（`TYPE_PRESENTATION`，
  SDK 隱藏的常數 2037）上開 `Presentation`，不綁 activity；通知上的按鈕收回。這一階段畫面是跳動的時鐘。
- 5566 用模擬次要螢幕（`settings put global overlay_display_devices 1280x720/240`，顯示器 4；看內容用
  `screencap -d <SurfaceFlinger 的 virtual display id>`）實測：
  - **不需要「顯示在其他應用程式上層」權限**，app 不在前景時（root `am start-foreground-service`）就能開。
  - app 在背景、在 app 裡切頁再回桌面、關螢幕 60 秒：視窗一直在，時鐘沒斷（程序沒被凍結）。
  - 顯示器被拿掉：不崩潰，但服務還在前景 → 第 1 階段要在 `onDisplayRemoved` 收掉並回本機。
  - **手機鎖定時，系統的鎖定畫面（KeyguardDisplayManager 的 presentation）會蓋住副螢幕**，解鎖後我們的視窗回來。
    投放時手機是輸入裝置，操作頁本來就保持亮屏；app 在背景、手機鎖起來時外接螢幕會顯示鎖定畫面。第 1 階段試
    `FLAG_SHOW_WHEN_LOCKED`／`setShowWhenLocked` 能不能蓋過，不行就記成限制。
  - 模擬器自己放在主螢幕上的小視窗在關螢幕後會消失（模擬器的行為，不是我們的視窗）。
