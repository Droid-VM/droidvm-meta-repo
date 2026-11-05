# iPadOS on DroidVM（UniXNU guest）：開發進度與交接

更新：2026-11-06。目標：讓 iPadOS 17.7.11（21H461，iPad7,1／iPad Pro 12.9"）在手機（Snapdragon 8 Gen 3、Adreno 750、
Gunyah）上的 DroidVM 裡能日常使用。App Store 不在範圍內。

續報已濃縮成下方三個清單；完整續報見 `git show 419232a:PROGRESS.md`。

## 已完成

- ✅ **11-06** 每個 GPU 行程啟動省下約 2–3 s CPU：Mesa 對每個「驅動可能實作」的 Vulkan 進入點取 weak 位址，沒實作的是 NULL；ld64 只有在 `-undefined dynamic_lookup` 下才肯連結，結果是 flat namespace bind，dyld 每次 dlopen Turnip 都要拿 5633 個名字去搜尋行程裡**每一個**映像（App 有數百個）才得到 NULL。設定 App 冷啟動時 PencilKit 在背景建立 Metal device，那條執行緒 2.9–3.0 s CPU、在 50 ms 取樣裡有 60 個樣本落在 dyld 的 `forEachBindTarget → hasExportedSymbol`。連結後把這些 weak import 改綁到 Turnip 自己（`scripts/macho-weak-self-binds.py`，簽章前執行、可重複執行；符號是 hidden 所以照樣是 NULL）：0.17 s，設定 App 9 秒內的 CPU 6.7→4.7 s；MetalCheck 42/42（fork 527b8b7）。App、widget、extension、respring 後的 SpringBoard 都一樣受益
- ✅ **11-06** 轉場卡頓（優先權反轉）：iPadOS 的 render server（backboardd）把 user-interactive QoS 壓到 37–46，我們的 Metal encode 執行緒因此排在每個 App 主執行緒（47）之下，但 CoreAnimation 的 display 執行緒每一幀都在等它（CA render-server 執行緒是 55）；打開 App 時 App 和 SpringBoard 的主執行緒佔走 CPU，encode 有四分之一的時間在 runnable。改成 backboardd 的 encode 執行緒預設 SCHED_RR 54（NativeMetal fb063de）。同一次開機開／關交替 3 對、每臂 2 輪六種轉場，每 100 幀超過 33 ms 的次數：widgets 12.3→5.6、App Library 5.8→2.9、Spotlight 26.2→4.1、打開設定 14.3→6.1、設定回主畫面 13.2→9.8，平均 fps 多 20–40；MetalCheck 42/42。開在每個行程時 App 切換器反而變差（App 的 encode 高過自己的主執行緒），所以只開在 render server。m2v 自己的 scheduler／handlers／queue-wait 也提高到 54 量不出差別，已撤掉。仍剩的 1% low（8–13 fps）主要是 render server 閒著等 App 交出畫面（App 啟動的 CPU）和手機被限頻到 1.4 GHz 的時段
- ✅ **11-06** memoryless 附件不再佔真實記憶體：Turnip 的 darwin backend 有 set_iova 但沒有 lazy BO，所以沒有 LAZILY_ALLOCATED 記憶體可用，metal2vulkan 把每個 memoryless（transient）附件都放進 wired 的 guest 記憶體。補上 lazy VMA 的 iova 保留／釋放，lazy BO 在第一個需要 sysmem 的 pass 才配置（`turnip-darwin-lazy-bos.patch`，fork 5c6a422）。同一次開機開／關交替 3 對：render server 515 vs 630 MiB、guest wired 2255 vs 2389 MiB；七個畫面的截圖比對都在雜訊內，MetalCheck 42/42。另外「先放最滿的 block」（0032）量不出差別，已撤掉；0031 是 pool 報告與 0029 的 A/B 開關
- ✅ **11-06** 一次打開 App 的 4 秒裡有 86 個行程死掉，查明是 jetsam 的 sustained-pressure 政策：壓力停在 warning 超過 10 分鐘後，依序殺 idle band 的行程（多是 1–3 MB 的 daemon，之後又被叫起來），不是每次打開 App 都會發生（對照實驗連開 3 次 0 個行程死掉）。guest 的 kill 計數（`memorystatus_kill_counts`，注意陣列跳過 IdleExit 與 Invalid 兩欄）累計 3196 次 sustained-pressure kill。5 ms 的整機 spindump 本身就吃掉約 3.8 s／5 s 的 CPU，量轉場要用 200 ms 整機（每個執行緒的 cpu time 不受間隔影響）或只取樣目標行程（`-onlyTarget -proc`）
- ✅ **11-05** Dock、工具列、Spotlight 的毛玻璃不再變黑或變成桌布：CoreAnimation 在 display pass 之間取樣旋轉過的 framebuffer 做 backdrop；pass 的旋轉 twin 和 shader 取樣的 read image 是同一塊 plane bytes 的兩個 shadow，read image 在這一幀第一次 capture 時 copy in，之後被帶到後面的 encoder。render encoder 之間沒有順序，twin 的 copy back 不會經過 `ShadowSync::wrote`（只有它會丟掉帶著走的 entry）→ 後面的 backdrop 一直取樣舊的 read image。修法：copy back 也丟掉跟它寫入同一份資料的 carried shadow，下次用到再 copy in（fork metal2vulkan 0026，181b8b4）。glasstest：Dock 亮度 221–237（原本會掉到黑），MetalCheck 41/41。0023–0025 是追查時加的 A/B 開關（DontCare 全部 STORE、各類附件的 DontCare 遮罩、每個 pass 前完整 barrier），預設全關；DONT_CARE 不是原因
- ✅ **11-05** guest 記憶體（VM 不能再加 RAM：12 GB 手機、Gunyah 0.5 G、Android 留 5.5 G）。guest wired 2.4–2.8 → 約 1.95–2.15 GB：
  - 根 policy 的 hash table（兩個碟共 116 MiB）存了 3 份：DarwinBoot 交出的靜態區、kernel 驗證用的 copy、每個碟各自一份。VirtioMmioBlock 0005 讓碟直接對 policy 那份驗證（Security 299 → 181 MB）。firmware 靜態區本身放不掉：physmap 從 kernel data 結尾開始，`ml_static_mfree` 拒絕更低的位址
  - render server 的 memoryless color backing 只服務同一個 extent，每種 extent 留一個、永不釋放：19 個、254 MiB。metal2vulkan 0029 讓單取樣 backing 服務它涵蓋得到的所有同類附件，新的長到最大那個的大小、被涵蓋的釋放 → 2 個、28 MiB
  - shadow 的 merge scratch 每個 shadow 永遠留 2 個，靜止的桌布也抱著 64 MiB。0030 讓它們閒置 10 秒後跟著 idle trim 釋放，記憶體壓力時全放
  - Turnip 的 freed-BO cache：每個常駐 client 的 96 MiB 預算都填滿（桌布 extension 為一張靜止圖片抱 56 MiB、widget／SpringBoard 各 30–40 MiB）；render server 釋放的 64 MiB block 吃掉共用預算，小 BO 一釋放就沒了、下次再重建（每次都要經 host 唯一的 virtio-gpu worker 跑一趟）。改成小 BO（≤1 MiB）有自己的預算（`turnip-darwin-bo-cache-small-budget.patch`）、超過預算的 BO 直接釋放（`-oversize.patch`，原本「最新放入的不淘汰」讓一個 32 MiB block 永遠留在 16 MiB 預算裡）（fork 97dc23e）；client 用 16＋8 MiB，render server 維持預設（NativeMetal 52162a4）
  - 結果：backboardd 的 GPU 記憶體高原 1031 → 約 642 MiB、桌布 extension 約 326 → 244 MiB；兩輪 sixfps 的開機碟讀取 190–227k → 約 46k 個 block（page cache 不再被擠掉）
  - 不是洩漏：長時間增加是 metal2vulkan 自己的保留加上 pool 碎片，會停在高原；貼圖在 Metal／Vulkan／Turnip 三層只有一份配置（例外是 host-pointer import 上的 shadow，Turnip 在那裡不綁 image）。Siri／intelligence 共 22 個 process、86–104 MiB（Siri 本體約 35 MiB）
  - 診斷工具：metal2vulkan 0028 用 `#[track_caller]` 記下每個 placement 的來源行（`m2v_placement_sites`），frontend 記 app 的 Metal 呼叫要了多少（`nmb_memory_row`／`nmb_memory_top`），`/private/var/ngpu/debug/client-mem` 讓每個 GPU client 每 5 秒把這些寫到暫存目錄的 m2v-mem.txt
- ✅ **11-05** 延遲來源：
  - ArmCpu 沒有回報 powergate_latency，XNU 的 `cpu_idle_latency` = 0，所以連 1 µs 的 `IODelay` 都去睡全域那一個 `clock_delay_until` 事件，各個 polling driver 的 thread 擠在同一個 waitq 的 lock 上；持有者的 vCPU 被 host 搶走時就 lock timeout panic。改成每個 CPU 回報 25 µs，短延遲改成自旋（ArmCpu 5265ef1）
  - VirtioMmioBlock 0006：讀取自旋 1 ms 之後改睡在 driver 自己的事件上、等碟的中斷（`droidvm,intid` 經 `armcpu_spi_attach`，最多 2 ms），不再每 20 µs 一次 delay 擠那個共用事件；A/B 跟 polling 一樣快
  - Data 碟的請求：自旋之後原本每次睡 `IOSleep(1)`（1 ms 以上），同一個碟的請求全排在它後面，主畫面翻頁時 Biome 每秒 200–300 次寫入讓 SpringBoard 主執行緒卡在 fsync。改成 50 µs 自旋＋50 µs 一步，並有等待時間直方圖
  - virtio-gpu：等 fence、等空位、顯示等 GPU 都改成等 transport 的中斷計數（`returns()`／`awaitReturn()`），不再 `IOSleep(1)` 輪詢；blob 的 GEM_NEW 和 CREATE_BLOB 預設不等回覆（`droidvm_virtgpu_async_create=1`），render server 第一次開 view 時不再每個 blob 等 0.1–15 ms（device 3af9eca、45052cd、6a8076f）
- ✅ **11-04** IOSurface 的 CPU 存取會等 GPU（Safari WebGPU textured cube 隨機破圖、canvas 像素遺失）：iPadOS 27 的 WebKit.GPU 用 CoreAnimation 的加速 CG（`CA::CG::Queue`，也就是 Metal）畫 2D canvas 和 ImageBitmap，`putImageData` 是先 flush、再 IOSurfaceLock 用 CPU 寫入；Apple 的 IOSurfaceLock 會等這個 surface 上還沒做完的 GPU 工作，這裡沒有 → 晚一步執行的 GPU 清除把 CPU 寫的像素蓋掉，畫完立刻讀回只拿到一半。submit 不會列出它用到的資源，所以改由 Metal plugin 在 commit 時告訴 kernel 這個 command buffer 用了哪些 IOSurface（ticket，分寫入或只讀），做完時結束；XNU 的 `iokit_user_client_trap` 在執行 trap 前呼叫 hook（`droidvm-surface-gpu-wait.patch`），IOSurfaceRootUserClient 的 lock（trap 2，unlock 是 3，27 上實測）等 lock 之前開始的 ticket：讀鎖等寫入、寫鎖連讀取也等，最多 500 ms（device e29d087、NativeMetal 3f8d44a）。5567 實測：flush 後立刻 putImageData 6/6 遺失 → 0、沒畫過的 canvas 5/5 → 0、ImageBitmap 經 copyExternalImageToTexture 20/20 錯 → 0、textured cube 連續重載 4 次都正常、MetalCheck 41/41；真的需要等的 lock 有 120 次（平均 5.3 ms、最長 88 ms、無逾時），合成、遊戲、WebGPU 畫面不經過這個等待。順帶修了 host 的 udmabuf：map/unmap 沒帶 importer 的 DMA 屬性，KGSL 對 IO-coherent 匯入要求的 DMA_ATTR_SKIP_CPU_SYNC 被丟掉，每次 unmap 都對 guest RAM 做 cache invalidate，可能丟掉 guest 還沒寫回的資料（gunyah_host_mod 8e3c5a9，wip/hackintosh 新分支）；原廠 GKI 的 udmabuf 也是這樣，只有載入我們模組的核心（8 Gen 3）修得到，8 Elite 用的是內建版
- ✅ **11-04** 觸控筆＝Apple Pencil（壓力、懸停、傾斜角、方位角、筆身按鈕）：host 端是通用的 pen tablet，crosvm 新增 `--input stylus`（INPUT_PROP_DIRECT、BTN_TOOL_PEN／RUBBER、BTN_TOUCH、BTN_STYLUS／2、ABS_PRESSURE 0..4095、ABS_DISTANCE 0..255、ABS_TILT_X/Y ±90°，crosvm c9e24ed54），和觸控螢幕是分開的裝置，跟 Linux（wacom、hid-multitouch）、Windows（Pen 與 Touch Screen 是不同 collection）、Apple 硬體的慣例一致。app 新增每個螢幕的 PEN 通道（排在所有輸入裝置最後，原有裝置的 MMIO 位址不變），任何輸入模式下觸控筆都走 pen：觸碰、懸停、筆身按鈕；tilt 是 Android InputReader 換算的精確反函數（有單元測試），離開感應範圍延後 60 ms（Android 在落筆前送 HOVER_EXIT、抬筆後送 HOVER_ENTER）（app fad5042，未推）。guest：virtio-input 的 KIND_PEN 在 kernel 內用整數換算 tilt→polar，發給第三個 HID 裝置「pencil digitizer」（Digitizer/Stylus、Built-In、DisplayIntegrated，report 4）（device b7396ee）。反組譯查到 iPadOS 27 的條件：UIKit 從 stylus 子事件的 **polar** 方向讀角度（altitudeAngle = π/2 − Altitude，azimuth 是 y 朝上逆時針），IOHIDEventDriver 只產生 tilt 型事件且丟掉 tilt → dispatch wrapper 直接改事件資料的 orientationType（+0x58）、用 setFixedValue（vtable slot 26）寫入角度、壓力和 Z；backboardd 的最大壓力取自 service 的 `AccurateMaxDigitizerPressureValue`（缺了網頁 pressure 就是 0），懸停高度取自 `MaxHoverHeight`，而且只讀 usage 0x20 的 service（缺了 UIKit 不產生 hover）。Safari Pointer Events 實測：pointerType pen、pressure 照送入值 0.1→1.0、懸停移動、四個方向的 tilt 與 altitude 都對，手機本身的 OnePlus Pencil Pro 也是；rig 新增 pen.py（經 daemon 送合成筆）、keys.py（鍵盤）
- ✅ **11-04** iPadOS 27 跑在 5567（8 Gen 3、Adreno 750）：1024x1366 @1x、7 vCPU、5 GiB；Metal（主畫面、widget）、VPU 硬體解碼 720p 95.7 fps、paravirt 硬體編碼 87.6 fps（ffprobe 驗證）都正常，不開 vCPU 防護腳本也沒重開機。全新 Data 的 seed 裡 GPU plugin、gfxprobe、ipatool、lsdiag 是舊版，不在開機碟的 trust cache → AMFI 拒絕（沒有 Metal、工具被 SIGKILL），從 Mac／另一台 guest 補上目前版本即可
- ✅ **11-03** 5567 之前重開機的原因（不是 PAC）：OPLUS 的 last kmsg（`/data/persist_log/backup/SYSTEM_LAST_KMSG.txt`）顯示 gh-watchdog bite，所有 host CPU 都卡在對 CPU 3 的 smp_call_function，也就是 PAC 探測綁在 cpu3 的 vCPU 一直沒離開 guest（探測在 shim 交接時就壞了，第一個字元都沒印出），屬於 10-25「vCPU 不退出拖死 host 核心」那一類；同型的 A720 核心 cpu2 的 PAC 探測是正常的。vmguard2.sh 修正誤判：只有在 CPU 時間真的增加時才算卡住（7 個 vCPU 時閒置的 vCPU 可以睡超過 1 秒）

- ✅ **11-03** Safari 影片是硬體解碼（查證，無需修改）：WebKit GPU process 把 decompression session 開在 videocodecd（profile 允許 `com.apple.coremedia.videocodecd.decompressionsession.xpc`，和真機一樣），videocodecd 經 paravirt 交給手機 VPU；Big Buck Bunny H.264 10 秒 250/250 格由 videocodecd（paravirt pid）解碼、0 錯誤。WebKit GPU 那筆 `AppleVideoToolboxParavirtualizationUserClient` 拒絕只是 VT 在本地探測 Apple 內部 VM 專用的捷徑（WebKit iOS GPU profile：`(require-all (system-attribute virtual-device) (system-attribute apple-internal))`），被拒就照真機路徑走。VideoToolbox 的 decoder 在本地跑與否由 `VTAreVideoDecodersRunningInProcess` 的旗標決定，預設 0（遠端）
- ✅ **11-03** GPU 權限 deny-first：由原廠 sandbox 決定誰能開 GPU，profile 拒絕就維持拒絕。原廠 profile 以 class 繼承鏈比對（字串表裡有 IOGPU 家族的 `IOGPUDeviceUserClient`，WebKit 的 GPU process 則拿 `IOGPU` 的 sandbox extension），真機的 AGXDeviceUserClient／AGXAccelerator 繼承 IOGPUDeviceUserClient／IOGPU，我們的同名 class 不是 → 先前連 backboardd 都被擋（實驗時鎖定畫面全黑）。修法：libkern 新增 `OSMetaClassAdoptSuperclass`（只在 0 個 instance、新父類別繼承自原父類別時才換），`publishMetal` 在 publish 前把兩個 class 掛到 IOGPUDeviceUserClient／IOGPU 底下（`ioreg -i` 與真機相同，`droidvm_gpu_chain` = 5）；換成功後 open-service／open-user-client 兩道只由 sandbox 決定，grant 只留給 method filter（原廠規則寫的是真 AGX 的 selector），換不成就維持舊行為。實測 respring 後 0 筆 GPU 拒絕；render server、SpringBoard、poster、widget、Dock、MapKit、Safari 與 WebKit GPU process（WebGPU helloTriangle MSAA）、GFXBench（app sandbox，ALU2 off 359 fps）、MetalCheck 42/42 都經原廠 profile 拿到 GPU（device 504aa0d）
- ✅ **11-03** GPU 全開（`droidvm-gpu-clients=*`，原廠行為）：每個 process 都能用 GPU。實測穩定後常駐 client 6 個（SpringBoard、Dock 資料夾、一個 poster、widget renderer、icon service、render server），wired 記憶體和名單模式相當（2478 vs 2557 MiB），Maps 地圖正常、render server 沒卡死（device af0c2d2）。11-02 記的「SpringBoard 當 GPU client 讓 home 手勢壞掉」其實是 SpringBoard 有了 Metal 之後 iPadOS 提供「視窗化 App」模式（`SBMedusaMultitaskingEnabled`）：該模式沒有 home 指示條；兩種模式底部上滑都能回主畫面，模式由使用者在設定→多工處理與手勢選，guest 已設回全螢幕
- ✅ **11-03** GFXBench Aztec high offscreen 不再崩潰：crosvm 的 fd 上限 65536 被 GPU blob 用光（每個 blob 在 host 佔 3 個 dmabuf fd，Aztec high 同時約 12000 個 blob → `drm2kgsl_renderer_get_blob: dup failed: Too many open files`）→ CREATE_BLOB 失敗 → Turnip 的失敗 cs 停在 fail sink，`tu_cs_add_entries` 卻照樣加 entry（讀空 BO 陣列 bos[-1]）而 SIGSEGV。修法：crosvm 啟動時把 `RLIMIT_NOFILE` 拉到 `nr_open`（1048576，crosvm d661920，wip/virtio-mmio 和 wip/hackintosh）；Turnip patch `turnip-cs-failed-stream-entries.patch` 讓失敗的 stream 回報錯誤（fork 32e1738）。實測峰值 66340 fd，5 次連跑全過（42.3／37.2／30.3 fps，熱降頻下）
- ✅ **11-03** render server 的 spare command pool 不再無限保留：metal2vulkan 把用過的 command pool 連同每個 pass instance 的 secondary 永久留著，Turnip 又在隱式 reset 時保留 command stream BO；視窗模式＋Maps 之後 backboardd 抱著 13890 個 blob（8–128 KiB，約 390 MiB wired）。fork patch metal2vulkan 0022：既有的 kept-memory trim（每 2 秒，壓力時立即）一併釋放閒置 ≥20 秒、最新 8 個以外的 spare pool（壓力時只留 2 個）；實測切 app 時 6343 → 閒置後 3031（fork ef4486d）
- ✅ **11-03** GFXBench 的 Tessellation 測試不是我們的問題：上游原始碼 `metal_wrapper.h` 寫死 `METAL_LOW_LEVEL_TESS_ENABLED 0`（`mtl_tess.mm` 還有 MTL_TESS_TODO），`metal_tess` id 註冊了卻沒有實作，GFXBench 對 NULL 測試物件呼叫 init0 而崩潰。曲面細分由 Car Chase（螢幕＋offscreen）覆蓋
- ✅ **11-03** iPadOS 27 任何第三方 app 都有 3D：`droidvm-gpu-clients` 加 `@apps`（主程式在 `/var/containers/Bundle/Application/` 下的 process），plugin 准入（fork 42ab1cd）和 kernel sandbox grant（`droidvm-gpu-grant-apps.patch`）都認它；系統常駐 process 仍逐一列名（每個都有自己的裝置和 64 MiB 記憶體池）。arm64 app 本來就能載入 arm64e 的 plugin（keys-off，PAC 指令等同 NOP；先前「dyld 不載入」的判斷是錯的，fat plugin 試做後撤回）。GFXBench 改簽 App Store app 的 entitlements（加 container-required：trust cache 讓它成為 platform binary）：舊的 no-container 版在 27 上被 System Policy 擋掉寫入自己的容器 → 存檔路徑 nil → 12 秒崩潰。在 sandbox 內跑：ALU2 108.6 fps（CPU 上限 2.75/3.13 GHz）、T-Rex 60、Manhattan 38.3、Manhattan 3.1 27.4、Car Chase 21.2、Aztec normal 30.3／high 21.4 fps（後段手機熱到 CPU 上限 1.0–1.3 GHz）；MetalCheck（arm64）42/42（device af625d8）。Offscreen 1080p：ALU2 333、Driver2 13.7、Fill2 39.0、T-Rex 71.0、Manhattan 88.2、Manhattan 3.1 60.9、Car Chase 40.5、Aztec normal 69.1 fps（CPU 上限約 1.1–2.4 GHz、手機 57–67°C）
- ✅ **11-03** arm64 process 的 C++ exception 不再崩潰：IB（return address key）也在 EL0 關掉（keys off），libunwind 對 arm64 frame 未簽章的 return address 做 autib 不再 PAC fail（`droidvm-native-pac-user-ib.patch`）。任何會丟 C++ exception 的 arm64 App Store app 原本都會死在 unwinder（device d85806a）
- ✅ **11-03** iPadOS 27 的 Metal 正確性：MetalCheck（arm64e）42/42 通過，無 GPU 錯誤／逾時／panic。測試工具重新成為 GPU client：`droidvm-gpu-clients` 從命令列搬回內建開機參數並加上 MetalCheck、app_ios、gfxprobe（命令列 1006→891 bytes；device 18e8d3f）
- ✅ **11-03** GFXBench 裝進 iPadOS 27：trust 加 app_ios CDHash，ipatool／lsdiag 修 27 的 LaunchServices selector（去掉 personaUniqueStrings）、解壓保留 Unix 權限、大 app 不再撐爆記憶體（device 9dca3ac）；IPA 經手機 nc 走網路傳入（ssh 只有 0.6 MB/s）
- ✅ **11-03** VM 螢幕高度 ≤1920 時 @1x：用 UniXNU 的 native-text-fixup 修補 QuartzCore `-[CADisplayMode preferredScale]` 兩處（虛擬裝置分支改走高度規則、門檻 1080→1920；`make-droidvm-adt.py --text-fixup` 寫 `/chosen/text-fixups`；code-signing bitmap 快速路徑也套用，`droidvm-text-fixup-bitmap.patch`）。1032×1376（13 吋 iPad 的點數、1/4 像素）：@1x、screen type 110 同 2048、首頁／桌布／設定／Safari WebGPU 正常、觸控正確；顯示 surface 85→22 MiB、backboardd GPU 記憶體 617→449 MiB；2048×2732 仍 @2x。VM 螢幕尺寸就是開關（device ffeb241）
- ✅ **11-03** 解析度／DPI 查明：iPadOS 27 的 UI scale 不看 DPI、`display-scale`、MobileGestalt，由 `-[CADisplayMode preferredScale]` 決定（模式帶 preferredUIScale 就用它，只有外接 digital-out 模式會帶；否則 MobileGestalt `IsVirtualDevice` 為真 → 至少 @2x；否則高度 >1080 px → @2x），而且每個 UIKit 行程各自算。所以 1024×1366 永遠是 @2x、512×683 點、iPad mini 排版。不改 userland 的省法：1536×2048（768×1024 點 @2x，SpringBoard screen type 111），首頁、設定排版正常、觸控正常，像素少 44%，backboardd GPU 記憶體 617→454 MiB、顯示 surface 85→48 MiB；代價是同樣的手機畫面只放 768×1024 點（介面放大約 1.33 倍）。VM 仍維持 2048×2732，換解析度只改 VM 螢幕設定，DPI 不影響
- ✅ **11-02** VideoToolbox paravirt 預設開啟（內建開機參數 `droidvm-vt-paravirt=1`，有 virtio-media 編／解碼裝置才發布）；裝置做不到的（小於 96x96、非 4:2:0）在 `dsta` 就拒絕，VideoToolbox 改用軟體解碼；主畫面、HEIC、JPEG 不受影響（device 706338e）
- ✅ **11-02** VideoToolbox 編碼走手機 VPU：guest 核心回 paravirtualized 編碼器（`encs`／`+enc`／`esta`／`efrm`→`Efds`／`Eemt`／`ecfr`），接 virtio-media 編碼器；App 的 IOSurface 經 videocodecd 自己的 client 建 port 再查（selector 0x23／0x22）。720p 60 幀：H.264 204 fps、HEVC 292 fps，0 失敗，ffmpeg 解得回來（Y PSNR 37–67 dB）（device 9d5a0ce）
- ✅ **11-02** VideoToolbox 解碼走手機 VPU：guest 核心扮演 Apple VM 的 paravirtualization host，接 virtio-media 解碼器（MediaCodec）。720p 60 幀：H.264 135–151 fps、HEVC 159–170 fps，0 失敗，亮度正確（device 1479852）
- ✅ **11-02** MSAA 在 Adreno 上降到單取樣成本：Turnip 對不儲存的多重取樣附件走 GMEM＋metal2vulkan 對 Turnip 交 DONT_CARE（`turnip-msaa-resolved-prefers-gmem.patch`、`0021-turnip-dont-care-stores.patch`；4x 64 draw 37.5→9.2 ms；fork 803a014）
- ✅ **11-02** 查明誰用 MSAA：系統 UI 不用（backboardd 0 個），只有動態桌布與 Safari 的 WebGL／WebGPU，「關 MSAA 讓 UI 變順」不適用
- ✅ **11-02** Swift 的計時恢復：`libswift_Concurrency` 把 deadline 寫死成 24 MHz（ns×3÷125），19.2 MHz 的 guest 上 `Task.sleep`／debounce／timeout 永不觸發 → 核心對外呈現 24 MHz 時基（`droidvm-timebase-24mhz.patch`、`droidvm-timebase-hz=24000000`，device 5edbbfc）
- ✅ **11-02** 設定側欄出現 Ethernet（時基修好後；詳細頁有 IPv4、遮罩、路由器、DNS、HTTP Proxy；「Optimizing Search and Siri」、TV Provider 也回來）
- ✅ **11-02** WebGPU 的 MSL 只有編譯警告時不再回 error（WebKit 把任何 error 當失敗）（AdrenoMetal 3a4afd3、fork bb654a0）
- ✅ **11-02** WebGPU bind group 能用：plugin 包裝 metal2vulkan 的 `ArgumentEncoder`、resource ID、`useResource`／`useHeap`，補 encoder descriptor、indirect draw、帶 options 的 buffer↔texture blit、swizzle view（AdrenoMetal 8841752、f4ce342，fork 667492a）；rotatingCube、computeBoids、texturedCube 等正常
- ✅ **11-02** 藍牙可用（On、可被發現、掃描中）：ADT 根層 `bluetooth` 節點（`transport-encoding` 10）讓 bluetoothd 用 Apple VM 的程序內虛擬控制器 BTVC，userland 全 stock（device 126487d）
- ✅ **11-02** keychain 寫入修好：27 的 NativeKeyStoreEvents 補回 aks_wrap_key／unwrap（selector 10／11，`package/KeyStoreWrap.inc`），bluetoothd 不再因存不了 LE identity root 重啟
- ✅ **11-02** launchd 90% CPU 修好：不再停用 bluetoothd（BTAudioHALPlugin 找不到它的 Mach 服務就每秒查找約 1900 次）→ 2%
- ✅ **11-02** Wi-Fi 介面：`package/DroidVMWifi.inc` 的 `IO80211Controller`／`IO80211Interface`＋無傳輸層的 `DroidVMVirtualWifi`（en1），Settings 的 Wi-Fi、Ethernet、Bluetooth 並存、上網走 en0；`droidvm-wifi-ssid=NAME` 測 UI（device 9bcff1a）
- ✅ **11-02** IOKit 會安靜、mobileassetd 不再吃 40% CPU：上游 SoftwareAES 搬到 27 提供 IOAESAccelerator（`package/SoftwareAES-24A446.S`、`SoftwareAESKeys.inc`），AppleImage4 不再卡住 config thread（device a42261e）
- ✅ **11-02** Safari WebGPU 能用（webgpureport 列出 adreno adapter、helloTriangle）：`com.apple.WebKit.GPU` 加進 GPU client、`owner-hide-vmm` 加 WebKit.GPU、plugin 的 `supportsFamily:` 只對 WebGPU.framework 回 Apple4（device 24a79b2、fork 3d8ef4d、AdrenoMetal 4089943）
- ✅ **11-02** Mesa 在 sandbox 擋 `hw.physmem`／`hw.pagesize` 的行程裡不再算出 0 bytes heap：改讀 `hw.memsize`（fork `mesa-darwin-total-memory-sysctl.patch`）
- ✅ **11-02** 純 arm64（非 arm64e）程式能跑：JOP 停用的 thread 回 EL0 時用 SCTLR_EL1 關 IA／DA／DB，shared cache auth mapping 與 dyld pager 用不簽章的專屬 key（`droidvm-native-pac-user-jop.patch`，device 8ea1e33）
- ✅ **11-02** Games 開得起來：加進 `droidvm-gpu-clients`（它的 VFX 沒有 Metal 就結束）（device af2be42）
- ✅ **11-02** 穩定性測試通過：連開 30 個 App、連砍 backboardd 3 次、上滑關 App、連砍 locationd 2 次，沒有卡死或連鎖 respring
- ✅ **11-02** 切到其他 Android App 再回來 VM 畫面不再黑：display client 記住每個 surface 最後一次 flip 的來源，新 surface 重新 flip（Virtualization 72d325bc3）
- ✅ **11-02** 多工快照寫得進去：Data seed 改 `newfs_apfs -e -x`（case-sensitive＋expanded records），SplashBoard 能標 purgeable（device 59ec0a8、fork f0dafc4；Data UUID 2EE158B3）
- ✅ **11-02** 多工卡片不再白：`make-droidvm-adt.py` 從 `graphics-featureset-fallbacks` 拿掉 APPLE2／MTL2,2，快照改 PNG 由 CPU 解（device 824043f）
- ✅ **11-02** locationd 重啟不再連帶 backboardd＋SpringBoard 崩潰：guest 核心加 SPU 命令通道 stub（`package/DroidVMSensorProcessor.cpp`，motion HID 類別改名 `AppleSPUHIDDevice`）（device e5009a5）
- ✅ **11-02** 記憶體壓力等級會動：`droidvm-pressure-pageable.patch` 把 page-shortage 門檻 OR 進來（GPU 記憶體全 wired，原本等級永遠 0）（device a60ed0e）
- ✅ **11-02** free page 門檻依頁大小換算（×16384/PAGE_SIZE，free target 7.8→31.2 MiB）（device 33fe95e）
- ✅ **11-02** 砍 backboardd／render server 後不再永遠轉圈：dyld pager 拿著自己的頁去 peek 同一 16K fixup page 的兄弟頁 → ABBA 死鎖，改成先 peek 再 fault（device 32075d9）
- ✅ **11-02** crosvm 裝置 worker 不再繼承 vCPU0 的綁核：WorkerThread、u_thread_create 改用主 thread 的 CPU 集合（crosvm 47cd593ee、virglrenderer 899a4e17）
- ✅ **11-01** 從畫面外黑邊滑進來會觸發手勢：整個顯示容器收觸控，EvdevEncoder 在跨過邊框處補 touchdown，沒進畫面的手指不送（app 6171c80）
- ✅ **11-01** 上滑停住叫得出多工：手指按著且 8 ms 沒新 frame 就重發、x 交替偏 1 軸單位（`DroidVMVirtioInput.c`，device f61a969）
- ✅ **11-01** 查明設定點選項 0.5–1 s 是磁碟 page-in（上游 VirtioMmioBlock 同步、一次一個 64 KB 請求），不是 CPU 不夠
- ✅ **11-01** 區塊驅動並行化：16 個 slot 在途、鎖只保護 ring、等待不持鎖（`ipados27/patches/VirtioMmioBlock/` 0001–0002，device dbe2270）；開機到鎖定畫面 176→152 s
- ✅ **11-01** 開機時 16K 簽章的 4K 雜湊預處理同一 vnode 只做一次（`droidvm-native4k-once.patch`，device 1dc2f68）；SystemOS 開機讀取 12.7→7.4 GB
- ✅ **11-01** 區塊單次傳輸 256 KB、完成偵測前 150 us 每 2 us 檢查（0003–0004，device 7586bea）
- ✅ **11-01** virtio-gpu 傳輸層不再因 stray element 停擺：`reap()` 讀 used index 後下 barrier、對不上的重讀後略過計數、client 關閉時 `abandon(ticket)` 交還 slot（device c23dda3）
- ✅ **11-01** 上游合併 UniXNU 407db1a（merge，fork `wip/droidvm` c4502e8；AdrenoMetal 01a3721、GopFramebuffer ed08bd4、ArmCpu c85e084、DarwinBoot c936dc6）；上游順便修好 CoreImage 的 `externFunctionNames`／kernel by name
- ✅ **11-01** render server 不再失去 GPU：drm2kgsl 每個 context 的 GPU VA 2→6 GiB（VBO 192 GiB 切 32 片，virglrenderer 6536a4a8）＋m2v spare 上限 1/16 位址空間、VA 用盡時 Turnip 寫下用量（fork c4502e8）
- ✅ **11-01** RenderBox `custom_effect` 能連結帶 function constant／靜態初始化的模組：metal2vulkan 0018 連結前在副本裡綁定 constant（fork 6833c6a）
- ✅ **11-01** iconservicesagent 不再被 jetsam 15 MB 上限殺掉：GPU blob 頁改 purgeable、歸 graphics 帳本不計 footprint（device b846440）
- ✅ **11-01** union 目錄列得出下層：`getdirentries` 上層讀完不回報 EOF（`native-union-getdirentries-eof.patch` 17／27，fork 1a9a7fc）→ CI 的 kernel library 找得到、設定的行圖示全部畫出；順修 `..` 的 NULL vnode panic
- ✅ **11-01** backboardd 不再在 `create_pipeline_state` abort（SpringBoard 閃退）：metal2vulkan 0015 對未附掛的 color attachment 讀取給 0（fork 69f377a）
- ✅ **11-01** `newFunctionWithDescriptor:` 的 `specializedName` 生效（RenderBox `clampedPlusL_v1` → `custom_blend`）（fork fdd21fe 0016、NativeMetal 6c17c82）
- ✅ **11-01** plugin 支援 Metal 動態函式庫（`newDynamicLibraryWithURL:`、`supportsDynamicLibraries`、preloaded libraries），CoreImage 的 `ci_stdlib` 等載得到（exp-bgra f926107；union 修好後驗證）
- ✅ **11-01** guest panic「Resuming from debugger synchronization failed」：內建 `ml-timeout-debug-ack-scale=40`（device 71750ba）
- ✅ **11-01** owner 除錯權限：帶 `com.apple.private.droidvm.debug` 的 binary 在 `owner-debug=1` 時可取 task port、唯讀讀 vnode（fork `zzye-owner-debug-task-ports`、`zzyf-owner-debug-vnode-read`）；debugserver 能 attach 系統程序、shell 能讀 data vault
- ✅ **11-01** vCPU 依需求 uclamp：GPU constraint 開著時 6 個 vCPU 的 uclamp.min 拉到 1024（virglrenderer 0682b304）；104–105→108–110 fps
- ✅ **11-01** guest 自己要效能：crosvm virtual cpufreq（`--virt-cpufreq-upstream`，1a5592aa9）＋DarwinBoot 6f5724f `/arm-io/cpufreq`＋`package/DroidVMCpufreq.c` perfcontrol callout（device 5389c07）
- ✅ **11-01** 大小核 AMP：拓撲由 host 推導（app 74a167f、DarwinBoot 284645c 寫 `cluster-type`、device abd17ab `droidvm-amp.patch` Edge 排程器＋4d4462f 互動 thread group 升頻）；AMP 110–112.6 vs SMP 106–109 fps
- ✅ **11-01** VM 設定不再在 daemon 重啟後回到舊值：rig `vmpersist.py` 把 daemon 設定寫回 `vms.json`（device 75ce85d）
- ✅ **10-31** IPI 風暴（手機發燙、一顆核心每秒 150 萬次 IPI）：IPI SPI 共用的 ICFGR 讀改寫加鎖、回讀、收到時清 ICPENDR（ArmCpu 177a0d3、fork 4fb10c6）
- ✅ **10-31** 停用手機上 crash loop 的 com.qti.qcc（使用者同意）
- ✅ **10-31** memorystatus 不再把 inactive 檔案頁算成可用（device 65d9d21）；Turnip freed-BO cache 上限 96 MiB（fork b612590，`TU_DARWIN_BO_CACHE_MB`）；m2v 空 block 回收（fork 32defe3，實測幾乎回收不到）
- ✅ **10-31** host blit 走 KGSL 高優先：手機 app 的 `libvulkan_freedreno.so` 換 priority 版（備份 `.bak-sep3`），queue 等待 p90 6.4→2.3 ms
- ✅ **10-31** 120 Hz：`droidvm-display-hz=120`、`ca-triple-buffer=1`（device 1ab7fdf）
- ✅ **10-31** complete-on-post：scanout＋flush 一送出就完成 swap（`droidvm_virtio_complete_on_post`，device 905ee57）；翻頁 82→98 fps
- ✅ **10-31** `bindfs_pagein: ubc_upl_map() failed` panic：GPU blob 配在呼叫端行程的位址空間、kernel 不映射（`droidvm_virtgpu_in_task`，device 0b73c2a）
- ✅ **10-31** GPU 依 guest 幀需求升頻：guest Turnip 把 render server 的 queue 建成 deadline queue（fork 1e49d86），drm2kgsl 依提交速率設 KGSL power constraint（virglrenderer e68e95d4）；每幀 GPU 6.28→2.69 ms、101–107 fps
- ✅ **10-30** 27 走 8-bit framebuffer＋virtio display 零 copy scanout：cherry-pick 上游 9eca077 到 NativeMetal `exp-bgra`，render server 出 BGRA；翻頁 14→72 fps
- ✅ **10-30** display 的 MaxEntries 4096→16384（2048×2732 surface 有 5464 段）（device b1908f8）
- ✅ **10-30** GPU blob 配不到 64 KiB 連續塊就退回一般頁，不再連續 respring 後一路 NoMemory（device 3089d22）
- ✅ **10-30** 27 首頁版面修好：unit-scale=2、VM 螢幕 2048×2732（UIScreen 1024×1366 @2x，選到 J320），DarwinBoot 開機畫面保留 8→24 MiB（device 34c42ef）
- ✅ **10-30** GPU userland 升到上游 7183e58（NativeMetal wip/hackintosh a188974、m2v 624bab39、bridge 0017–0019，fork 476204c）：27 render server 正常出幀，圖示、IconRendering、CoreImage、widget 有內容
- ✅ **10-30** 27 首頁與鎖定畫面有桌布：`*Poster*` 與 `SBRendererService` 加進 GPU client（device 8277f55）
- ✅ **10-30** 27 也開動態 ADT（`--dynamic`：FDT 補 RAM、panic 區、boot video 保留、`/arm-io` 裝置、CPU／GIC）
- ✅ **10-30** 17 的功能搬到 27 並實機驗過：launch policy、內建 boot-arg（`DroidVMBootArgs27.c`）、en0（IONetworkingFamily-188）、電池、時鐘、Data store、觸控／Home、動作感測、App cryptex（`sheng-no-lc=1`）
- ✅ **10-30** 27 的 ssh 除錯 shell：工具改編 arm64e（`DROIDVM_IOS_TARGET`；ownervisor c6c8b2a、applebox 6e3b471、device 08db257、70839e1）
- ✅ **10-30** 27 音訊：`owner-hide-vmm=audiomxd` 只對音訊 server 隱藏 hypervisor（fork `zzyd-owner-hide-vmm` 7c8d2f6）＋`/product/audio` `acoustic-id` 2029；鎖定／解鎖音效經 virtio-snd 播出（device 0bce497）
- ✅ **10-30** 27 HID：sheng 的 27 版 ShengHidInput 照 `hid-device-24A446.json` 綁回原廠（53 個 binding），三個 IIG `*_Invoke` 補進 reviewed pairing
- ✅ **10-30** 27 能觸控、解鎖、開 Settings：`sheng-touch-split=1` 獨立 digitizer 裝置（合併裝置的 primary usage 是 Keyboard，backboardd 丟掉觸控）
- ✅ **10-30** native `__DATA` 槽位 16→336 KiB：input queue、display scratch、信箱 buffer 改執行期配置（`DROIDVM_*_DYNAMIC`）
- ✅ **10-30** 檔案信箱 4 MiB、公布實體位址：`export.py` 75 KB/s→1.8 MB/s
- ✅ **10-30** 27 時鐘從 crosvm 的 PL030 設日曆（`DroidVMClock.c`，launchd 之前）
- ✅ **10-30** 27 unified log：`logarchive.py` 從 timesync 算出 archive Info.plist 的時間參考，macOS 27 的 `log show` 讀得了
- ✅ **10-30** 27 鎖定畫面用 Metal 畫出：17 的 virtio GPU（傳輸／3D／display）與 NativeAdreno 進 27 display archive，staged AGXAccelerator 掛在 24A446 原廠 IOGPUFamily 下
- ✅ **10-30** 27 GPU userland：fork ios27 target 編 Turnip 與 plugin，Data seed `--plugin`、trust `--owner`，backboardd 載入 plugin（CA 的 49 個 pipeline 成功）
- ✅ **10-30** 27 Data 改走 data-store（`droidvm-data-persist=2`、第三顆磁碟、seed 12 GiB），GPU 連續 blob 配得到
- ✅ **10-30** RGhA 幀黑畫面：`LegacyDisplayProbe.cpp` 在 CPU 複製前等 GPU 做完（最多 200 ms）
- ✅ **10-30** 27 SpringBoard 起來：Data seed 寫 `CAEnableMedina=false`（`seed-data-prefs.py`）
- ✅ **10-30** 27 顯示：sheng 的 27 legacy display（`build-droidvm-legacy-display.py`）畫到 DarwinBoot 的 GOP framebuffer
- ✅ **10-30** 27 檔案信箱（`DroidVMFileExport.c`）：`export.py ps/ls/get`、`crashes.py` 可用；fork 的 RELEASE 參考 kernel 補 `__zone_site_register` stub
- ✅ **10-29** 27 launchd 起來、userland 開到 SpringBoard：Data seed（`build-droidvm-data-seed.py`）、IPSW 原版三個 trust module 包成 TrustCache bundle（3711 筆）
- ✅ **10-29** fork 併入上游 `feat/ipados27-gpu-parity` 6ad1297；sheng 6ed0ba4（每次開機丟 LaunchServices 資料庫）移植到 27
- ✅ **10-29** AppleImage4 壞指標：手動配對把 `read_random` 認成 `SHA512_Init`；改正後補 28 個 stub 配對，stub 呼叫點 65→24
- ✅ **10-29** `fileset-reviewed.json` 新增 `data` 清單：補上沒配上的 kext→kernel 資料參照（APFS named-stream vnop desc、sandbox `audio_active`）
- ✅ **10-29** 27 kernel 修正：ArmCpu fe98808（IRQ handler 還沒裝就收到中斷）、sheng SIGP recovery 預設關（`sheng-sigp-recover=1`）、ADT `/chosen/kernel-ctrr-to-be-enabled = 0`、暫用 `use_contiguous_hint=0`
- ✅ **10-29** P3：27 kernel 6 顆 CPU 起來，OS volume 以 root 掛上（APFS ARV），owner chain 掛上 SystemCryptex
- ✅ **10-29** P2：裝置 repo 第二個 board `ipados27/`，arm64e kernel prelink 進 24A446 fileset kernelcache（fork 補 RELEASE+LTO 比對用 kernel）
- ✅ **10-29** 27 儲存：IOBlockStorageDevice 從原始碼編、掛原廠類別下，配上 NativeVirtioBlock／NativeRamBlock／Data store；OS／SystemOS raw image 與簽章 root policy（117 MiB）
- ✅ **10-29** 27 kernel 開到 AppleImage4：random-seed 256 bytes、`fileset-reviewed.json` 補配對（stub 呼叫點 162→65）、corecrypto FIPS POST 全過
- ✅ **10-29** 隨機卡頓 0.2–1.8 s：display worker 改用 per-client `fenceLock`、CREATE_BLOB 取頁 4 MiB→256 KiB 塊（device 1d8a612）
- ✅ **10-29** 設定桌布／Stage Manager 的 respring：NativeAdreno 的 OOL 判斷錯（>4096 bytes 的 EXECBUFFER 被拒）（32e864a）＋1 MiB 大請求 buffer（device 4161a9a）
- ✅ **10-29** 設定 App 崩潰：mimalloc v3 的 TSD 108／109 撞 Swift 的 slot → v2（fork 88675ae）
- ✅ **10-29** 上游 GPU parity 的 GPU 半邊合進（metal2vulkan 0dfdbcd、17 個 bridge patch、Turnip 紅黑樹 VA 與 BO 快取）：約 1.7 倍幀數（fork 82744fe、device b8e5279、NativeAdreno 627836d、NativeMobileDisplay 364ce27）
- ✅ **10-29** 上游 surface import 保留的 UAF（cache 命中存了呼叫者的 IOSurfaceRef，backboardd 約 30 s 崩一次）（NativeMetal 7da9d3d）
- ✅ **10-29** arm64e 可行性：三支手機在 Gunyah pseudo-unprotected 下 PAC 都可用（`plans/IPADOS27_BUMP.md`）；使用者決定直接 bump 到 iPadOS 27
- ✅ **10-29** 從零建置自動化：`scripts/build-droidvm-all.py`（全新 clone → `out/droidvm/release/`，每步 stamp，reference candidate 自動 build）＋rig `fresh-deploy.sh`（手機上換一台新 VM）
- ✅ **10-29** 動態 ADT：DarwinBoot 從 firmware FDT 補 RAM、`/arm-io` 裝置（DarwinBoot b2ad902、device 2c9227e…3f3474d 的 `--dynamic`）；接進 `board.toml`，crosvm 裝置變動不必重產 ADT [[droidvm-dynamic-adt]]
- ✅ **10-29** owner 工具（applebox、ipatool、debugserver、lsdiag）烤進 Data seed，不再開機後 stage
- ✅ **10-29** applebox 獨立倉庫 Droid-VM/applebox（2307bb9），裝置 repo 以 `feeds.toml` 釘 commit
- ✅ **10-29** libimobiledevice 進流程：21 個工具併成一顆 4 MB multicall（`build-droidvm-libimobiledevice.py`），乾淨 clone 從零 17 分鐘
- ✅ **10-29** ownervisor 獨立成 debug shell 倉庫 Droid-VM/ownervisor（65fc2c7）：一份 `debug-shell.json` 信任紀錄取代六份
- ✅ **10-29** 8 Gen 3 那支刪掉舊 VM、`fresh-deploy.sh` 建新 VM（crosvm d5c13c494）開到主畫面：Metal、en0、電量、virtio-media／snd 正常
- ✅ **10-29** 推上後乾淨 clone 全流程一次跑完（fork 1c8e709、device 312cb4a，約 16 分鐘；Adreno740 7b61139 補 hostsim 的 `proc_selfpid`）
- ✅ **10-29** 8 Elite Gen 5（Adreno 840）的 Metal 修好：Data seed 帶的舊 Turnip 不在開機 trust cache，換成已 trust 的 plugin bundle（seed 也換新）[[gpu-8e5-support]]
- ✅ **10-29** iPadOS 的 virtio-media 傳輸層：guest 自檢讀到解碼器格式 H.264／HEVC／VP9／AV1 → NV12（crosvm `--virtio-mmio-media` d5c13c494、guest `DroidVMVirtioMedia.c` e66a7b4）
- ✅ **10-28** TODO 6 電池：crosvm goldfish battery（通用 sysfs backend）→ `DroidVMBattery`（`IOPMPowerSource` 子類別）→ powerd → SpringBoard，放電與充電都驗過 [[droidvm-battery]]
- ✅ **10-28** TODO 3 音訊原廠堆疊整條通：`IOAudio2Device`（Speaker／Mic 依 UID 分裝置）→ VirtualAudio → HAL → virtio-snd（virtio-mmio 上的 vhost-user AAudio）；PCM 逐位元正確，Safari 播放經手機喇叭出聲（device 3e0d34c、crosvm 8d587f266）[[droidvm-audio]]
- ✅ **10-28** crosvm 的 vhost-user 能用在 virtio-mmio：activate 不強求 MSI-X、frontend 尊重 `VIRTQ_AVAIL_F_NO_INTERRUPT`
- ✅ **10-28** entitlement 全集盤點（stock 21H461：3,658 key、247 個 list key；權限類候選全集 3,430 key／約 360 KB）[[entitlement-fullset]]
- ✅ **10-28** 決定：UniXNUSetting＝ownervisor 的 in-app GUI，要 root 的操作經 socket 交 ownervisor，不做特權 app
- ✅ **10-28** 實測：persona 不能讓 mobile 自力提權（EPERM）；360 KB 全集 AMFI 拒收（上限約 256 KB）；109-key lockdownd 除錯集（17 KB）AMFI 全部授予
- ✅ **10-28** runtime 信任快取可行：`zzyd-owner-runtime-trust-cache.patch`＋`owner-runtime-trust-cache=1`，載入 version-2 模組後 cdhash 立即被信任，不用重開機
- ✅ **10-28** AMFI 把任何 entitlement（含私有）授予 cdhash-trusted 的 binary（實測）
- ✅ **10-28** TODO 1 陀螺儀原廠路線：kernel HID 服務（`DroidVMMotionHid.inc`）→ locationd／CoreMotion → backboardd；ADT 根 compatible 第一項改 `J120AP`；App 的 `CMMotionManager` 讀得到，自動旋轉不靠 orientd
- ✅ **10-28** 介面 fps 22→64~92（旋轉改走 2D 引擎、答案快取、編碼執行緒、mimalloc）
- ✅ **10-28** GFXBench 拉伸修好（開機 framebuffer blob 補白頁；切換 producer 後重套 transform）
- ✅ **10-28** 上游 UniXNU rebase 進來（元件改名 NativeMetal→AdrenoMetal 等；MetalCheck 29/29；舊 tip 存 `pre-rebase-20261028` tag）
- ✅ **10-28** wip/vpu 全部 rebase 進 wip/hackintosh（11 個 repo；crosvm 76 個 VPU commit；app 582 測試過）
- ✅ **10-27** 整套 iOS hackintosh 推上 GitHub
- ✅ **10-27** 開機參數內建進 kernel（`DroidVMBootArgs.c`）
- ✅ **10-27** 畫面旋轉＋動作感測器（host 全通用，crosvm `--input motion`）
- ✅ **10-27** GFXBench IPA 改用 UIScene，修實機閃退
- ✅ **10-27** guest 的 droidvm-gpu 驅動拆除
- ✅ **10-27** fps 調校：送出畫面前等 GPU 畫完，修破圖
- ✅ **10-26** 隨機記憶體破壞：8 位元 ASID＋Gunyah vCPU 遷移 → 16 位元 ASID（fork `zzxa-16bit-asid.patch`），GFXBench 10/10
- ✅ **10-26** GFXBench 破圖（Aztec 全黑＝pipeline reflection；T-Rex／Car Chase）
- ✅ **10-26** host 端只剩通用裝置：droidvm-gpu 退役、drm2kgsl 不再辨識 guest
- ✅ **10-25** drm2kgsl 遷移：iOS 3D 預設走 virtio-gpu＋drm2kgsl（`vgpu-3d=1`），ALU2 22→50 fps
- ✅ **10-25** 重型 GFXBench（Aztec／Car Chase／T-Rex）都出分
- ✅ **10-25** 兩種手機 watchdog 當機（guest WFE＋secondaries 讀 stale boot data）
- ✅ **10-24** GFXBench 第一次出分
- ✅ **10-24** GPU 記憶體 2 GB→590 MB
- ✅ **10-24** 發現手機 OPLUS daemon 把大核限頻（跑分要記 `scaling_max_freq`）

## 未解／待查

- ⬜ **11-05** host 記憶體耗盡時 guest 卡死、恢復不了：5567 在截圖很多的測試裡 host 記憶體用光（anon 72 MB、GFP_NOWAIT 配置失敗、osvelte lowmem），adb 斷線，guest 所有 vCPU 停在 `gh_vcpu_ioctl`、timer 中斷 0、觸控叫不醒，只能重啟 VM；懷疑 crosvm／Gunyah 的中斷路徑在記憶體壓力下掉了 wakeup，未證實。有一次 18 分鐘後自己醒來，launchd reboot 時 APFS unmount panic（`vnode_rele_ext` usecount 變負），是另一個 kernel bug（懷疑 union／Data overlay）
- ⬜ **11-05** GPU 記憶體還剩的浪費：metal2vulkan pool 的碎片（backboardd 的 64 MiB block 只用了 8–51%，約 200 MiB；桌布約 100 MiB；「先放最滿的 block」量不出差別）；IOSurface 的 shadow 約 57 MiB（架構性，要 dma-buf import 才能省）；render server 自己的 Turnip cache 64–85 MiB
- ⬜ **11-04** Safari 網址列快速輸入時會掉字（例如一次送 "http://..." 只剩 "http"）：guest kernel 的鍵盤報告一個不少（droidvm_input_key_reports 對得上），字是在 iOS 那端掉的；一個字一個字送就正常，可能跟網址列的自動完成或按鍵間隔有關
- ⬜ **11-04** 觸控板：iPadOS 的觸控板手勢要哪種裝置（通用 HID Touch Pad，還是 Apple 的 multitouch 介面）還沒逆向；crosvm 已有 multi-touch-trackpad（缺五指和解析度），app 還是在本地模擬滑鼠
- ⬜ **11-04** Windows guest 的 virtio-input 驅動（vioinput）能不能把 stylus 裝置的壓力、傾斜對應成 HID Pen，尚未確認

- ⬜ **11-03** 偶發：GPU 全開實驗中 backboardd 有一次收到來源不明的 SIGTERM（jetsam reaper 掃過 70 個閒置 process、開始強制 soft memory limit 之後 15 秒），三輪重現都沒再發生；另有一次 VM 重開卡在 root 掛載前（`apfs_sysctl_register` 之後無輸出），同一個 disk 前後兩次都正常
- ⬜ **11-03** 每個 GPU blob 在 crosvm 佔 3 個 fd（virgl object 的、virgl resource 的、rutabaga resource 的 export），可以降到 1–2 個；fd 上限拉高後不急
- ⬜ **11-02** VideoToolbox paravirt 編碼器還不吃 App 的設定：`esup` 沒列 AverageBitRate、MaxKeyFrameInterval、RealTime、ProfileLevel 等，VideoToolbox 直接拒絕、不送 `eset`，碼率與 GOP 用 MediaCodec 預設。要做：列進清單、`eset` 對到 V4L2 `V4L2_CID_MPEG_VIDEO_*`，且 codec 要延到第一幀才建立（App 在 session 建好後才設，`esta` 時已經 STREAMON）
- ⬜ **11-02** gpu-3d 的「fence waits timed out」（Turnip 每 100 ms 一段的等待到期）只在較重的 WebGPU 範例出現（deferredRendering、shadowMapping），MSAA 修改前就有，原因待查
- ⬜ **11-02** 有一次開機 gpu-3d 出現 3 次 fence wait 逾時，待查
- ⬜ **11-02** WebGPU renderBundles 要 `MTLIndirectCommandBuffer`（執行期有 API，plugin 還沒包裝）
- ⬜ **11-02** WebGPU 的 cubemap、fractalCube 範例待查
- ⬜ **11-02** Wi-Fi 沒有無線電：station 掃描結果為空、沒加入網路（`droidvm-wifi-ssid` 只測 UI）；接真實硬體要在 station 換後端（例如 host 的 Wi-Fi 掃描／連線經 virtio 轉入）
- ⬜ **11-02** 藍牙只有 Apple VM 的虛擬控制器（LE 走 Bonjour）；接手機真實藍牙未做：bluetoothd 的 "VIRT" driver（`<裝置>-in`／`-out`）由 kernel 轉 virtio，或 H4＋kernel control socket
- ⬜ **11-02** 嚴格的 Apple4 做不到：raster order groups、imageblocks、tile shaders、imageblock sample coverage、post-depth coverage 被拒，indirect／ICB 邊角、linear texture、depth/stencil resolve 等有缺口；附件型 ROG／imageblock 可部分模擬；只問 Apple4 以上的 App 會被拒
- ⬜ **11-02** locationd 每次開機約 10 秒後 PAC 崩潰一次（arm64e，Cohort:0 佇列上已釋放的 dispatch 物件）；重啟後正常，已不波及 UI
- ⬜ **11-02** 新 Data 第一次產生桌布圖庫時的記憶體風暴：PosterBoard 讓各桌布擴充同時 GPU 渲染，wired 衝到 4.65 GiB、jetsam 殺掉幾十個行程；blob 頁不計 footprint，jetsam 看不到真正的大戶
- ⬜ **11-02** metal2vulkan keep_room 的空 pooled block（render server 547–616 MiB，`emptied=None`，trim 不釋放）；下一步：壓力 ≥ Warning 時暫停 keep_room，或限制空 block 總量
- ⬜ **11-02** 16 MiB block 會讓 render server 的 GPU context hang（3/5 vs 64 MiB 0/5，不是 UBWC），根因未查；fork feefe53、AdrenoMetal 8f735a2 未推，手機 plugin 1a47826 沒有除錯檔時預設 16（guest 已寫 64）
- ⬜ **11-02** kgsl-sync、vrend-sync、Binder:crosvm 被 VM 的 GPU cgroup 放進 `/dev/cpuset/gpuworker`（cpu 7），與 vCPU5 共用 core 7（VM 設定問題，未改）
- ⬜ **11-01** 設定第一次開某頁仍要 300–650 ms：冷 page-in（每次 fault 0.1–0.2 ms），區塊驅動並行化後單執行緒冷讀小檔改善有限
- ⬜ **11-01** 開機路徑仍有 6 GB 的 4K 雜湊預處理（讀 21 s、雜湊 10.5 s，corecrypto `CC_USE_ASM=0` 純 C SHA）；方向：硬體 SHA 指令，或存下推出來的 4K 雜湊
- ⬜ **11-01** 09:18 UTC 當機：guest 可用記憶體 150 ms 內掉 1 GB（同時 KaleidoscopePoster OutOfMemory），誰吃掉的待查
- ⬜ **11-01** 一次開機 SpringBoard 沒起來（只畫 3 格），重開即好，未重現
- ⬜ **11-01** Adreno740 留在 627836d：合併版在 NativeAdreno `wip/merge-up-1101`（f57a9c6），等移植 `build-droidvm-gpu.py` 對 `NativeAdrenoPublish.cpp` 的文字替換
- ⬜ **11-01** 上游兩個 Turnip patch（render-mode、gmem-mutable-swap）套不上 Droid-VM/mesa，連同 bridge 0020 未收
- ⬜ **11-01** union 不去重：上下層同名的項目列兩次（`System`、`usr`、`CoreImage.metallib`）
- ⬜ **11-01** 設定側欄約 60 fps、下拉搜尋 46 fps：Liquid Glass 讓 pass 數與像素暴增；Spotlight 的重幀大半是 metal2vulkan 模擬 no-copy buffer（每幀整塊拷 6–27 MB＋上千次小拷貝）
- ⬜ **11-01** 使用者指定的卡頓：設定亂點、旋轉、左側小工具、App 資料庫、下拉搜尋（連帶的 SpringBoard 閃退已修，卡頓仍在）
- ⬜ **11-01** 翻頁下一步：固定 120 Hz 以上的觸控注入器排除測試方法本身；抓那 1/5 主執行緒連續忙 9–14 ms 的幀在算什麼
- ⬜ **11-01** 次要：guest GPU 驅動輪詢 `IODelay(5)` 的微阻塞（SpringBoard 主執行緒 6 秒 8,824 次）；host CREATE_BLOB／GEM_CLOSE／CREATE_BLOB_USER 往返偶爾 10–33 ms（`droidvm_virtgpu_slow_ops`）
- ⬜ **11-01** DroidVM 被手動加進 OPLUS 遊戲空間（CPU 上限 1.0–1.1 GHz），是否移出由使用者決定
- ⬜ **10-31** 手機上的 `usr/lib/libvirglrenderer.so` 是手動換的（原檔 `.bak-098ce1c7`），還沒打包進 APK
- ⬜ **10-31** 強制 GMEM 會黑畫面，待查
- ⬜ **10-31** metal2vulkan 排程器從不扣住批次，73% 的提交送出時 GPU 佇列是空的
- ⬜ **10-31** host blit（prio 5）在 IB 之間搶占，約 30% 的幀多 1.5–2.4 ms
- ⬜ **10-31** 首頁編輯模式（圖示抖動）58 fps：每幀 47 個 render pass、467 個 draw、6100 萬像素
- ⬜ **10-31** 下一步候選：GPU 工作不留空檔（縮短每幀 GPU 階段或提前送下一幀）；app 端 `requestUnbufferedDispatch`；毛玻璃多 pass 的 GPU 成本（GMEM／sysmem）；CA tick 對齊 host vsync
- ⬜ **10-30** 開機時 render server 偶爾卡在 Turnip 的 `CREATE_BLOB_USER`（7 個 GPU 提交沒完成），abort 一次 backboardd 後正常
- ⬜ **10-30** rig `touch.py`（寫 guest RAM）在 27 上沒效果：HID report 有增加但鎖定畫面與翻頁沒反應（量測改用 `input.py`）
- ⬜ **10-30** iPadOS 17 也用上游 7183e58 那個 GPU pin，但還沒用這版跑過
- ⬜ **10-30** 27 還沒搬：tools overlay、麥克風錄音驗收（virtio-media 解碼 11-02 已在 27 上；GPU client 11-03 起全開、由 sandbox 決定）
- ⬜ **10-30** 一次開機在開機動畫後就沒再出 frame（沒有 GPU fault），同一映像重開正常，當偶發
- ⬜ **10-30** Liquid Glass 的重影
- ⬜ **10-30** 關機卸載時 kernel 在 `vnode_rele_ext` panic（usecount 變負；10-29 起）
- ⬜ **10-29** 上游 RamBlock 4be2d7e 未收：它只在 Install（sheng-data-reset）時建 Data store，DroidVM 新 VM 的空白 data-store.img 會永遠存不進去
- ⬜ **10-29** IOHIDFamily 一個只讀不寫的 32 位元旗標沒配對（落在 0 上），先不動
- ⬜ **10-29** `use_contiguous_hint=0` 是暫解：正解是 emitter 把 4K kernel 的 `__TEXT` 對齊 64 KiB
- ⬜ **10-29** ArmCpu fe98808 只在 Mac 的 27 樹用 ignored `ipados27/local.toml` 覆寫，fork pin 未動（等 17 量過再釘）
- ⬜ **10-29** 8 Elite Gen 5 那支的 iPadOS 17 VM 在停／開與重啟 daemon 後開機 panic「offline scratch Data mount failed: 2」，沒修（重建 seed 會清 Data），等使用者決定
- ⬜ **10-29** 8 Gen 3 那支開機後一次 backboardd NULL deref：`tu_CmdCopyImageToBuffer2` ← metal2vulkan `ShadowCopy::record_gated` 的 `ShadowTarget::Rotated`（我們的 0011 旋轉 patch，只有橫向走這條）
- ⬜ **10-29** GPU parity 只部署到三支手機中的兩支
- ⬜ **10-29** hostsim 的 deferred-pressure 檢查失敗（上游 Turnip patch 與測試不一致），記在 `release.json` 的 `checks`，不擋 build
- ⬜ **10-29** iPadOS 17 新 Data 的桌布是黑的（Poster 問題；27 已有桌布）
- ⬜ **10-29** 兩格小工具首次打開空白
- ⬜ **10-29** ownervisor 的 serial-shell 有定義但不啟動：本板 `/dev/console` 還沒接到 UART
- ⬜ **10-28** 陀螺儀待補：單位、動態轉動的實機驗證
- ⬜ **10-28** 錄音還沒在 app 裡驗到：host 的 capture stream 開著，guest 沒收到 input 的 StartIO；Voice Memos 按錄音沒反應（tccd 處理 `voicememod` 時 LaunchServices 回 -10814）
- ⬜ **10-28** GPS 暫停：J120 上 locationd 不會啟動 GNSS（WiFi 版 iPad 沒有 GPS provider bit），要換 J121AP 身分；未解的是 J121 走 gpsd 還是基頻 QMI；回來第一步只換 ADT 身分實測 [[droidvm-gps-plan]]
- ⬜ **10-28** 8 Elite Gen 5 那支的 seed 已換：下一次 `payload-redeploy.sh` 要 `ALLOW_CHANGE=seed`，會重置 Data（先備份 `/private/var/ngpu`）；8 Gen 3 主 tree 的 seed 仍帶未 trust 的舊 Turnip（沒動）
- ⬜ **10-28** 搬到 8 Elite 那支中止：留下 app r312、crosvm（`crosvm.bak-579d1a5b`）、UniXNU 映像與 VM 項目（data-store 已失效）[[droidvm-5568-state]]
- ⬜ **10-28** `board.toml` 的 trust pin 是 8 Elite Gen 5 rig 自己的，沒 commit
- ⬜ **10-28** no-sandbox staged app 從主畫面啟動未端到端跑（app-launch 半邊等 runtime 安裝器）
- ⬜ **10-28** UniXNUSetting app 本身未做：staged 系統 app 放唯讀 os.img、SpringBoard 不給刪（`plans/UNIXNUSETTING.md` §3.1）
- ⬜ **10-28** 持久化 trust 清單改由 kernel 在 Data 掛上時直接讀（`DroidVMTrustCache.c`），未實作
- ⬜ **10-28** entitlement 要盤一份 curated 清單（不簽 360 KB 全集）；keychain 的 `*` 萬用字元要查 Security 原始碼，未驗
- ⬜ **10-28** runtime trust cache 實驗（`zzyd` patch、`DroidVMTrustCache.c`）當時是本機 WIP；定案前要收掉 `owner-tc-selftest=1` 與 gfxprobe 的實驗 entitlement
- ⬜ **10-28** 配對：機內 lockdownd 協定配對走不通（value-only 端點；TCP 62078 要 TLS／passcode）；剩 USB-mux 模擬、無線（設密碼）、直接寫 `/var/db/lockdown` 的 pair record（待逆向格式）
- ⬜ **10-28** debug bridge／USB 未做：NCM（USB Ethernet gadget）把 PC 橋到 guest en0；真 usbmux 要 FunctionFS

## 陷阱與工具（續報整理）

### 陷阱

- fileset 會搬動 native kernel 程式碼：從 native code 呼叫原廠位址要經帶絕對位址字面值的 stub（`ldr x16 / br x16`），PC 相對呼叫會 instruction fetch abort
- fileset 比對：改到會被內聯的核心函式後，靠「參考順序」配上的函式會失配（`microuptime` → 開機 panic "original component called an unmapped kernel function"）；重建無補丁核心、比對新舊 `kernel.map.json`，把差異寫進 `fileset-reviewed.json`
- emitter 對沒配上的 kext→kernel 資料參照會原地加 slide，落在 native 物件上（kernel.json `missing`）：在 `fileset-reviewed.json` 的 `data` 清單補
- 手動補配對時字串掃描會跑過函式結尾（`read_random` 被認成 `SHA512_Init`）：逐一對照原廠反組譯與 xnu 原始碼
- `deploy27.sh` 會把 `out/kernel.nm` 換回 native 位址：每次都要重跑 `fileset-syms.py`，否則 rig 符號全錯、還會誤報 panic
- xnu-12377 的 random-seed 要 256 bytes，少了會在 console 出來前 panic
- DEVELOPMENT kernel 的 625 µs 看門狗會在 vCPU 被 host 搶占時觸發：`interrupt-masked-debug-mode=0`、`sched_preemption_disable_debug_mode=0`
- 改 defconfig 後要 `unixnu defconfig -D <board> droidvm_ipados27_defconfig` 重新合併 `.config` 並刪 `kern_exec.o`（XNU 的 make 不追 define），否則 kernel 仍是舊 Data UUID → `offline scratch Data mount failed: 2`
- 每次建 seed 都是新的 Data volume UUID（build kernel 前寫進 `CONFIG_XNU_OWNER_DATA_VOLUME_UUID`）；27 換 seed 就要重建 data-store
- Data seed 要用 `--case-sensitive --expanded-records`（`newfs_apfs -e -x`）建：SplashBoard 的 purgeable 需要 expanded records，只能在建卷時設
- ADT 的 `graphics-featureset-fallbacks` 不能有 APPLE2／MTL2,2：MobileGestalt 會判 DeviceSupportsASTC，SplashBoard 改寫 ATX 快照，解 ATX 要 AGX 私有 API；舊 .ktx 快照要等 app 再開一次才換掉
- AMP 核心遇到沒有 `cluster-type` 的 CPU 會開機 panic（`recount: cannot map cluster type`）：從 Mac 建磁碟要換上 AMP 版 DarwinBoot
- 命令列上限 1023 bytes（曾到 1051）：新參數放核心內建（`DroidVMBootArgs*.c`）
- 上游 AdrenoMetal 的診斷是開關：命令列要 `sheng-diag=1 log-gpu=1`
- rig 的 Mac 建置樹（fresh27）會落後已 commit 的檔案：dev-cycle 只同步相對 HEAD 有改動的檔案。11-03 改 `make-droidvm-adt.py` 時把 11-01 的 AMP cluster-type 一起帶過去，而磁碟用的 DarwinBoot.efi 是 10-29 版（不替複製的 CPU 寫 cluster-type）→ cpu0 'P'、其餘無類型 → kernel panic「recount: cannot map cluster type」。要用 11-01 以後的 DarwinBoot（會寫 cluster-type）；panic 太早時 panic.py 讀不到，讀 `debugger_panic_str`（kernel VA 轉 PA）
- 不能整個拿掉 `vmm-present`（AMFI panic「No PMGR?」），也不能對所有行程隱藏（SpringBoard 的背光 watchdog 殺 SpringBoard、全黑）：用 `owner-hide-vmm=` 逐行程隱藏
- WebGPU.framework 在 VM 裡（`kern.hv_vmm_present`=1）只在 `WebKitAllowWebGPUOnVMs` 為真時繼續，adapter 只給 Apple4 以上
- WebKit 把 `newLibraryWithSource:` 回傳的任何 error（含只有警告）當失敗
- iPadOS 27 要 `sheng-no-lc=1` 跳過 launch constraint；17 的 `owner-skip-launch-constraints` 在 27 不讀
- 27 的 zsh 會重設 login shell 的 PATH：root 的 `~/.zshenv` 把 `/private/var/ngpu/bin` 放進 PATH
- 27 的 QuartzCore `preferredScale`：虛擬裝置、或高度 >1080 的 panel 一律 @2x（17 沒有），所以 27 用 2048×2732@2x
- 27 與 17 的核心都是 4 KiB 頁（UniXNU 在非 Apple SoC 用 BCM2837 的配置）：大 surface 段數多（2048×2732＝5464 段）
- ADT `/product` 的機種身分是從 J820 靜態複製的；螢幕尺寸不在 FDT（走 virtio-gpu／GOP）
- 原地覆寫正在用的 plugin → kernel 快取的簽章 blob 對不上（`cs_mtime != mtime`），respring 不夠，要重開 VM
- J820 是 Face ID 機型，叫醒後約 2 秒熄屏；probe 在 transfer 少於 2 次時不受理 Home，熄屏的 respring 後先用 `touch.py` 點一下
- `plugin-build-fam.sh` 不會重建 Turnip（log 顯示 `same libvulkan_freedreno.dylib`）：改 Mesa 後先跑 `link-droidvm-gpu-sources.py`（補上 drivers/Adreno740）再 `build-turnip-darwin.py --target ios27`
- rust 1.98.0 編 ios27 plugin 前要 `rustup component add rust-src`
- DarwinBoot.efi 要用 unixnu 準備的 LLVM toolchain（`CLANG_BIN=out/droidvm/toolchain/`；Apple clang 沒有 llvm-lib）
- 本板格式下本機 `unixnu.lock` 會蓋過 `feeds.toml` 的 pin：`build-droidvm-all.py` 每次 `fetch --update`
- multicall 併檔：工具是 hidden visibility，改名的 main 會留 hidden，要用 `ld -r -alias _main _<tool>_main`
- 新 Data 首次開機約 5 分鐘才出第一張圖（要建所有 app／extension 的 container）
- 複製 data-store 前一定先停來源 VM，否則 guest panic「libSystem.B.dylib not loaded」
- 手機重開後 `gh_hugepage_reserve.ko` 在使用者的 KernelSU 目錄（請使用者 insmod）；`load-modules.sh` 依 `uname -r` 選模組目錄 [[droidvm-host-reboot-recovery]]
- VM 設定只存在 daemon 記憶體：只做 `vm_modify` 的話 daemon 重啟後回到舊設定，改完要跑 `vmpersist.py` 寫回 `vms.json`（27 VM 的設定檔在 rig 的 `unixnu27-vm.2048.config.json`）
- crosvm 的 `PowerClient` 要同時實作 `get_power_data` 與 `last_request_timestamp`；build wrapper 吃掉退出碼曾部署到舊 binary（畫面停在 goldfish 預設 50%）
- IOKit 驅動先 `init()` 再 `attach()`，反了會在 `attachToParent` data abort
- 手機沒聲音先查手機的媒體音量（`STREAM_MUSIC` speaker index 0）；`cmd media_session volume --set` 在這支手機設不進去，用 `KEYCODE_VOLUME_UP/DOWN`
- OPLUS 遊戲空間常把所有核心壓在 1.0–1.1 GHz（`/proc/game_opt/cpu_max_freq`）：量測時用 root 暫設 `/proc/game_opt/disable_cpufreq_limit=1`、量完還原；沒記限頻狀態的數字不可靠
- host WALT 以「忙碌時間×目前頻率」算負載、每 16 ms 視窗只升約 25%：0.9 GHz 滿載只算 25%，爬到頂要 40–116 ms，guest 的短爆量做完頻率還沒上來
- 手機平放時 guest 開機是直向，往 y 滑會拉出 Spotlight＋鍵盤（曾誤判成手機過熱）：量之前一律 `shot.py` 看一眼
- guest 裡的 spindump 會占一顆 vCPU，1 ms 取樣還會讓 SpringBoard 的檔案頁被換出（假的 1.5 秒 page-in），不能拿來判斷誰在等 CPU
- u_trace（`gpu-traces`）會把 GPU 時間拉長數倍，量幀時要關
- GPU 時間要以 pass 為單位看：整個 batch 混了 host blit 搶占與中途變頻，看不出時脈效果
- A840 不吃單筆 batch 的 power constraint 旗標；constraint 常駐會讓閒置首頁也鎖在 1200 MHz，所以依提交速率切換
- GPU 時間已排除（改了不變）：IO-coherent（virglrenderer 82e81d2e 的 `DRM2KGSL_NONCOHERENT`）、m2v inline memoryless 切 pass、強制 sysmem
- 試過沒收益：display hold（讓 commit 提早回傳）、encode 執行緒 SCHED_RR 54（commit→送出的 3.3 ms 是翻譯本身）
- 翻頁每幀只有 1 個 render pass（89 draw）：「每個 pass 翻完先送」不適用；m2v 在 commit 前送半個 pass 有 Metal 語意風險，不做
- rig 的 `frame-burst.sh` 讀開機 simplefb，virtio-gpu 之後量不到東西：改用 scratchpad `rec.sh`（screenrecord，每格時間戳）
- crash report 裡的 code 0xdac11a30 不是錯誤碼，是 `autda x16, x17` 的機器碼（PAC 驗證失敗）
- 不能用「jop_key 為 0」判斷 JOP 停用：shared region 第一個 slide pager 的 key 就是 0，launchd 會 PAC 崩潰、開機卡死
- 8 Gen 3 那支跑 PAC probe 時 cpu3 卡住讓手機重開過（cpu0–2 正常）
- 平台 sandbox 只放行 Apple 列出的 IOKit 類別：自製的 HID／user client 類別名要用 Apple 的（如 `AppleSPUHIDDevice`），否則 `iokit-open-user-client`／`iokit-open-service` 被擋
- 不要停用 bluetoothd：它的 Mach 服務不存在時 audiomxd 的 BTAudioHALPlugin 每秒查找約 1900 次，launchd 每次讀 password 檔、吃 90% CPU（17 也踩過，註解在 `DroidVMBootArgs.c`）
- AppleImage4 的 `start()` 會等 IOAESAccelerator，沒有就卡住 IOKit config thread（InterfaceNamer 每個新介面等 4 分鐘）；它的硬體金鑰 0x8a4 回 unsupported 會 panic，要由裝置種子軟體衍生
- 27 的 stock Wi-Fi 堆疊條件：configd 看 controller 類別、IO80211.framework 看 IFT_ETHER＋`IFNET_SUBFAMILY_WIFI`、wifid 用 `IOInterfaceName` 比對、`APPLE80211_IOC_FILTER_MONITOR_EVENTS` 被拒就放棄、MobileGestalt 的 `wifi` 看 `/arm-io/wlan`；wifid plist 有 `_LimitLoadToDeviceTree=wlan`
- AMFI 把任何 entitlement 授予任何 cdhash-trusted binary（含之後 runtime 信任的使用者 IPA）：授權不能只查 entitlement，要查對端 cdhash
- entitlement 全集：萬用字元的比對規則各檢查方不同；同一 key 型別不一致（給錯型別＝沒給）；聯集裡有雜訊（`no-sandbox\n`、誤入的 `CFBundleIdentifier`），聯集 ≠ 真全集
- `dyld` 還沒初始化完就查 image 清單會讓 debugserver 卡住：改用 `qMemoryRegionInfo` 找主程式

### 除錯工具

- `gfxprobe dontcare`（device 3ad4a03）：BGRA8／RGBA16Float／Depth32Float × 1x／4x × Clear／Load／DontCare 的儲存行為，配 `TU_DEBUG=gmem|sysmem`
- `gfxprobe clocks`：用 Swift 的算法排計時器，驗證時基
- `gfxprobe argbuf`：argument encoder（descriptor／function × kernel／fragment）
- `gfxprobe families`（plugin 的 `droidvmFamilyBlockers:`）：在裝置上跑 Metal family 稽核
- `gfxprobe ktxdecode`、`pitchcheck`、`spuopen`；`gfxprobe wired`（device 3089d22）：guest 記憶體分類
- `gfxprobe mg`、`gfxprobe sbscreen`（device 343ea40）：MobileGestalt 值、SpringBoard 選到的螢幕
- `dbgattach.py`：在 `WebGPU::Device::generateAValidationError(NSString*)` 設斷點讀 WebKit 被隱私遮蔽的錯誤；同一次開機的 shared cache slide 可從閒置 daemon 量
- `dbgbreak.py`（scratchpad）：debugserver 斷點、自動跨過、改暫存器、印 Swift 類別名、用 GOT 推算 shared cache slide
- 檔案信箱 kind 8（`package/DroidVMPageInfo.c`，`export.py page CTX perm`，device dc66d13）：stackshot 的 PageBusy context 減 `vm_kernel_addrperm` 就是 page，印 offset、旗標、object 與 4 層 shadow、vnode 檔名（guest `vm_pages` 實體不連續，host 讀不到）
- `export.py mem`：debugserver 取 `libvulkan_freedreno` 載入位址後讀 Turnip 的 `darwin_va` 用量
- plugin 的 MEM／MA 列（核心 `native_adreno_metal_rows`，scratchpad `mtrows.py`，MA 用 `NativeAdrenoMetal.map` 解）
- 找 Turnip device loss：guest 開關 `/private/var/ngpu/debug/mesa-log`（NativeMetal c9f76cf）→ `MESA_VK_ABORT_ON_DEVICE_LOSS` → crash report
- plugin 的 `gpu-traces` 開關（NativeMetal fafb7fc，`/private/var/ngpu/debug/gpu-traces`）：Turnip u_trace 每個 pass 的 GPU 時間戳；scratchpad `utrace.py`、`utframe.py`、`utkgsl.py`、`utclk.py` 對齊 KGSL trace
- plugin 日誌公開（`NBLOG` 用 `%{public}s`）：被拒的 pipeline、缺少的 selector、Rust panic 進系統日誌，pipeline 日誌有 `L`／`D` 行；scratchpad m2v27 worktree 的 `examples/journal_replay.rs` 用 guest 的 metallib 重放被拒的日誌行
- frames.trace 逐幀＋u_trace：scratchpad `gestframes.py`、`utgroups.py`、`gaps.py`
- `droidvm-sched-trace.patch`＋`tools/rig/schedtrace.py`（device 81def30）：context switch／wakeup 寫進 12 MiB ring，host 直接讀，和 frames.trace 同一個 mach 時鐘
- `uclat`：在手機上量 WALT 升頻延遲
- scratchpad `tlrow.py`、`tlcap.sh`、`cop-ab.sh`、`blitrace.py`、`inflight.py`：spindump 時間線、complete-on-post A/B、host blit 時序
- NativeMetal exp-bgra 94b6c57 的 Q 列：metal2vulkan 排程器（host step／gate／event／grouping）
- 觸控延遲：手機端直接讀 guest 記憶體的計數器（觸控、HID 報告、畫面）＋screenrecord；scratchpad `rec.sh`、`probe.sh`
- 計數器：`native_virtio_time`（區塊裝置、驗證、複製、等鎖時間，每顆磁碟）、`droidvm_input_still`、`droidvm_virtio_gpu_stray`、`droidvm_virtgpu_slow_ops`
- `logarchive.py` 修正（device d7b279c）：`log show` 不再停在最後一筆 timesync
- rig `panic.py` 用 fileset 的 KernelCache slide 符號化（device 3804c57）；AdrenoMetal 334eeb8 在 library 檔打不開時寫 log
- `kcdiff.py`：guest 記憶體對照映像
- `sheng-exc-name` 讓 userland 例外進 kernel log；Mac 上掛 SystemOS cryptex 用 `ipsw dyld a2s` 符號化（slide 從 pc 附近 8 個指令字在 cache 裡找，16K 對齊）
- `stacks+*.ips`（stackshot，`export.py`／`crashes.py` 取）含所有行程的 thread 堆疊：看 userland 卡在哪
- `scratchpad/entdump.py`／`entclass.py`：擷取、分類 entitlement；產物 `fullset-candidate.plist`、`ents-21H461.jsonl`、`ents-21H461-cryptex.jsonl`

## 1. 現況

**能用：**
- **開機：** edk2-gunyah → UniXNU → DarwinBoot → XNU（我們自己編的 DEVELOPMENT_ARM64）→ iPadOS userland。
- **畫面：**
  - 鎖定畫面、主畫面、Dock。
  - 小工具：時鐘（即時）、備忘錄、行事曆、新聞、天氣。
  - 設定 app 的所有頁面。
  - 桌布：包括動態的萬花筒、天文、天氣、Emoji、顏色，以及「新增桌布」圖庫。
- **Safari：** 網頁正常顯示、可以打字、搜尋建議會出來。
- **輸入：** 觸控，加上實體鍵盤（app 的 virtio 鍵盤）和螢幕鍵盤。
- **網路：** en0，DHCP IPv4／IPv6，走 app 的 br-wifi。
- **Metal：** 經 virtio-gpu＋drm2kgsl 到主機 KGSL（droidvm-gpu 已在 2026-10-26 退役）。GFXBench 的 Metal 測試都能跑到出分。
- **旋轉：** 面板是直式 1024×1366；陀螺儀（crosvm `--input motion`）讓 iPadOS 自然旋轉，app 可以轉 Display、鎖 Screen。
- **電池：** 狀態列顯示手機真實電量與充電狀態（crosvm goldfish battery → `IOPMPowerSource`，2026-10-28，5566 上驗過）。
- **Data volume：** 12 GiB，會持續保存。
- **owner 工具：** 可以 ssh 進 guest；有 ownervisor 服務管理、toybox、zsh、lsdiag、gfxprobe。

**已知問題（目前開著的）：**
1. **render server 的 DeviceLost（偶發）：** host KGSL hang → backboardd client 0 EDEADLK → 畫面閃爍到重開機，沒有自動恢復（人工重啟 backboardd 可重開 context）。Maps 因此刻意不放進 GPU client 名單。
2. **偶發文字破圖：** 少數情況仍會出現錯位條紋，等重繪才恢復，無法照指令重現（常見那種已修，見 memory [[droidvm-garbled-text]]）。
3. **健康檢查的 fence waits timed out 計數持續增加**（見第 7 節其他待辦）。
4. **一次性系統卷讀取失敗（原因未明）：** 陀螺儀那版某次開機約 4 分後 `/dev/disk3s1` 讀取全 EIO、backboardd 崩潰循環；重開後 6+ 分鐘正常，未再現。

## 2. 架構

**手機端：**
- Android，root（KernelSU），Gunyah。
- DroidVM app（`cn.classfun.droidvm`）＋ droidvmd。
- crosvm fork。
- 大頁模組 `gh_hugepage_reserve`：guest RAM 只從這裡來。
- `gunyah_share`：pseudo-unprotected VM 的 RAM 共享。

**crosvm 裝置**（VM 的 `extra_options` 加上 app 自動產生的部分）：

| 裝置 | 用途 | guest 端 |
|---|---|---|
| `--block droidvm-disk.img`（ro） | FAT ESP：UniXNU 設定、kernel、ADT、trust cache、**打包的 Data seed** | edk2／DarwinBoot |
| `--virtio-mmio-block os.img`、`systemos.img`（ro） | iPadOS 系統，有驗證 | NativeVirtioBlock |
| `--virtio-mmio-block data-store.img` @0x0a002000 | Data 的持續層：16 GiB 檔案，裡面是一個視窗 | `package/DroidVMDataStore.c` |
| `--virtio-mmio-input` @0x0a003000-0x0a006000 | 觸控、平板、鍵盤、滑鼠 | `package/DroidVMVirtioInput.c` → NativeHidInput |
| `--droidvm-gpu` @0x0a007000 | 自訂的 KGSL proxy（wire 3） | `package/DroidVMGpu.cpp` ＋ NativeAdreno |
| `--virtio-mmio-net` @0x0a008000 | en0 | `DroidVMVirtioNet.c`／`DroidVMVirtioEthernet.cpp` ＋ IONetworkingFamily-177（從原始碼編） |
| `--virtio-mmio-gpu` @0x0a009000 | 顯示（2026-10-24 起取代 simplefb）：guest-handle blob scanout，主機 udmabuf GPU blit | `package/DroidVMVirtioGpu.cpp`＋`DroidVMVirtioGpuDisplay.cpp`，經 NativeLegacyDisplay 的 `native_legacy_gpu_offer` |

**guest kernel：**
- UniXNU fork 的 XNU，加上 `patches/xnu/*.patch`。我們加的 patch 都以 `zz*` 開頭：

| patch | 作用 |
|---|---|
| `zzt` | 讓 sandbox 內也能讀 hw.pagesize |
| `zzu` | 沒有 cprotect 時仍保存 data protection class |
| `zzw`／`zzwb` | GPU client 的 sandbox 授權 |
| `zzx` | pmap 的 cache flush，以及 user mapping 計數 |
| `zzy` | bindfs vget（讓可刪除的系統 app 和它們的小工具能註冊）、staged apps、GPU addon 掛載 |
| `zzz` | 開機進度 |

- 板子的程式碼在裝置 repo 的 `package/`，在 tree 裡以 `kits/droidvm` symlink 編進 XNU。重要的開機參數在 `board.toml` 的 `kernel_args`：
  - `droidvm-data-persist=2`
  - `owner-dataprotect=1`
  - `droidvm-gpu-clients=…`（支援 `*X*` 和 `X*` 樣式）
  - `armcpu-self-ipi=1`、`armcpu-spi-ipi=1`：Gunyah 會丟掉 guest 的 SGI，沒有這兩個就完全沒有 IPI。
  - `droidvm-disable-jobs=…`

**GPU userland：**
- `/private/var/ngpu/addons/NativeAdrenoMetal.bundle` 包含三層：NativeMetal frontend、metal2vulkan（Metal→Vulkan）、turnip。
- turnip 用 darwin KMD，基於 Droid-VM/mesa 的 droidvm 分支，加上 fork 的 `patches/mesa/`。
- metal2vulkan 依 pin 版本，加上 fork 的 `patches/metal2vulkan/`。

**owner userland：** 在 `/private/var/ngpu/bin`。
- kernel 在開機時直接 spawn ownervisor，它再管理 dropbear 等服務。launchd overlay 的做法行不通。
- 其他工具：toybox、zsh、lsdiag、gfxprobe。

## 3. Repo 與分支

**只推各 repo 的 XNU wip 分支，合併由使用者決定。** commit 作者用 `HuJK <gh@hujk.org>`。

| Repo | 本機位置 | 分支 → 推送 |
|---|---|---|
| DroidVM meta repo（本 repo） | `DroidVM_wip_gpu` | `wip/hackintosh` → `git push https://github.com/Droid-VM/droidvm-meta-repo.git wip/hackintosh:wip/hackintosh`（origin 是 SSH，不能用；**絕不推 `droidvm`**） |
| UniXNU 裝置 repo | `UniXNU/UniXNU-droidvm` | `main` → `git push droidvm main:wip/hackintosh`；推之前先跑 rig 的 `scrub_rig.py` |
| UniXNU fork | `UniXNU/orgrepos/UniXNU` | `droidvm` → `git push droidvm droidvm:wip/droidvm`（不推 origin） |
| crosvm | 本 repo的 `crosvm/` | `wip/virtio-mmio` → Droid-VM/crosvm 的 `wip/virtio-mmio` **和** `wip/hackintosh`（後者是 build 腳本的分支鏈會拿的） |
| Virtualization（display client，連結進 crosvm） | 本 repo 的 `Virtualization/` | `droidvm` → `git push droidvm HEAD:wip/hackintosh`；改完要重建 crosvm |
| virglrenderer（drm2kgsl） | 本 repo 的 `virglrenderer/` | `droidvm` → `git push droidvm droidvm:wip/hackintosh` |
| Banners-Turnip（host Turnip） | 本 repo 的 `turnip/banners-turnip`（detached HEAD） | `git push origin <commit>:refs/heads/wip/hackintosh` |
| fork 的 Droid-VM submodule（AdrenoMetal＝Droid-VM/NativeMetal、Adreno740＝NativeAdreno、GopFramebuffer＝NativeMobileDisplay、DarwinBoot；10-28 起用上游的新目錄名） | fork 的 `drivers/` | `git push droidvm HEAD:wip/hackintosh`；先推 submodule 再推 fork |
| DroidVM app | `DroidVM-display-fix` worktree | `git push origin HEAD:wip/hackintosh` |

2026-10-24 最初交接時的head（歷史；最新commit見文件頂端）：
- meta：本 commit
- 裝置 repo：`512350a`（rig 工具）
- fork：`0fecbc8`
- crosvm：`61c47a469`

元件（NativeMetal、NativeAdreno、NativeMobileDisplay…）是 fork 的 `drivers/` submodule，先找各自的 dev 分支，再用 org 的穩定 droidvm 分支。
上游 UniXNU 每天有幾十個 commit。2026-10-28 把 fork rebase 到上游 `120067c`（元件改名，見 10-28 06:00 續報）。上一次 merge 是 fork 的 a3412ef（2026-10-23），重點：
- 在獨立的 worktree 試合併。
- 用 bundle 把 Mac 的 checkout 搬過去。
- patch 名稱改了要 reset `.cache/xnu-work`。
- defconfig 要 `CONFIG_XNU_BUILD_ARCHIVES=y`。

## 4. 建置與部署

建置在 build Mac 上（`BUILD_HOST`，UniXNU checkout 的 `out/droidvm` 就是 `BUILD_OUT`），部署和測試在這台 Linux 上用 rig 做：
- 工具在裝置 repo 的 `tools/rig`。
- 私有設定放旁邊的 `rig.env`，不進 git。
- 變數表見 rig README。

| 改了什麼 | 怎麼做 |
|---|---|
| 全部從頭（新 checkout） | 在 Mac 的裝置 repo 跑 `python3 scripts/build-droidvm-all.py --unique-chip-id …`（`--ipsw-cache` 免重抓 IPSW 卷）→ `out/droidvm/release/`；rig 的 `fresh-deploy.sh [--build]` 把它變成手機上的一台新 VM（舊的連目錄一起刪） |
| XNU patch | 在 Mac 的 `out/droidvm/tree/.cache/xnu-work` 改 → tree 裡跑 `scripts/save-xnu-patch.py NAME FILE` → 把 patch 複製回本機 fork。要換掉已套用的 patch，先用**絕對路徑**的 `git apply --reverse` 退掉舊版 |
| kernel 或板子程式碼（`package/*.c`） | 同步裝置 repo 的 `package/` **和 `scripts/`** 到 Mac → Mac 上 `PATH=/opt/homebrew/bin:$PATH ./unixnu build kernel` → rig 的 `deploy.sh` → `vm.sh restart`。編譯失敗後缺物件時，刪掉 `build/xnu/ios-obj/.../osfmk/DEVELOPMENT/startup.o{,.json}` 讓它跑 bootstrap pass |
| Metal 外掛（frontend、bridge、turnip） | `tools/rig/plugin-redeploy.sh`（`FORK` 指向本機 fork）。Mesa 的 patch 清單（`scripts/data/adreno-compiler-inputs.json` 的 `patches`）改了，就把 Mac 的 `.cache/mesa-work` reset 回 pin，再照順序 `git apply`。metal2vulkan 的 patch 由 AdrenoMetal 的建置自己堆疊套用，原始碼只要停在 pin |
| owner 工具或 trust | 在 Mac 跑 `build-droidvm-*.py`，然後 `tools/rig/payload-redeploy.sh [TOOL…]`。新的 binary 要 reseed；只是新增一個服務用已信任的 binary 不必 |
| crosvm | 本 repo 的 `./2_build_crosvm.sh`（約 10 分鐘）→ `vm.sh stop` → `CROSVM_BIN=… tools/rig/crosvm-deploy.sh` → `vm.sh start`。guest 的 `DroidVMGpuWire.h` 和 `droidvm_gpu.rs` 的 wire 版本必須一致 |
| Data seed | `seed-data-grow.py`、`add-*-data.py` 產生新的 `.dbr`，再 `DATA_SEED=… payload-redeploy.sh`。**換 seed＝Data 重來**（第 6 節） |
| 只改開機參數 | 改 rig 的 `out/unixnu.toml` → `MTOOLS_SKIP_CHECK=1 mcopy -o -i out/droidvm-disk.img out/unixnu.toml ::/EFI/UniXNU/unixnu.toml` → adb push。下一次 `deploy.sh` 會蓋掉它 |
| VM 設定（螢幕、extra_options） | daemon IPC `vm_modify`；rig 本機的 `unixnu-vm.config.json` 給 `daemon-recover.sh` 用 |

**目前的 Data seed 是 `data-12g-skip-ov.dbr`，任何 payload 重建都必須用它。** 它是 `data-2g-skip-ov.dbr` 經 `seed-data-grow.py --gib 12` 長出來的，`payload-redeploy.sh` 預設就用它。
如果 payload 用回 2 GB 的 seed，Data 會被悄悄重設，然後在 2 GB 滿掉時開不了機：panic 訊息是 `board launch policy failed: 28`，也就是 ENOSPC。

## 5. 除錯流程

- **開關 VM：** 一律用 `vm.sh`：stop → 等 10 s 讓大頁池回收 → 確認池滿才 start。同時一定要開著 `hostwatch.py` 監視，它會回報主機重開、crosvm 死掉、開機失敗。
- **每次開機後：** 先看 `health.py`。kernel panic 不會讓 VM 停下來，所以要用 `panic.py`（或 `peek.py kernel_debugger_entry_count`）確認。新的 crash 用 `crashes.py` 看。
- **進 guest：** `guest-ssh.sh "toybox …"`。Data 重設之後先跑 `guest-ssh.sh --key`。guest 的 zsh 不能在 data vault 裡用 glob。
- **log：**
  - 快速看：`guest-newlogs.sh 2`，最新的 tracev3 解析成 JSON lines。
  - 完整：`logarchive.py` 做鏡像後用 `unifiedlog_iterator` 解析，或在 Mac 上用 `logs.sh`（macOS 的 `log show`）。
  - 換 seed 後要重新做鏡像。
- **畫面：**
  - `fbgrab.sh`：截圖。
  - `frame-burst.sh`：動畫中連拍。
  - `input.py`：tap／swipe／unlock／text，座標用 guest 的。
  - 手機上的畫面凍住時，用 `show-vm.sh` 恢復。
- **kernel 狀態：** `peek.py SYMBOL`。常用的有：
  - `native_adreno_client_log 352`：每個名稱的 opens／refused。
  - `droidvm_gpu_lost`
  - `native_adreno_kept`
  - `native_legacy_copy_{n,last,max,sum}`：顯示複製的時間，單位是 19.2 MHz tick。
  - `armcpu_ipi_sent`
  - `droidvm_store_*`
- **行程：**
  - `trace.py --focus NAME --symbolize`：看卡住的行程在哪。
  - `lsdiag procs`：取代 ps。
  - `lsdiag app|ext|rebuild|relink|protect|copy|image`：查 LaunchServices、data protection、ATX 圖檔。
  - `gfxprobe sync|cg|box|coherence`。
- **crash 符號化：** 在 Mac 上用 `dsc_sym.py`、`dsc_dis.py`（`PATH=/opt/homebrew/bin`）。`dsc_dis.py` 顯示的 adrp 立即值大約差一頁，要自己解原始指令。

## 6. 陷阱（每個都花過至少一輪）

**Data 與部署：**
- **Data 重設：** 換 seed 時 store 會從頭開始。重設前先把 `/private/var/ngpu` 備份出來：
  `guest-ssh.sh "toybox tar cf - -C /private/var ngpu" > ngpu.tar`，再存一份 md5 清單。
  重設後要還原有差異的檔案：外掛 bundle、`bin/gfxprobe`、`bin/lsdiag`、`wallpaper/*`。
  - 每個檔案先寫成 `NAME.new` 再 `mv -f`，不要直接覆蓋正被 map 的 dylib。
  - 接著 `gfxprobe sync`，然後重開機。
  - toybox 的 `mkdir -p` 在 `/private` 上會回 EROFS，只能 mkdir 最後一層。
- **放檔案進 guest 之後不能馬上停 VM。** 曾經截斷 21 MB 的外掛，SpringBoard 在 dyld 階段 crash loop。要先 `gfxprobe sync` 再等一下。
  另外，不要往已經 panic 的 guest 放檔案：`export.py put` 會默默失敗。
- **外掛部署被中斷**會留下半份 bundle，結果是黑畫面加 crash loop：重跑 `plugin-redeploy.sh`。
- **VM 停下後 daemon 偶爾會死**（hostwatch 報 BOOT FAILED）→ `daemon-recover.sh`，再 `vm.sh start`。

**GPU：**
- **dmesg 裡的「Sandbox deny iokit-open-user-client AGXDeviceUserClient」是雜訊**，是 NativeAdreno 自己的診斷呼叫印的。真正的資料看 `native_adreno_client_log`。
- **GPU client：**
  - 名單是 `board.toml` 的 `droidvm-gpu-clients`。
  - 沒有 GPU 裝置的行程讀不了已 twiddle 的 ATX，所以設定 app 必須是 GPU client。
  - 每個名稱的開啟次數用 token bucket 限制：8 次，每 30 秒補 1 次。

**顯示與快取：**
- **MobileGestalt 會快取 ArtworkDisplayGamut。** 舊的 Data 要刪一次 `systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist`，`--display-gamut sRGB` 才會生效。
- **ReportCrash 每個行程每天最多 25 份報告**，換 seed 會重置這個上限。
- **guest 給 host 顯示的 blob 至少要 `stride × align(height, 4)`。**少一點點，host Turnip 就拒絕匯入，那一幀改走 CPU 複製（7～10 ms），
  crosvm 也會切換 ANativeWindow 的 producer。匯入點只有 `DroidVMVirtioGpuDisplay.cpp` 的 `create()`（surface 和開機 framebuffer）。
- **crosvm 的 C++ log（display client）只進 logcat**，而手機的 logcat 幾分鐘就被系統訊息洗掉；stderr 檔（app 的
  `cache/console_<vm>_stderr.log`）只有 Rust 的 log。要抓就先在手機背景錄：
  `logcat -v time -T 1 crosvm:V BufferQueueProducer:D '*:S' > /data/local/tmp/crosvm-logcat.txt &`。
- **檢查手機上的旋轉：**`dumpsys SurfaceFlinger` 找 VMNativeDisplayActivity 的 SurfaceView（BLAST）層：Display 轉過時
  `geomBufferTransform` 應該不是 0，`toDisplayTransform` 的 x、y 縮放應該相同。

**owner 工具：**
- **每個 owner 工具都要 ad-hoc 簽，而且要帶 `com.apple.private.security.no-container`**，否則會被 launch constraint 擋下。
- **lsdiag 要用 manual RC**（`-fno-objc-arc`）。
- **IONetworkingFamily 的子類別一定要 `-D__PRIVATE_SPI__`**，否則 MAC 位址會是 0。

**主機：**
- **Mac 的 `hdiutil attach` 在 `/Volumes/DATA` 上 over ssh 會被拒**，seed 相關的腳本要從 `/tmp` 的 root 跑。
  `seed-data-grow.py` 的磁碟辨識 bug 已在 fork `0fecbc8` 修好。
- **主機當機**都是 watchdog bite，而且都發生在 stop 之後立刻 start、大頁池還沒回收完的時候 → 一律照 `hugepage-harness.md` 做。
- **手機重開機後，先跑 `load-modules.sh` 再 `vm.sh start`。**沒有 `/dev/udmabuf` 時 crosvm 一啟動就 panic
  （「failed to open udmabuf driver」，hostwatch 報 UNEXPECTED＋BOOT FAILED）。大頁池被系統拿回、補不滿時，重開手機能拿回整池。
- **host Turnip 的建置目錄編的是另一份原始碼**（`turnip/banners-turnip/turnip_workdir/mesa/build-android-aarch64` 用相對路徑指到
  `DroidVM_meta_repo/turnip/...`）：要改那一份，改完用 llvm-objdump 確認。

**量測：**
- 手機廠商會動態限制大核頻率（1.36～2.57 GHz 之間都看過），每個效能數字都要記 `scaling_max_freq`。
- 主機上 vCPU 執行緒的 CPU% 沒有參考價值（96% 在 Gunyah 的 hvc 裡，包括 guest 的 WFI）；看 guest 的 `gfxprobe cpu`。
- 主畫面從不閒置：時鐘小工具約 20 fps、時鐘 app 圖示約 10 fps。量手勢 fps 要扣掉前後的這些幀。
- 用 `lsdiag launch-args` 啟動 GFXBench 偶爾會卡在 dyld（suspended），kill 後重新啟動。

## 7. 下一步

### TODO（使用者 2026-10-28 指定，依序）

原則：
- **ownervisor 只用來除錯。**整個拿掉也不能影響 iPadOS 的使用；使用者會用到的功能都要走 iPadOS 原廠的機制
  （launchd、IOKit、HID、locationd 等），不能依賴 ownervisor 底下的服務。要先盤點目前哪些功能靠它（例如旋轉的 orientd）。
- **外設通用性（host 端）：**
  - 最後推送的 host 端（crosvm、virglrenderer／drm2kgsl、DroidVM app）相對 DroidVM 原本只能多出**通用的虛擬裝置**
    （virtio、virtio-mmio 這類標準傳輸）。不加只給 iOS 用的裝置（droidvm-gpu 就是因此在 2026-10-26 退役）。
  - host 程式**不辨識 guest**：不依 guest 名稱、context 名稱分支（drm2kgsl 的 `xnu:` 判斷已改成對所有 guest 一樣）。
    真的要不同時，用 guest 自己宣告的 capability。
  - guest 特有的行為放在 guest 端（裝置 repo、UniXNU fork）；例如 guest 頁面的生命週期歸 guest 管。
  - 共用的 crosvm／drm2kgsl 改動要 opt-in，或證明對 Linux guest 沒有影響，並在 Ubuntu VM 上實際驗過。
  - 每加一段 host 程式先問：Linux guest 能不能原封不動地用它？
- **外設的架構**（`plans/HOST_PERIPHERALS_SURVEY.md`「建議架構」）：同一個 Android 資料來源與共同協定，經標準虛擬裝置送進 guest，
  再由各 guest（iOS、Windows、Linux）自己的 provider 接到原生 API。線上協定不帶 IOKit selector、Objective-C 物件、Apple struct
  或 host 指標。傳輸能通只代表資料送得到 guest，不代表系統 API 已經接上（例如陀螺儀現在進得了 guest，app 卻讀不到）。

1. ✅ **陀螺儀：原廠路線已完成（2026-10-28）**：kernel HID 服務（`DroidVMMotionHid.inc`）→ locationd/CoreMotion → backboardd；ADT 根 compatible 改 `J120AP`；一般 app `CMMotionManager` 讀得到，自動旋轉不靠 orientd；待補項見「未解／待查」。memory [[droidvm-motion-sensors]]。
2. **iPadOS 內的 IPA 安裝器 / UniXNUSetting（進行中）。** 見最上面「TODO 2 續報」：runtime 信任快取已證實可行、entitlement 可任意授予。配對先擱著。範圍與動工順序：
   - **(1) shell 環境（先做）＝ 4 個工具，全部簽上 entitlement 全集 + owner-trust，每個 applet/行程都帶滿權限**（AMFI 對 cdhash-trusted binary 授予任意 entitlement，已驗）：
     **applebox**（單一 multicall：Apple OSS `_cmds`（file/text/shell/adv/network…）+ toybox 補缺口（xz/timeout/od…）+ zsh，用 `ld -r` + exported-symbols-list 併一顆）、**dropbear**（ssh，login shell exec applebox-zsh → 滿權限 zsh）、**debugutil**（原 gfxprobe）、**libimobiledevice**（備著，待配對通了才用）。entsh 暫不做（這幾顆滿權限的就是它）。
     `build-applebox.py`：table-driven、per-tool `-Dmain=<t>_main` + `ld -r` localize + 聚合一個 `applebox.json` trust。研究報告見 scratchpad `applebox-research.md`。
     待辦子項：entitlement 全集要盤一份 curated 清單（多數 boolean、少數陣列值如 iokit-user-client-class/finegrained-*；逐步加、個別 restricted AMFI 可能拒要一加一驗）；terminfo db 要一起 stage（less/vim/top/zsh 互動要）；scp/sftp 用 OpenSSH sftp-server。
     **entitlement 全集 → 日後搬進 kernel（`cap.sys_admin` 計畫）**：現在「簽滿」是為了快速把全集盤穩；穩了之後定義一個自定義 entitlement **`cap.sys_admin`**（非 apple 前綴，不受 AMFI restriction 檢查，就是個 dict key），工具只簽它，**patch AMFI 在 exec 附掛 entitlement 時、看到 `cap.sys_admin` 就注入 kernel 內 curate 的全集 dictionary**。這個附掛點**一處同蓋 kernel 端（`IOTaskHasEntitlement`／sandbox／MACF）與 userspace （`SecTask`/`csops` → lockdownd 等）**，因兩層都讀 task 附掛的 entitlements；value 型 entitlement（finegrained-*、iokit-user-client-class）要給值/萬用。`cap.*` 命名留擴充空間（日後 `cap.net_admin`、`cap.pairing`… 各映射 entitlement 子集，做成 capability 風格）。取捨：改全集內容「簽滿」是 re-sign（輕）、`cap.sys_admin` 要重建 kernel（重），所以迭代用前者、穩定用後者。
   - **(2) trust-cache user client（唯一要改 kernel 的一塊）**：讓 userspace 呼叫已驗證的 `load_legacy_trust_cache`（owner-gated）。+ 機內 cdhash 抽取 → **普通 IPA 安裝端到端**（抽 cdhash → runtime 信任 → staged + LaunchServices 登記 → 上主畫面；移除走 SpringBoard 長按）。
   - **(3) 持久化 trust 清單**：裝好的 cdhash 存到 Data；**開機早期由 kernel（`DroidVMTrustCache.c`）在 Data 掛上時直接讀已存清單重載**（不經 ownervisor 服務——見上方 10-28 下午續報的決定；撐過重開機、不用主機、不重建 kernel）。+ **特權 IPA 安裝/移除**（同 (2) + 全集只簽在 helper；移除：刪 bundle + 從清單移除）。
   - **(4) serial-shell 服務**（zsh 掛到指定 serial，getty 式）+ **ownervisor `protected` 旗標**（ssh、serial-shell 可停不可刪）+ **服務管理**（新增/刪除/列表/狀態，GUI 由 (5) 經 app socket 交 ownervisor 執行）。
   - **(5) UniXNUSetting＝ownervisor 的 in-app GUI（10-28 晚修訂，取代「特權 app」與更早的「GUI＋unixnusettingd」）**：staged 系統 app（唯讀 os.img、不可刪）、以 mobile 跑、不簽大 entitlement；要 root 的操作經 app 專用 socket 交 ownervisor 執行，ownervisor 以對端 cdhash 只認 payload 內建的 UniXNUSetting，擋未經授權的第三方 app；debug 工具目錄 root-only。細節 `plans/UNIXNUSETTING.md` §3.1。
   - **配對（獨立 track，擱置）**：USB-mux 模擬 / 無線（設密碼）/ 直接寫 `/var/db/lockdown` 的 pair record（吃 kernel 控制，待逆向格式）。
3. **音訊（喇叭、麥克風）：原廠堆疊已通（2026-10-28，5566）。**guest `IOAudio2Device`（Speaker／Mic 依 UID 分裝置）→ VirtualAudio →
   HAL → virtio-snd → crosvm vhost-user AAudio helper（app uid）；PCM 以 self-test＋`backend=file` 驗到逐位元正確。
   **剩：**iOS 裡實際播放（聽得到）與錄音（`droidvm_snd_rx_periods` 會漲）的驗收；commit。見最上面 10-28 晚續報、memory [[droidvm-audio]]。
4. **VPU（編碼器、解碼器）與相機（含對焦、閃光燈）。**
   - **host＋Linux guest：已完成。**virtio-media 三個裝置（相機、解碼器、編碼器）、vhost-user helper（app uid）、`media_host`／`media_guest`
     池、Linux guest driver（DKMS）、libva-v4l2 都做完，Ubuntu 上出貨組態驗收（Firefox 硬解 H.264／VP9／AV1、ffmpeg 硬體編碼、相機）
     大部分已關；`wip/vpu` 已 rebase 進 `wip/hackintosh`。還開著的：**P-6**（畫面卡死、之後鎖定畫面全黑，blocker，未能重現）、**P-5**
     （硬體編碼 drain 偶發掉尾幀，非決定性）、P-2（low）、P-9 的 12.4 h 實機 soak 沒做。細節 `plans/VPU_DESIGN.md` §7.8。
   - ✅ **iPadOS guest：傳輸層第一個里程碑完成（10-29）**：guest 自檢讀到解碼器格式（H264／HEVC／VP90／AV01 → NV12，9 個 command、0 timeout）；crosvm `--virtio-mmio-media`（d5c13c494）、guest 輪詢式 `package/DroidVMVirtioMedia.c`（e66a7b4）、動態 ADT（DarwinBoot b2ad902、device 3f3474d）。memory [[droidvm-dynamic-adt]]、[[droidvm-virtio-media-ios]]。
     - 陷阱：`VIDIOC_QUERYCAP` 由 driver 用 config space 自己回答，送給 device 會回 ENOTTY。
     - 解碼、編碼的往返已由下面的 VideoToolbox 路線做完；相機還沒接。
   - **接 VideoToolbox：用 Apple 自己 VM 的 paravirtualization 通道（11-02 查明，從 24A446 shared cache 讀出）。**
     - iPadOS 27 的 VideoToolbox 本身帶完整的 paravirtualized 解碼器、編碼器、JPEG、motion estimation（`ParavirtualizedVideoDecoder_*`
       等；macOS host 那半邊 `VTParavirtualizationHost*` 也編在同一顆）。`VTParavirtualizationIsRunningInGuest` 只看
       `AppleVideoToolboxParavirtualizationDriver` 打不打得開（不看 `kern.hv_vmm_present`），打得開就讓合格的 codec 全走它。
       userland 原封不動，XNU 扮演 host，把 session 翻成 virtio-media 的 V4L2：符合「通用 host 裝置、XNU 翻譯、userland 原廠」。
     - 傳輸（`VideoToolboxParavirtualizationSupport.framework`，8 KB，`AppleParavirtGPU-1`）：IOServiceOpen type 0。
       selector 0 `{size}`→`{容量, 送出 buffer, 佇列}`（kernel 映射進行程，先 16 KiB）；1／2 註冊／註銷 guest UUID（16 bytes）；
       3 `{長度, 最多 5 個 IOSurface ID}`→`{status}`；4 佇列取空。host→guest 用 IODataQueue＋notification port（每則 ≤16 KiB）。
       sandbox 只放行 `AppleVideoToolboxParavirtualizationUserClient` 這個名字（kernel 的 profile 有這串）。
     - 訊息：48 bytes 的 FigAtom `'vtpv'`（類型 FourCC、flags、guest UUID、request ID），後接序列化 CF 型別與 sample buffer 的 atom。
       解碼器：guest→host `decs` 列表、`dcap` 能力、`+dec` 建立、`dsta` 開 session、`dcan`、`dfrm` 解一幀、`dfin`、`dcop`／`dset`／
       `dmul`／`dsup`／`dsav` 屬性、`dinv`、`-dec`、`Bye!`；host→guest `Dbuf` 請 guest 配 pixel buffer（IOSurface）、`Demt` 送出解好的幀、
       `Ddpa`／`Dpba`／`Drpa` 屬性、`Dfub`。編碼器對稱（`encs`…）。
     - ✅ **解碼、編碼都通（11-02）**：`package/DroidVMVTParavirt.cpp`（傳輸、Apple 名字的 driver／user client）＋`DroidVMVTHost.cpp`
       （host：session 依 UUID，V4L2 session、worker thread、IOSurface 查詢）＋`DroidVMVTWire.h`（訊息格式）。device 1479852（解碼）、
       9d5a0ce（編碼）、706338e（預設開啟）。開機就發布（關掉：命令列 `droidvm-vt-paravirt=0`）；執行中改 `kern.droidvm_vt_paravirt`
       只影響之後才啟動的行程（videocodecd 若已啟動就不會換）。
       測試：`gfxprobe vtdecode FILE N`、`gfxprobe vtencode [hevc] W H N`（輸出 `/private/var/ngpu/enc.h264|hevc`）、`gfxprobe imgdecode FILE N`。
     - 「在 guest 裡」除了 codec 還改了什麼（24A446 shared cache）：VideoToolbox 隱藏非 paravirt 的硬體 codec（AVD、AVE，這裡本來就沒有）；
       MediaToolbox 放寬防錄影檢查（外部保護不足時不遮畫面，FairPlay 這裡本來就沒有）；CMPhoto 問 paravirt JPEG（`jcap`），被拒後用軟體。
       實測開／關對照：HEIC、JPEG 像素相同、速度相同；4:2:2 H.264 兩邊都解不了（軟體也不支援）；不開時 H.264 編碼是軟體 `anon-1`（720p 32 fps）。
       VM 要有 `--virtio-media kind=decoder` 與 `kind=encoder`（＋`--virtio-mmio-media`、`media-host-mb=160`）。
     - 格式怎麼來的：Mac（macOS 27）上 `tools/vtpv-oracle`：`hostonly` 把 guest 錄到的訊息餵給 VideoToolbox 自己的 host session，
       錄 host 的回覆（`Efds` 要回真的 format description，host 才會吐 `Eemt`）；編碼器在 macOS 是 out-of-process，loopback 跑不起來。
     - 陷阱：
       - guest framework 在 selector 3 整段持鎖，host 不能在 guest 的 thread 上等 guest 回覆（輸入排隊、worker 做事）。
       - MediaCodec 會扣幀（單張 IDR 也扣），`dfin`／`ecfr` 要 drain（`*_CMD_STOP`→LAST→`*_CMD_START`），兩秒還沒交出的幀回錯誤。
       - 高通 AVC 解碼器 720p 要 21 個 CAPTURE buffer；c2.qti 解碼最小 96x96。
       - IOSurface 只能被「建立者 task」或「已持有它的 client」查：解碼的 surface 是 videocodecd 自己建的，核心另開一個 client 查即可；
         編碼的 surface 是 App 的（XPC 傳進來），要用行程自己的 client（`IOUserClientCreator` 找）建 port 再查。
         同一個 client 查第二次會被拒，所以依 ID 快取，session 結束 `clientClose` 一次還。
       - 關鍵幀不能帶 `NotSync`（WebRTC、gfxprobe 都只看有沒有這個 key）。
       - 解碼器、編碼器 session ID 會重複，媒體事件要依裝置＋session 分派。
       - VideoToolbox 只轉發 `dsup`／`esup` 支援清單裡有的屬性，清單外的它自己回 -12900、不問 host；目前清單只列
         `UsingHardwareAccelerated{Decoder,Encoder}`（回 true，device fab4fb1）。HEVC 編碼 session 會主動問
         `MVHEVCVideoLayerIDs`（多視角 HEVC），回不支援是對的。
     - 下一步：開機預設發布並測 Safari／AVPlayer 播放與錄影類 App；1080p；VP9／AV1 解碼（VideoToolbox 的 paravirt 清單能不能列）。
5. **地理位置（磁力計、GPS、Wi-Fi 唯讀）。**
   - **GPS：調查完、暫停（使用者 10-28 指示，晚點回來）。**結論見最上面 10-28 晚續報：J120 上 locationd 不會啟動 GNSS（WiFi 版
     iPad 沒有 `kProviderLocationGps`），要換 J121AP 身分（值已從官方 IPSW 取得）；未解的是 J121 上 locationd 走 gpsd 還是基頻
     QMI。路線：virtio-console 具名 port（NMEA）→ XNU 驅動提供 `/dev/cu.gps` → gpsd＋薄 vendor plugin。
   - 磁力計：手機有 mmc56x3x，走第 1 項的 HID 路徑（未做）。
   - Wi-Fi 唯讀：survey 過，kernel 沒有 IO80211 family、真驅動是 DriverKit，太重，暫不做。
6. ✅ **電池：已完成（2026-10-28）**：crosvm goldfish battery（通用 sysfs backend）→ `DroidVMBattery`（`IOPMPowerSource` 子類別）→ powerd → SpringBoard，放電、充電都驗過。memory [[droidvm-battery]]。
7. **電源鍵、音量鍵（使用者 2026-10-30 加；DroidVM app 目前沒有這些按鍵）。**
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

### 其他待辦

1. **介面流暢度（2026-10-28 的狀態見最上面的續報）：**瓶頸是 metal2vulkan 每個 draw 約 27 µs。兩條路還沒決定：
   - A1：一般 draw 的快速路徑（依 pipeline 快取要檢查的功能），工程較大，預估每個 draw 省 30～50%；
   - A2：零星小修（例如 `render.rs` 的 `sampler_maps` 每個 draw 掃一遍所有 texture），約 5%。
   另外待查：外掛裡閒置吃 19% CPU 的執行緒（省電）；健康檢查的「fence waits timed out」計數一直增加；
   把 GPU 頻率拉高能讓顯示階段減半，但屬於耗電策略，要使用者同意。
2. **GFXBench：**全部 Metal 測試都能跑到出分（這版 iOS 建置沒有 Tessellation 測試）。待辦：把改過的 `libvirglrenderer.so` 正規打包進 APK。
   - 已完成：記憶體破壞（16 位元 ASID）、持久化 shader 快取（NativeMetal 3eb5926：Car Chase 232 → 133 秒；`NATIVE_METAL_NO_SHADER_CACHE=1` 關閉；
     GFXBench 的 container 在 `/private/var/mobile/Containers/Data/`，root ssh 列不出來）。
3. **Metal Check：**host／guest 均 28 PASS、0 FAIL、0 SKIP，三項 benchmark PASS；最後 20 輪 API／counters PASS 但視覺 FAIL（見上文），
   不是完整的 Metal 或 display conformance。
4. **GPU 恢復與文字破圖：**尚無自動 GPU 恢復；若文字破圖重現，立即截圖並記錄 backboardd 的 IOSurface 資訊。
5. ~~3D 改走 drm2kgsl~~：已完成（2026-10-25 起預設）；venus／gfxstream 之後再評估。

使用者允許 Luna（max）承接明確、機械性的工作；Sol承接大範圍程式碼／文檔粗篩，由主agent細讀。

## 8. 文件索引

- `hugepage-harness.md`：VM 開關與主機當機的除錯流程（必讀）
- `plans/IOS_VIRTIO_GPU_SURVEY.md`：iOS guest 改走 virtio-gpu 的 survey 與路線
- `plans/NATIVE_CONTEXT_PLAN.md`、`plans/VENUS_SURVEY.md`、`plans/VENUS_BRINGUP.md`、`plans/GFX_SHIP_PLAN.md`：Linux guest 的三條 3D 路線
- `plans/DISPLAY_PIPELINE_DECOUPLING.md`：crosvm 的 screen／frame／exporter 模型
- `plans/HOST_PERIPHERALS_SURVEY.md`：Android host 外設來源及 iOS／Windows／Linux guest 接入方案（尚未實作）
- 裝置 repo `tools/rig/README.md`：rig 工具與變數
- 裝置 repo `board.toml`：開機參數；每一項都有註解說明為什麼要加
- 各 repo 的 commit message：每個修正的根因都寫在 commit 裡，這是最完整的歷史
