# 統一「投射到外部顯示器」：從獨立入口變成 console 內動作

使用者裁定（2026-08-26）：把「外部顯示器的 VNC」從控制台的獨立入口，改成 VNC/native
console **內部選單**的一個統一動作「投射到外部顯示器」，和 console 類型無關。

## 現況

- 控制台選單（VMConsoleRouter）有多個獨立 activity 入口：`openNative`（native
  console）、`openVnc`（VNC console）、`openVncExt`（外部顯示器的 VNC，只有 VNC 版，
  native 沒有）。
- 外部顯示器＝獨立 activity `VMVncPresentationActivity extends BaseVncActivity`，用
  Android `Presentation` API（`DisplayPresentation extends Presentation`）把畫面渲染到
  非預設 Display；手機退化成 `VncTouchPadPanel`（相對游標觸控板）。
- 兩種 console 的畫面來源根本不同：
  - **native**：crosvm 透過 binder `ICrosvmAndroidDisplayService` 直接畫到一個 Android
    `Surface`（DisplayProvider 把 SurfaceView 的 surface 交給 crosvm）。
  - **VNC**：app 自己收 RFB Bitmap + 解 H.264，畫到 app 的 view。

## 核心可行性（已讀碼確認）

**投射＝把畫面渲染目標從「activity 內部 view」換成「外部 Display 上的 view」。** 兩種
console 這個抽象都成立，實作不同但都可行：

- **VNC**：現成——`VMVncPresentationActivity` 已經在做（decoder view + bitmap 指向
  Presentation 的 view）。
- **native 可行**（關鍵確認）：`DisplayProvider` 的 surface 是可換的——它本來就
  `surfaceDestroyed → removeSurface`、下一個 `surfaceCreated → setSurface`
  （DisplayProvider.java:33-35），死亡重連時「bounce SurfaceView」的機制已在
  （:125）。所以把 crosvm 的渲染 surface 從手機 SurfaceView 換到 Presentation 上的
  SurfaceView 是支援的操作，不是新能力。cursor plane 是第二個 SurfaceView，同樣跟著換。

## 設計

### 1. `ExternalProjectionController`（新，base 共用）
從 `DisplayPresentation` + `VMVncPresentationActivity` 抽出，兩種 console 共用：
- 顯示器選擇對話框（`DisplayManager.getDisplays(ALL_INCLUDING_DISABLED)`，含電源狀態名）
- 建/毀 `Presentation`；`DisplayManager.DisplayListener` 監聽拔線/斷投屏 → 自動撤回
- Presentation 的 layout 提供渲染目標（見下），letterbox（TextureView 無 scaleType，
  手工 fit——現有 `DisplayPresentation.fitH264` 邏輯保留）

### 2. `ProjectionTarget` 抽象（新介面）
console 實作「把畫面投到這個 Presentation / 收回」：
```
interface ProjectionTarget {
    void projectTo(ExternalProjectionSurfaces s);  // s 提供 Presentation 上的 SurfaceView/TextureView/ImageView
    void recall();                                  // 畫面切回 activity 自己的 view
}
```
- **native 實作**（VMNativeDisplayActivity）：`projectTo` → DisplayProvider 把 main +
  cursor 的 surface 從手機 SurfaceView 切到 Presentation 的 SurfaceView（removeSurface
  舊的 + setSurface 新的，crosvm 已支援）；`recall` 反向。手機的 displayContainer 這時
  當觸控板用——native 的輸入本來就走 gestureTranslator，MOUSE（相對）模式天然是觸控板
  語意，不需新面板。
- **VNC 實作**（VMVncDisplayActivity）：`projectTo` → `setH264View(presentation 的
  TextureView)` + bitmap 目標指向 Presentation 的 ImageView；`recall` 指回 activity
  view。手機顯示 `VncTouchPadPanel`（現有）。

### 3. 統一選單動作
兩個 console（native + VNC）的 FAB/overflow 加「投射到外部顯示器」：
點擊 → controller 選顯示器 → 建 Presentation → `target.projectTo(...)` → 手機切觸控板；
再點「收回投射」或拔線/斷投屏 → `target.recall()` → 手機恢復正常 console。

### 4. router / 入口簡化
- 刪 `VMConsoleRouter.openVncExt`；控制台選單移除兩個「外部顯示器的 VNC/native」入口，
  只留「VNC 控制台」「native 控制台」（+ 文字控制台們）。
- `VMVncPresentationActivity` 退役——邏輯拆進 `ExternalProjectionController` +
  VNC 的 `ProjectionTarget` 實作。`DisplayPresentation` 保留但改為 controller 用。

## 難點與決策點（實作前要定）

A. **native 投射後的 resize**：Presentation 顯示器尺寸 ≠ guest。crosvm 固定畫 guest 尺寸
   （`setFixedSize`），Presentation 的 SurfaceView 用 fitCenter/letterbox。現有 native
   console 已處理 guest 尺寸 vs view 尺寸的縮放，複用。

B. **H.264 re-sync（VNC）**：投射是**執行中動態切換**，decoder view 換到 Presentation
   時是全新 Surface。單一 port 已有 per-geometry sync cache（`H264ConsolePipeline` 快取
   reset-flagged rect 的 SPS/PPS/IDR）——`projectTo` 重建 decoder 時走同一條 replay 路徑
   即可（cold-open 修復自然覆蓋這個 case）。這也順帶收掉之前記錄的
   「presentation h264 late-bind 會丟 SPS/PPS」殘留問題。

C. **生命週期**：投射中 console activity 仍在前景（手機顯示觸控板），Presentation 綁在
   activity 上。要處理 activity onPause/旋轉/背景化 → Presentation 的存續策略（跟著
   activity 死，還是 activity 背景時暫停投射）。現有 VMVncPresentationActivity 是整個
   activity 就為投射而生，改成動態後這個生命週期要重新界定。

D. **cursor plane（native）**：native 的 hardware cursor 是獨立第二 SurfaceView，
   投射時 main + cursor 兩個 surface 都要切到 Presentation（Presentation layout 要有
   對應的 cursor SurfaceView）。

E. **輸入座標系**：投射後手機是觸控板（相對），不是絕對映射。VNC 已用 VncTouchPadPanel
   做相對游標。native 靠 MOUSE 模式（相對 REL_X/Y）——投射時強制切 MOUSE 模式，收回時
   還原使用者原本的模式。

## 分階段

1. 抽 `ExternalProjectionController` + `ProjectionTarget` 介面 + Presentation surfaces
   容器（把 VMVncPresentationActivity 的邏輯搬進來，VNC console 先接上、行為等價）。
2. VNC console 接 projectTo/recall + 選單動作 + 手機觸控板切換；驗證等價於舊
   VMVncPresentationActivity。
3. native console 接 projectTo/recall（DisplayProvider surface 切換 + cursor + MOUSE
   模式強切）+ 選單動作；驗證 native 畫面上外部顯示器、手機觸控板可操作。
4. 刪 openVncExt + VMVncPresentationActivity 退役 + 選單清理。

## 驗證（需外接顯示器或 Android 模擬 secondary display）
- VNC console → 投射 → 畫面上外部螢幕、手機觸控板動游標、拔線自動撤回、收回恢復。
- native console → 同上（含 cursor plane、guest 尺寸 letterbox）。
- 投射中旋轉手機 / 背景化 / VM 停：無崩潰、Presentation 生命週期正確。
- 選單：舊的兩個外部顯示器入口消失，console 內「投射」統一出現。
