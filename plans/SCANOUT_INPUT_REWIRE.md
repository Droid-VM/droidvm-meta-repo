# Scanout 輸入重接線：tablet 跟著後端走，全域 VNC 輸入組退役

使用者定的資源模型（2026-08-26，逐字）：

    scanout 資源:
    後端: VNC/native
    輸入: touchscreen(在 app 選到該 scanout 時接線)
          tablet(native: 在 app 選到該 scanout 時接線, VNC: 接線到對應 VNC server 上)

使用者第二次裁定（同日，取代上面模型的鍵盤部分並簡化 tablet 部分）：

    鍵盤也加入 scanout 資源。crosvm 端自動為每個 vnc 建立一個 tablet 和 keyboard，
    vnc 操作直接導入(除非 view-only=true)。app 的 DisplayVNC 底下的 tablet 和
    keyboard 就是對 vnc 操作。touchscreen 是例外，由 app 建立+維護，當對應
    DisplayVNC 啟用時注入對應的 touchscreen。app 的輸入裝置關閉時，view-only=true。

即最終模型：
- **VNC 匯出的螢幕**：crosvm 自動為該 binding 建一顆 tablet + 一把 keyboard，
  RFB pointer/key 事件直接注入（app 的 VNC console 和第三方 client 一視同仁，
  app 對這兩者的操作就是普通 RFB 事件）；`view-only=true` 時兩者都不建、RFB 輸入丟棄。
- **touchscreen 例外**：一律由 app 建立+維護（daemon socket，現狀），app 在對應
  VNC console 啟用時注入該螢幕的 touchscreen。
- **native 匯出的螢幕**：完全不變（tablet/touchscreen 走 daemon socket，鍵盤走
  VM 全域 daemon keyboard socket）。
- **view-only 的來源**：螢幕的輸入裝置開關關閉 → daemon 傳 view-only=true。
- crosvm 的 VM 全域 display-window 組（"DroidVM VNC Touch/Tablet/Mouse" + keyboard）
  對 VNC 全部退役；daemon 的 VM 全域 keyboard socket **不動**（native console 用）。
- guest 會看到多把鍵盤（daemon 的一把 + 每個非 view-only VNC 螢幕各一把）——
  使用者明示接受，guest 對多鍵盤天然無感。

## 修的 bug（診斷已完成，三 case 全對上）

VNC 指標今天注入的是 VM 全域組，而那組：
1. 只在「無 GPU 裝置」時才接到 simplefb bridge（linux.rs:513 的
   `gpu_parameters.is_none()` 閘）→ GPU+simplefb 併存時 simplefb 的 VNC 輸入無接收端
   （程式碼註解自認是 step 9 欠的債）；
2. 就算接上（GPU 自家 VNC），兩個 VNC display 各按自己的 fb 正規化座標注入同一個
   tablet，guest 無從分辨來源螢幕——雙螢幕語意必錯。

## 設計定案

（鍵盤失效機制備考：事件遞送按「display 擁有者」切分——simplefb bridge 是獨立
GpuDisplay 實例，GPU 存在時它的 event_devices 清單是空的，任何 kind 的事件含鍵盤
都靜默丟棄。裝置在，路不通。per-scanout keyboard 讓這整條分派路對 VNC 直接消失。）

座標契約現成：DisplayVnc 正規化到 `VNC_ABS_MAX = 0x7FFF`，省略 width/height 的
absolute-mouse 廣告 `NORMALIZED_ABS_MAX = 0x7FFF`，兩常數本就互相要求相等。

## Seam（daemon ⇄ crosvm 的參數契約，雙方照此實作，不得各自發明）

- `--vnc-server` 的 `input=` 鍵**移除**，改為 `view-only=true|false`（serde bool，
  預設 false）。false → crosvm 為此 binding 建一顆 tablet + 一把 keyboard 並注入
  RFB 輸入；true → 兩者都不建、RFB 輸入（pointer+key）丟棄。舊鍵 `input=` 出現即
  parse 錯誤（deny_unknown_fields；無 PR、無舊安裝要顧）。
- daemon：螢幕 input_enabled=false 時傳 `view-only=true`。
- daemon 對 VNC 匯出的螢幕：**不再**綁 tablet socket、不再傳該螢幕的
  `--input absolute-mouse[...]`（touchscreen 的 socket+arg 照舊）；
  native 匯出的螢幕兩者照舊。
- crosvm 內建 tablet/keyboard 的裝置名：tablet 與 daemon 的每螢幕命名慣例一致
  （`NativeDisplay.tabletDeviceName(screenId)` 的字串）；keyboard 用同款格式的
  keyboard 變體（如 `DroidVM Keyboard (gpu-0)`）。執行者讀出實際格式並在兩邊各留
  註解指向對方；這是跨 repo 常數 seam。

## crosvm 半邊

1. `VncConfig`：`input` 欄位刪除、加 `view_only: bool`（serde default false）。
2. 裝置建立：對每個 view_only=false 的 vnc binding，建兩組 `StreamChannel::pair`：
   一組給 absolute-mouse 建構子（省略 w/h → NORMALIZED 範圍）、一組給 keyboard
   建構子，名字按 seam；兩個注入端交給該 binding 的 DisplayVnc——gpu-0 走
   `DisplayBackend::VncTcp` 的建立路徑、simplefb 走 bridge 的 DisplayVnc 建立路徑，
   兩條都要把 channels 傳進去。
3. DisplayVnc：RFB pointer 事件寫進自己的 tablet channel、RFB key 事件寫進自己的
   keyboard channel（`EventDevice::send_report` 框架），view_only 時全部丟棄；
   `GpuDisplayEvents`/owner 分派這條路對 VNC 整個停用。單一 DisplayVnc 的事件都在
   它自己的執行緒序列化，無跨執行緒共享 writer、無鎖。
4. 退役：`create_display_window_input_devices` 的 VNC 觸發路徑整組——
   `!cfg.vnc_server.is_empty()` 的座標覆蓋、simplefb 分支（linux.rs:513）、
   display-window keyboard/mouse/touch/tablet 全部（vnc 不再自動開
   display_window_* 旗標）。daemon 的 `--input keyboard[path=…]`（VM 全域）完全不動。
   X11/其他平台路徑不動。
5. 多 client：同一 VNC server 的多個 RFB client 注入同一組 tablet+keyboard——維持。

## daemon / app 半邊（DroidVM repo）

1. `CrosvmBackendInstance`：`absoluteInputScreens()` 的 tablet 半邊按螢幕匯出端分流
   （vnc → 不綁 tablet socket、不出 absolute-mouse arg）；`--vnc-server` 按該螢幕
   input_enabled 加 `view-only=true|false`；`NativeDisplayInputBridge` 的 per-screen
   TABLET slot 同步只為 native 螢幕建。touchscreen socket/arg 照舊按 input_enabled。
2. app VNC console：TABLET 模式送 RFB pointer、鍵盤送 RFB key 事件（使用者模型明定
   「app 的 DisplayVNC 底下的 tablet 和 keyboard 就是對 vnc 操作」）——執行者讀碼
   確認現況是否已如此（鍵盤特別要查：若現在走 daemon socket 就改成 RFB KeyEvent）；
   TOUCH 模式走每螢幕 touchscreen socket、於 console 啟用時注入（現狀，確認即可）；
   MOUSE 模式走 VM 全域相對 mouse socket（確認即可）。有出入回報。

## 驗證（對照使用者的三 case 狀況表 + 迴歸）

w11（5568）雙螢幕輸入全開：
1. gpu-0 vnc + simplefb vnc：兩個 VNC console 指標都動、各自落在自己螢幕；
   TigerVNC 連上任一 port 也能動指標。
2. gpu-0 native + simplefb vnc：native console 動（socket tablet）、simplefb VNC 動
   （綁定 tablet）——今天的死角。
3. gpu-0 關 + simplefb vnc：照舊動（原本唯一活的 case，不得退化）。
4. guest 裝置清單："DroidVM VNC Touch/Tablet/Mouse"+display-window keyboard 消失；
   每個非 view-only 的 VNC 螢幕出現自己的 tablet + keyboard（seam 命名），
   native 螢幕的 socket 裝置與 daemon 全域鍵盤照舊。
4b. 鍵盤三路驗證：app native console 打字（daemon 鍵盤）、app VNC console 打字
   （該螢幕的 VNC keyboard）、TigerVNC 打字（同上）——三路都通
   （今天 simplefb-VNC-伴隨-GPU 的鍵盤是死的）。
4c. view-only：關掉某 VNC 螢幕的輸入裝置 → 該 binding 無 tablet/keyboard、
   RFB 輸入被丟棄、其他螢幕不受影響。
5. u26（Linux guest）VNC console 指標迴歸。
