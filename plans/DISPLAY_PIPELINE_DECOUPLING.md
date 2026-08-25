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
- zero-copy 留好路徑並標 TODO，不新增設定列舉——邊協定已設計（§4.7），排在最後

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

**VNC**（`vnc_server_bridge.c` 的 `vnc_server_composite`）：原本每幀 `memcpy` 整張 +
`rfbMarkRectAsModified(0,0,w,h)`。**`crosvm 0b2680cba` 起 sink 自帶 damage**：
32-row band 對 `last_clean` 比對，只複製、只標記變了的 band——8gen3 實測，
靜止桌面 12 秒 banded <0.1 MB、舊版 1.7–14 MB（不引比值，因為基線不是穩定量，§9）。
同 commit 修掉 resize 使 `last_clean` 失效的黑屏洞與 `restore_rect` 的越界寫。
零客戶端的複製浪費：**閘只放在 simplefb 迴圈（timer 生產者）**，
VNC flush 路的短路被刻意拿掉——理由見 §3.4 的「掉格需要再供給」規則。

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
                              （legacy SET_SCANOUT 沒有 scanout_data → 視為 XR24＝正規 BGRX，§4.4）

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
- **沒有匯出端時降到 liveness 頻率，不是完全停**：~1 Hz、只算雜湊、只更新 `last_changed_at`，
  不產畫格（≈6 MB/s 的讀，可忽略）。**不能完全停的理由是自洽性**：§1.1 拿 `last_changed_at`
  回答「使用者怎麼知道哪個螢幕是活的」，而他最需要這個值的時刻正是**還沒接上**匯出端的時候——
  完全停了它就在那一刻是舊的。全速輪詢只在有匯出端時發生，那仍是這個模型最大的一筆省。
  （virtio-gpu 螢幕不受此影響：它的 `last_changed_at` 由 flush 事件免費更新）

**「掉格需要再供給機制」（`crosvm 0b2680cba` 實測得到的規則）**：
「沒消費者就跳過」只在**生產者是 timer** 時安全——下一拍會重新供給，消費者回來最多晚 33 ms。
flush 驅動的畫格掉了就**永遠不會再來**：實測客戶端跨解析度變更斷開再連 → 永久黑屏 0 bytes/s。
所以 `has_consumer` 的閘只准放在 pull/watcher 側；push 側要跳過，先要有
「消費者到場時重新呈現」的機制（sink 已留著 `last_clean`，缺的是 newClientHook 那條線）——
**這和上面「匯出端接上時強制送完整畫格」是同一個需求的兩面**，做第 6 步時一起收。

**sink 側 band 比對與來源側 watcher damage 是疊加不是重複**：
來源 damage 省掉的是它上游的讀與複製（sink 根本不被叫醒）；
sink 比對照顧的是不帶 damage 的來源（virtio-gpu flush 今天送整張），兩層都留。

**驗證這件事有它自己的界線，見 §9**——結構論證擋得住設計錯誤，擋不住差一錯誤。
§9 那套判準已有一個活例：`0b2680cba` 的量測（每臂四次開機、交錯排序、
基線不穩就不引比值、地板由舊 binary 自己的 reconnect 格獨立釘住）。

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
       ↑ 加：格式必須一開始就對  ＋  邊的方向反轉（§4.7）
    Zero copy   ＝ Direct：sink 出借 render target，內容不過邊

**約束的階梯成立，但第三階的機制不是「sink 直接呈現來源的 dmabuf」**——
那個 import 方向在這個平台上不存在（gralloc 不收捐贈，§4.7 查證），
第三階是方向反轉的 Direct。

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

    螢幕宣告        我能產出：Cpu | Dmabuf(fourcc, modifier)；以及能否落在外部 render target 上（§4.7）
    匯出端宣告      我能吃：  Cpu | Dmabuf-可blit轉換；以及能否出借 render target（provide_render_targets，§4.7）
    邊上協商        取交集的最高階

**沒有一層需要知道對方是誰。** 新增一個渲染器不必動任何 sink，
新增一個 sink 不必動任何渲染器。

**Zero-copy 的 TODO 標在匯出端的 `provide_render_targets` 宣告上**，
不標在設定、也不標在螢幕上。**今天沒有 sink 宣告它，所以 Direct 永遠不會被選中
——路徑留著但不啟用。**
（上一版把這個 TODO 寫成「我能直接呈現這些 fourcc 的 dmabuf」——
那是 import 方向，已被 §4.7 否證；能力的形狀是「出借」，不是「收下」。）

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

**迴圈形狀（第 5 步照抄）**：每拍逐 **32-row band**「hash → 沒變就跳 → 變了馬上 copy（還在 cache）→
存**copy 出來的位元組**的 hash → 記 damage」，掃完 damage 非空才呼叫 present_frame——
沒有事件匯流排，「發事件」就是這一個呼叫；空 damage 的一拍下游完全不動。
（原寫 64×64 tile；改 band 的理由：粒度的唯一消費者是「要不要跳過」這個決定，
band 讓雜湊順著記憶體走，而且和 VNC sink 自己的 banding 同構。）
存 copy-bytes 的 hash 而非第一次算的：guest 並發寫、無同步，hash 與 copy 之間內容可能又變，
存前者會讓下一拍誤判重 copy（不漏、但多做工，症狀是動態畫面頻寬比預期高）；存後者自愈。
最壞情況（全畫面在動）成本 ≈ 舊的無條件複製 + 一趟 cache 內的雜湊運算，不反噬。

**damage 非空時 present 的是完整畫格，不是只有變的 band**：原生 sink 的 buffer 會輪替
（沒有 buffer-age 追蹤），窄複製會留下舊區塊。**「跳過」才是贏的地方，「窄複製」是陷阱**；
窄複製要等 buffer-age（或 setDamageRegion 那類真正的 rect 消費者）才合法。
watcher 這邊靠 `read_buf` 跨拍持久解掉同一個問題：沒變的 band 留著上次的內容，
所以 guest 記憶體只讀變了的部分，present 卻永遠是完整畫格。

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

### 4.7 Zero-copy：方向反轉的邊（設計；§6 第 14 步，排最後）

**Zero-copy 不是同一條流的第三階，它把邊的方向反過來：**

    Copy 模式     內容向前流。來源產畫格 → sink 消費；呈現 buffer 是 sink 自己的，
                  最後畫進呈現 buffer 的都是 host（CPU memcpy 或 host GPU blit）
    Direct 模式   buffer 向前借。sink 出借畫布（AHB）→ guest 驅動的渲染直接落在上面；
                  acquire fence 向前（內容好了）、release fence 向後（compositor 讀完了）
                  **內容不過邊**

對外它仍顯示成階梯的第三階（§4.6 面板不變）；對內它是另一種邊協定。
能力宣告因此加一個方向（§4.2 原本只有「能吃什麼」）：

    sink 宣告      我能出借：provide_render_targets { fourcc: [AB24/XB24], usage, 幾何 }
                   只有 NativeDisplay 會宣告；VNC 要讀像素，永不
    來源宣告       can_target_external_buffer（per route，見下表）

**方向由物理決定，不是設計選擇：AHB 只能由 host gralloc 配置，包不了 guest 記憶體。**

反方向（「從 guest shared region 挖一塊 → 包成 AHB → app 呈現 → guest 直畫」）查過，不成立：

    AHardwareBuffer_allocate()           記憶體是 gralloc 給的，不能自帶
    AHardwareBuffer_createFromHandle()   收的是 native_handle，且要裝置 mapper 認得——
                                         QTI mapper 驗自家 private_handle_t，udmabuf 包的
                                         手工 handle 過不了 importBuffer；偽造 handle 正是
                                         「Skia abort → surfaceflinger 崩 → 軟重啟」的領域（§2）
    今天樹裡所有 AHB                      全部來自 dequeueBuffer → getHardwareBuffer
                                         （cpp:1678/1718），沒有一個不是 gralloc 鑄的

**gralloc 是唯一的鑄幣者，而它不收捐贈。**那條管線四段裡三段其實成立
（udmabuf ✓、turnip 吃 raw dmabuf ✓、guest renderer 照畫 ✓），只有「SF 呈現 guest 記憶體」
沒有入口——把那格換成一次 GPU blit，它就是第 10 步的 GPU copy：
零次 CPU 複製、一次 GPU 複製，host GPU 直接取樣 guest 記憶體。**這就是 guest-memory-backed
來源（pool scanout、simplefb）的天花板**，與 §4.1 的決定一致。

**而正方向比看起來便宜：過邊的是 handle，不是記憶體。**
三條 GPU route 的渲染都在 host GPU 上執行，guest 只發命令——Direct 模式下
guest 只需要 resource_id 這個把手，AHB 的位元組不需要映射進 guest，
Gunyah memparcel／映射數量上限都不用碰
（除非 guest 要 CPU 存取＝`BLOB_FLAG_USE_MAPPABLE`，合成器對 scanout 不會要）。

**guest 不需要知道（決定）。** 不加新的握手協定；guest 收到的「能」就是它已經收到的東西：

    plane 清單已收斂 AB24（§2）           → 告訴合成器該產什麼格式
    blob resource + SET_SCANOUT_BLOB      → guest 本來的初始化流程，一個位元組不改

變的是 host 的配置策略：邊協商到 Direct 時，合格的 scanout blob 在
`resource_create_blob` 就配成 AHB-backed；否則 heap。
**guest 永遠不會和一個它看不見的能力失同步**，edk2 與舊 guest 自動留在 Copy。

**模式是「當前綁著的 scanout 資源合格嗎」的函數，每次綁定事件重新評估：**

    edk2 / 開機前期    2D transfer 資源，不合格          → Copy（host 搬圖）
    桌面起來           合成器綁 AB24 blob（AHB-backed）  → 升級 Direct
    ctrl+alt+2         fbcon 綁 XR24 / 非 blob           → 降級 Copy
    renderer 消失      KMS 回 fbcon 或 scanout unbound   → 降級 Copy
    OS 交接            device reset（mod.rs:1630 那個）  → 重新評估

**觸發器和被刪掉的仲裁同一個形狀**——「每次綁定重新評估，判定依據是協定事實不是啟發式」
（§1.1 的原話）。仲裁死了，它的觸發器以每條邊的模式切換重生；沒有 timer、沒有猜。
降級永遠可行，因為 CPU copy 是無條件下界（§4.1）。

**host 實作三件事，兩件已存在：**

    呈現       ASurfaceTransaction_setBuffer(ahb, acquire_fence)
               —— 已存在（cpp:1808-1826），今天 fence 傳 -1；Direct 要把 route 的
               完成 fence 接上（gfxstream/venus：host Vk fence；drm2kgsl：kgsl timestamp）
    回壓       take_flip_completion_fence 的契約一字不差就是 release fence
               （"signals when the display is done reading, i.e. when the guest may
               safely render into it again"，lib.rs:258）→ 完成 virtio flip fence
               → guest KMS 才重用 buffer。register/complete_flip_fences 機制現成
    新東西     resource_id → AHB 的配置與綁定（per route，見下表）

**Event 不會消失**——四條 route 的呈現都走 virtio-gpu 的 scanout 協定，flip/flush 就是
present 事件；zero-copy 拿掉的是複製點，不是事件。真正的角落是「綁一次就不再 flush 的
front-buffer 直渲 guest」：那個 scanout 就是 pull 來源，`frame_boundaries=false` + watcher
（§3.4）——模型已經有這個槽，不需要新機制；watcher 的產出從「複製」變成「戳 compositor 重合成」。

per-route 可行性：

| route | 怎麼落在 AHB 上 | 距離 |
|---|---|---|
| gfxstream | host renderer，colorbuffer 綁 AHB（cuttlefish 先例） | 最近 |
| venus | swapchain image 要 AHB-backed（turnip AHB import，同 §7 MediaCodec 那條假設） | 中 |
| drm2kgsl | 今天 scanout BO 在 guest pool＝guest 記憶體，**永不合格**；要先改成 host 提供的 blob，kgsl 再 import AHB 的 dmabuf | 最遠 |
| 2D | 沒有 guest 渲染能落在外部 buffer 上 | 永不 |

**設定面不變**（§4.6）：Direct 顯示成「Zero copy（協商）」，唯讀。
但模式是 per-bind 的，所以矩陣每格記錄的是「觀察到的模式集合」，不是單一值。
換匯出端 = 通道重初始化（§5.3）→ mode-set → 合成器重建 scanout buffer → 新配置策略生效，
所以配置策略和模式不會失同步。

### 4.8 傳輸不依賴裝置層

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

### 5.3 圖形設定的形狀（2026-08-25 使用者定版）

**圖形分頁 = 兩大塊平級裝置，內部結構幾乎相同**：

    Virtio-GPU 塊
        啟用顯示設備        ← 這個裝置的螢幕（scanout）存在與否
        渲染器 section      2D / Virglrenderer / GfxStream ＋ 各自子設定
                            （圖形 API／主機驅動／顯存…——既有的三級 GPU 設定重組進來）
        顯示設定            解析度 / 刷新率 / DPI（per-device，不再與 SimpleFB 共用）
        匯出設定            匯出端(無/原生/VNC) ＋ 傳輸 ＋ 啟用輸入裝置

    SimpleFB 塊
        啟用顯示設備
        （無渲染器 section——它天生 2D）
        顯示設定            解析度 / 輪詢率（poll-hz，即它的「刷新率」；DT 無 DPI）
        匯出設定            同上

**「啟用顯示設備」＝整個裝置的開關（2026-08-25 使用者二次定版）**：
Virtio-GPU 塊關掉 → `--gpu` 參數整個消失（含渲染器），只剩 `--simplefb`。
**零 scanout 純加速的狀態不存在**——使用者實測那個模式下 guest 桌面根本起不來，
它從來不是可用配置；一度提議的 `no-scanout` 旗標與「移除預設 scanout 退路」都作廢。
渲染器 section 是**裝置內的設定**（2D＝無加速、Virgl/GfxStream＝加速），不是獨立軸；
舊 `gpu_enabled` 布林折進遷移（gpu_enabled 而顯示關 → 裝置關，本來就沒在動的組合）。

**「定義了就存在」落在旗標層**：`--gpu` 定義了＝裝置存在且有 scanout（app 一律連
`displays=` 一起發）；`--simplefb` 定義了＝那個裝置存在。沒定義＝沒有。
**CLI 形狀已確認（使用者選定）**：維持 `--gpu` 與 `--simplefb` 兩個旗標、語意與內部結構平級——
不做「--gpu 可重複、simplefb 當一種 type」的統一旗標家族。crosvm 側唯一要動的是
無綁定時的 Stub 靜音（ERROR 垃圾 → 一行 INFO）。

**UI 命名**：匯出設定裡的傳輸控制叫「**傳輸管線**」（值與 §5.4 上限語意不變；
CLI 鍵維持 `transport-cap`）。

**傳輸管線選單定版（2026-08-25 使用者定，取代先前的 自動/上限 寫法）**：
選項本身就是階梯、**選的是天花板**（§5.4 上限語意），最高階即「自動」，不設獨立自動項：

    原生顯示    CPU Copy / GPU Copy / Zero Copy
    VNC        CPU Copy / GPU Copy / GPU Copy(硬體編碼)

未實作的階顯示但停用（標「未實作」）：原生的 Zero Copy（本輪排除）、
VNC 的兩個 GPU 階（隨 11/13 步落地啟用）。預設＝當下最高可用階（原生=GPU Copy、VNC=CPU Copy）。

**選單跟著匯出端、不跟裝置（2026-08-25 使用者釐清）**：兩塊的匯出端各自獨立、
都能選 VNC；選了 VNC 就出現 VNC 的三階（含硬編），與這塊是 virtio-gpu 還是 simplefb 無關。
**simplefb＋原生沒有 Zero Copy 這個選項**（使用者定；§4.1/§4.7 的結構論證：guest-memory-backed，
AHB 包不了 guest 記憶體）——不是停用，是**不出現**，該格選單就兩階 CPU Copy / GPU Copy。
完整矩陣：virtio-gpu＋原生 = CPU/GPU/Zero*；simplefb＋原生 = CPU/GPU；任一塊＋VNC = CPU/GPU*/硬編*。

**VNC 的「GPU」不是只做 blit——是 blit 進 MediaCodec 硬編 H.264**：第 11 步（VNC GPU 半邊）
與第 13 步（HwEncoder）因此是同一條路的兩段，H.264 的交付方式（RFB Open H.264 encoding 50
vs 側通道）是第 13 步的設計題。`transport-cap` 枚舉屆時對 VNC 綁定加 `gpu` 值（加法擴充，
不影響已釘的 `auto|cpu` 契約）。
**Zero-copy 不在本次重構範圍**（§4.7 設計保留，第 14 步另議）。

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
| 0 | ~~VNC 的 `is_dmabuf_import_supported()` → `false`~~ | **已收：`crosvm 0b2680cba`** |
| 1 | ~~沒有消費者就短路~~ | **已收：`crosvm 0b2680cba`，且範圍修正**——閘只在 simplefb 迴圈（timer 生產者）；VNC flush 路的短路被刻意拿掉（§3.4「掉格需要再供給」）。同 commit 額外給 VNC sink 32-row band damage（8gen3 實測）。價值範圍見 §1.3.1 |
| 2 | ~~驗 simplefb + 原生顯示的顏色~~ | **已由觀測回答：正確**（Windows simplefb-only）。原因見 §4.4——BGRX 不變式；推論錯在哪見 §8（七） |
| 3 | ~~原生 sink 實作 `has_consumer`~~ | **已收 + 裝置驗收 PASS（2026-08-25，5567）**：`Virtualization a049e2a` + `crosvm 0a1deb731`。原生 sink、無 app 連接：橋執行緒 1.73% CPU（liveness 態；執行緒被 libbinder 改名 `Binder:crosvm`，靠 syscall=nanosleep 指認）；對照「說謊的預設 true」的反事實成本 27.11%（16×）；VNC 無消費者 1.56% ≈ 原生無 app 1.73%，兩 sink 收斂同一態。**殘留**：app 真的 attach → true 的正向臂未單測（日常使用即覆蓋） |
| 4 | ~~引入 `ScanoutFrame`，`present_frame` 收攏三個 CPU 複製點~~ | **已收 + 裝置 A/B PASS（2026-08-25，5567）**：儀器 `Virtualization 1213db9` + `crosvm 0208302e8`；重構 `crosvm a2508bea8`。simplefb→VNC 1841 幀單一雜湊 A==B（獨立驗證非全黑：31 種取樣色；全零幀雜湊另算過不同）；`present_external` 4 幀全同，且**跨路交叉**：它的雜湊 == simplefb 直路的值——同一份位元組走兩個生產者。**覆蓋為零的兩處**：pool-scanout 站（EDK2 on 2D 走 `transfer_read`，未觸及的複製點；要真 3D guest 才到）與 padded-stride 原生路（已知條件：那裡不同是修剪切 bug 不是回歸）。site 2/3 數學同構是結構論證，pool 站以 3D 桌面目視 + 顏色驗收補 |
| 5 | ~~simplefb watcher + poll-hz~~ | **已收 + 裝置驗收 PASS（2026-08-25，5567，三輪重現）**：`crosvm bb681a2a2`。無消費者 30s＝0 present；attach 邊緣恰好 1 張全幀；靜止+連線 30s＝0；按鍵流 24.0/s（<30 上限）、停鍵後歸零——**§9 雙向判準成立**；`poll-hz=10` 臂：啟動行印 `@ 10fps`、按鍵流 9.6/s ≤10。額外抓到：`NoFramebuffer` 掉格在 watcher 下需 `pending_present` 重供給（agent 實作時抓到並修，「掉格需要再供給」在迴圈內的應用）。附註：裝置端 crosvm 曾被 OPLUS lowmem（osvelte）外部 SIGKILL（mlock 892MB），量測窗皆在存活區間內，與顯示路徑無關 |
| 6 | ~~匯出端 per-screen（crosvm 側）~~ | **crosvm 側已收**：6a `98bb2a8cd`（`screen=gpu-0\|simplefb` 選擇器、Vec 化、1:1 驗證 + 14 測試；兩個「靜默→吵」的行為變化見 commit）＋ 6b `b375beceb`（simplefb 綁定就走自有 sink，GPU 在不在都一樣；VNC bridge 查無單例狀態）。**裝置 PASS**：雙 VNC（5900=gpu-0、5901=simplefb 異幾何）同時活 72s，各自的 FRAMEHASH/位元組數區分清楚。**app 側工單另行**（見下） |
| 7 | ~~刪掉仲裁~~ | **已收：`b3fe7cf5e`**（+15/−488；刪除符號 grep 97→0 含註解；`feed_loop`/`present_external`/`external_scanout.rs` 同葬，`present_frame` 站點 3→2；snapshot 從未載過仲裁狀態，無需遷移；三個拼不出被刪名字的位置參數呼叫點由編譯器抓出）。**裝置確認新模型**：EDK2 在 2D 後端下 gpu-0 readback 黑（載具性質）、畫面在 simplefb 螢幕——舊碼會在 grace 後把它搬上 gpu-0，正是被刪掉的交接。**出貨閘未解除**：APK 仍須帶 app 端螢幕綁定一起部署 |
| 8 | 游標：`move_cursor` 依 `scanout_id` 重掛（§1.4.1）+ scanout unbind/reset 時主動藏游標（§3.5 的缺口，不再靠 guest 自願）。**範圍修正**：「游標跨到 simplefb 螢幕」在協定上不可表達——`cursor_pos.scanout_id` 只索引 virtio-gpu scanout，simplefb 螢幕不在那個編號空間，且 simplefb 迴圈從不呼叫游標 API，**所以 simplefb 的 `cursor: None` 是結構性成立**；§8（五）當時把 host 螢幕與 virtio scanout 混為一談，補記於 §8（八） | **已收：`ce91f2ba6`**。重掛完全重用 `update_cursor` 的路（+`flush_resource`，因為重掛建的是空白表面而 MOVE_CURSOR 不帶影像）；兩個 hide 邊（scanout disable / device reset）都查證 sink 側 release 不覆蓋（只是 Box drop）後補上；**順手修上游潛伏 bug**：`parent_scanout_id` 從未被寫入，snapshot/restore 一直讀永遠 None 的值。單 scanout 下重掛分支不可達、行為逐位元組不變。裝置驗收併入全鏈檢查 |
| 9 | ~~每螢幕「啟用輸入裝置」屬性~~ | **已收**：app `c8bf61c`（per-screen socket/`input_enabled`/console 路由，102 測試綠）+ crosvm `6d7a17b57` + app `7d048bd53`（`absolute-mouse` 收 `name=`——原本發了會 parse error；RFB 裝置集停止偷第一個 multi-touch 的名字，改用自有 `DroidVM VNC *` 常數名）。**發現並繞過**：crosvm 的 RFB 輸入裝置集是 VM 全域、且 `gpu_parameters.is_none()` 才建——GPU 開著時 VNC 綁的 simplefb 螢幕沒有 crosvm 側輸入裝置，app 的 per-screen socket 裝置因此對 VNC 綁定也照發（不是死裝置，app 的 TOUCH 模式走它）。RFB 集 per-screen 化留給多 scanout 期 |
| 10 | ~~simplefb udmabuf GPU copy~~ | **程式碼已收**：`63de53bfd`+`8235b4155`（一次 import 整區、fence 25ms 有界等待、任何失敗一次記錄後永久退 CPU）；`e9b295b0d`（無綁定 Stub 靜音，裝置 PASS：ERROR 0）；`ee10238db`（`transport-cap=auto\|cpu` 兩匯出端，裝置實測 cap 連 turnip 都不 dlopen）。**全部前提 CONFIRMED（2026-08-25 終驗，tier 1）**：udmabuf-over-SHARE ✓；WC 可見性 ✓
（EDK2 經 WC 寫入 → udmabuf import → turnip blit → 面板，畫面是 guest 自己的位元組）；
fourcc 宣告 ✓（TianoCore 橘 `(255,85,0)` 兩路逐位元組相同，R↔B 反轉不存在）。
三段遷移、新發射（無 `--gpu`、per-screen 幾何、`transport-cap` 被接受）、還原全 PASS。
**兩個殘留小項**：`--gpu-cgroup-path` 在無 GPU 裝置時仍發射（無害，gate 在 gpu_cgroup_enabled
不在裝置上，下批 app 工單收）；APK 部署後 app 可能停在 SetupActivity（解壓頁），daemon
要等 UI 過場才起——部署程序補一步。**兩個 app 側障礙**：turnip 要 16px 倍數寬（1400 不行、1408 可以，producer 不硬編 sink 規則，CPU 退路清楚可讀）；`applyDisplayBlitEnv` 只認 gpu-0 原生（simplefb+原生拿不到 Vulkan lib）。**兩 repo 同船閘**：app 預設配置發 `transport-cap=cpu`，舊 crosvm 拒啟——APK 打包天然滿足，手動混搭會炸 |
| 11 | VNC 實作 GPU 半邊 | VNC 能吃 dmabuf；畫面與顏色不變；**guest vblank 不隨 VNC 客戶端有無而變**（§7） |
| 12 | ~~VNC 畫格匯流拆分~~ | **已收＋PASS：`aab68b2d1`**。縫在 C（狀態都在那側）；A rebuild 位元相同（build 可重現）；EDK2 選單跨開機不可重現 → 用 FRAMEHASH 的函數同一性論證；游標路徑 host harness 204 行 trace A≡B＋陰性對照 |
| 13 | ~~H.264 硬編~~ | **已收＋tier 1 PASS**。host：crosvm `e15b27a0a` + Virtualization `a05556ff`（lazy encoder、DVH2/DVHX、SPS/PPS 連線快取、cap 四階 port 綁定實測、**§7 MediaCodec-Vulkan CONFIRMED**（有無 Vulkan blit 之 SPS+PPS+首 IDR 位元相同；橘色同像素同值、交換值零出現）；兩個真機才現形的修正：`consumer_generation` 取代 bool（消費者集合變化要重供給）、死 peer EOF peek）。app：`10634d9`+`c27d08b`（TextureView 疊層事件穿透、抑制=不處理訊息、`modifiedRegion` 語意保證無縫恢復、framing parser 11 測試）。**app↔host 端到端未合測**——最終部署 smoke 補。**已補（2026-08-25 終）**：初次接觸即通（連拒絕路徑都對）；抓到出貨阻斷——APK 殘留的
`libgui.so` 陰影平台庫使 `libmediandk` 不可 dlopen、任何裝置都建不起編碼器（手動測試自設
library path 所以看不見）——已修（meta `44de01d` 疊層剝除守衛 + prebuilt-root `f653df3`）並以
正式配置重驗：DVH2、Qualcomm 硬編、NAL 正確、暫停語意成立。**後續強化清單**（非本輪）：
側通道無讀取逾時/心跳（stall 凍結 console 且 RFB 仍被抑制）；退回後不再重探 H.264；
首圖前的拒絕對使用者無提示；`input keyevent` 不達 guest；PresentationActivity 無 H.264 路

**強化輪（2026-08-25 使用者核准 1/2/3；14 與多 scanout 維持排除）**：
1. **側通道 liveness 契約**：心跳＝u32 長度 0 的幀，host 端 3s 無資料即發（drain 側計時）、
   寫逾時 10s 斷停滯客戶端（`set_write_timeout`）；app 端 `soTimeout=10s`，逾時＝死亡→退回 RFB；
   console 關閉必須關 socket + 收 reader 執行緒（修 E2E 抓到的洩漏）。舊 app 遇心跳＝退回 RFB（良性，兩側同 APK 出貨）。
2. **DVHX 理由 token 化**：`no-encoder`（app 放棄重探＋顯示不可用註記）/`busy`（退避重試 5→10→15s cap）/
   其他（退避重試）；退回後在 console 存活期間持續重探；首圖前被拒也給狀態註記（不再 gate 在 wasLive）。
3. **鍵盤事件**：VMVncDisplayActivity 接 `dispatchKeyEvent`（實體/注入鍵→RFB keysym，重用既有映射；
   系統鍵 BACK/HOME/音量留本地）；**PresentationActivity 補 H.264 路**（一個 TextureView + place() 鏡像）。

**強化輪收案（2026-08-25，7/7 PASS，r271.g6f5bf13 三台部署）**：
stall→退回 **10.07s**（原本無限凍結）；心跳 3.02-3.06s、靜止 38s 無誤退；重探階梯 5→10→15s
且 **rung 由 onLive 重置實證**（二次退回後 5s 回歸）；host 停滯清位 **21.8s**（churn 位元率；
idle 位元率下緩衝填不滿是已知框架）；busy token 含**冒號修復**端到端（host 寫 `token: sentence`、
app 取詞帶冒號精確匹配必失——跨 repo 縫由監督者抓出，縫測試持 host 原字串）；
presentation overlay 過。**keyevent 結案：ROM 產物**——ColorOS 不把注入鍵事件派給 app 視窗
（source=0x0/deviceId=-1 被攔，三 app 對照皆然、觸控注入可達），實體鍵盤走已證的 RFB 路，
`dispatchKeyEvent` 自 initial commit 即完整。
**附帶抓到並修掉**：編輯器首開必炸（`currentTransport` 守 ISE 但真 widget 未 configure 拋 NPE；
`6f5bf13` 改自追蹤 menu-built 旗標）——躲過所有檢查因為單元測試不 inflate 真 widget、
裝置驗證全走 IPC 沒人開過編輯 UI（教訓入 memory：每輪交付前 am start 掃主要 Activity）。
**已知小項**：已退回 RFB 註記約 6.5s 後被下一次 probe 的 wasLive=false 清掉（外觀性）。 |
| 11 | ~~VNC 的 GPU Copy 階~~ | **已收＋雙 tier PASS**：crosvm `f9b09f59a` + Virtualization `2a661d2`。headless blit ctx（`ensureTarget` 是唯一知道目標用途的成員——13 換成 MediaCodec input 即可）；stride 決策=packed 時映射即 offer（零複製）、padded 才重排，12 的縫不動；**顏色**：來源 fourcc 紅藍交換宣告讓 `vkCmdBlitImage` 免費換通道，首張全幀 md5 跨 2 開機×2 傳輸全同；**§7 vblank CONFIRMED**：30s 窗 406-416 offers，客戶端有無/傳輸種類皆不動 guest flush 率（一個 0→677 暫態被重複實驗排除）。fence=None 顯式覆寫。**兩個 app 阻塞待修**：`applyDisplayBlitEnv` 不認 VNC 綁定（env 不設 → ctx 起不來）；`isImplemented(VNC,GPU)`=false → 一律 cap CPU（放開即可，crosvm 零改動——gpu 天花板本來就不發旗標） |
| 14 | Direct scanout（zero-copy，§4.7），gfxstream 先行 | 協商到 Direct 時桌面畫面與顏色不變；ctrl+alt+2 降級、切回升級，肉眼無縫；拔掉 app Surface 降級不卡 guest；矩陣記錄該格觀察到的**模式集合** |
| — | **多 scanout 啟用** | **使用者決定先不做**；第 6 步做完後阻礙只剩 AIDL 的 serviceName list |

**第 6-9 步的收官驗證（2026-08-25，5567，真實 daemon 路徑）**：遷移正確（七個 legacy 鍵折進 `screens`，
值保留；檔案重寫延遲到下次 UI 儲存是設計）；發射逐旗標對；**抓到一個硬阻斷並修掉**：
per-screen socket 路徑爆 `SUN_LEN`——舊命名 106/107 只剩 1 字元餘裕，任何 screen 後綴都溢出，
且 daemon 的 `bind()` 靜默截斷自報成功而 crosvm 正確拒絕（app `e5fda33` 修：socket 檔名是水管不載身分，
縮成 `dvmin_<uuid>[_sc]_<ch>.sock` worst case 90，bind 前有響亮的長度檢查）。修後預設配置端到端：
開機到 login、四路輸入接通、`(screen,channel)` routing 拒絕錯誤螢幕、乾淨停機。
**部署程序陷阱**（進記憶）：APK 升級不殺 root daemon，舊 daemon 續跑舊碼——裝完必須 `kill -INT` 重啟。

**使用者抓到的拆一半（2026-08-25 補完中）**：UI 已是兩列平級螢幕，但 `buildGpuCommand` 的
`useDisplay = gpuScreen || fbScreen` 是仲裁時代謂詞的逐字翻譯，註解還在描述已刪的
「simplefb bridge 餵 GPU 裝置」——**simplefb 螢幕開著也會給 GPU 裝置掛 scanout**，
Linux guest 看到 virtio-gpu output 就把桌面畫過去而沒人匯出（= 終驗黑幀的根源）。
修法分兩段：app 的 poll-hz + per-screen 幾何先行；謂詞翻轉（`gpuScreen` only）要等
crosvm 能表達**零 scanout 的 GPU**（`displays=` 缺席時會退到內建 1280×1024 預設 scanout，
dormant scanout 照樣勾走 Linux 桌面）＋無綁定 Stub 的噪音靜音，兩 repo 一張工單。
**遷移的一個可見後果**：legacy `display_backend=SIMPLEFB` + `gpu_enabled` 的 Linux VM 折成綁 simplefb，
但桌面在 gpu-0 上——舊仲裁會把桌面搬過來、新模型要使用者自己把匯出端綁到 gpu-0（一次設定）。
guest OS 決定正確答案（Windows 反之），遷移時不可判定，所以折 UI 所示、由使用者裁決。

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
| gfxstream colorbuffer 能否 AHB-backed | 第 14 步整條 | cuttlefish 有先例；本樹未驗 |
| kgsl 能否 import gralloc dmabuf 當 render target | 第 14 步 drm2kgsl 那格 | `IOCTL_KGSL_GPUOBJ_IMPORT`；未驗 |
| Direct 下 SF 的 release fence 會不會把 guest vblank 綁得更死 | 第 14 步 | Copy 路已有「guest vblank 跟面板」的耦合；Direct 讓 release fence 直接成為 gate，螢幕暗/低刷新率時的行為要實測 |

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

**（八）「兩個螢幕並存所以 `move_cursor` 的 scanout_id 比對從第一天就必須發生」——推理錯，結論仍對但理由變弱。**

（五）把 host 螢幕與 virtio-gpu scanout 混為一談：`cursor_pos.scanout_id` 只在 virtio-gpu
的 scanout 編號空間裡取值，simplefb 螢幕根本不在其中，游標跨到它**協定上不可表達**——
`cursor: None` 對 simplefb 是結構性質，不是要維護的規則。單 gpu scanout 之下
`scanout_id` 恆 0，比對照舊是恆真。修 `move_cursor` 的理由退回原本的：
多 scanout 啟用時才會咬人的已知缺陷，順手修掉比留著便宜。
**錯誤形態**：在兩個不同的命名空間（host 螢幕 / virtio scanout）之間做了無標記的映射。

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
