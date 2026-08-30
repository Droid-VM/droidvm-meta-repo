# virtio-media:相機、解碼、編碼

狀態:三個 device 都要做,分三階段。相機的 host backend 已實測可用(crosvm `6a35ebf8b`,
app `6a5f283`),三個 virtio-media device 都尚未實作。2026-08-26;同日對碼覆核
(7 路平行、file:line 逐條)後修訂——被推翻的結論收在 §7 末六列。

順序是 **相機 → 解碼 → 編碼**,理由在 §6。三者共用同一組地基(§2),所以先做的那個負責把
未知數趟掉,後面兩個是加法。

## 0. 地基是量出來的

`crosvm/android_camera` 是一支 Rust 的 Camera2 NDK 綁定加一支探針,在 5567(pineapple/8gen3,
Android 16 SDK 36)上跑出來的:

| # | 問題 | 結果 |
|---|---|---|
| 1 | 裸 native process 能不能用 Camera2 NDK | ✅ 但**必須先起 binder threadpool**,見 §2.2 |
| 2 | frame 真的會來嗎 | ✅ 1280x720 首幀 256ms、sensor timestamp **29.45 fps**、listener 觸發 60/60 次 |
| 3 | 是不是活的串流(不是凍結 buffer) | ✅ 60 張 luma digest **全不同** |
| 4 | 像素是不是真的(不是黑畫面) | ✅ torch off luma 6.5–7.6 → torch on **7.6–254.1**,同場景 35 倍 |
| 5 | layout 是什麼 | **NV21**(plane2 在 plane1 前一個 byte),`row_stride == width`,無 padding |
| 6 | 控制項會生效嗎 | ✅ zoom / flash / AF mode / fps range 全部接受,dump 出的 PNG 顏色正確 |

探針 dump 的 1280x720 NV21 用 `ffmpeg -pix_fmt nv21` 轉出來顏色正確(藍袋子是藍的),
所以 layout 判定不是自我一致的錯覺。

### 三台機器的相機模型不一樣,這件事會影響設計

| 機器 | 相機數 | id 0 是 logical | 物理鏡頭 | zoom |
|---|---|---|---|---|
| 5566 canoe PLK110 | **5** | **true** | **3, 2, 4** | **0.67**–20.0 |
| 5567 pineapple OPD2404 | 2 | false | 無 | 1.0–10.0 |
| 5568 sun TB322FC | 2 | false | 無 | 1.0–8.0 |

推論:**「切長焦/微距」對一般 app 只有一個入口,就是 `CONTROL_ZOOM_RATIO`**,HAL 自己決定用哪顆
sensor。5566 的 0.67 下限就是超廣角。手動選鏡頭只在物理鏡頭也進公開 id 清單時才可能
(5566 有 5 個 id,另外兩台只有 2 個),而那在我們這邊就是「這個 device 釘哪個 camera id」,
不需要任何私有機制。

> 判讀陷阱:第一版探針把「capability 讀不到」和「capability 不存在」印成同一個 `false`。
> 修成印出原始清單之後才敢下結論(5567 讀到 `0,3,5,1,6,2,19,20,18`,11 是真的不在)。

### 這台機器的硬體 codec(`/vendor/etc/media_codecs*.xml`,`c2.qti.*`)

| | 硬體支援 |
|---|---|
| 解碼 | **AV1、H.264、HEVC、VP9**、Dolby Vision(各有 low_latency / secure 變體) |
| 編碼 | **H.264、HEVC**、Dolby Vision |

沒有硬體 VP8,也沒有硬體 AV1 編碼(有軟體的 `c2.android.av1.encoder`)。
對用途的意義:**YouTube 的 VP9/AV1 有硬解,剪輯輸出的 H.264/HEVC 有硬編**。

---

## 1. 現況盤點

| | 狀態 |
|---|---|
| 相機 | virtio-media 那半**不存在**(crate 只有 `simple_device` / `v4l2_device_proxy` / `video_decoder`);Android 那半**已完成並驗證** |
| 解碼 | 上游 device **在**(`video_decoder.rs`,1281 行,整套 V4L2 stateful 狀態機),但 `video-decoder` feature **沒編進產物**,且三個 backend(libvda/vaapi/ffmpeg)**沒有一個能用在 Android** |
| 編碼 | 兩層都沒有,crate 裡連 encoder device 都沒有 |

產物實查(`crosvm_out/crosvm`):`--v4l2-proxy` 和 `--simple-media-device` 在,
`--media-decoder` / `--video-decoder` / `--video-encoder` 都不在。

**三個階段缺的東西不一樣**:相機缺 device(backend 已就緒)、解碼缺 backend(device 已就緒)、
編碼兩層都缺。

---

## 2. 三個 device 共用的地基

### 2.1 記憶體:host 池 + MMAP,協定一個 bit 都不用改


virtio-media 的 MMAP 流程本來就是「**host 配置、host 挑位置、把位置回給 guest**」:

```rust
// devices/src/virtio/media.rs:156-179
let shm_offset = self.allocator.allocate(length, Alloc::FileBacked(offset), ...)?;
Ok(shm_offset)                       // 回給 guest 當 driver_addr
```
```c
// driver/virtio_media_driver.c:702-712
vma->vm_pgoff = (resp_mmap->driver_addr + vv->mmap_region.addr) >> PAGE_SHIFT;
io_remap_pfn_range(vma, vma->vm_start, vma->vm_pgoff, ...);
```

guest 送出去的只有 V4L2 的 mmap cookie,從頭到尾沒有挑過位置——**virtio-gpu 為了保護 VM 加的
「有位置就覆蓋自己挑的」那個分支,media 不需要**,它天生就是那個形狀。

#### 移植:guest 端

只換 guest 端加的那個 base:

* 池在 → `/reserved-memory` 找 `media_host@<gpa>` 節點的 base(照
  `virtgpu_kms.c:54-75` 的 `virtio_gpu_find_pool_base_named` 同一招)
* 池不在 → `virtio_get_shm_region()`,也就是原行為(upstream KVM、非保護 VM)

`io_remap_pfn_range` 那行不動。預估 driver **~30 行**,一個檔案,跟 virtgpu 的
`if (!vgdev->gpu_pool_base)` 同型(已核實 `mmap_region` 只在 probe 一處填、
mmap/munmap 兩處用,全在 `virtio_media_driver.c`)。

#### 移植:host 端(第一版漏列,量不小)

guest 那 30 行只是尾巴。host 要做的、全部列入 Stage A1:

1. 建 `media_host` 池 + 領 `pool_id`(`fdt.rs:1069-1077` 的計數器)
2. `fdt.rs` 發 `/reserved-memory` 的 `media_host@<gpa>` 節點(`create_pool_node`
   同 `gfx_host`,`fdt.rs:1064`)
3. **SHARE parcel**:RM 規則是每塊 SHARE'd parcel 要有 reg 對得起來的
   reserved-memory 節點,否則 VM_START 回 NORESOURCE——節點和 share 要一起做
4. media device 的 allocator 重指到池 GPA:`media.rs:156` 的
   `allocate(..., Alloc::FileBacked(offset))` 現在配的是泛用 shm region 的位址空間,
   要改成從池裡切
5. app/daemon 的 size 設定接線(`VpuConfig.KEY_HOST_POOL_MB` 已在,
   daemon → crosvm cmdline 那段還沒有)

**漏做 host 半的失敗樣貌是靜默的**:pVM 上池不存在,guest driver 走 shm fallback,
mmap 到沒 share 的記憶體——驗收只會在非保護 VM 上過。所以 A1 驗收必須在 pVM 上跑、
確認走的是池路徑(driver log 印 pool base),另跑一輪 fallback(非保護 VM)。

#### 池的尺寸、耗盡、與 DRC 下的重用

* 池能否在 VM_START 後長大要先確認(gfx_host 在 pVM 上今天真的會長嗎?);不能就是
  靜態池,按最壞情況(裝置數 × 最大解析度 × buffer 數)給 sizing 公式和預設值
* 耗盡的錯誤路徑要指定:失敗落在哪個 ioctl(REQBUFS?MMAP command?)、錯誤碼是什麼
* **DRC 換 buffer 時 offset 不可立刻重用**:舊 CAPTURE buffer 可能還被 guest map 著,
  REQBUFS(0)/REQBUFS(new) 之後要等 munmap refcount 歸零才能把 offset 還給
  allocator,否則是 host 寫進 guest 舊視圖的髒污

#### virtqueue 與 ioctl payload 的落點(pVM)

相機 30fps × N 路加上編解碼的 QBUF/DQBUF,每幀的 descriptor 和 marshal 過的
payload 都走 guest RAM——pVM 上它們跟既有能動的 virtio 裝置同路徑(restricted DMA
pool bounce)。不是新機制,但要明寫:否則出問題的樣貌是「命令永不完成/高幀率下
bounce pool 耗盡」,會被誤診成 backend bug(virtio-snd 的 lent-memory 教訓同型)。
A1 在 pVM 上驗收時順帶確認。

#### USERPTR / guest 池:v1 不做

協定的 SG-entry 路徑(`sg_entry->start = sg_phys(sg_iter)`,`scatterlist_filler.c:303`)是
guest→host 方向,對應 `media_guest` 池 + drm_buddy。但:

* MMAP 那條已經夠用,而且拷貝次數一樣(host codec/camera → host 池 一次)
* USERPTR 的頁來自**應用程式**而不是 driver,driver 沒辦法把它改成從池子配置;要支援得先做
  「對 userspace 講 MMAP、對 host 講 USERPTR」的 driver 內部轉譯
* 已核實這個取捨對主要消費端零成本:ffmpeg 的 `v4l2_context.c` 寫死
  `V4L2_MEMORY_MMAP`(m2m 解碼/編碼同一套),GStreamer io-mode auto 也選 MMAP。
  `VIDIOC_EXPBUF`(DMABUF 匯出)上游同樣是 TODO(`device/src/ioctl.rs:898`),
  gst 某些 io-mode 會先探測再退,錯誤要回得乾淨

所以 `media_guest` 池**先只保留 app 端的設定欄位**,不建節點時 guest driver 走原版行為
(從 system RAM 配置)。app 端 `VpuConfig.guestPoolMbFor()` 已經把「0 = 不建節點」這個語意寫進去了。

#### DT 節點名(已拍板)

`media_host` / `media_guest`。一池一用途,不與 `gfx_host` 共用 allocator。
`fdt.rs:204-207` 的註解顯示多 growable pool 是設計時就預留的(`pool_id` 是明寫的)。

---

### 2.2 權限與前景服務


1. **binder threadpool**。裸 process 沒有它,session 會設定成功、HAL 會開、
   `startCameraStreamingOps` 會放行,然後**零 frame、零錯誤訊息**。唯一線索是 logcat 開頭
   `W BpBinder: ... there are no threads (yet?) listening to incoming transactions`。
   已在 `NdkApi::load()` 尾端做掉(dlopen libbinder_ndk + `setThreadPoolMaxThreadCount(4)` +
   `startThreadPool()`)。
2. **uid 必須在前景**。閘其實有兩道,先撞的是 UidPolicy:`CameraService.cpp:1851`
   的 `isUidActive` 不過就直接 ERROR_DISABLED;AppOps 那道也在(`MODE_IGNORED` →
   PERMISSION_SOFT_DENIED → -EACCES → 同樣 ERROR_DISABLED)。兩道都落到 `openCamera`
   回 `ERROR_CAMERA_DISABLED`(-10012)而不是 PERMISSION_DENIED,對策不變(讓 uid
   前景)。`cmd appops set --uid N CAMERA allow` 沒用,會被 `PermissionPolicyService`
   立刻同步回去。
3. **uid 要對應到持有 CAMERA 的 package**。uid 0 查不到 package(NDK 呼叫沒帶 package name,
   服務端用 uid 反查,`AttributionAndPermissionUtils.cpp:388-401`),而 `isTrustedCallingUid()`
   只放行 AID_MEDIA / AID_CAMERASERVER / AID_RADIO,root 不在裡面。

**列舉相機不吃權限**,uid 0 也能列——所以 app 端的 picker 可以在授權之前就填好。

#### 前景服務由 daemon 拉起,不是 app

`PROCESS_CAPABILITY_FOREGROUND_CAMERA` 掛在 **uid** 上,由 OomAdjuster 從 ActivityManager
管得到的 process 算出來。crosvm 是 root daemon 的 child,AM 看不到它,所以只能靠 app 自己的
process 撐著。而 app 在背景不能拉 FGS——但 **daemon(uid 0)可以**:
`ActiveServices.java:8773` 的 `case ROOT_UID: ... ret = REASON_SYSTEM_UID`,而背景啟動檢查
`int ret = allowWhileInUse;`(:9068)從同一個結論起算。服務仍然跑在 app process、
capability 掛 app uid;呼叫者是 root 只影響「准不准啟動」。

已實作:`daemon/vm/PeripheralForegroundControl` 掛在 `VMInstance.setState()`,
規則是「任一非 STOPPED 的 VM 帶著要求 FGS 的外設就撐著」,type 取聯集,
程式碼裡不出現 camera 判斷(來自 `PeripheralType.getForegroundServiceType()`)。

---

編碼/解碼**不需要** CAMERA 權限,也不需要前景服務——MediaCodec 的**准入**對一般 uid
沒有前景門檻。但有一條 reclaim 但書:ResourceManagerService 按 oom score 搶回 codec
(`ResourceManagerService.cpp:594` reclaimResource → `:963` 挑「比請求者低優先且最大」
的受害者),前景 app 搶同型硬體 codec 時,背景 uid 的 session 會被強制收回
(`MediaCodec.cpp:353-384` 直接 `codec->reclaim()`)。緩解恰好對我們有利:AM 看不到的
native process(crosvm 是 root daemon 的 child)拿 INVALID_ADJ,估不了價的 pid 在挑
受害者時被跳過(`ResourceManagerService.cpp:1009-1012`)——大概率不會被選中,代價是它
自己也搶不贏別人。binder threadpool 那一條**三個都要**,因為 codec 一樣是 binder 服務。

### 2.3 NDK 綁定的形狀:`android_camera` 是模板

`android_camera` 已經把這個形狀驗過了,`android_codec` 照抄:

* **runtime dlopen,不連結**。`libcamera2ndk` / `libmediandk` 都經過 `libgui`,而這棵樹編不出
  `libgui`(缺 `system/tools/sysprop`,補了又缺 `external/llvm-libc`)。`ndk_api!` macro 讓每條宣告
  同時展開成 struct 欄位、`dlsym`、和同名的自由函式,呼叫端寫起來跟 `extern "C"` 一樣。
* **`installable: false` + phony**。可安裝的 `rust_binary` 會讓 install rule 依賴
  `system/lib64/libc.so`,一樣把 bionic 拖下來編。
* **不要明寫 `shared_libs: ["libdl"]`**,那會要求完整 bionic;預設 system_shared_libs 走 stub。
* **簽章一律從 header 抄**。唯一憑記憶寫的那個 tag 在實機上就爆了(§7)。

---

## 3. Stage A — 相機

### 3.1 控制項


| Camera2 | V4L2 | 備註 |
|---|---|---|
| `CONTROL_ZOOM_RATIO` | `V4L2_CID_ZOOM_ABSOLUTE` | **這就是自動切鏡頭** |
| `FLASH_MODE` | `V4L2_CID_FLASH_LED_MODE` | 要先把 `AE_MODE` 釘成 `ON`,否則 3A 會蓋掉 |
| `CONTROL_AF_MODE` / `AF_TRIGGER` | `V4L2_CID_FOCUS_AUTO` / `AUTO_FOCUS_START`/`STOP` | |
| `CONTROL_AF_STATE` | `V4L2_CID_AUTO_FOCUS_STATUS`(volatile 唯讀) | **配 `V4L2_EVENT_CTRL` 推送,不要 polling** |
| `CONTROL_AE_MODE` / `SENSOR_EXPOSURE_TIME` | `V4L2_CID_EXPOSURE_AUTO` / `EXPOSURE_ABSOLUTE` | 三台都有 `MANUAL_SENSOR` capability |
| `SENSOR_SENSITIVITY` | `V4L2_CID_ISO_SENSITIVITY` (+ `_AUTO`) | |
| `CONTROL_AE_EXPOSURE_COMPENSATION` | `V4L2_CID_AUTO_EXPOSURE_BIAS` | |
| `CONTROL_AWB_MODE` | `V4L2_CID_AUTO_N_PRESET_WHITE_BALANCE` | menu 選項幾乎 1:1 |
| `CONTROL_AE_ANTIBANDING_MODE` | `V4L2_CID_POWER_LINE_FREQUENCY` | |
| `CONTROL_EFFECT_MODE` / `SCENE_MODE` | `V4L2_CID_COLORFX` / `V4L2_CID_SCENE_MODE` | |
| `VIDEO_STABILIZATION_MODE` | `V4L2_CID_IMAGE_STABILIZATION` | |
| `AE_TARGET_FPS_RANGE` | `VIDIOC_S_PARM` | 單值 V 映成 max==V 的最寬支援區間,**不是 (V,V)**——釘死 min 關掉低光變幀率,畫面比原生相機暗 |
| `SCALER_STREAM_CONFIGURATION_MAP` | `ENUM_FMT` / `ENUM_FRAMESIZES` / `ENUM_FRAMEINTERVALS` | |

> tag 值一律從 `frameworks/av/camera/ndk/include/camera/NdkCameraMetadataTags.h` 抄。
> 唯一憑記憶寫的那個(`AE_MODE` 猜成 `+4`,實際 `+3`)在實機上就爆了——NDK 會驗證 tag 型別,
> 錯的 tag 回 `ERROR_INVALID_PARAMETER` 而不是靜默失效,算是不幸中的大幸。

#### 數值約定(guest 可見 ABI,先於實作拍板)

第一版實作挑的約定會靜默變成合約,所以先寫死:

* **zoom**:`ZOOM_ABSOLUTE` 是 s32,`CONTROL_ZOOM_RATIO` 是 float(5566 下限 0.67)。
  約定 **×100 定點**(min=67、max=2000、step=1)——否則 0.67 不可表示,「zoom 就是
  切鏡頭」到不了超廣角
* **exposure**:`EXPOSURE_ABSOLUTE` 單位是 **100µs**,`SENSOR_EXPOSURE_TIME` 是 ns,
  差 10^5,host 換算
* **ISO**:`ISO_SENSITIVITY` 是 INTEGER_MENU——host 要從 CameraCharacteristics 的
  連續範圍**合成選單**(100/200/400/…),不是數值直傳
* QUERYCTRL 的 min/max/step 一律在 camera group 建立時從 CameraCharacteristics 導出

#### AE 狀態機(flash 列和 exposure 列在搶同一個欄位)

表裡 flash 那列要求把 `AE_MODE` 釘 `ON`,exposure 那列又讓 guest 經 `EXPOSURE_AUTO`
驅動 auto/manual——兩個 V4L2 控制寫同一個 Camera2 欄位,不能各寫各的。host 端要有
唯一的 AE 狀態機:`(EXPOSURE_AUTO, FLASH_LED_MODE)` → `AE_MODE` 的對映表。
兩個順帶的承認:auto-flash(`AE_MODE_ON_AUTO_FLASH`)在 V4L2 flash 模型裡沒有對應,
v1 不支援;V4L2 flash 期待獨立 STROBE 觸發而 Camera2 `FLASH_MODE_SINGLE` 隨 request
發,v1 flash 先限 TORCH/off。

#### AF 事件要有人生產(driver 只轉發)

`V4L2_EVENT_CTRL` 不會自己出現:host device 要 (a) 掛 Camera2 capture-result
callback——A1 的 AImageReader-only 骨架**沒有**這條管線、(b) 按 session/fh 追蹤
SUBSCRIBE_EVENT、(c) 把 30fps 的 result metadata 節流成變更事件。這是 Stage A 的
明列工作項(A3),「active physical id」唯讀控制也靠同一條管線。

> 附註:V4L2 控制框架文件說 volatile 控制**不產生**變更事件,守規矩的 guest 軟體
> 可能因此不訂閱——這裡能動是因為 virtio-media 繞過 guest 控制框架直送事件,
> 偏離要明寫。

#### 私有擴充(V4L2 補不到的)

私有 CID 挑 `V4L2_CID_USER_BASE + 0x1200` 起的 0x10 對齊區塊——header 的慣例是
每 driver 0x10 一塊、從 +0x1000(MEYE)排到 +0x11e0(UVC),`+0x1000*n` 在 n=1 就
撞 MEYE。事件用 `V4L2_EVENT_PRIVATE_START`(64 bytes payload)。
virtio-media **兩個方向都原封轉發、沒有白名單**:

* 事件:`VIRTIO_MEDIA_EVT_EVENT` → `v4l2_event_queue_fh()`(`virtio_media_driver.c:441-451`)
* 控制:`SUBSCRIBE_EVENT` 轉發(`virtio_media_ioctls.c:611`);compound control 的 payload 指標
  有專用 marshalling(`virtio_media_ioctls.c:312-319`)

要做的三個:

1. **AE/AF 區域(點擊對焦/測光)**——最實質的缺口,V4L2 完全沒有對應。5567 實測
   `CONTROL_MAX_REGIONS = (AE 1, AWB 0, AF 1)`,硬體支援。compound control 帶
   `{x, y, w, h, weight}`,**座標是串流相對的正規化座標**(guest 只知道自己的解析度),
   host 經當前 zoom/crop 轉成 sensor active-array 座標——不然 zoom≠1 時點哪對焦到
   別處,而 5566 是 0.67–20x,zoom≠1 才是常態。wire format 是 ABI,座標約定後補是
   破壞性變更。
2. **stream use case**——三台都支援(`PREVIEW` / `STILL_CAPTURE` / `VIDEO_RECORD` /
   `PREVIEW_VIDEO_STILL` / `VIDEO_CALL`)。menu 型,只在 streamoff 時可設。
3. **active physical id**(唯讀)——讓 guest 知道現在是哪顆鏡頭。只有 5566 的 id 0 有意義。

**不做**:per-frame metadata。`V4L2_BUF_TYPE_META_CAPTURE` 要第二個節點,而 guest 端沒有讀它的
生態(Linux 上沒有,UVC 從來沒提供過)。AF「對好了沒」用 volatile 控制 + `V4L2_EVENT_CTRL`
就夠,而那本來就是 V4L2 的慣用法。

---

### 3.2 多串流與控制歸屬


#### 事實

Camera2 一個 session 只有一份 CaptureRequest,AF/AE/AWB/zoom/flash **全部是 session 級**,
output 只是 frame 落地的 surface。**次要串流本來就是 view only。**

而 virtio-media **一個 device = 一個 V4L2 節點 = 一個功能**——driver probe 裡只嵌一個
`video_device`,caps 來自單一 config word(`virtio_media_driver.c:805-828`)。所以 N 路串流
就是 N 個 device。

#### 問題與解法

N 個節點各自複製一份控制項,會讓人以為它們獨立,而改 A 的焦距其實會動到 B。
正統解是 Media Controller:控制項住在 sensor subdev 上(一份),N 個 video node 各是一路串流。
但 virtio-media 不支援(README 明列 Media API 未支援,driver 裡沒有任何
`v4l2_subdev` / `media_device` / `MEDIA_IOC_*`)。

**採用的是 subset,不是完整 subdev**:

* host 端一個 **camera group** = 一個 Camera2 session + N 個 virtio device
* device 帶 `role: Main | Aux`
* **Main 回完整控制項清單,Aux 回空**,Aux 上的控制 ioctl 回 `-EINVAL`
* 分組寫在 `card`:`"vcam0 main"` / `"vcam0 aux1"`

成本:**driver 0 行、協定 0 bit**。因為控制項清單是 host 回答的——`QUERYCTRL` /
`QUERY_EXT_CTRL` / `QUERYMENU` 都是 `SIMPLE_WR_IOCTL` 直接 proxy
(`virtio_media_ioctls.c:484-488, 1151-1159`)。

而且它誠實:`v4l2-ctl -d /dev/video1 --list-ctrls` 印出空的,看得出這個節點不擁有控制項。

**但 role/card 只解決控制歸屬;session 生命週期是另一半,要在 A1 凍介面前寫掉**:
Camera2 的 output surface 集合在 session 建立時固定,Aux 在 Main 已 live 之後才
streamon 就得重建 session(Main 會 glitch/斷流)。要先定:session 重建的觸發條件、
N 個節點間 streamon/streamoff 的順序規則、只有 Aux 在串流時 session 歸誰、
per-device S_FMT 引發的整組重談判政策。v1 只有 Main 也一樣要寫——這些規則決定
role+card 是不是對的 seam;「早留 seam 便宜」的貴處在這個狀態機,不在 enum。

> 為什麼不用 `bus_info` 分組(UVC 的慣例):driver 把它寫死成
> `"platform:virtio-media0"`(`virtio_media_ioctls.c:545`),所有節點共用。要讓它從 config area
> 讀就得加欄位、偏離上游,先不做。

> 完整 subdev 的增量估計:driver 400–600 行 + host 300–500 行,協定**不用改**
> (wire 只帶 ioctl NR,而 `VIDIOC_SUBDEV_G_FMT` 與 `VIDIOC_G_FMT` 都是 `_IOWR('V', 4, ...)`,
> 歧義由「這個 device 宣告自己是什麼節點」解掉)。真正的門檻不是工程量,是**消費端**:
> MC/subdev 在 Linux 上的使用者是 libcamera 和專用 pipeline 工具,瀏覽器/OBS/ffmpeg/GStreamer
> 一律開 `/dev/videoN` 用普通控制項。哪天目標變成「guest 跑 libcamera」再做。

---

---

## 4. Stage B — 解碼

### 4.1 缺的只有 backend

`video_decoder.rs`(crate,1281 行)已經實作整套 V4L2 stateful decoder:`REQBUFS` / `QBUF` /
`DQBUF`、兩條 queue 的 streamon/off、`V4L2_EVENT_SOURCE_CHANGE`、`VIDIOC_DECODER_CMD`。
接縫是 `VideoDecoderBackend` trait(`device/src/devices/video_decoder.rs:465`):

```
new_session / close_session / enum_formats / frame_sizes / adjust_format / apply_format
  session: decode / use_as_output / drain / clear_output_buffers / next_event
           current_format / stream_params / poll_fd / streaming_state
```

crosvm 的 `devices/src/virtio/media/decoder_adapter.rs` 是同一個 trait 的既有實作(把舊 virtio-video backend 接上來),
**當範例讀,但不要走它那條路**——那會拖進整個 virtio-video 和 `video-decoder` feature。
直接寫一個 MediaCodec 版的 `VideoDecoderBackend`。

### 4.2 MediaCodec ↔ V4L2 stateful:對得很好

兩邊都是 stateful,概念幾乎一對一:

| V4L2 stateful decoder | MediaCodec |
|---|---|
| OUTPUT queue(壓縮輸入) | `AMediaCodec_dequeueInputBuffer` + `queueInputBuffer` |
| CAPTURE queue(解出的 frame) | `dequeueOutputBuffer` + `getOutputBuffer` + `releaseOutputBuffer` |
| `V4L2_EVENT_SOURCE_CHANGE` | `AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED` |
| `V4L2_DEC_CMD_STOP` → drain → last-buffer flag | `BUFFER_FLAG_END_OF_STREAM` 進 / 出 |
| **OUTPUT** streamoff/on(seek) | `AMediaCodec_flush` |
| CAPTURE streamoff/on(DRC 換 buffer 的 ack) | **不 flush**,只重配 buffer |
| `ENUM_FMT` | `AMediaCodecStore_getSupportedMediaTypes` / `findNextDecoderForFormat` |
| `ENUM_FRAMESIZES` | `AMediaCodecInfo_getVideoCapabilities` → `ACodecVideoCapabilities_*` |

用 **`AMediaCodec_setAsyncNotifyCallback`(async 模式)**,不要輪詢 dequeue:device 本來就是
事件驅動的,async 回呼直接對應 `next_event`。

`ENUM_FMT` **從 `AMediaCodecStore` 實際問**,不要寫死清單——三台機器的硬體 codec 不一樣。

> 第一版把 seek 寫成 CAPTURE streamoff/on——**錯了**。stateful 語意:seek 是
> **OUTPUT** streamoff;CAPTURE off/on 是 DRC 換 buffer 的 ack。接反的後果是每次
> 解析度變更都 flush codec 丟幀、真 seek 反而不 flush,舊幀繼續冒出來。

#### 輸出格式政策(B2 最大的一塊隱藏工作)

解碼器吐的是 `COLOR_FormatYUV420Flexible`,vendor 自選 layout——QC 的 c2 解碼器在
很多解析度下 `KEY_STRIDE`/`KEY_SLICE_HEIGHT` 大於 width/height,沒協商 flexible
還可能給 opaque/UBWC。政策:要求 flexible YUV;stride/slice-height 從 output format
讀;能用 `bytesperline`/`sizeimage` 表達的就直接表達(零額外拷貝),表達不了才
repack——那就多一次拷貝,§2.1 的「拷貝次數一樣」在這條路上不成立,要認。
CAPTURE 的 ENUM_FMT 列 backend 真做得到的格式,不是 codec 清單。
鏡像問題在編碼器:hw encoder 的 ByteBuffer 模式要求對齊的 input stride,guest 給的
是緊排——同一政策反向套用。

### 4.3 guest 端誰會用

| 消費端 | 怎麼接上 |
|---|---|
| GStreamer `v4l2h264dec` | **自動**(rank primary+1,playbin/decodebin 直接插,零設定) |
| ffmpeg | 明選 `-c:v h264_v4l2m2m` |
| mpv | 明選 `--hwdec=v4l2m2m-copy`(預設 no;沒有 EXPBUF 只有 -copy 型可用) |
| VLC | **實質接不到**(named wrapper 不在它的自動選擇裡) |
| 瀏覽器 | **接不到**,見下 |

Chromium 桌面 build 硬解只認 **VA-API**(`use_v4l2_codec` 是 ChromeOS/嵌入式才開,
桌面 Linux 至今沒開)。Firefox **已不是**「只有 VA-API」:116 起 ARM64 Linux 有
V4L2-M2M 路徑(走 ffmpeg `h264_v4l2m2m`,RPi4 預設開、其他機器 pref 開)——但它要求
解碼器輸出 **DRM-PRIME/dmabuf**,而 virtio-media 的 `VIDIOC_EXPBUF` 是 TODO
(`device/src/ioctl.rs:898`,回 invalid),Firefox 還是會退回軟解。V4L2 stateful M2M
也沒有 VA-API driver 可墊(`libva-v4l2-request` 是給 stateless 的)。

所以「YouTube 硬解」**不會因為做完 Stage B 就成立**。要它成立有三條路,都不在這個 plan 裡:

1. 自編 Chromium 開 `use_v4l2_codec`——沒有語意落差,但要長期維護一個瀏覽器包。
2. 實作 EXPBUF + guest 端 dmabuf 匯出/virtio-gpu 匯入的接通,餵 Firefox 現成的
   V4L2 路徑——面積最小的一條,但 dmabuf 跨 virtio 裝置的身分問題要先解。
3. 寫一個 VA-API driver。**真正的鴻溝不是傳輸層,是語意**:VAAPI 是 stateless/slice-level
   (呼叫端自己 parse,傳 picture param + slice data),MediaCodec 是 stateful/bitstream-level。
   中間必須有一層把 slice 重組回 Annex-B,H.264/HEVC 還要從參數反推合成 SPS/PPS。每個 codec 啃一次。

**把這件事寫清楚是為了不要讓 Stage B 被當成「YouTube 硬解」的交付。** 它交付的是
ffmpeg/GStreamer/mpv 那條線。

---

## 5. Stage C — 編碼

### 5.1 device 要從零寫

crate 裡沒有 encoder device。要寫的是一顆 V4L2 stateful encoder:
OUTPUT queue 收 raw frame,CAPTURE queue 吐 bitstream,`VIDIOC_ENCODER_CMD` /
`V4L2_ENC_CMD_STOP` 收尾。`video_decoder.rs` 是形狀上的範本(兩條 queue 的狀態機、事件、
buffer 記帳),方向反過來。

### 5.2 控制項:標準 CID 齊全

| 用途 | V4L2 | MediaCodec |
|---|---|---|
| 位元率 | `V4L2_CID_MPEG_VIDEO_BITRATE` (+207) | `AMEDIAFORMAT_KEY_BIT_RATE`;動態改用 `AMediaCodec_setParameters` |
| 位元率模式 | `V4L2_CID_MPEG_VIDEO_BITRATE_MODE` (+206) | `AMEDIAFORMAT_KEY_BITRATE_MODE` |
| GOP | `V4L2_CID_MPEG_VIDEO_GOP_SIZE` (+203) | `AMEDIAFORMAT_KEY_I_FRAME_INTERVAL` |
| 強制 I 幀 | `V4L2_CID_MPEG_VIDEO_FORCE_KEY_FRAME` (+229) | `setParameters` 的 request-sync-frame |
| SPS/PPS 放哪 | `V4L2_CID_MPEG_VIDEO_HEADER_MODE` (+216) | `BUFFER_FLAG_CODEC_CONFIG` |
| profile / level | `V4L2_CID_MPEG_VIDEO_H264_PROFILE` (+363) / `_LEVEL` (+359) | `AMEDIAFORMAT_KEY_PROFILE` / `_LEVEL` |

輸入走 **ByteBuffer(`getInputBuffer` / `queueInputBuffer`)而不是 input surface**:
guest 交過來的就是 raw frame 在記憶體裡,`createInputSurface` 那條是給 host 端 producer 用的。
注意 hw encoder 的 ByteBuffer 模式要求對齊的 input stride(讀 input format 的
`KEY_STRIDE`),guest 給的是緊排——按 §4.2 的格式政策反向套用。

### 5.3 guest 端誰會用

ffmpeg 的 `h264_v4l2m2m` / `hevc_v4l2m2m` **編碼器**,也就是 kdenlive(melt→ffmpeg)、
OBS、直接用 ffmpeg 轉檔。**不需要改任何應用程式**,只要在 render profile 指定編碼器
(kdenlive 沒有現成 profile,使用者自加一條 `vcodec=h264_v4l2m2m`;這個 wrapper 只
暴露基本 rate control——bitrate/GOP,沒有 CRF)。

這是三個階段裡**唯一沒有生態落差的**:不像解碼卡在瀏覽器要 VA-API,編碼這條 guest 端本來就是
ffmpeg 打底。

---

## 6. 階段與驗收

### 為什麼是這個順序

| | 缺什麼 | 新程式碼量 | guest 生態 |
|---|---|---|---|
| A 相機 | device(backend 已驗證) | 中 | **無落差**,V4L2 capture 是 Linux 上唯一的相機介面 |
| B 解碼 | backend(device 已就緒) | **小** | 有落差(瀏覽器要 VA-API) |
| C 編碼 | device + backend | **大** | **無落差**,ffmpeg 直接吃 |

相機第一,因為它的 backend 已經在真機上驗證過,把 §2 的地基(池、降權、binder、dlopen)
一次趟完。解碼第二,因為 device 是現成的,**用最少的新程式碼把 MediaCodec 綁定驗起來**——
同一個「先做風險最低的那個」邏輯。編碼最後,因為它要寫最多東西,但那時綁定和地基都已經是熟的。

### Stage A

* A1 capture device 打通。骨架抄 `simple_device.rs`,pattern 換成 AImageReader 的
  buffer。一個 device 一顆 camera id;host 端建 **camera group**(session 與 device
  分開)、device 帶 `role`,v1 只有 Main——但 §3.2 的 session 狀態機要先寫,seam 才
  凍得對。**host 記憶體半套全在 A1**(§2.1 host 端 1–5:池、fdt 節點、share、
  allocator、設定接線)。格式對 guest 廣告 **`V4L2_PIX_FMT_NV12`**——Android 端量到
  的是 NV21,但 ffmpeg 的 v4l2 輸入表、Chromium、Firefox/libwebrtc 都**沒有 NV21**
  (只有 GStreamer 吃),host 在拷進池的那次順手把 chroma byte-swap 成 NV12(720p
  半個 plane,幾乎免費)。layout **每次從 frame 讀回來判定**,不寫死;判定不符的
  政策:stride 不符 → `bytesperline` 表達;plane 序不符 → repack;其他 → streamon
  可見地失敗。
  **驗收**:在 **pVM** 上跑,driver log 確認走池路徑;guest `v4l2-ctl --all` 認得,
  `ffmpeg -f v4l2 -i /dev/video0` 錄到會動的畫面;另跑一輪非保護 VM 驗 fallback;
  gst `v4l2src` 一條 pipeline 當第二消費端 smoke。
* A2 標準控制項(§3.1 上半,含數值約定與 AE 狀態機)。**驗收**:`--set-ctrl
  zoom_absolute=` 之後畫面真的變,且 **5566 上到得了 0.67x**(×100 定點的 min=67)。
* A3 私有擴充(§3.1 下半)+ capture-result 事件管線(AF 事件的生產者,也是 active
  physical id 的來源)。**驗收**:對焦事件不用 polling 就收得到;**2x zoom 下點擊
  對焦,對到的是點的那個物體**(座標轉換正確性)。
* A4 翻 `PeripheralType.VIRTIO_CAMERA.available = true`,三台各跑一輪——**尤其 5566**,
  它是唯一有 logical camera 和 5 個 camera id 的。

### Stage B

* B1 `android_codec`:MediaCodec 的 Rust 綁定 + 探針,照 `android_camera` 的形狀。
  **驗收**:探針在真機上解一段 H.264 出正確的 YUV,並列出 `AMediaCodecStore` 報的 codec 清單。
* B2 `VideoDecoderBackend` 的 MediaCodec 實作 + device 接線 + §4.2 的輸出格式政策。
  **驗收**:不能用 `-f null`+「沒有 fallback 訊息」——`-f null` 丟掉所有幀,而
  v4l2m2m 失敗是報錯不是 fallback,那句話恆真(成功值=壞掉值)。改成 guest 解成
  rawvideo,對同片軟解輸出做 checksum/SSIM;再加一支 DRC 片段(中途變解析度)和
  一次中途 seek。
* B3 VP9 / HEVC 各驗一輪(`vp9_v4l2m2m` / `hevc_v4l2m2m` 都在)。**AV1 例外**:
  ffmpeg 沒有 `av1_v4l2m2m`,stateful AV1 要 GStreamer ≥1.28.1(2026-02)的
  `v4l2av1dec`——guest 發行版跟上之前,AV1 腳先掛起或用自帶 gst 驗。

### Stage C

* C1 V4L2 stateful encoder device(crate 內,方向與 `video_decoder.rs` 相反)。
* C2 MediaCodec encoder backend + 標準控制項(§5.2)+ 輸入 stride 對齊政策。
  **驗收**:guest `ffmpeg -i in.mp4 -c:v h264_v4l2m2m out.mp4` 產出可播放的檔案,
  且**先釘時脈**後同片同 preset 的 CPU 時間 ≤ libx264 的 1/3(「明顯低於」不可
  否證;未釘時脈跨開機差 3.8–7.5 倍)。
* C3 kdenlive render profile 實跑一次。

### Stage D — 若要支援 libcamera

完整 subdev + MC。§3.2 末的估計。

---

## 7. 被推翻的假設(留著,免得重走)

| 當初以為 | 實際 | 怎麼發現的 |
|---|---|---|
| Android host 有 V4L2 codec 節點可以 `--v4l2-proxy` | `/dev/video0,1,32,33` 是 camera group 的節點,codec 在 Codec2 HAL 後面 | 實機 `ls -l /dev/video*` |
| swiotlb 蓋得到 buffer,或 pVM 要靠 `add_mapping_blob` + runtime_share | runtime_share 只是實驗性;正式機制是池,而 media 的 MMAP 天生就是池要的形狀 | 使用者指正 + 讀 `virtgpu_vram.c` |
| 相機外設可以做成多端點清單(照 virtio-snd) | 一個 virtio-media device 一個節點一個功能,多顆相機 = 多個外設 | 使用者指正 + driver probe |
| 「解碼/相機已實作」 | 相機是**反的**(缺 device、backend 已就緒);解碼的 device 在但沒編、沒 Android backend | 產物 strings + Android.bp feature 實查 |
| `ACAMERA_CONTROL_AE_MODE = START + 4` | `+3`(+4 是 `AE_REGIONS`,int32 陣列) | 實機回 `ERROR_INVALID_PARAMETER` |
| 這棵樹編得出 libcamera2ndk | 缺 `system/tools/sysprop`,補了又缺 `external/llvm-libc`,鏈還會延續;改用 runtime dlopen | soong 連兩次失敗 |
| `rust_binary` 預設可安裝沒差 | install rule 依賴 `system/lib64/libc.so`,一樣把 bionic 拖下來編;要 `installable: false` + phony | ninja `-t query` |
| 探針的 `false` 就是「沒有這個能力」 | 讀不到和不存在印成同一個值;修成印原始清單才敢下結論 | 5567 說 `logical=false` 但 dumpsys 有 physicalIds |
| guest 給 NV21 就好 | ffmpeg/Chromium/Firefox 的 v4l2 格式表都**沒有 NV21**,連 A1 自己的驗收指令都協商不了;改廣告 NV12,拷貝時 swap | 覆核查三家 source 的格式表 |
| 記憶體移植=guest ~30 行 | guest 半確實 30 行;host 半(池/fdt/share/allocator/設定)整套漏列,漏做的失敗在 pVM 上是**靜默 fallback**、驗收只在非保護 VM 過 | 設計覆核 |
| 「Firefox 硬解只認 VA-API」 | 116 起 ARM64 有 V4L2-M2M 路徑;結論僥倖存活——它要 DRM-PRIME 而 EXPBUF 是 TODO | 覆核查 Mozilla bug 1833354 |
| seek 是 CAPTURE streamoff/on | stateful 語意:seek=**OUTPUT** streamoff;CAPTURE off/on 是 DRC ack,接 flush 會每次 DRC 丟幀 | 覆核對 V4L2 stateful spec |
| 私有 CID 用 `USER_BASE+0x1000*n` | header 慣例每 driver **0x10** 一塊(+0x1000 起到 +0x11e0),n=1 就撞 MEYE;改挑 +0x1200 起 | 覆核讀 v4l2-controls.h:96-115 |
| 「MediaCodec 背景完全沒限制」 | 准入沒有,但 ResourceManagerService 有 oom-priority reclaim;AM 看不到的 native process 恰好估不了價、不被選中 | 覆核讀 ResourceManagerService.cpp |
