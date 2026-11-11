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

## 11-11 第 1 階段：native display 投到外部顯示器（app e26c6af，本地）

- 操作頁選單：「在外部顯示器顯示」（只有一台就直接投，多台跳清單）／投放中變「拉回本機」。
- `VmOutputRouter`：每個 VM 螢幕的畫面在哪（一個螢幕一個擁有者，crosvm 一個螢幕只有一個 scanout 槽）；用顯示器**名稱**
  記住選擇（顯示器重新接上 id 會變），操作頁打開時那台在就自動投過去，直到使用者拉回。
- `ExternalOutputService`：每個螢幕一個 Presentation；顯示器消失時通知 router（畫面自動回操作頁，記住的選擇保留）；
  通知上的「拉回本機」把全部拉回。
- `NativeExternalOutput`：Presentation 裡的 scanout＋游標 SurfaceView 交給 crosvm（自己的 broker attach＋DisplayProvider），
  依 guest 比例置中，游標層跟著 guest 回報的位置。
- 操作頁的 `DisplayProvider.setHeld(true)`：把 crosvm 的槽還回去（先存畫面）、關掉游標串流、不再送 Surface；SurfaceView 的
  版面不動，上面疊一個由同一個 viewport 擺放的深色色塊，所以觸控換算完全不變。`DaemonDisplayAttach` 改吃 Context。
- 5566 模擬次要螢幕實測：外部有畫面、手機是色塊；在色塊上點「設定」，外部打開設定；app 到背景再開操作頁不搶回；
  選單拉回、通知拉回；拔掉顯示器自動回本機；app 被殺掉後再開操作頁，自動投回重新接上的顯示器。
- **限制**：手機鎖定時系統的鎖定畫面蓋住外接螢幕（關螢幕時是黑的），`FLAG_SHOW_WHEN_LOCKED` 蓋不過；解鎖後恢復。
- 測試中碰到一次 iPadOS 主畫面大片黑塊：是 PosterBoard 沒在跑（桌布那層空的），拉回本機一樣黑，respring 後正常，
  跟外部輸出無關（見 phones-rigs／下午的桌布問題）。

## 11-11 第 2 階段：VNC 投到外部顯示器，舊投放頁拿掉（app 0b35661，本地）

- `VncSession`（程序層級，`acquire`／`release` 引用計數，key = VM／螢幕）：RFB 連線、自動重連、H.264 管線從 activity 拆出來，
  操作頁與外部視窗共用一條連線；H.264 的 TextureView 同時只有一個擁有者（`setH264View`／`releaseH264View`），晚加入的
  listener 由 `replay` 補上狀態、尺寸、畫面。`BaseVncActivity` 1085 → 700 行。
- `ExternalOutputService` 依 `EXTRA_VNC` 開不同的視窗：native 是自己的 SurfaceView，VNC 是 `DisplayPresentation`＋
  `VncExternalOutput`（加入同一個 session，圖在 ImageView、H.264 在 TextureView）。`VmOutputRouter.Screen` 多一個 `vnc`。
- VNC 操作頁：「在外部顯示器顯示／拉回本機」、viewport 同時擺圖、解碼 view 與深色色塊；投放中不畫圖、把解碼 view 讓出去
  （`wantsH264View()`）；路由的 key 用開頁時的螢幕 id（session 之後才解析出螢幕時也不變，外部視窗才不會開第二條連線）。
- 兩個 console 的外部顯示選單、挑顯示器、色塊文字共用 `ExternalOutputControl`。
- 刪掉：`VMVncPresentationActivity`（＋版面、選單、manifest）、`UsbHidInput`、`DisplayTouchPadPanel`、`VncTouchPadPanel`、
  沒有實作的 `DisplayInputBackend`，以及只有它們用的 19 個字串（四種語言）。
- 5566 實測（Ubuntu 的 gpu-0 暫時改成 VNC 輸出，測完還原）：外部顯示 Ubuntu 登入畫面、手機是色塊；色塊上方的全鍵盤打字
  進到 guest；app 到背景外部畫面不斷，再開操作頁不搶回；選單拉回；拿掉顯示器自動回本機、記住的選擇保留，之後再開操作頁
  自動投回去。

## 11-11 第 3 階段：鍵盤上／下、左右鍵（app 945b748，本地）

- `ConsoleWorkspace`：把操作頁根 LinearLayout 的子 view 重排——鍵盤（Extra／FNx 列、全鍵盤）放在指標區上方或下方。系統 IME
  是 Android 畫的，永遠在最下面，選「上」時只有 app 自己的鍵盤列移上去。
- 左右鍵按鈕列（`view_pointer_buttons`）只在滑鼠、觸控板模式出現，送 BTN_LEFT／BTN_RIGHT 到 VM 的相對滑鼠（觸控板模式也是
  送到滑鼠裝置）；按下／放開有手機自己的觸感回饋（VIRTUAL_KEY），沒做開關。
- 選單長按：鍵盤列任一個按鈕 → 鍵盤換邊；滑鼠按鈕 → 左右鍵顯示／隱藏；toast 說新狀態。設定存在 `droidvm_prefs`
  （`display_keyboard_on_top`、`display_pointer_buttons`），兩個 console 共用。
- 絕對模式的座標換算沒有改：色塊和畫面由同一個 viewport 擺放，框外貼齊邊緣仍是原本那一份程式。
- 測試時看到：Surface 重建或改尺寸後 guest 畫面偶爾出現黑塊，像是 host 只把部分畫面複製進新的 BufferQueue buffer；和
  11-11 在 5566 看到的狀態列黑塊閃爍（某一個 CoreAnimation framebuffer 裡留著舊的黑塊，全畫面重畫才清掉）可能同源，待查。

## 11-11 第 4 階段：USB 直通彈窗與規則的類別層（app 180532a，本地）

- 操作頁選單「USB 直通」：先確認這台 VM 有 xHCI 控制器（沒有就說明）；勾選項目是 everyone（ANY 層指向這台 VM）、hid
  （新的類別層，class `03`）與現在插著的每個裝置（DEVICE 層 vid:pid）。只改有變動的列，這台 VM 的規則插在最前面，
  `usb_rules_set` 寫回；「規則」按鈕開 `UsbRulesActivity`。
- daemon `UsbRules`：EXACT > PORT > DEVICE > CLASS > ANY；類別層比對裝置類別或任一介面類別（`Device.classes`）；
  類別層是空的時候 JSON 不寫 `class`，舊版 daemon／app 還讀得懂（可降版）。
- 規則頁多一個「類別」區段（類別挑選器、`UsbClasses` 名稱），VM 編輯器的 xHCI 綁定差異保留類別。單元測試 610 個全過。
- 5566 實測：勾 hid → 規則檔多出 `"class": [{"class": "03", "target": "vm", ...}]`，Windows VM 原本的 ANY 規則沒動；
  再開彈窗 hid 是勾著的；取消 → 規則檔的 `class` 整個消失。

## 11-11 第 5 階段：兩個 console 共用輸入控制器與選單（app 766e4a6，本地）

- `ConsoleInput`：輸入模式（app 一個設定；這個螢幕的輸入關著時選絕對模式的提示；同步告訴 workspace、forwarder、手勢轉譯）、
  送進 VM 的路徑（daemon binder 到了走 socket，之前與失敗時走 vm_input）、滑鼠右／中鍵不進觸控路徑也不變成 BACK、觸控板
  手指、收起系統鍵盤。觸控落在畫面哪裡仍是各自的：native 是會旋轉的 SurfaceView，VNC 是可縮放的圖與 RFB 的 tablet。
- `ConsoleMenu`：兩個 console 的選單（輸入模式、鍵盤兩列與長按、console 自己的列——native 的旋轉列、全螢幕、外部顯示、
  USB 直通）。原計畫的 `DisplayInputBackend` 介面沒有做成兩份實作，直接刪掉，共用的部分收進這兩個類別。
- 測試找到的回歸：VM 一啟動 app 就開操作頁，那時 VNC server 還沒起來，重連 5 次後放棄；共用 session 之後，晚開的操作頁
  加入的是放棄了的 session。修正：加入 ERROR 狀態的 session 會重連一次（以前每頁自己一條連線的行為）。
- 5566 實測（Ubuntu VNC、UniXNU 27 native）：選單切模式、左右鍵與相對拖曳（guest evtest）、觸控板手指、觸控點擊、觸控解鎖、
  兩個長按、投到模擬次要螢幕再拉回。5566 的 iPadOS 看不到觸控板游標是已知的（游標修正只在 5567，見觸控板記錄）。

**剩下的限制與未定**
- 手機鎖定時，系統鎖定畫面蓋住外接螢幕（第 1 階段）。
- 投放中鍵盤獨占（`PhysicalKeyboardGrab`）仍是離開前景就放開；要不要投放時繼續獨占，未定。
