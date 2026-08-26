# Scanout 輸入重接線：tablet 跟著後端走，全域 VNC 輸入組退役

使用者定的資源模型（2026-08-26，逐字）：

    scanout 資源:
    後端: VNC/native
    輸入: touchscreen(在 app 選到該 scanout 時接線)
          tablet(native: 在 app 選到該 scanout 時接線, VNC: 接線到對應 VNC server 上)

即：每個 input_enabled 的 scanout 恆有一組 touchscreen + tablet（就是現有的每螢幕
裝置，不新增）；touchscreen 永遠走 app→daemon socket；**tablet 的事件源按該螢幕的
匯出端切換**——native 時走 socket（現狀），VNC 時由該螢幕自己的 VNC server 注入。
crosvm 的 VM 全域 display-window 指標組（"DroidVM VNC Touch/Tablet/Mouse"）退役。

## 修的 bug（診斷已完成，三 case 全對上）

VNC 指標今天注入的是 VM 全域組，而那組：
1. 只在「無 GPU 裝置」時才接到 simplefb bridge（linux.rs:513 的
   `gpu_parameters.is_none()` 閘）→ GPU+simplefb 併存時 simplefb 的 VNC 輸入無接收端
   （程式碼註解自認是 step 9 欠的債）；
2. 就算接上（GPU 自家 VNC），兩個 VNC display 各按自己的 fb 正規化座標注入同一個
   tablet，guest 無從分辨來源螢幕——雙螢幕語意必錯。

## 設計定案

- **guest 可見裝置集不變**：每 input_enabled 螢幕一個 touchscreen + 一個 tablet，
  名字維持每螢幕命名（`DroidVM Touch (gpu-0)` 等）。全域 VNC 指標三件套消失。
  RFB **鍵盤**維持 VM 全域（鍵盤語意本來就是 VM 級），沿用現有 display-window
  keyboard 通道；VM 全域相對 mouse socket（app MOUSE 模式用）不動。
- **native 匯出的螢幕**：完全不變（tablet/touchscreen 都是 daemon socket）。
- **VNC 匯出的螢幕**：touchscreen 照舊 socket；tablet 改由 crosvm 內部建立，
  事件端綁到該螢幕的 DisplayVnc——RFB pointer 事件（app 的 VNC console TABLET 模式
  和第三方 client 一視同仁）注入這一顆。座標契約現成：DisplayVnc 正規化到
  `VNC_ABS_MAX = 0x7FFF`，省略 width/height 的 absolute-mouse 廣告
  `NORMALIZED_ABS_MAX = 0x7FFF`，兩常數本就互相要求相等（EvdevEncoder 註解）。

## Seam（daemon ⇄ crosvm 的參數契約，雙方照此實作，不得各自發明）

- `--vnc-server` 的既有 `input=` 鍵改語意：`input=tablet`（daemon 在該螢幕
  input_enabled 時傳）→ crosvm 為此 binding 建立一顆綁定的 tablet；
  `input=none`（input_enabled=false 時傳）→ 不建。舊值 `mouse`/`touch` 移除，
  出現即 parse 錯誤（deny_unknown_fields 風格的 loud failure；無 PR、無舊安裝要顧）。
- daemon 對 VNC 匯出的螢幕：**不再**綁 tablet socket、不再傳該螢幕的
  `--input absolute-mouse[...]`（touchscreen 的 socket+arg 照舊）；
  native 匯出的螢幕兩者照舊。
- crosvm 內建 tablet 的裝置名：與 daemon 的每螢幕命名慣例一致
  （`NativeDisplay.tabletDeviceName(screenId)` 的字串——執行者去讀出實際格式並
  在兩邊各留註解指向對方；這是跨 repo 常數 seam）。

## crosvm 半邊

1. `VncConfig.input`：重定義為上述兩值；`validate_config` 解析。
2. 裝置建立：對每個 `input=tablet` 的 vnc binding，建
   `StreamChannel::pair` → 一端給 `virtio::input::new_mouse`… 正確說是
   absolute-mouse 建構子（省略 w/h → NORMALIZED 範圍），名字按 seam；另一端
   （`EventDevice::touchscreen`/`mouse` 同款包裝，kind=Tablet）交給該 binding 的
   DisplayVnc——gpu-0 走 `DisplayBackend::VncTcp` 的建立路徑、simplefb 走 bridge 的
   DisplayVnc 建立路徑，兩條都要把 channel 傳進去。
3. DisplayVnc：RFB pointer 事件改寫進自己綁定的 channel（`EventDevice::send_report`
   的框架現成），不再產生給全域分派的 pointer `GpuDisplayEvents`；鍵盤事件維持
   走原分派（全域 keyboard）。
4. 退役：`create_display_window_input_devices` 的 VNC 觸發路徑——
   `!cfg.vnc_server.is_empty()` 的座標覆蓋、simplefb 分支（linux.rs:513）的指標
   三件套、以及 vnc 自動開 `display_window_mouse` 的行為；keyboard 部分保留
   （vnc 存在時仍建 keyboard 並照舊分派）。X11/其他平台路徑不動。
5. 多 client：同一 VNC server 的多個 RFB client 注入同一顆 tablet——本來如此，維持。

## daemon / app 半邊（DroidVM repo）

1. `CrosvmBackendInstance`：`absoluteInputScreens()` 的 tablet 半邊按螢幕匯出端分流
   （vnc → 不綁 socket、不出 arg、`--vnc-server` 加 `input=tablet|none`）；
   `NativeDisplayInputBridge` 的 per-screen TABLET slot 同步只為 native 螢幕建。
2. app console 不用動：VNC console 的 TABLET 模式本來就送 RFB pointer；TOUCH 模式
   本來就走每螢幕 touchscreen socket；MOUSE 模式走 VM 全域相對 mouse socket。
   執行者驗證這三條假設（讀碼確認，不臆測），有出入回報。

## 驗證（對照使用者的三 case 狀況表 + 迴歸）

w11（5568）雙螢幕輸入全開：
1. gpu-0 vnc + simplefb vnc：兩個 VNC console 指標都動、各自落在自己螢幕；
   TigerVNC 連上任一 port 也能動指標。
2. gpu-0 native + simplefb vnc：native console 動（socket tablet）、simplefb VNC 動
   （綁定 tablet）——今天的死角。
3. gpu-0 關 + simplefb vnc：照舊動（原本唯一活的 case，不得退化）。
4. guest 裝置清單：每螢幕命名的裝置各就各位，"DroidVM VNC Touch/Tablet/Mouse"
   三件套消失，RFB 鍵盤仍在。
5. u26（Linux guest）VNC console 指標迴歸。
