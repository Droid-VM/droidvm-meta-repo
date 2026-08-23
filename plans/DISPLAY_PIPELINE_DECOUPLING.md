# 顯示管線解耦：螢幕 / 畫格 / 匯出端

2026-08-23。目標是讓「渲染器 × 資料傳輸 × 顯示後端」不再互相決定。

**這一版換掉了上一版的中心決定。**上一版說 simplefb 與 virtio-gpu 之間的仲裁是必要的，
兩者共用一個匯出端；這一版說**它們是兩個平行的顯示裝置，各自提供一個螢幕**，
仲裁連同 `ExternalScanout` 一起刪掉。**前提怎麼變的記在 §1.1，被推翻的推論記在 §8。**

一級概念只有三個：**螢幕**（誰在產生畫面）、**畫格**（唯一的通貨）、**匯出端**（誰在顯示）。
「傳輸方式」不是第四個，它是螢幕與匯出端之間那條**邊**的屬性（§4）。

---

## 0. 目標與非目標

**目標**

- **simplefb 與 virtio-gpu 是兩個平行的顯示裝置**，各自提供螢幕；不再有誰讓給誰
- 四條渲染路徑（2D / venus / gfxstream / drm2kgsl）只掛在 virtio-gpu 底下
- 每個螢幕有自己的**定義**（身分、幾何、fourcc、可調屬性、能力、游標欄位）
- 匯出端（NativeDisplay / VNC）綁在**螢幕**上，不是綁在 VM 上；app 端就是把螢幕列出來讓人選
- 資料傳輸方式由能力協商決定，不是使用者設定的一個軸
- pull 來源（simplefb）用 watcher 轉成與 push 來源相同的模型（§3.4）
- zero-copy 留好路徑並標 TODO，不新增設定列舉

**非目標**

- **不啟用 virtio-gpu 多 scanout**（使用者決定；路徑留好，見 §3.1）
- **不做鏡像**（一個螢幕同時餵兩個匯出端）——螢幕與匯出端是 1:1，見 §3.1
- **不做 GPU watcher**——它在型別上就是耦合，見 §4.5
- **不改 simplefb 的 DT `format`**——EDK2/Windows 不讀它，而且改了不省工作，見 §4.1
- 不改渲染器本身
- 不在這一輪加硬體編碼（§6 最後兩步之後）

---

## 1. 現況

### 1.1 simplefb 與 virtio-gpu：仲裁在什麼前提下是對的

**「誰在顯示」是未知 guest 的執行期屬性，兩個方向都會發生：**

    Linux    早期 console → 載入 virtio-gpu 驅動 → virtio-gpu 接手
    Windows  edk2 用 virtio-gpu → 進 Windows 後改用 SimpleFB（virtio-gpu 不被辨識）

**這段觀察仍然成立，而且是整份計畫的地基**——它是「兩個裝置都必須存在、
而且都可能是活的那一個」的理由。

`devices/src/virtio/gpu/mod.rs:1630` 的註解把交接寫死了：

> *"ownership actually changes -- a scanout bound or unbound, a device reset at OS handover ...
> That is exactly the handover this exists for (firmware paints through virtio-gpu, then Windows,
> which has no virtio-gpu driver, never binds a scanout again)."*

仲裁的判定是兩個條件，不只是「有沒有綁」（`virtio_gpu.rs:1652`）：

    guest_owns_display() = guest_scanout_bound && last_guest_present.elapsed() < guest_idle_grace

**但這個結論成立的前提是「一台 VM 只有一個匯出端」。**
在那個前提下，兩個來源必須合併，而合併就得有人仲裁。

**前提沒了。**匯出端 per-screen 之後，兩個來源各自有自己的匯出端，
使用者自己選要看哪一個——host 不必替他猜，也就沒有東西需要仲裁。

上一版拒絕這個方向的理由是「會得到兩個視窗、其中一個永遠是舊的，而使用者要自己判斷哪個是活的」。
**那個反對意見用 watcher 產出的 `last_changed_at` 就解決了**（§3.2），
而且比讓 host 用 grace timer 猜要誠實：清單上直接寫著哪個螢幕多久沒動了。

### 1.1.1 guest 確實看得到兩個裝置

同時啟用時實測（`--gpu virglrenderer --simplefb`）：

    card0  driver=simple-framebuffer   /dev/fb0  simpledrmdrmfb   card0-Unknown-1 connected
    card1  driver=virtio-pci           /dev/fb1  virtio_gpudrmfb  card1-Virtual-1  connected
    kwin 把兩個 DRM 裝置都 open()
    但 kwin supportInformation: **Number of Screens: 1**

**所以「兩個顯示裝置」不是這一版發明的，它是 guest 本來就看到的東西**——
上一版是在 host 端把它們合併回一個。這一版不合併。
（`enabled=enabled` 是 simpledrm 在 probe 時建立的固定管線，不是 kwin 在驅動。）

**上一版記下的那個「原理上的損失」在這一版消失了**：
若某個合成器/OS 同時驅動兩者，上一版只顯示 virtio-gpu、simplefb 側被 `present_external`
安靜丟棄；這一版兩個螢幕都在清單裡，兩邊都在畫就是兩個都有畫面，不需要「把擁有權變成可觀測的」。

**注意 `Number of Screens: 1`**：guest 看得到兩個 DRM 裝置，卻只把其中一個當輸出。
這對輸入裝置的歸屬有直接後果，見 §5.2。

**刻意不測的情境**：兩裝置並存時 fbcon 掛在哪個 fb、`chvt` 是否跨越邊界。
每個 guest OS 的行為不同，測單一 OS 的結果不能推廣，所以不作為設計依據。

### 1.2 `DisplayT` 已經是縫線，但只實作了一半

`gpu_display/src/lib.rs`：

    CPU 路   framebuffer()      :227   flip()      :242
    GPU 路   import_resource()  :410   flip_to()   :247
    能力探測 is_dmabuf_import_supported()  :378   ← 預設 true
    消費探測 has_consumer()                :393   ← 預設 true

| 後端 | CPU 半邊 | GPU 半邊 | `has_consumer` |
|---|---|---|---|
| `gpu_display_android.rs` | ✓ | ✓（`:283` / `:420`，`:378` 是真的探測） | **✗ 吃預設 true——但它有真的答案，見下** |
| `gpu_display_vnc.rs` | ✓ | ✗ 未實作，探測已誠實回 false（`:563`） | ✓（`:571`） |

生產端：

| 生產者 | 走哪條 | 原因 |
|---|---|---|
| `virtio_gpu.rs` | 先試 GPU，失敗退 CPU 並快取 `CpuFallback` | 有做探測 |
| `simplefb_display.rs` | **永遠 CPU** | 硬寫 `framebuffer()`+`flip()`，不問探測 |

**GPU blit 今天只存在於一格：virtio-gpu 生產 × android 匯出。**

**原生 sink 的 `has_consumer` 是個現成的缺口**：它明明有答案。
`ICrosvmAndroidDisplayService.aidl:34` 有 `removeSurface(boolean)`，
`DisplayProvider.java:337` 在 `surfaceDestroyed` 時呼叫它，
`crosvm_android_display_client.cpp:1576` 收下並清掉 native surface。
**也就是使用者離開顯示畫面之後，crosvm 這側知道沒人在看，卻回報 true。**
而原生是 app 的兩個顯示模式之一，所以 §6 第 1 步的省在那條路徑上今天是零。

### 1.3 匯出端的成本

**VNC**（`vnc_server_bridge.c` 的 `vnc_server_composite`）：每幀 `memcpy` 整張 +
`rfbMarkRectAsModified(0,0,w,h)`，**沒有 damage 追蹤**。
libvncserver 的 `rfbMarkRegionAsModified`（`main.c:412`）逐一走訪已連線客戶端，
**零客戶端時迴圈不執行 → 編碼不發生，但複製照做**（已修，見 §6 第 1 步）。

**simplefb**（`simplefb_display.rs`）：固定 `DEFAULT_FPS = 30` 無條件輪詢。
兩條迴圈行為不同，這是個坑：

    simplefb_feed_loop      :64-67   有 last_buf 比對，只在真的變了才送
    simplefb_display_loop   :251-277 **無條件整張複製** ← 獨立 sink 那條，也就是這一版要走的那條

simplefb + VNC 在靜止畫面、零連線下每幀曾有 4 次全幀複製
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

**這也修正了「零客戶端短路」（§6 第 1 步）的價值判斷**：VNC 模式下只要使用者在看就永遠有客戶端，
**所以那個最佳化生效的是「VM 在背景跑、沒人看」** —— 那是常見狀態，但不是主要情境。
**有客戶端時的浪費要靠 damage 追蹤**（§3.4）。

**對這一版的另一個後果**：app 兩種檢視器都已經寫好了。
§3.1 的「選 VNC 就起 VNC client、選原生就建 Surface」不是新功能，是把既有的兩條路
接到「螢幕清單」這個新的選擇點上。

### 1.4 匯出端是 VM 層級單例——有四個，不是三個

    1. android_display_service: Option<String>                一個名字（config.rs:787）
    2. setSurface(Surface, boolean forCursor)                 兩個 slot（主畫面 + 游標）
    3. 單一 cursor_scanout，且 move_cursor 忽略 _scanout_id
    4. **display_backends 是有序 fallback 清單，只挑第一個開成功的**  ← 最底層的那個

第四個是前三個的地基，**也是 §6「匯出端 per-screen」那一步真正要動的東西**：

    devices/src/virtio/gpu/mod.rs:311-325       for display_backend in display_backends { ... break }
    devices/src/virtio/gpu/virtio_gpu.rs:1235   display: Rc<RefCell<GpuDisplay>>   ← 單數，37 處引用
    src/crosvm/config.rs:1014                   vnc_server: Option<VncConfig>      ← 也是單數

就算 AIDL 改成 list、游標按螢幕配發，`VirtioGpu` 仍然只有一個 display。

**而這個 fallback 順序今天就有一個使用者踩得到的 bug**：
`gpu.rs:192` 先 `insert(0, Android)`，`gpu.rs:204` 再 `insert(0, VncTcp)`
→ 順序是 `[Vnc, Android, X, Stub]`。**兩個都開時 VNC 靜默贏，
Android sink 的 `AServiceManager_addService` 根本不會執行**，
app 的原生顯示就永遠等不到 binder（`DisplayProvider.java:39-52` 的重試沒有上限，
所以症狀是「畫面永遠空白」而不是報錯）。
app 這邊 `display_enabled` 與 `vnc_enabled` 是兩個獨立布林
（`CrosvmBackendInstance.java:963`），使用者選得出這個組合。

**`forCursor` 是布林值，所以一個服務只能持有兩個 Surface（主畫面 + 游標），
在型別上表達不了 N 個螢幕。**解法是 serviceName 變 list，不是 AIDL 加索引——理由見 §1.4.2。

**方向和直覺相反：crosvm 是註冊服務的一方**
（`crosvm_android_display_client.cpp:2160` 的 `AServiceManager_addService`），app 是客戶端，
而**名字是 app 取的**（`NativeDisplay.serviceName(config)`）——所以 app 不需要列舉服務，
它列自己建立的清單就行。**這正是 §3.1 的 list 化能成立的原因。**

**`serviceName` 已經是「一條通道」的身分，不只是顯示的**：輸入 socket 路徑也由它決定
（*"One virtio-input device per NativeDisplay channel"*、*"their paths must match NativeDisplay"*）。

### 1.4.1 游標：一半有一半沒有

    virtio_gpu_cursor_pos { scanout_id, x, y }           協定有帶
    update_cursor(resource_id, scanout_id, ...)          **有用到**：依 scanout_id 找父表面，
                                                          把單一游標表面重新掛上去
    move_cursor(_scanout_id, x, y)                       **底線前綴，刻意忽略**（`virtio_gpu.rs:1832`）
    VirtioGpuScanout::new_cursor()                       單數，一個

**模型本身是對的**：真實多螢幕也只有一個指標，所以「一個游標表面、依 `scanout_id` 重新掛載」
才是正確模型，而 `update_scanout_resource` 的 `SurfaceType::Cursor` 分支已經實作了重新掛載。

**缺的是 `MOVE_CURSOR` 那條路**：影像不變的純移動只發 `MOVE_CURSOR`，
而 `move_cursor` 忽略 `scanout_id` → 指標跨螢幕時游標表面留在舊的父表面上，座標卻是新螢幕的。

**上一版說「單 scanout 之下忽略它結果相同，所以現在不用改」——這一版不成立。**
兩個螢幕從第一天就並存，而 §3.5 的游標模型**就是拿 `scanout_id` 去比對**，
所以那個比對必須真的發生。修法是一次比較，見 §6 第 8 步。
**症狀是「游標出現在錯的螢幕或座標偏移」，不是「游標不見了」——不會報錯，只會不對。**

### 1.4.2 游標的呈現方式（現況即設計）

    app（原生）   setSurface(surface, forCursor=true)
                  游標有自己的 Android Surface → **獨立圖層**，SurfaceFlinger 疊
    VNC           blend_cursor()   CPU 疊進畫格（`vnc_server_bridge.c:611/628`）給被動觀看的客戶端
                  rfbSetCursor()   RFB 游標偽編碼（`:424`；取消是 `rfbSetCursor(NULL)`，`:359`）
                  **兩路同時發**，因為客戶端可能是任一種

**`forCursor: bool` 只有在「一個服務服務 N 個螢幕」時才不夠。
一個服務對一個螢幕的話，兩個 slot（主畫面 + 游標）正好。**
所以 §1.4 的阻礙解法是「serviceName 變 list」，不是「AIDL 加索引」。

**VNC 的「GPU 疊加」是拿到 GPU 半邊之後的事**：疊加可以移進 Vulkan blit，
和格式轉換在同一個位置順便做。

---

## 2. 量到的事實（2026-08-22/23，5567 OPD2404）

- **fourcc 是 per-route 固定，不是 per-boot 隨機**：改動前 gfxstream=AB24、venus=AR24、drm2kgsl=AR24，各自跨開機一致（gfxstream 連續 10 次，水域 RGB 像素級相同）
- **移除 plane 清單的 ARGB8888 之後**（`droidvm-guest-additions 893d059`）：三條 route 全收斂 AB24，全部開到桌面，顏色全對；console 走 XR24 紅藍正確；`AB24 ↔ XR24` 雙向切換乾淨
- **simplefb 區域是 SHARE 的**：`MemoryRegionPurpose::SharedFramebuffer`（`aarch64/src/lib.rs:1044`）→ `hypervisor/src/gunyah/mod.rs:341` 的 `=> false`，走 swiotlb 的共享路徑
- **它由 `memfd:crosvm_guest` 撐著，不是 DMA heap 的 dmabuf**：裝置上 dmabuf fd 數 = 0，memfd 一個，沒有 framebuffer 大小的獨立映射
- **guest 用 `ioremap_wc()` 映射它**——write-combining
- **CPU 管線有一個正規位元組順序：B,G,R,X**（`crosvm_android_display_client.cpp:1497` 的 *"crosvm always renders scanouts in B,G,R,X byte order"*）。每一端都對得起來，而且是正確地對、不是碰巧——見 §4.4 的表
- **simplefb 的 fourcc 由 DT 宣告，預設 `a8r8g8b8`**（`config.rs:644`，寫進 `fdt.rs:856`）= AR24 = 記憶體 B,G,R,A ＝**正規順序，所以它裸複製是對的**
- **VNC 的 serverFormat 也是正規順序**：`vnc_server_bridge.c:190-192` red<<16 green<<8 blue<<0、little-endian → 記憶體 B,G,R,A
- **Android 視窗固定 RGBA_8888**（`crosvm_android_display_client.cpp:1473`）→ 記憶體 R,G,B,A，**所以原生 sink 在 post 前無條件 swap**（`swapRedBlueInPlace`，`:1504`／呼叫點 `:1800`）。不能改成 BGRA：註解記載 Adreno 的 Skia RenderEngine 會在 external-OES BGRA 貼圖上 abort，打掛 surfaceflinger 並軟重開機
- **生產端維持不變式的方式是看 fourcc**：`virtio_gpu.rs:757` 的 `needs_swizzle` 只在 guest 宣告 ABGR8888/XBGR8888（R-first，如桌面的 AB24）時才 `px.swap(0,2)`；fbcon 的 XR24 已經是 BGRX，不能動
- **GPU / zero-copy 路不吃這個不變式，它讀 fourcc**：`vkFormatFromDrmFourcc`（`cpp:617-626`）把 AR24/XR24 → `VK_FORMAT_B8G8R8A8_UNORM`、AB24/XB24 → `R8G8B8A8_UNORM`
- **格式切換偵測器已存在**（`:2306` 的 `lastFourcc.exchange`），缺的是動作：*"until buffer reallocation plumbing exists app-side, the guest's scanout fourcc is diagnostic only"*
- **這份 libvncserver 沒有 H.264 編碼器**：只有 corre/hextile/rre/tight/ultra/zlib/zrle；`rfbEncodingH264` 只是協定常數
- **Gunyah 沒有 dirty log**：`hypervisor/src/gunyah/mod.rs:1440` 的 `VmCap::DirtyLog => false`，`get_dirty_log` 是 stub
- **`UdmabufDriver` 已經在 `VirtioGpu` 裡**（`virtio_gpu.rs:1244`），`create_udmabuf(&GuestMemory, &[(GuestAddress, usize)])` 走 `mem.shm_region(addr)` 的 memfd（`vm_memory/src/udmabuf/sys/linux.rs:109-137`）
- **crosvm 的多 scanout 在 device 層已就緒**：`display_params: Vec`、`max_num_displays`、`VIRTIO_GPU_MAX_SCANOUTS=16`、`num_scanouts` 告訴 guest。**display 層沒有**，見 §1.4 第 4 個單例

---

## 3. 目標模型

### 3.1 螢幕是唯一的一級概念

    來源（顯示裝置）              螢幕
    ├── simplefb device     ──>  1 個，固定（DT 定死）
    └── virtio-gpu device   ──>  N 個（今天 N=1；多 scanout 啟用時才 >1）
            └── 渲染器：2D / venus / gfxstream / drm2kgsl

    畫格（唯一的通貨）
        ScanoutFrame { Cpu{..} | Dmabuf{..} } + fourcc + 幾何 + damage

    匯出端（每個螢幕一份）
    ├── NativeDisplay(channel_name)
    └── Vnc(host:port)

**規則**

- **一個螢幕綁一個匯出端（1:1）**，各自獨立設定
- **不做鏡像**（同一個螢幕同時給原生和 VNC）。這是決定，不是限制的副產物：
  今天的行為是「VNC 靜默贏、原生永遠拿不到」（§1.4），要嘛修成鏡像、要嘛修成 1:1，這裡選 1:1
- 匯出端 per-binding 實例化
- 傳輸方式由協商決定（§4）
- **simplefb 是一個顯示裝置，不是 scanout 0 的另一個來源**

**app 端因此很簡單**：crosvm 把螢幕清單給出來，使用者選一個，
定義說它是 VNC 就起 VNC client、說它是原生就建 Surface，然後照定義搬資料。
**兩種檢視器都已經寫好了**（§1.3.1），要新增的只是「選哪一個螢幕」這個選擇點。
app 也不需要列舉服務——**名字是 app 自己取的**（§1.4），它列自己建立的清單就行。

### 3.2 螢幕的定義

    身分     stable_id        跨開機穩定（app 存的是使用者選的那個；§5.2 的輸入對應也用它當 key）
             display_name     給人看的

    幾何     width/height/stride
             geometry_fixed   simplefb=true（DT 定死）  virtio-gpu=false（guest 執行期可改）

    格式     fourcc           simplefb 從 DT 讀（§2）  virtio-gpu 從 scanout_data 讀

    能力     frame_boundaries simplefb=false  virtio-gpu=true
             backpressure     simplefb=false  virtio-gpu=true
             產出             Cpu | Dmabuf(fourcc, modifier)

    狀態     last_changed_at  watcher 或 flush 更新 —— **app 用它顯示哪個螢幕是活的**
             cursor           None | Some{image, hotspot, position}   見 §3.5

    可調     simplefb         輪詢率
             virtio-gpu       解析度 / DPI / refresh rate

**「可調屬性」必須是定義的一部分，不能平鋪給所有螢幕。**
上一版把「解析度 / DPI / refresh rate」列成每個 scanout 都有的設定——
對 simplefb 有一半是假的（幾何由 DT 定死），
而它有一個 virtio-gpu 沒有的真設定項：**輪詢率**（host 的性質，不是 guest 的）。

**`last_changed_at` 是上一版反對意見的答案**（§1.1）：
使用者不會選到凍住的螢幕而不自知，因為清單上就寫著它多久沒動了。

### 3.3 刪掉仲裁刪掉了什麼

匯出端 per-screen 之後，下面這一整組沒有存在的理由：

    devices/src/virtio/gpu/external_scanout.rs        整個檔案
    guest_owns_display() / guest_scanout_bound
    last_guest_present / guest_idle_grace / GUEST_IDLE_GRACE_AFTER_RECLAIM
    external_had_display（「搶回來時提高門檻」那段）
    ExternalScanout::poke()（每秒一次只為了重新評估擁有權的喚醒）
    present_external / serve_external_scanout

    觸點：mod.rs:55/1061/1159-1160/1198/1753/1778-1779/1886
          virtio_gpu.rs:1257-1270/1423-1424/1718/1749-1755
          virtio/mod.rs:60、gpu_config.rs:131
          sys/linux.rs:385/1192/2472/3894

**這一版是在刪程式碼，不是加。**代價只有一個——使用者要自己選看哪個螢幕——
而那正是 §3.2 的 `last_changed_at` 要處理的。

**一段歷史要記住，否則會有人把它改回去**：`gpu.rs:192` 的註解說 GPU device 必須擁有 sink，
理由是 *"Two registrations under one name is what made the app's Surface go to whichever
producer won the race, with the loser drawing into nothing for the rest of the VM's life."*
**關鍵是 under one name**——當初的問題是兩個 producer 搶同一個 service 名字，
不是「第二個 sink 本身是錯的」。**每個螢幕有自己的名字之後，那個 race 從構造上消失。**

### 3.4 畫格：watcher 把 pull 轉成 push

**兩個來源的模型本來不一樣，而且不是實作差異，是協定本質：**

| | virtio-gpu | simplefb |
|---|---|---|
| 畫格何時存在 | guest 送 `RESOURCE_FLUSH` / `SET_SCANOUT`（`mod.rs:605`） | 沒有任何訊號，只有一塊記憶體 |
| host 怎麼知道 | 佇列事件 | **只能輪詢** |
| 為什麼不能 event 化 | — | guest `ioremap_wc()` 直接映射、區域是 SHARE 的，寫入不 trap；Gunyah 沒有 dirty log（§2） |
| 畫格邊界 | 有 | **沒有**，取樣可能取到寫到一半 |
| damage | flush 帶 rect（今天沒用） | 沒有，只能自己比出來 |
| 回壓 | 有（flip fence 可擋住 guest 的 command 完成） | **不可能**，guest 不等任何人 |

**watcher（內容比對）把「畫格何時存在」補上，於是 push/pull 的區別在畫格層面消失**——
下游一律看到「有新畫格 + damage」，不必分支處理來源型別。

**造不出來的兩件事就老實宣告成能力，不要讓 `ScanoutFrame` 假裝有：**

    frame_boundaries: false     沒有人說過「這張畫完整了」
    backpressure:     false     release fence 對這個來源沒有意義

**沒有第三條路可以取代比對**（三條都查過）：guest 送 doorbell——simplefb 的前提就是 guest
沒有驅動，Windows 我們動不了；硬體 dirty log——`VmCap::DirtyLog => false`；
host 端寫保護取 fault——guest 直接 stage-2 映射，沒有 trap 點。

**watcher 的產物是 damage，不是「省下一次複製」。**
這個定義是它與傳輸解耦的關鍵：省複製只是 damage 的下游後果，
而只要它的定義裡不提複製，它就沒有東西可以跟傳輸耦合。

    watcher 產出    Option<DamageSet>    空集合 = 這一拍沒變
    傳輸吃的是      frame + damage

兩端都現成：

    VNC      rfbMarkRectAsModified(x,y,w,h) 取代今天的 (0,0,w,h) → 空 damage = 完全不編碼
    原生     ANativeWindow_lock 的第三個參數今天寫死 nullptr（cpp:1636/1856）= 整張 dirty

**空 damage 最大的好處不是省複製，是根本不 queue buffer**——SurfaceFlinger 不被叫醒，
不合成、不動 GPU。這是耗電的差別，而且跟傳輸走 CPU 還是 GPU 無關。
**而 damage 也是 §1.3.1 指出的那個缺口的解**：有客戶端在看的時候，短路幫不上忙，只有 damage 幫得上。

**兩個 watcher 必須有的行為**：

- **匯出端接上時強制送一張完整畫格**，即使內容一個 byte 沒變
  （`simplefb_feed_loop` 已經有這個概念，別在搬過去時掉了）
- **沒有匯出端時整個不要 poll**，不只是跳過複製。這是這個模型最大的一筆省

**驗證這件事有它自己的界線，見 §9**——結構論證擋得住設計錯誤，擋不住差一錯誤。

### 3.5 游標是螢幕定義的一個欄位

    simplefb 螢幕        cursor: None        永遠（它的游標是 guest 畫進 framebuffer 的像素，不是圖層）
    virtio-gpu 螢幕      cursor: Some(..)    當 cursor_scanout 的 scanout_id 對得上這個螢幕
                         cursor: None        對不上

**這條規則從「只有一個指標」自動推出**：任一時刻每個螢幕的游標要嘛是那個指標、要嘛什麼都沒有。

**`None` 是主動狀態，意思是「這個螢幕上沒有游標」，不是「不做事」。**

這是唯一容易寫錯的地方，而且錯法是靜默的。指標離開某個螢幕、或 Windows 交接之後，
那個螢幕的 cursor 從 `Some` 變 `None`；若匯出端把 `None` 讀成「不做事」，
原生 sink 的 cursor Surface 就留著最後一張游標圖浮在凍住的桌面上，
VNC 也還在對客戶端廣告舊游標。這正是既有的缺口：
`set_cursor_visible` 今天只在 `update_cursor` 裡被呼叫（`virtio_gpu.rs:1802/1807`），
**只有 guest 明說時才動**；今天靠的是 guest 自願告知
（edk2 多半不用硬體游標；Linux 切 console 時 guest 會主動送 `resource_id=0`）。

    匯出端讀到 None    原生：隱藏 cursor slot     VNC：rfbSetCursor(NULL) + 停止 blend_cursor
    匯出端讀到 Some    原生：更新 cursor slot     VNC：兩路都發（§1.4.2）

**每次都宣告當下的完整狀態，不靠事件邊緣**——這樣交接的那一刻不需要特例，缺口自己消失。

**`CursorState` 是 {image, hotspot, position} 一個不可分的單位。**
現在有一條靠註解維持的順序規則（`virtio_gpu.rs:1817-1823`：hotspot 必須在 flush 之前設，
否則「這張圖配上一張的 hotspot」）。宣告完整狀態讓它變成結構性的，那條註解可以退休。

**這個模型從第一天就被測到**，不必等多 scanout：simplefb 螢幕與 virtio-gpu 螢幕並存的當下，
游標就該只出現在後者。也因此 `move_cursor` 忽略 `scanout_id` 必須修（§1.4.1）。

**殘留的假影（接受）**：指標跨螢幕的那一幀，兩個螢幕的畫格各自推送，
會有一瞬間游標在兩邊或都沒有。單指標下這是一幀的事，要消掉得跨螢幕同步，不值得。

---

## 4. 傳輸方式：它是「邊」，不是一層

**CPU copy / GPU copy / Zero copy 放不進 裝置→螢幕→匯出端 這棵樹，
因為它不是節點的屬性，是兩個節點之間那條邊的屬性。**

    螢幕決定        來源「能產出什麼」
    匯出端決定      「能吃什麼」
    傳輸方式        = 這條邊上協商的結果

### 4.1 三者是一道階梯，每階多一個約束

    CPU copy    無約束，永遠可退回（下界）
       ↑ 加：來源能匯出 dmabuf  ＋  匯出端能 import
    GPU copy    仍有轉換機會（Vulkan blit 順便換通道順序）
       ↑ 加：格式必須直接相符（沒有 blit 可以轉換）
    Zero copy

**GPU copy 與 Zero copy 的差別不是快慢，是「有沒有一個可以做格式轉換的步驟」：**

    CPU copy   轉換在生產端的 `px.swap(0,2)` ＋ sink 的無條件 swap —— **兩者靠一條不變式接起來，見 §4.4**
    GPU copy   轉換在 Vulkan blit 裡（順便做，不額外收費）
    Zero copy  **沒有地方可以轉** → 格式必須一開始就對

**這就是移除 ARGB8888（§2）和 zero-copy 同向的原因**：它把合成器推到唯一能被
zero-copy 的格式（AB24 = AHB RGBA_8888）上。今天 Android 視窗固定 RGBA_8888
且不能改成 BGRA（§2），所以只有 AB24/XB24 有資格。

**推論到 simplefb**：它的 DT 格式預設是 `a8r8g8b8` = AR24（§2），正是被排除的那一個，
所以 **simplefb 沒有 zero-copy 資格**。看起來只要把 `default_simplefb_format` 改成
`a8b8g8r8`（即 §2 對 virtio-gpu 做過的那次收斂）就解決了——**不要改，理由有三個，都查證過。**

**（1）三邊只有一邊讀 DT `format`：**

| | 從哪裡拿格式 | 改 DT 之後 |
|---|---|---|
| Linux | DT `format`；`a8b8g8r8` 在標準表裡（`include/linux/platform_data/simplefb.h:26` → `DRM_FORMAT_ABGR8888`，6.6 / 6.12 都有） | **會變** |
| EDK2 | **不讀 `format`**——`SimpleFbFdtClientLib.c` 只讀 `reg`/`height`/`width`，格式寫死 | 不變 |
| Windows | EDK2 交接的 GOP，不讀 DT | 不變 |

    GunyahPkg/Drivers/SimpleFbDxe/SimpleFbDxe.c:286-287
    /* SimpleFB runs on a8r8g8b8 (VIDEO_BPP32) for WoA devices */
    mDisplay.Mode->Info->PixelFormat = PixelBlueGreenRedReserved8BitPerColor;

**"for WoA devices" 表示 a8r8g8b8 是 Windows-on-ARM 的慣例，不是隨手挑的預設值。**
只改 crosvm 的 DT，結果是同一塊記憶體 Linux 寫 RGBA、firmware + Windows 寫 BGRA，
而 host 只有一套解讀 → 必有一邊翻色。要一致得連 EDK2 一起改，然後賭 Windows 的
Basic Display Driver 吃 RGB 的 GOP——而那句註解正暗示那不是走過的路。

**（2）就算三邊都吃，它不省工作，是把工作搬到退路上。**
simplefb 今天產出的 AR24 **正好就是管線的正規 BGRX**（§4.4），所以裸複製正確、VNC 免費對。
改成 AB24 之後 CPU 路反而要 swizzle——**而那正是想消掉的那次全幀複製**，
只是從快路搬到了每一條退路（dmabuf export 失敗會退 CPU）。

**（3）simplefb 的 zero-copy 本身可疑。**
它沒有畫格邊界（§3.4），zero-copy 等於讓合成器直接掃描一塊 guest 正在連續寫的記憶體，
撕裂從「每拍取樣可能取到寫一半」變成「持續撕」。

**→ 第 10 步瞄準 GPU copy，不是 zero-copy。**blit 順便做格式轉換（不額外收費），
拿到幾乎全部的好處，而且完全不需要動 DT。

### 4.2 解耦方式：各層只宣告自己的能力

    螢幕宣告        我能產出：Cpu | Dmabuf(fourcc, modifier)
    匯出端宣告      我能吃：  Cpu | Dmabuf-可blit轉換 | Dmabuf-需格式相符
    邊上協商        取交集的最高階

**沒有一層需要知道對方是誰。** 新增一個渲染器不必動任何 sink，
新增一個 sink 不必動任何渲染器。

**Zero-copy 的 TODO 標在匯出端的能力宣告上**（「我能直接呈現這些 fourcc 的 dmabuf」），
不標在設定、也不標在螢幕上。**今天所有 sink 都宣告「不能」，所以它永遠不會被選中
——路徑留著但不啟用。**

### 4.3 目前各端的能力（實測）

| | 能產出 / 能吃 | 依據 |
|---|---|---|
| virtio-gpu 3D | Dmabuf（export 可能失敗 → 退 Cpu） | `try_import_resource_to_display` 的 fallback |
| virtio-gpu 2D | Cpu（pool-scanout 有 udmabuf 路徑） | `resource_create_blob` |
| simplefb | **Cpu only**（產出已是正規 BGRX，所以不需要轉換，見 §4.4） | `simplefb_display.rs` 硬寫，不問探測 |
| NativeDisplay | Cpu + Dmabuf-可blit | `import_resource` + `flip_to` + `android_display_is_vulkan_blit_available` |
| VNC | Cpu only（探測已誠實回 false，`:563`） | 沒實作 GPU 半邊 |

**所以今天唯一的 GPU copy 是 `virtio-gpu 3D × NativeDisplay`。**

### 4.4 兩條路用不同的顏色約定

**顏色今天是對的**（Windows simplefb-only 實測正確），而且是正確地對，不是碰巧。
但**CPU 路和 GPU 路維持正確的方式不一樣**，而這正是 §3.2 要把 fourcc 放進螢幕定義的理由：

| | 怎麼決定顏色 | 依據 |
|---|---|---|
| CPU 路 | **隱含不變式**：一律假設輸入是 BGRX，sink 無條件 swap | `swapRedBlueInPlace` `cpp:1504`／`:1800` |
| GPU / zero-copy 路 | **顯式 fourcc**：fd 的 fourcc 選 VkFormat | `vkFormatFromDrmFourcc` `cpp:617-626` |

不變式由生產端維持：

    virtio-gpu   needs_swizzle 依 guest 宣告的 fourcc 把 AB24(R-first) 轉成 BGRX   virtio_gpu.rs:757
    simplefb     DT 宣告 a8r8g8b8 = AR24 = **本來就是 BGRX** → 不轉，裸複製正確
    VNC sink     serverFormat 就是 BGRX → 不轉
    原生 sink    無條件 BGRX → RGBA_8888

**風險在切換路徑的那一刻，而且是安靜的。**
第 10 步讓 simplefb 走 udmabuf，等於把它從左欄搬到右欄：
sink 不再無條件 swap，改成照宣告的 fourcc 選 VkFormat。
**宣告 AR24 → `B8G8R8A8_UNORM` → 正確；宣告錯 → 整張 R↔B 反，沒有任何錯誤訊息。**
同一個陷阱也適用於任何新來源：它必須知道自己該滿足哪一邊的約定，
而今天「該滿足哪一邊」是靠讀註解知道的。

**所以結論不變，理由變了**：fourcc 是螢幕定義的欄位（§3.2），
讓「這個螢幕產出什麼位元組順序」變成宣告出來的資料，
而不是一條寫在 C++ 註解裡、靠每個新來源自己去讀的不變式。

### 4.5 watcher 不是第二個軸（決定）

嚴格說有 `{none, cpu, gpu} watcher × {cpu, gpu, zero} copy`，
但**它不是自由網格，有一條單向依賴**：

    gpu watcher ──需要──> dmabuf ──也正是──> gpu/zero copy 的前提

- `cpu watcher × gpu copy`：合理
- `gpu watcher × cpu copy`：存在但沒有人會選——為了 watcher 把 dmabuf import 進來，傳輸卻不用它
- 傳輸是**邊**的屬性、會在執行期協商（export 失敗就快取 `CpuFallback`）；
  watcher 是**來源**的屬性、選一次。**GPU watcher 讓來源依賴一個協商可能剛判定不能用的資源**

**決定：watcher 固定 CPU，用分塊雜湊。**理由：

- **不需要保存上一幀**。存每塊的 u64 雜湊即可：1400×1050 切 64×64 約 360 塊 ＝ 2.9 KB，
  取代 5.88 MB 的 `last_buf`，靜止畫面每拍寫入為零。
  碰撞造成漏一幀的機率在 u64 下不會發生，而且就算發生也只是「一張畫面晚一拍」，
  下一次變動自動修正
- **讀那一次躲不掉**（5.88 MB／拍，30Hz ≈ 176 MB/s），但用
  `guest_mem.get_slice_at_addr()`（`vm_memory/src/guest_memory.rs:1394`）對 host 映射直接比對，
  連現在 `read_exact_at_addr` 那一次整張複製都省掉
- **GPU watcher 在統一記憶體的手機上不省流量，只是換發起者**，而且要在**靜止畫面**
  每 33 ms 把 GPU 叫醒一次——那正是 watcher 存在的理由；還要付一次 GPU→CPU readback
  （要嘛序列化「要不要呈現」的決定，要嘛再欠一幀延遲），而且排在 udmabuf 之後才可用
- **退回 CPU 傳輸時仍需要 CPU 版**，所以 GPU watcher 是多一份實作，不是換掉一份

**一個要誠實記下的張力**：`cpu watcher × cpu copy` 這一格可以融合成一遍
（讀一次，同時算雜湊、同時把變動的塊寫進 sink 的 buffer），省掉對 guest 記憶體的第二次讀。
**介面維持解耦，融合只當那一格的內部最佳化，而且先不要做**——
先量到「第二次讀真的是瓶頸」再說，否則就是為了省一次讀把剛拆開的兩個軸黏回去。

### 4.6 為什麼不做成使用者設定

兩個代價：驗收矩陣乘一次；不可能的組合要靠人記得不去測。
協商的話，不可能的組合在型別上就選不出來。

- 保留**除錯用**覆寫（比照 `GPU_SCANOUT_FORCE_TRANSFER=1`），那不是產品設定
- **矩陣每格記錄「實際協商到什麼」**——矩陣因此同時是回歸測試：協商結果變了會被看到

**使用者能選的東西，必須是他選了就一定會生效的東西。** 傳輸方式不是——
它取決於來源能不能匯出、匯出端能不能吃、格式合不合。
**使用者選「Zero Copy」而系統靜默降級到 CPU copy，就是「看起來成功了」那類失效。**

面板形狀：

    匯出端         VNC / 原生顯示                    ← 選
    啟用輸入裝置    預設 on                          ← 選
    可調屬性        依螢幕定義而異（§3.2）            ← 選
    ────────────────────────────────
    實際傳輸       GPU copy（協商）                  ← **唯讀，顯示結果**
    [進階] 傳輸上限  自動 ▾                          ← 除錯用，預設自動

**覆寫的語意必須是「上限」，不是「選擇」：**

    自動（預設）      協商結果
    上限 = GPU copy   即使可以 zero-copy 也不用
    上限 = CPU copy   即使可以 GPU blit 也不用（等同 GPU_SCANOUT_FORCE_TRANSFER=1）

**只能往下限制，不能往上要求。** 「要求 GPU copy」在來源匯不出 dmabuf 時無法滿足，
那時只有靜默降級（壞）或明確失敗（吵）兩種行為；**做成上限就沒有這個問題，任何值都一定可滿足。**

### 4.7 傳輸不依賴裝置層

**最容易搞錯的一點**：simplefb 和 virtio-gpu 都可能產出 dmabuf
（simplefb 透過 udmabuf over memfd，§7）。**所以傳輸能力屬於螢幕與匯出端，
不屬於裝置層。** 把它掛在裝置層會讓「simplefb 永遠 CPU」變成架構事實，
而它其實只是今天沒實作。

---

## 5. 輸入

### 5.1 裝置配置

    VM 全域        keyboard ×1        mouse（相對）×1
    每 guest 輸出   multi-touch ×1     absolute-mouse ×1     ← name= 帶通道身分

**依據**：鍵盤沒有輸出綁定，合成器按焦點送；相對指標跨輸出移動、焦點跟著走——
兩者都是 VM 全域的。**絕對裝置的座標只在特定輸出的幾何下有意義，本質上是 per-output。**

**注意是「每 guest 輸出」，不是「每 host 螢幕」**——見 §5.2。

**相對滑鼠的一個後果要寫進 UI 行為**：guest 的指標位置才是權威的。
app 應只轉送「有 Android 焦點的那個視窗」的相對移動，否則兩個視窗會互相打架。

### 5.2 絕對裝置綁 guest 的輸出，不是綁 host 的螢幕

**這是這一版最不直覺的一點。**simplefb 與 virtio-gpu 在 host 側是兩個螢幕，
**但在 guest 裡未必是兩個輸出**：§1.1.1 實測 kwin 開了 card0 卻回報 `Number of Screens: 1`。
所以給 simplefb 螢幕配一組絕對裝置，在那個 Linux 桌面配置下**找不到能對應的輸出**；
Windows 下則反過來（simplefb 才是那個輸出）。

**evdev 和 HID 都沒有「我屬於第 N 個螢幕」的欄位**——裝置無法自我宣告。
映射一律是 guest 端設定，且一律以**裝置名字**當 key：

    Linux/Wayland(kwin)  設定 → 輸入裝置 → 觸控螢幕 → 對應螢幕；按裝置名字存
    Linux/X11            xinput map-to-output <device> <output>
    Windows              控制台 → Tablet PC 設定 → Setup，逐螢幕點按指認（純手動）

**所以 crosvm 的 `--input ...[name=N]` 是唯一的槓桿，而且名字必須跨開機穩定**
（名字一變，使用者的映射設定就失效）。建議形式：`DroidVM Touch (display-0)`，
與螢幕定義的 `stable_id`（§3.2）同源。

**guest 輸出數 > 1 時，每個 guest OS 都需要一次性的手動設定步驟，
那是產品面的持續成本，要寫進使用者文件。**

### 5.3 每個螢幕有自己的設定（決定）

    設定 → 圖形 → 每個螢幕：
        匯出端         VNC / 原生顯示
        啟用輸入裝置    預設 on
        可調屬性        依螢幕定義（§3.2）：simplefb 給輪詢率，virtio-gpu 給解析度/DPI/refresh

- **app 開啟該顯示時可選**
- **切換匯出端 = 重新初始化該通道**
- **切換「啟用輸入裝置」需要重建 crosvm 的 `--input` 裝置集合，而那是開機時固定的
  → 實際上是整台 VM 重啟。**UI 要照實講，不能講成熱切換
  （除非哪天有 virtio-input 熱插拔，今天沒有）。
  實作後果：關閉時該螢幕不建立 `multi-touch` / `absolute-mouse`，
  鍵盤與相對滑鼠是 VM 全域的，不受此屬性影響
- **傳輸方式不在這裡**——它是協商結果（§4.6），但**協商到什麼要顯示出來**

---

## 6. 遷移順序

每一步可單獨出貨、單獨驗證。純重構的步驟要寫明**用什麼儀器**驗——
「逐位元組相同」沒有儀器就等於沒有驗收條件。

| # | 動作 | 驗收條件（含儀器） |
|---|---|---|
| 0 | ~~VNC 的 `is_dmabuf_import_supported()` → `false`~~ | **已實作，未 commit**（`gpu_display_vnc.rs:563`） |
| 1 | ~~VNC / simplefb：沒有消費者就短路~~ | **已實作，未 commit**（`:571`、`simplefb_display.rs:243`）。價值範圍見 §1.3.1，量測判準見 §9 |
| 2 | ~~驗 simplefb + 原生顯示的顏色~~ | **已由觀測回答：正確**（Windows simplefb-only）。原因見 §4.4——BGRX 不變式；推論錯在哪見 §8（七） |
| 3 | 原生 sink 實作 `has_consumer` | 離開顯示畫面後 simplefb 迴圈不再讀 guest 記憶體（`simpleperf` 分「在看／不在看」兩格） |
| 4 | 引入 `Screen` 定義 + `ScanoutFrame`（含 fourcc 與 damage），兩個來源都改用 | **純重構**：對 sink 收到的 buffer 逐幀取雜湊，改動前後序列相同 |
| 5 | simplefb watcher：分塊雜湊取代無條件複製（§4.5） | 靜止畫面每拍寫入為零、下游零推送；`last_changed_at` 會動；接上匯出端時立刻收到完整畫格；**判準雙向，見 §9** |
| 6 | **匯出端 per-screen**：`display_backends` 從 fallback 清單改成 per-screen 綁定；`VncConfig` 變 list；android service name per-screen。**app 端同步 list 化** | VNC + 原生同時開時兩個都活（今天 VNC 靜默贏，§1.4）；單螢幕行為不變 |
| 7 | 刪掉仲裁（§3.3 那一整組） | 行為不變；`external_scanout.rs` 整檔移除 |
| 8 | 游標變螢幕定義的欄位（§3.5）+ `move_cursor` 改用 `scanout_id` | 游標只出現在 virtio-gpu 螢幕；切到 simplefb 後**游標消失而不是留在畫面上** |
| 9 | 每螢幕「啟用輸入裝置」屬性（§5.3） | 關閉時該通道無絕對裝置；UI 明講需要重啟 VM |
| 10 | simplefb 走 udmabuf → 能產 `Dmabuf`（**目標是 GPU copy，不是 zero-copy，見 §4.1**） | simplefb + 原生走 GPU blit；**顏色不變**——這一步把 simplefb 從「無條件 swap」搬到「照 fourcc 選 VkFormat」，宣告錯就整張 R↔B 反且不報錯（§4.4） |
| 11 | VNC 實作 GPU 半邊 | VNC 能吃 dmabuf；畫面與顏色不變；**guest vblank 不隨 VNC 客戶端有無而變**（§7） |
| 12 | VNC sink 內部切 encoder / transport | **純重構**：錄 RFB 位元組流比對 |
| 13 | `HwEncoder`（MediaCodec）+ H.264 側通道 | 新功能，不影響既有 RFB 客戶端；**對遠端價值大得多**（§1.3.1） |
| — | **多 scanout 啟用** | **使用者決定先不做**；第 6 步做完後阻礙只剩 AIDL 的 serviceName list |

**優先度**：第 3 步便宜且直接影響今天的使用者（原生是 app 的兩個顯示模式之一）；
第 6 步修掉「VNC + 原生同時開 → 原生永遠空白」；第 5、10 步影響 Windows guest 的桌面成本（§1.3）。

---

## 7. 未驗的前提

| 前提 | 影響 | 怎麼驗 |
|---|---|---|
| ~~simplefb + 原生是不是 R↔B 反~~ | — | **已答：不是**（§4.4、§8（七）） |
| **simplefb 走 dmabuf 之後宣告的 fourcc 對不對** | 第 10 步；宣告錯是安靜的 R↔B 反 | 與 CPU 路並排比對同一張畫面，不能只看「有畫面」 |
| udmabuf 能否包 Gunyah SHARE 的 `SharedFramebuffer` | 第 10 步整條 | **比想像便宜**：`UdmabufDriver` 已在 `VirtioGpu` 裡，simplefb 區域就在 `GuestMemory`（bridge 已用 `read_exact_at_addr` 讀它），直接對它 `create_udmabuf` 即可。硬條件只有 offset/size 頁對齊 |
| WC 寫入對 GPU 讀取的可見性 | 第 10、11 步 | 比照 pool 路徑的 `linear_verified` |
| **VNC 拿到 GPU 半邊後會不會對 guest 施加回壓** | 第 11 步 | `register_flip_fences`/`complete_flip_fences` 讓 sink 的呈現完成 gate guest 的 vblank（已知：guest kwin vblank = 手機面板刷新率）。VNC 今天是 CPU 路、立刻回；加上 GPU 半邊等於把一條網路 sink 接進 guest 的 vblank 迴路 |
| 多螢幕時誰的 fence 擋住 guest | 第 6 步 | 同上；1:1 且單 scanout 之下暫時不會遇到 |
| VNC 的 700 MB/s 推算 | 第 1 步的價值判斷 | `simpleperf` 分「有連線 / 無連線」兩格 |
| CPU watcher 的 idle 成本（推算 176 MB/s 讀） | 第 5 步；以及要不要考慮 §4.5 的融合 | 量了再決定，不要先優化 |
| simplefb 獨佔 sink（無 GPU）那條路 | 第 6、10 步 | 目前所有 simplefb 觀測都在有 `--gpu` 之下，走的是 `GpuDevice` |
| MediaCodec input Surface 能否由 Vulkan 餵 | 第 13 步 | `createTargetImage(AHardwareBuffer*)` 吃任意 AHB，機制上可行，未驗 |

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

Windows 正好相反（§1.1）。**碼裡的註解本來就寫對了，是我沒讀到它就先推論。**

**（三）一句過時註解已修**（`crosvm b2444fd86`）：`src/crosvm/sys/linux.rs` 原本說 simplefb 區域
*"backed by a DMA-BUF from the DMA heap and shared via map_cma_region"*，實際不是。
**照那句讀，GPU import 看起來免費（fd 現成），實際上要先建 udmabuf——工作量估計差很多。**

**（四）「simplefb ↔ virtio-gpu 的仲裁是必要的，不該拆」——結論被換掉，但推理沒有錯。**

上一版的論證在**「一台 VM 只有一個匯出端」**這個前提下完全成立：
兩個來源共用一個出口，就必須有人決定誰佔用它。
**換掉的是前提，不是推理。**匯出端 per-screen 之後兩個來源各有出口，仲裁失去對象。

**這個錯誤形態和（一）（二）不同，值得分開記**：前兩個是「事實查錯了」，
這一個是**「事實都對，但把一個當時的實作限制當成了必須維持的性質」**。
`ExternalScanout` 是真的、註解是對的、grace timer 是必要的——**在那個前提下。**
分辨方法：問「這個限制是協定給的，還是我們自己的程式碼給的？」
協定給的（guest 會交接顯示權）留下；程式碼給的（只有一個 sink）可以改。

**（五）「單 scanout 之下 `move_cursor` 忽略 `scanout_id` 結果相同，現在不用改」——錯。**

那句話的前提也是「兩個來源合併成一個螢幕」。兩個螢幕並存之後，
游標的歸屬**就是**靠比對 `scanout_id` 決定的（§3.5），所以那個比對從第一天就必須真的發生。

**（六）「CPU copy 那一階一定有轉換的機會」——成立，但轉換不在我以為的位置。**

`px.swap(0,2)`（`virtio_gpu.rs:762`）是**生產端**維持 BGRX 不變式的地方，不是「唯一的轉換點」。
真正把顏色交給 Android 的轉換在 sink：`swapRedBlueInPlace`（`cpp:1504`），無條件執行。

**（七）「simplefb + 原生顯示應該是 R↔B 反的」——錯，而且錯得很難看。**

推論鏈是：simplefb 宣告 a8r8g8b8（B,G,R,A）→ Android 視窗是 RGBA_8888（R,G,B,A）→
simplefb 的兩條複製路都是裸複製 → 所以應該反。
**三個前提各自都是對的，結論卻錯，因為漏了第四個環節**：
原生 sink 在 post 前無條件 `swapRedBlueInPlace`，而整條 CPU 管線的正規順序就是 BGRX，
simplefb 產出的**正好就是**正規順序——所以它不需要轉換，裸複製是正確的。

**錯誤形態和（二）完全同型，這是第二次**：
`virtio_gpu.rs:742-744` 的註解就寫著 *"the Android backend's swapRedBlueInPlace converts
BGRX -> RGBA_8888"*——**就在我讀過並且引用了後半段的那個 hunk 裡**。
我引用了它關於 fourcc 的部分，卻沒把它關於 sink 的部分讀進去。

**可以推廣的那一條**：*"全樹只有一處"* 這種話，只有在**全樹**真的搜過才能說。
我搜的是 `--include=*.rs`，而這條管線跨 FFI 到 C++。
→ **在跨語言邊界的管線上宣告「只有一處」之前，先問這條管線經過幾種語言。**

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
