# 顯示管線解耦：來源 / 畫格 / 匯出端

2026-08-23。目標是讓「渲染器 × 資料傳輸 × 顯示後端」不再互相決定。

現況的問題**不是**抽象少了一層，是**匯出端被做成 VM 層級的單例**。
而 simplefb 與 virtio-gpu 之間的仲裁**不是**問題，它是必要的——原因見 §1.1。

被推翻的推論記在 §8，因為推錯的過程和結論一樣需要交代。

---

## 0. 目標與非目標

**目標**

- 四條渲染路徑（2D / venus / gfxstream / drm2kgsl）只掛在 virtio-gpu 底下
- 資料傳輸方式由能力協商決定，不是使用者設定的一個軸
- 匯出端（NativeDisplay / VNC）綁在**scanout**上，不是綁在 VM 上
- zero-copy 留好路徑並標 TODO，不新增設定列舉

**非目標**

- **不啟用 virtio-gpu 多 scanout**（使用者決定；路徑留好，見 §4）
- 不拆 simplefb ↔ virtio-gpu 的仲裁——那是正確的，見 §1.1
- 不改渲染器本身
- 不在這一輪加硬體編碼（§6 第 8 步之後）

---

## 1. 現況

### 1.1 simplefb ↔ virtio-gpu 是**仲裁**，不是兩個顯示器

**「誰在顯示」是未知 guest 的執行期屬性，兩個方向都會發生：**

    Linux    早期 console → 載入 virtio-gpu 驅動 → virtio-gpu 接手
    Windows  edk2 用 virtio-gpu → 進 Windows 後改用 SimpleFB（virtio-gpu 不被辨識）

`devices/src/virtio/gpu/mod.rs:1630` 的註解已經寫死這件事：

> *"ownership actually changes -- a scanout bound or unbound, a device reset at OS handover ...
> That is exactly the handover this exists for (firmware paints through virtio-gpu, then Windows,
> which has no virtio-gpu driver, never binds a scanout again)."*

**判定依據是「有沒有 scanout 被綁定」——協定事實，不是啟發式**，而且每次工作迴圈都重新評估，
所以旗標能翻回去。同一段註解解釋了為什麼不能只在畫格到達時更新：
那樣第一次「guest 擁有」會變成永久的，橋停止提供畫格、就沒有東西喚醒它重新評估。

**未來 Windows 的 virtio-gpu 驅動落地也自動正確**：驅動綁 scanout → 旗標翻 true → virtio-gpu 贏。
不需要改任何東西。

**因此 `ExternalScanout` 不該被拆掉，也不該給兩個來源各一個匯出端**——
那會得到兩個視窗、其中一個永遠是舊的，而使用者要自己判斷哪個是活的。

**仲裁的判定是兩個條件，不只是「有沒有綁」**（`virtio_gpu.rs:1652`）：

    guest_owns_display() = guest_scanout_bound && last_guest_present.elapsed() < guest_idle_grace

綁了但停止呈現的 guest 會在 grace 之後把顯示讓回去。

### 1.1.1 guest 確實看得到兩個裝置，但（此配置下）只用一個

同時啟用時實測（`--gpu virglrenderer --simplefb`）：

    card0  driver=simple-framebuffer   /dev/fb0  simpledrmdrmfb   card0-Unknown-1 connected
    card1  driver=virtio-pci           /dev/fb1  virtio_gpudrmfb  card1-Virtual-1  connected
    kwin 把兩個 DRM 裝置都 open()
    但 kwin supportInformation: **Number of Screens: 1**

**所以合併在這個 Linux 桌面配置下是無損的**：kwin 開了 card0 卻沒把它當輸出。
（`enabled=enabled` 是 simpledrm 在 probe 時建立的固定管線，不是 kwin 在驅動。）

**但損失在原理上存在**：guest 看得到兩個裝置，若某個合成器/OS 同時驅動兩者，
host 只會顯示 virtio-gpu 那個，simplefb 側被 `present_external` 直接丟棄。

→ **維持仲裁，但把擁有權狀態變成可觀測的**，那樣「兩邊都在畫」會現形而不是安靜丟棄。

**刻意不測的情境**：兩裝置並存時 fbcon 掛在哪個 fb、`chvt` 是否跨越仲裁邊界。
每個 guest OS 的行為不同，測單一 OS 的結果不能推廣，所以不作為設計依據。

### 1.2 `DisplayT` 已經是縫線，但只實作了一半

`gpu_display/src/lib.rs`：

    CPU 路   framebuffer()      :227   flip()      :242
    GPU 路   import_resource()  :395   flip_to()   :247
    能力探測 is_dmabuf_import_supported()  :378   ← 預設 true

| 後端 | CPU 半邊 | GPU 半邊 |
|---|---|---|
| `gpu_display_android.rs` | ✓ | ✓（`:283` / `:420`，`:378` 是真的探測） |
| `gpu_display_vnc.rs` | ✓ | **✗ 兩個都沒實作，且沒覆寫探測 → 探測說謊** |

生產端：

| 生產者 | 走哪條 | 原因 |
|---|---|---|
| `virtio_gpu.rs` | 先試 GPU，失敗退 CPU 並快取 `CpuFallback` | 有做探測 |
| `simplefb_display.rs` | **永遠 CPU** | 硬寫 `framebuffer()`+`flip()`，不問探測 |

**GPU blit 今天只存在於一格：virtio-gpu 生產 × android 匯出。**

### 1.3 匯出端的成本

**VNC**（`vnc_server_bridge.c` 的 `vnc_server_composite`）：每幀 `memcpy` 整張 +
`rfbMarkRectAsModified(0,0,w,h)`，**沒有 damage 追蹤、沒有客戶端判斷**。
libvncserver 的 `rfbMarkRegionAsModified`（`main.c:412`）逐一走訪已連線客戶端，
**零客戶端時迴圈不執行 → 編碼不發生，但複製照做。**

**simplefb**（`simplefb_display.rs`）：固定 `DEFAULT_FPS = 30` 無條件輪詢。
simplefb + VNC 在靜止畫面、零連線下每幀仍有 4 次全幀複製
（guest→read_buf、read_buf→display fb、flip→shared_fb、composite→libvncserver）。
1400×1050 約 23.5 MB/幀 × 30 ≈ **700 MB/s**。**讀碼推算，未實測。**

> **優先度**：Windows guest 的**桌面**走 simplefb（§1.1）。
> 所以這不是開機階段的小事，它是 Windows 使用者桌面的常態成本。

#### 1.3.1 VNC 同時服務遠端與 app 自己

**app 內建 VNC 客戶端**：`libvncclient` 有編進去，並有
`VMVncDisplayActivity` / `VMVncPresentationActivity` / `VncClient.java` / `VncDisplayView.java`。
**所以 VNC 模式下手機上也有畫面 —— 是 app 當客戶端連上本機的 VNC server。**

    crosvm → VNC server → localhost → app 的 VNC client → SurfaceView     本機
    crosvm → VNC server → 網路      → 任何 RFB 客戶端                      遠端

**三個設計後果：**

1. **VNC 是真正的網路伺服器，不能假設只有一個本機客戶端** ——
   不能改成共享記憶體之類的本機捷徑
2. **本機 app 走 VNC 會付一趟本機編碼 + 解碼**，而原生路徑沒有。
   **那不是可以最佳化掉的，是那個選擇的本質成本**；VNC-for-local 存在是因為原生顯示不是每個配置都能用
3. **hw encoding 對遠端價值大得多**（頻寬）；對本機 app，理想是「不要編碼」而不是「編得更好」

**這也修正了 §6 第 1 步（零客戶端短路）的價值判斷**：VNC 模式下只要使用者在看就永遠有客戶端，
**所以那個最佳化生效的是「VM 在背景跑、沒人看」** —— 那是常見狀態，但不是主要情境。
**有客戶端時的浪費要靠 damage 追蹤。**

### 1.4 匯出端是 VM 層級單例

    crosvm  config.rs:787   android_display_service: Option<String>       ← 一個名字
    AIDL    ICrosvmAndroidDisplayService.setSurface(Surface, boolean forCursor)
                                                            ↑ 唯一的區分器
    app     CrosvmBackendInstance.java:446   一個 --android-display-service
            NativeDisplayBinder.java:53/108  waitForDisplayBinder(String) ← 已按名字參數化
            DisplayProvider.java:57          一個 SurfaceView，setSurface 至多一次

**`forCursor` 是布林值，所以一個服務只能持有兩個 Surface（主畫面 + 游標），
在型別上表達不了 N 個 scanout。這是多 scanout 原生顯示的真正阻礙。**

**方向和直覺相反：crosvm 是註冊服務的一方**
（`crosvm_android_display_client.cpp:2160` 的 `AServiceManager_addService`），app 是客戶端，
而**名字是 app 取的**（`NativeDisplay.serviceName(config)`）——所以 app 不需要列舉服務，
它列自己建立的清單就行。

**`serviceName` 已經是「一條通道」的身分，不只是顯示的**：輸入 socket 路徑也由它決定
（*"One virtio-input device per NativeDisplay channel"*、*"their paths must match NativeDisplay"*）。

### 1.4.1 單例有三個，不是一個

    1. android_display_service: Option<String>                一個名字
    2. setSurface(Surface, boolean forCursor)                 兩個 slot（主畫面 + 游標）
    3. 單一 cursor_scanout，且 move_cursor 忽略 _scanout_id   ← 最隱蔽

第三個最容易被當成已支援，因為它**一半有一半沒有**：

    virtio_gpu_cursor_pos { scanout_id, x, y }           協定有帶
    update_cursor(resource_id, scanout_id, ...)          **有用到**：依 scanout_id 找父表面，
                                                          把單一游標表面重新掛上去
    move_cursor(_scanout_id, x, y)                       **底線前綴，刻意忽略**
    VirtioGpuScanout::new_cursor()                       單數，一個

**模型本身是對的**：真實多螢幕也只有一個指標，所以「一個游標表面、依 `scanout_id` 重新掛載」
才是正確模型，而 `update_scanout_resource` 的 `SurfaceType::Cursor` 分支已經實作了重新掛載。

**缺的是 `MOVE_CURSOR` 那條路**：影像不變的純移動只發 `MOVE_CURSOR`，
而 `move_cursor` 忽略 `scanout_id` → **指標跨螢幕時游標表面留在舊的父表面上，座標卻是新螢幕的。**

    crosvm 這側    move_cursor 偵測 scanout_id 變了就重新掛載 —— 大致就這樣
    VNC 匯出端     免費：每個 scanout 一個 server，各自有游標
    原生匯出端     卡在 AIDL 的同一個限制，但那是主畫面就已經卡住的地方，非游標特有

**單 scanout 之下 `scanout_id` 恆為 0，忽略它和用它結果相同，所以現在不用改。**
多 scanout 啟用時它會壞，而**症狀是「游標出現在錯的螢幕或座標偏移」，不是「游標不見了」**
——不會報錯，只會不對。

### 1.4.2 游標的呈現方式（現況即設計）

    app（原生）   setSurface(surface, forCursor=true)
                  游標有自己的 Android Surface → **獨立圖層**，SurfaceFlinger 疊
    VNC           blend_cursor()   CPU 疊進畫格      給被動觀看的客戶端
                  rfbSetCursor()   RFB 游標偽編碼    給自己畫游標的客戶端
                  **兩路同時發**，因為客戶端可能是任一種

**VNC 的「GPU 疊加」是第 5 步之後的事**：VNC 拿到 GPU 半邊後，
疊加可以移進 Vulkan blit，和格式轉換在同一個位置順便做。

### 1.4.3 游標狀態按 scanout 配發（決定）

**app 是客戶端，它連的是某一個 scanout；crosvm 就配發那個 scanout 當下的游標狀態。**

    指標在這個 scanout      配發游標影像與位置
    指標在別的 scanout      配發 null（隱藏）
    SimpleFB 擁有顯示時      一律 null —— 它的游標是 guest 畫進 framebuffer 的，不是圖層

**這條規則從「只有一個指標」自動推出**：任一時刻每個 scanout 的游標要嘛是那個指標、要嘛什麼都沒有。

**而它讓 AIDL 不必改**：`forCursor: bool` 只有在「一個服務服務 N 個 scanout」時才不夠。
**一個服務對一個 scanout 的話，兩個 slot（主畫面 + 游標）正好。**
所以 §1.4 的阻礙解法是「serviceName 變 list」，不是「AIDL 加索引」。

**順帶補掉一個現有缺口**：`set_cursor_visible` 今天只在 `update_cursor` 裡被呼叫
（`virtio_gpu.rs:1802/1807`），也就是**只有 guest 明說時才動**；
`present_external` 與 `serve_external_scanout` 都沒碰游標。
**所以 simplefb 接手時，virtio-gpu 的游標圖層不會被隱藏** —— guest 若曾顯示游標、
之後不再使用 virtio-gpu（Windows 交接正是如此），那個游標會浮在 simplefb 畫面上。
今天大概碰不到（edk2 多半不用硬體游標；Linux 切 console 時 guest 會主動送 `resource_id=0`），
**但它依賴 guest 自願告知。按 scanout 配發游標狀態之後，這個缺口不需要特例就消失了。**

**多 scanout 時的後果**：VNC 端每個 scanout 各自疊加，互不影響，免費；
原生端每個 scanout 一個服務、各自兩個 slot。

---

## 2. 量到的事實（2026-08-22/23，5567 OPD2404）

- **fourcc 是 per-route 固定，不是 per-boot 隨機**：改動前 gfxstream=AB24、venus=AR24、drm2kgsl=AR24，各自跨開機一致（gfxstream 連續 10 次，水域 RGB 像素級相同）
- **移除 plane 清單的 ARGB8888 之後**（`droidvm-guest-additions 893d059`）：三條 route 全收斂 AB24，全部開到桌面，顏色全對；console 走 XR24 紅藍正確；`AB24 ↔ XR24` 雙向切換乾淨
- **simplefb 區域是 SHARE 的**：`MemoryRegionPurpose::SharedFramebuffer`（`aarch64/src/lib.rs:1044`）→ `hypervisor/src/gunyah/mod.rs:341` 的 `=> false`，走 swiotlb 的共享路徑
- **它由 `memfd:crosvm_guest` 撐著，不是 DMA heap 的 dmabuf**：裝置上 dmabuf fd 數 = 0，memfd 一個，沒有 framebuffer 大小的獨立映射
- **guest 用 `ioremap_wc()` 映射它**——write-combining
- **Android 視窗固定 RGBA_8888**（`crosvm_android_display_client.cpp:1473`），**不能改成 BGRA**：註解記載 Adreno 的 Skia RenderEngine 會在 external-OES BGRA 貼圖上 abort，打掛 surfaceflinger 並軟重開機
- **格式切換偵測器已存在**（`:2306` 的 `lastFourcc.exchange`），缺的是動作：*"until buffer reallocation plumbing exists app-side, the guest's scanout fourcc is diagnostic only"*
- **這份 libvncserver 沒有 H.264 編碼器**：只有 corre/hextile/rre/tight/ultra/zlib/zrle；`rfbEncodingH264` 只是協定常數
- **crosvm 的多 scanout 已就緒**：`display_params: Vec`、`max_num_displays`、`VIRTIO_GPU_MAX_SCANOUTS=16`、`num_scanouts` 告訴 guest

---

## 3. 目標模型

    來源（產生畫格）
    ├── simplefb bridge        輪詢 SharedFramebuffer；未來可產 Dmabuf（udmabuf over memfd）
    └── virtio-gpu device      guest 驅動
            └── 渲染器：2D / venus / gfxstream / drm2kgsl
    這兩者由 ExternalScanout 仲裁，共用同一個匯出端 —— 見 §1.1，維持現狀

    畫格（唯一的通貨）
        ScanoutFrame { Cpu{..} | Dmabuf{..} } + fourcc + 幾何

    匯出端（每個 scanout 一份，不是每台 VM 一份）
    ├── NativeDisplay(channel_name)
    └── Vnc(port)

**規則**

- 一個 scanout 綁一個匯出端（1:1），各自獨立設定
- 匯出端 per-binding 實例化
- 傳輸方式由協商決定（§4）
- **simplefb 不是一個 scanout，它是 scanout 0 的另一個來源**

---

## 4. 傳輸方式：它是「邊」，不是一層

**CPU copy / GPU copy / Zero copy 放不進 裝置→渲染→Scanout 這棵樹，
因為它不是節點的屬性，是兩個節點之間那條邊的屬性。**

    渲染層決定      來源「能產出什麼」
    Scanout 層決定   匯出端「能吃什麼」
    傳輸方式        = 這條邊上協商的結果

### 4.1 三者是一道階梯，每階多一個約束

    CPU copy    無約束，永遠可退回（下界）
       ↑ 加：來源能匯出 dmabuf  ＋  匯出端能 import
    GPU copy    仍有轉換機會（Vulkan blit 順便換通道順序）
       ↑ 加：格式必須直接相符（沒有 blit 可以轉換）
    Zero copy

**GPU copy 與 Zero copy 的差別不是快慢，是「有沒有一個可以做格式轉換的步驟」：**

    CPU copy   轉換在 `px.swap(0,2)` 那個迴圈
    GPU copy   轉換在 Vulkan blit 裡（順便做，不額外收費）
    Zero copy  **沒有地方可以轉** → 格式必須一開始就對

**這就是移除 ARGB8888（§2）和 zero-copy 同向的原因**：它把合成器推到唯一能被
zero-copy 的格式（AB24 = AHB RGBA_8888）上。今天 Android 視窗固定 RGBA_8888
且不能改成 BGRA（§2），所以只有 AB24/XB24 有資格。

### 4.2 解耦方式：各層只宣告自己的能力

    渲染層宣告      我能產出：Cpu | Dmabuf(fourcc, modifier)
    Scanout 層宣告   我能吃：  Cpu | Dmabuf-可blit轉換 | Dmabuf-需格式相符
    邊上協商        取交集的最高階

**沒有一層需要知道對方是誰。** 新增一個渲染器不必動任何 sink，
新增一個 sink 不必動任何渲染器。

**Zero-copy 的 TODO 標在 Scanout 層的能力宣告上**（「我能直接呈現這些 fourcc 的 dmabuf」），
不標在設定、也不標在渲染層。**今天所有 sink 都宣告「不能」，所以它永遠不會被選中
——路徑留著但不啟用。**

### 4.3 目前各端的能力（實測）

| | 能產出 / 能吃 | 依據 |
|---|---|---|
| virtio-gpu 3D | Dmabuf（export 可能失敗 → 退 Cpu） | `try_import_resource_to_display` 的 fallback |
| virtio-gpu 2D | Cpu（pool-scanout 有 udmabuf 路徑） | `resource_create_blob` |
| simplefb | **Cpu only** | `simplefb_display.rs` 硬寫，不問探測 |
| NativeDisplay | Cpu + Dmabuf-可blit | `import_resource` + `flip_to` + `android_display_is_vulkan_blit_available` |
| VNC | **Cpu only** | 沒實作 GPU 半邊，**且沒覆寫探測 → 探測說謊** |

**所以今天唯一的 GPU copy 是 `virtio-gpu 3D × NativeDisplay`。**

### 4.4 為什麼不做成使用者設定

兩個代價：驗收矩陣乘一次；不可能的組合要靠人記得不去測。
協商的話，不可能的組合在型別上就選不出來。

- 保留**除錯用**覆寫（比照 `GPU_SCANOUT_FORCE_TRANSFER=1`），那不是產品設定
- **矩陣每格記錄「實際協商到什麼」**——矩陣因此同時是回歸測試：協商結果變了會被看到

### 4.5 傳輸不依賴裝置層

**最容易搞錯的一點**：simplefb 和 virtio-gpu 都可能產出 dmabuf
（simplefb 透過 udmabuf over memfd，§7）。**所以傳輸能力屬於渲染層與 Scanout 層，
不屬於裝置層。** 把它掛在裝置層會讓「simplefb 永遠 CPU」變成架構事實，
而它其實只是今天沒實作。

---

## 5. 輸入

### 5.1 裝置配置

    VM 全域        keyboard ×1        mouse（相對）×1
    每 scanout     multi-touch ×1     absolute-mouse ×1     ← name= 帶通道身分

**依據**：鍵盤沒有輸出綁定，合成器按焦點送；相對指標跨輸出移動、焦點跟著走——
兩者都是 VM 全域的。**絕對裝置的座標只在特定輸出的幾何下有意義，本質上是 per-output。**

**相對滑鼠的一個後果要寫進 UI 行為**：guest 的指標位置才是權威的。
app 應只轉送「有 Android 焦點的那個視窗」的相對移動，否則兩個視窗會互相打架。

### 5.2 映射由 guest 決定，且無法自動化

**evdev 和 HID 都沒有「我屬於第 N 個螢幕」的欄位**——裝置無法自我宣告。
映射一律是 guest 端設定，且一律以**裝置名字**當 key：

    Linux/Wayland(kwin)  設定 → 輸入裝置 → 觸控螢幕 → 對應螢幕；按裝置名字存
    Linux/X11            xinput map-to-output <device> <output>
    Windows              控制台 → Tablet PC 設定 → Setup，逐螢幕點按指認（純手動）

**所以 crosvm 的 `--input ...[name=N]` 是唯一的槓桿，而且名字必須跨開機穩定**
（名字一變，使用者的映射設定就失效）。建議形式：`DroidVM Touch (display-0)`。

**但在單 scanout（現狀）下 guest 只看得到一個顯示器，沒有東西要映射。**
這個問題只在多 scanout 啟用後才出現，而屆時每個 guest OS 都需要一次性的手動設定步驟，
**那是產品面的持續成本，要寫進使用者文件。**

### 5.3 每個 scanout 有自己的設定（決定）

    設定 → 圖形 → 每個 scanout：
        匯出端         VNC / 原生顯示
        啟用輸入裝置    預設 on
        解析度 / DPI / refresh rate

- **app 開啟該顯示時可選**
- **進去之後也能切換**，切換 = 重新初始化該通道
- **傳輸方式不在這裡**——它是協商結果（§4），但**協商到什麼要顯示出來**

### 5.4 設定 vs 狀態：傳輸顯示在 scanout 層，但不是可選項

**使用者能選的東西，必須是他選了就一定會生效的東西。** 傳輸方式不是——
它取決於來源能不能匯出、匯出端能不能吃、格式合不合。
**使用者選「Zero Copy」而系統靜默降級到 CPU copy，就是「看起來成功了」那類失效。**

面板形狀：

    匯出端         VNC / 原生顯示                    ← 選
    啟用輸入裝置    預設 on                          ← 選
    解析度 / DPI / refresh rate                     ← 選
    ────────────────────────────────
    實際傳輸       GPU copy（協商）                  ← **唯讀，顯示結果**
    [進階] 傳輸上限  自動 ▾                          ← 除錯用，預設自動

**覆寫的語意必須是「上限」，不是「選擇」：**

    自動（預設）      協商結果
    上限 = GPU copy   即使可以 zero-copy 也不用
    上限 = CPU copy   即使可以 GPU blit 也不用（等同 GPU_SCANOUT_FORCE_TRANSFER=1）

**只能往下限制，不能往上要求。** 「要求 GPU copy」在來源匯不出 dmabuf 時無法滿足，
那時只有靜默降級（壞）或明確失敗（吵）兩種行為；**做成上限就沒有這個問題，任何值都一定可滿足。**

**「實際傳輸」欄位同時是驗收矩陣每格要記錄的那一項**（§4.4）——
協商結果變了就會被看到，矩陣因此同時是回歸測試。

**實作後果**：關閉時該 scanout 不建立 `multi-touch` / `absolute-mouse`
（鍵盤與相對滑鼠是 VM 全域的，不受此屬性影響）。
切換需要重建 crosvm 的 `--input` 裝置集合，因此是**重新初始化**而非熱切換。

---

## 6. 遷移順序

每一步可單獨出貨、單獨驗證。純重構的步驟要明確寫下驗收條件。

| # | 動作 | 驗收條件 |
|---|---|---|
| 0 | VNC 的 `is_dmabuf_import_supported()` → `false` | 每個資源不再有一次失敗的 export+import |
| 1 | VNC sink：沒有客戶端就短路 | 零連線時每幀複製次數下降；有連線時畫面不變 |
| 2 | 引入 `ScanoutFrame`，兩個來源都改用 | **純重構：輸出逐位元組相同** |
| 3 | 匯出端改 per-scanout（VNC 先行） | 單 scanout 行為不變；型別上能表達 N 個 |
| 4 | simplefb 走 udmabuf → 能產 `Dmabuf` | simplefb + 原生走 GPU blit；畫面與顏色不變 |
| 5 | VNC 實作 GPU 半邊 | VNC 能吃 dmabuf；畫面與顏色不變 |
| 6 | 每 scanout「啟用輸入裝置」屬性（§5.3） | 關閉時該通道無絕對裝置；切換後重新初始化正確 |
| 7 | VNC sink 內部切 encoder / transport | **純重構：線上位元組相同** |
| 8 | `HwEncoder`（MediaCodec）+ H.264 側通道 | 新功能，不影響既有 RFB 客戶端 |
| — | **多 scanout 啟用**（AIDL 加 scanout 索引或 serviceName 變 list） | **使用者決定先不做**；§1.4 是阻礙所在 |

**優先度**：第 1、4 步直接影響 Windows guest 的桌面成本（§1.3），不是一般優化。

---

## 7. 未驗的前提

| 前提 | 影響 | 怎麼驗 |
|---|---|---|
| udmabuf 能否包 Gunyah SHARE 的 `SharedFramebuffer` | 第 4 步整條 | 對該區域建一次 udmabuf |
| WC 寫入對 GPU 讀取的可見性 | 第 4、5 步 | 比照 pool 路徑的 `linear_verified` |
| MediaCodec input Surface 能否由 Vulkan 餵 | 第 8 步 | `createTargetImage(AHardwareBuffer*)` 吃任意 AHB，機制上可行，未驗 |
| VNC 的 700 MB/s 推算 | 第 1 步優先度 | `simpleperf` 分「有連線 / 無連線」兩格 |
| simplefb 獨佔 sink（無 GPU）那條路 | 第 3、4 步 | 目前所有 simplefb 觀測都在有 `--gpu` 之下，走的是 `GpuDevice` |

---

## 8. 被推翻的推論

**（一）「保護 VM 下 host 讀不到 guest 記憶體，所以 simplefb + pwf 不能運作」——錯。**

依據是 `MemoryRegionPurpose` 的分類看到 `GuestMemoryRegion => true`（lend）。
錯在 **`SharedFramebuffer` 就在那個 match 裡，但在 grep 輸出被截斷的後半**，它是 `=> false`。

**這個錯誤形態值得記**：不是查錯路徑，也不是對照組沒有那個東西，
而是**輸出本身不完整，而它長得和完整的一模一樣**。
`grep | head -N` 看起來就是清單，截斷的 `ls`/`ps` 看起來就是全部。
→ **任何要下結論的清單，先確認沒被截。數量是最便宜的完整性檢查。**

**（二）「simplefb 是開機階段、virtio-gpu 是執行期」——錯，那是 Linux 的順序。**

Windows 正好相反（§1.1）。這個錯誤讓我一度把「每個來源一個匯出端」套到 simplefb ↔ virtio-gpu 上，
而那會產生「凍結的畫面旁邊放一個活的桌面」。**碼裡的註解本來就寫對了，是我沒讀到它就先推論。**

**（三）一句過時註解已修**（`crosvm b2444fd86`）：`src/crosvm/sys/linux.rs` 原本說 simplefb 區域
*"backed by a DMA-BUF from the DMA heap and shared via map_cma_region"*，實際不是。
**照那句讀，GPU import 看起來免費（fd 現成），實際上要先建 udmabuf——工作量估計差很多。**

---

## 9. 驗證的界線

**結構論證擋得住設計錯誤，擋不住實作錯誤。**

damage 追蹤有一個乾淨的結構論證：「判斷粒度和複製粒度是同一個，所以部分變動 by construction 安全」。
**那讓設計層面的失敗不可能發生，但它對以下三種一句話都說不上：**

    memcmp 的偏移算錯
    rows 的邊界差一
    rfbMarkRectAsModified 的參數順序寫反

**三種都會讓「畫面有一塊是舊的」發生，而且都不會報錯。**
所以結構論證再乾淨，端到端的畫面比對還是要跑。

**「靜止畫面」是一個關於內容的假設，而我們量的是頻寬。**
未經驗證的內容假設會以變異的形式出現在量測裡，看起來像噪音：
同一條件下舊 binary 跨 5.3–7.0 MB、新 binary 跨 0.0–5.3 MB，
原因是工作列時鐘每分鐘變一次、還有通知與動畫。

**因此判準要雙向**：

    比舊的低一個數量級   = 生效
    同一個數量級         = 沒生效
    **真的是 0.0**       = **反而可疑** —— 大部分判準只防「沒生效」，
                            這一條防的是「生效過頭 = 壞掉」

**建置協作**：請對方建置後、拿到 md5 前不改那些檔。
建置飛行中改檔會編出改動前的版本，而失敗的外觀完全正常
（exit 0、md5 算得出來、符號閘也過）。**唯一查得出來的是「產物 mtime vs 原始碼 mtime」。**
