# iPadOS on DroidVM（UniXNU guest）：開發進度與交接

更新：2026-10-27。目標：讓 iPadOS 17.7.11（21H461，iPad7,1／iPad Pro 12.9"）在手機（Snapdragon 8 Gen 3、Adreno 750、
Gunyah）上的 DroidVM 裡能日常使用。App Store 不在範圍內。

## 續報（2026-10-27 01:00，Claude）：整套 iOS hackintosh 都推上 GitHub 了

從 meta repo 的 `wip/hackintosh` 重建時，各元件依 `lib_branch.sh` 的分支鏈（`wip/hackintosh` → `droidvm`，app 是 → `master`）拿到的版本，都已核對等於目前部署的版本。

**沿分支鏈拿到的元件**

| Repo（Droid-VM/） | 分支 | Commit |
|---|---|---|
| droidvm-meta-repo | `wip/hackintosh` | 本 commit |
| crosvm | `wip/hackintosh`（新建，和 `wip/virtio-mmio` 同一個 commit） | `89c3f9725` |
| virglrenderer（drm2kgsl） | `wip/hackintosh` | `b743904fc` |
| edk2-gunyah | `wip/hackintosh` | `67b9dba4a` |
| DroidVM app | `wip/hackintosh` | `852027a56` |
| gfxstream、Virtualization、libvncserver、zstd、crosvm-minimal-manifest、droidvm-guest-additions、mesa、mesa-cross、gunyah_host_mod | `droidvm`（這次沒改，本機沒有未推的 commit） | — |

- 之前 crosvm 只推 `wip/virtio-mmio`。分支鏈找不到 `wip/hackintosh` 時，會退回沒有 virtio-mmio 的 `droidvm`，iOS VM 就開不了機。現在兩個分支都要推。

**UniXNU 這邊（建在 build Mac 上）**

| Repo | 分支 | Commit |
|---|---|---|
| UniXNU-droidvm（裝置 repo） | `wip/hackintosh` | `d520caf7b`（rig 工具已補齊、scrub 過） |
| UniXNU fork | `wip/droidvm` | `16f58b47d` |
| fork 的 Droid-VM submodules | NativeMetal、NativeAdreno、NativeMobileDisplay、ArmCpu 在 `wip/hackintosh`；DarwinBoot 在 `wip/droidvm-virtio-gpu` | `b69ca28f4`、`77088961d`、`3aa4b2680`、`52454a292`、`af934b218` |
| fork 的 UniXNU/ submodules | 上游各自的 `main` | 每個 pin 都確認可由遠端分支取得 |

**不在 repo 裡的東西**
- Apple 的二進位：iPadOS IPSW、kernelcache。
- 測試用的 GFXBench 本體。它的改動收在裝置 repo 的 `compat.patch`。
- rig 的私人設定：`rigenv.sh`、VM config 等。
- `DroidVM_20260903.zip`（舊 app 包）。

**GFXBench（Metal，onscreen；目前的堆疊：virtio-gpu＋drm2kgsl，droidvm-gpu 已退役）**

| 測試 | fps | 量測 |
|---|---|---|
| Aztec Ruins Normal | 17.7–17.9 | 10-26 21:41／21:51，大核限頻 1.36 GHz |
| Aztec Ruins High | 8.6 | 10-26 19:47，限頻 1.71–1.92 GHz |
| Car Chase | 10.8 | 10-26 21:41，1.36 GHz |
| T-Rex | 33.2 | 10-26 21:41，1.36 GHz |
| ALU 2 | 56.3–57.7 | 10-26 21:41／21:51 |
| Manhattan 3.1 | 22.0 | 10-26 13:00，M7 之前，頻率沒記錄 |

- 舊的 droidvm-gpu 路徑上，ALU 2 是 22 fps。
- 頻率沒鎖時，同一測試可以差到 30%：13:00 那輪 T-Rex 42.7、Car Chase 13.7。
- 診斷用的 dump 跑分偏低，不算在內。

## 續報（2026-10-26 22:10，Claude）：host 端只剩通用裝置：droidvm-gpu 退役，drm2kgsl 不再辨識 guest

使用者的目標：最後推送的 host 端（crosvm、virglrenderer、app）相對 DroidVM 原本只多出通用裝置（virtio-mmio 可以）。盤點結果：

| 項目 | 性質 | 處理 |
|---|---|---|
| crosvm：virtio-mmio 的 block/input/net/gpu、Gunyah ioeventfd datamatch 修正 | 通用 | 保留 |
| crosvm：`--droidvm-gpu`（KGSL proxy，自訂 virtio ID 59） | iOS 專用 | **已移除**（crosvm 89c3f9725） |
| drm2kgsl：依 context 名稱 `xnu:` 決定釋放時解除綁定 | 辨識 guest | **改成所有 guest 適用**（virglrenderer b743904f） |
| crosvm virtio-gpu：flip fence 不再強制完成、guest blob iovec | 通用，但改了 Linux 的行為 | **Ubuntu 驗證通過**（見下） |
| `--simplefb`、`--pre-alloc`、`--android-display-service` | 9 月就在 `droidvm` 分支 | 原本的功能 |

**droidvm-gpu 退役（M7）。**
- 3D 其實早就全走 virtio-gpu＋drm2kgsl。這次開機的 crosvm log 裡，所有 client（backboardd、WidgetRenderer、各 Poster、GFXBench）都是 drm2kgsl context，droidvm-gpu 0 個。
- 拔不掉的原因：virtio-gpu 3D 的使用者入口（open type 0x4149）掛在 NativeAdreno 的 user client 上，而它和 Metal 的 accelerator 註冊都排在 droidvm-gpu 裝置 attach 之後。
- guest 改動（device 04d9f0d）：沒有 `droidvm-gpu=1` 時，`DroidVMGpu.cpp` 用不接後端的 KGSL 物件發佈 user client，再註冊 accelerator。KGSL 路徑（0x4147）會被拒絕。
- board.toml：拿掉 `droidvm-gpu=1` 和 `--gpu-mmio`。net 與 virtio-gpu 的 MMIO 往前一頁（0x0a007000、0x0a008000），並換上新的 crosvm FDT。
- VM 的 crosvm 參數用 daemon 的 `vm_get`／`vm_modify` 修改。
- 驗證（沒有 droidvm-gpu 的 VM）：
  - accelerator 註冊完成（stage 5）；
  - GFXBench Aztec 17.9 fps、Car Chase 10.8、T-Rex 33.2、ALU2 56.3（大核 1.36 GHz）；
  - Metal Check 29 項正確性測試全過；
  - 小工具、桌布、圖示正常，沒有新的 crash。

**drm2kgsl 的解除綁定。**
- 釋放 guest 配置的 BO 時，所有 context 都解除它的 VA 綁定。舊規則只對 `xnu:` 開頭的 context 這樣做。
- 這樣是安全的，因為兩種 guest 都保證 unref 時已經沒有在途使用：
  - Linux Turnip 的 zombie VMA 等 queue fence 過了才關 handle；
  - freedreno 把 BO handle 交給 EXECBUFFER，kernel 會持有到 fence；
  - XNU 驅動等關閉前的 submit 完成才 unref。
- host 配置的 BO 維持不解除。`NCTX_KEEP_FREED_RANGES=1` 可退回舊行為。
- 驗證：
  - UniXNU 不變；
  - Ubuntu（有 guest pool）跑 vkmark headless 得 1913 分，再加壓 3 分鐘，host 和 guest 都沒有 GPU fault。
- Ubuntu 改成 pseudo-unprotected（沒有池，guest 顯示 `guest-alloc: no pool in DT, backing blobs from shmem`）：vkmark headless 1890 分，再加壓 3 分鐘，沒有 GPU fault。
  - 第一次這樣開機時拿不到網路；第二次開機網路正常，原因不明，沒有再重現。
  - 網卡由 networkd 的 `Type=ether` 比對，與 PCI 位置無關。
  - Ubuntu 的設定已還原成 `protected_without_firmware`。

**crosvm flip fence（不再 25 ms 強制完成）在 Linux 上的驗證。** Ubuntu（有 guest pool）停掉 sddm，用 `vkmark --winsys kms` 直接做 KMS page flip：
- mailbox 模式：約 470 fps，跑完不卡；
- fifo 模式：穩定 120 fps（每幀都等 flip）；
- fifo 跑的同時，把 app 的顯示畫面叫到前景再按 Home，反覆拆裝 Surface 四次：只有拆的瞬間掉到 97 fps 一次，馬上恢復，guest 從沒卡住；
- crosvm 沒有任何 flip fence 警告。

**還沒做：**
- guest 端的完整清理：只服務 0x4149 的小 user client，移除 KGSL proxy 原始碼。
- vgpu-3d 下 scanout 不等 3D 完成（`droidvm_gpu_scanout_wait` 在這條路徑沒作用）。
- Aztec 牆面暗塊：查到這一步（NativeMetal b69ca28 的工具）。
  - 暗塊來自 G-buffer pass 後段的光照 draw（envprobe irradiance 盒子）；跳過這些 draw，暗塊就消失。
  - 每個盒子讀自己探針的 SH 係數。GPU 寫出的 SH 和 CPU 照 `m_envprobe_generate_sh_compute` 用同一幀的探針圖集重算的結果一致（每個被畫到的探針誤差 ≤ 0.2%），所以 SH 的計算沒錯。
  - 暗的探針（例：12、17、19 號）是因為它們的環境圖本身就暗。環境圖來自直接光照 lightmap（太陽加火炬，1024x1024），而 lightmap 約 98% 是黑的，只有陽光和火炬附近有亮區。
  - 陰影取樣用 shader 裡寫死的 constexpr sampler（`compare_func::less_equal`），和綁定的 sampler 無關。
  - 這可能就是演算法在室內的正確結果，也可能是 lightmap 的打光或陰影有誤。需要真機或 Android 原生 GFXBench 同一時間點的畫面當參考才能判斷。

## 續報（2026-10-26 19:50，Claude）：Aztec Ruins 全黑修好了：pipeline reflection

**先處理 hugepage pool。** 17:00 那次之後 pool 卡在 2498/2560，acquire 補不回來。使用者同意重開手機，重開後 pool 回到 2560/2560。重開手機後的步驟：
- `load-modules.sh`：載入 Host Share 等模組；
- `guard-start.sh`：啟動 vmguard；
- 掛上 hostwatch 與 guard 的監視器；
- `vm.sh start`。

之後每次關機仍會掉約 115 頁（例：2445/2560），但在剛重開的手機上，`vm.sh` 的 acquire 補得回來。

**Aztec Ruins 全黑。**
- 原因：NativeMetal 建立 pipeline 時，`reflection:` 一律回 `nil`。GFXBench 的 NGL 引擎（只有 Aztec 用它；T-Rex、Manhattan、Car Chase 用舊引擎）完全靠 reflection 找 uniform：
  - uniform struct buffer 的成員給出每個 uniform 在 `setVertexBytes`/`setFragmentBytes` 資料裡的 offset；
  - 各 argument 給出每張貼圖和 buffer 的 index。
- 沒有 reflection，它就什麼都不綁。shader 讀到的全是 0，所有幾何都被裁掉，深度維持在清除值 1.0，整個畫面全黑（但照樣出分，8.7 fps）。
- 修正：NativeMetal 582edf5（fork 8659a7b）。
  - bridge 新增 `nmb_render_pipeline_reflection` / `nmb_compute_pipeline_reflection`，把 metal2vulkan descriptor 的 reflection 輸出成 JSON。
  - frontend 用 Metal 自己的 `MTLArgument`、`MTLStructType`、`MTLStructMember`、`MTLArrayType`、`MTLPointerType`、`MTLTextureReferenceType` 和 pipeline reflection 類別的子類別回應，所以呼叫端的類別檢查會通過。completion handler 版本也一併回傳。
- 結果：神殿、陰影、景深、bloom 都正確。Aztec Normal 在大核 2.11 GHz 時 20 fps，1.71 GHz 時 13.5 fps；High 8.6 fps。同一版下 Car Chase 和 T-Rex 都正常，沒有 crash。

**找出原因的工具（NativeMetal 582edf5）：**
- `NATIVE_METAL_WARNINGS=1`：metal2vulkan 的訊息（降級、精度說明），每種印一次。
- `NATIVE_METAL_DUMP_CB=起:數量`：在 app 的第「起」個 command buffer 之後讀回結果。
  - 每個 pass 的 attachment：load/store/clear。
  - 每個 pass 前 6 個 draw：pipeline（函式、格式、vertex layout）、depth state、viewport，以及每個綁定的 buffer/bytes 的前幾個 word。
  - 每個 target：各通道的 min/max/mean、NaN、inf、黑色比例，以及 32x8 的亮度格。
  - Aztec 的線索就是這樣看出來的：每個 draw 都只綁了 vertex buffer 0，完全沒有 uniform。
- GFXBench 原始碼（BSD，含 NGL）在 Mac 的 `$BUILD_OUT/benchmarks/gfxbench`。

**還沒解決：** Aztec 牆面上偶爾有幾塊柔邊、和螢幕對齊的暗色矩形。前面的藤蔓不受影響，所以問題出在光照（可能是 SSAO 或間接光）；Car Chase 天空頂端的小暗塊可能是同一類問題。32x8 的亮度格太粗，找不到這些暗塊，下一步要做全解析度擷取。

## 續報（2026-10-26 17:00，Claude）：GFXBench 的破圖（T-Rex 全黑、Car Chase 車身全黑加尖刺）修好了

使用者回報「3d 渲染結果有破圖」。之前只看分數、沒有看畫面。逐一截圖後，各測試狀況如下：

- **Manhattan 3.1**：正常。
- **T-Rex：整個畫面全黑，但照樣出分。**
  - 原因：它用 PVRTC 貼圖（`MTLPixelFormatPVRTC_RGBA_4BPP`）。Adreno 的 Vulkan 沒有這個格式，metal2vulkan 只保留區塊供複製，任何取樣都會被拒絕，結果 2,491 個 command buffer 裡有 1,242 個被拒。
  - 修正：NativeMetal 4b52c78。PVRTC 貼圖改建成 RGBA8，`pixelFormat` 仍回報 PVRTC。`replaceRegion` 和 `copyFromBuffer:toTexture:` 在 CPU 上用 PVRTC1 演算法解碼。現在 0 個被拒，叢林正常顯示。
- **Car Chase：車身全黑、頂點尖刺、大片黑色三角形、過曝。**
  - 原因：Bézier 車身用 `[[patch(quad, 0)]]`（0 個控制點，per-patch 資料用 `patch_id` 讀取）。metal2vulkan 從 TESS tag 讀到的數量 0 被當成「沒量測過」拒絕，bridge 就把它回報成「沒有 patch」，NativeMetal 也就沒把 tessellation 狀態傳下去（繞向、partition、factor 的 step function）。
  - 修正：fork 32a7224，`patches/metal2vulkan/0010-patch-with-no-control-points.patch`，回報 Quad 和 0。現在車子和場景都正確。
  - 剩下的小問題：天空頂端偶爾有幾個小的深色方塊。

用來找出原因的工具：

- `gfxprobe tess`（device 0d2c663）：畫 tessellation 並逐像素檢查。三角形與四邊形、各種 factor 和 partition、Car Chase 的每一種用法（FractionalOdd、36-byte 控制點加 `UChar3Normalized`、UInt16 控制點索引、PerPatchAndPerInstance factor），以及 `patch(quad, 0)`。
- `NATIVE_METAL_TIMING=1`：每 20 秒把遙測表寫到 stderr。`S c<commits>/<被拒絕>` 這一行一眼就能看出有沒有被拒的 command buffer，T-Rex 就是這樣發現的。
- `NATIVE_METAL_DUMP_TESS=1`（NativeMetal 76641fa）：把 tessellation 的原始碼和 pipeline 狀態寫到 stderr。

另外加了持久化的 shader 快取（NativeMetal 3eb5926）：Car Chase 從 232 秒降到 133 秒，快取熱時載入只剩約 40 秒。

**陷阱：** 有幾次重開 VM 後，DroidVM app 的 native display 沒有啟動。手機上會出現「Failed to start native display」，或停在開機選單；dmesg 一直出現 `virtio-gpu: command 104 response 1200`，也就是每個 RESOURCE_FLUSH 都被 host 拒絕。`./vm.sh attach` 或 `vm.sh restart` 就能恢復。截圖之前先用 `health.py` 確認「display N frames presented」有在增加。

## 續報（2026-10-26 11:00，Claude）：隨機記憶體破壞的根因：8 位元 ASID＋vCPU 遷移；改 16 位元 ASID 後 GFXBench 10/10

**根因。**
- 這個 XNU 用 BCM2837 板子設定編譯，沒有 `HAS_16BIT_ASID`，只用 8 位元硬體 ASID（255 個）。
- guest 有約 340 個行程，pmap 於是讓多個 address space 共用同一個硬體 ASID（virtual ASID，`pmap_asid_plru`）。
- 切換時只對「這顆 CPU」的 TLB 清掉那個 ASID（`pmap_switch`、`cpu_sw_asids`），前提是每顆 CPU 的 TLB 永遠是自己的。
- 在 Gunyah 底下 vCPU 執行緒沒有綁核心（`phone-vcpu-affinity.sh`：每個 vCPU 每秒遷移約 280 次）。一個實體核心會留著別的 vCPU 剛用過的 TLB 項目，行程就用到另一個共用 ASID 行程的轉換，讀寫到對方同一虛擬位址的頁。
- 最常中的是 shared cache 的 `__DATA_DIRTY`：每個行程都在同一位址，而且大家都一直在讀。裡面有 `__stack_chk_guard`、environ、os_alloc_once 表、pthread keys、malloc 狀態。
- 症狀正是先前看到的那一串：stack canary 失敗、pthread 簽章、os_unfair_lock、objc_sync、AutoreleasePoolPage、malloc free list。不只 GFXBench，launchd（造成 kernel panic「initproc exited」）、剛出生的 xpcproxy、symptomsd 等 daemon 也會中。

**修正：** fork `patches/xnu/zzxa-16bit-asid.patch`（fork 433dbf9）。
- BCM2837.h 定義 `HAS_16BIT_ASID`，打開 TCR_EL1.AS，每個 address space 一個硬體 ASID。
- `pmap_bootstrap` 檢查 `ID_AA64MMFR0_EL1.ASIDBits`，不支援就 panic。所有 ARMv8.2 以上的核心都支援。
- cpu.c 的 `cpu_sw_asids` 加上條件編譯。

**A/B（CPU 固定頻率，同樣 10 項重型測試，背景跑 `cowcheck`）：**

| | 8 位元 ASID | 16 位元 ASID |
|---|---|---|
| GFXBench 10 項 | 每輪 4–5 項失敗（今天多輪） | 10/10 出分 |
| `cowcheck` 外來 guard | 約 1/4,000 個子行程 | 112,000 個子行程 0 次 |
| 新 crash report | 每輪數份，含系統 daemon | 0 |

效能也變好：Car Chase 11.0 fps（之前約 9.5），Manhattan 3.1 為 18.1 fps（16.7），Aztec High 4.9 fps（1.3–3.2）。

最終版（拿掉診斷儀器，只留 16 位元 ASID）的確認 soak 結果：
- GFXBench 9/10 出分。唯一的失敗是一次 Car Chase 在載入階段（`PROGRESS: 0.90`）結束，原因不明：那一輪沒開探針，而 app_ios 當天的 crash report 已經到 25 份上限。
- `cowcheck` 11.1 萬個子行程 0 次外來頁面。
- 修正之後沒有任何系統 daemon 的 crash report（daemon 不受 app_ios 的上限影響）。
- kernel 沒有 panic。

另外，`cowcheck` 每 spawn 一個子行程，dmesg 就印一行 `AMFI: Launch Constraint Violation (enforcing)`。子行程其實照常執行，但其他 kernel 訊息會被洗掉。

之後兩輪都是 10/10：
- 一輪開探針、不跑 `cowcheck`，CPU 固定頻率。
- 一輪**解除固定頻率**（`phone-cpu-pin.sh free`，big core 上限約 2.57 GHz），加 `cowcheck` 8 萬個子行程，0 次外來頁面，沒有任何 crash。

修正後合計 **39/40**。修正前「頻率上限越高、崩潰越多」的現象，正是 ASID 撞車的特性：同時在跑的行程越多，vCPU 遷移越頻繁，就越容易撞上。

自然頻率下的成績（fps，括號內為固定 1.4 GHz 時）：
- Aztec Normal 10.3（2.4–4.7）
- Manhattan 3.1 為 22.0（16–18.7）
- T-Rex 42.7（28–34）
- Car Chase 13.7（9.3–11.1）
- ALU2 44.5（32–39）
- Aztec High 2.6–3.8（GPU 到 66°C，受溫度限制）

陷阱：`phone-cpu-pin.sh unpin` 寫回的是 pin 當下存的值，如果那時 OPLUS 正在限頻，就會寫回被限制的上限。要回到自然狀態請用新的 `free`（恢復硬體範圍）。

**怎麼找到的（這些工具都留在 gfxprobe，見各自的 usage）：**
- NativeMetal 的 abort 探針（NativeMetal 3ce9d65，`GFX_ENV='NATIVE_METAL_ABORT_PROBE=1' ./gfx-suite.sh ...`）抓到一次 `__stack_chk_fail`：**全域** guard 變成另一個合法格式的值（byte 1 為 00，是 kernel 產生的 guard），frame 裡存的副本沒變。也就是說，GFXBench 看到的是另一個行程的資料頁。
- `gfxprobe cowcheck PROCS LIFE_MS SECONDS` 讓大量短命行程盯著自己的 guard 和 environ。負載下重現；**不跑 GPU、只用 CPU 記憶體壓力也重現**，GPU 路徑因此排除。其中一次讀到外來 guard 之後，同一頁幾微秒後又跟自己的副本完全一樣，表示是暫態的轉換錯誤（TLB），不是頁被換掉。
- 之前的 `asidcheck` 沒抓到，因為它的測試頁只有自己的子行程會碰，而且是在閒置時跑。

**排除過的（各有工具，結果都是 0）：**
- GPU 晚寫入已釋放的 blob：在驅動裡隔離已釋放的頁 2 秒再檢查，17,154 個 blob、8.7 GB。
- 誤寫進長駐唯讀頁：`textcheck`，含 `__DATA_CONST` 的逐字比對。
- 全新頁面不乾淨：`zerocheck`，3.6 億頁。
- reusable 頁被回收後資料遺失：`reusecheck` 加對照組，對照組被收回 1,358 萬頁，寫回的頁 0 遺失。
- SIMD 和 TSD 暫存器：`regcheck`、`regfault`。
- mach 收訊的大小：`machcheck`。
- 檔案讀取：`filecheck`。
- 匯入時的位址轉換：page stamps。
- 編譯器並行：加鎖之後照樣失敗。原本的 `std::mutex` 已經讓編譯一次一個。另外，MTLCompiler 會用 `split_stack_call` 自己 mmap 8 MiB 的 stack。
- GFXBench 改走 droidvm-gpu（`GFX_ENV='TU_DARWIN_VIRTGPU=0'`）：照樣破壞，launchd 也死過一次。

**陷阱：**
- 改 XNU：直接在 xnu-work 改到別的 patch 的 context，build 重新套 patch 時會失敗，而且 late patch 已經被反向。先跑一次乾淨的 `unixnu build kernel` 讓 tree 恢復，再改，再 `save-xnu-patch.py NAME FILES`，把 patch 放進 fork 和 `$BUILD_OUT/../../patches/xnu`。
- 改 gfxprobe 必須整個 payload-redeploy（trust bundle 釘住它的 CDHash）。
- CPU 吃滿超過一分鐘的探針會被 vmguard2 凍結；用 SIGCONT 恢復 crosvm，再殺掉探針。
- ReportCrash 每個行程每天最多 25 份 report；之後的崩潰只會顯示「no result」。

**開機 panic「ArmCpu: IRQ drain exceeds 128 id=1b」已處理**（ArmCpu 52454a2，fork 9ebd783）。
- 今天約 15 次開機中出現 2 次。
- 原因：virtual timer 在開機時本來就會突發。vCPU 被 host 搶占後，`rtclock_intr` 剛設的 deadline 到 EOI 時已經過了，timer 就再觸發一次。這是正常的突發，不是卡住的中斷線。
- 只有 `armcpu-diagnostics=1` 會把超過 128 次變成 panic。
- 現在改成計數：`armcpu_irq_long_drains` 記錄超過 128 次的次數，`armcpu_irq_drain_most` 記錄單次最大值。只有單次超過 100 萬次（真的停不下來）才會 panic。計數在沒開診斷時也有效。
- 驗證：連續重開 5 次都沒有 panic，單次最多 drain 102、56、64、20、86 次，常常逼近舊的門檻。
- 開機期間 timer 中斷約每秒 2.3 萬次，閒置時約每秒 1,500 次（4 核）。

**還沒處理的：** 一次 vmguard「secondary v3 never slept」，所有 CPU 都已過 stage a6，不是 MMU-off 那個問題；killvm 再 `vm.sh start` 就好。

## 續報（2026-10-26 03:00，Claude）：GPU 記憶體從 2 GB 降到 590 MB；手機 CPU 被限頻；記憶體破壞仍在查

**越跑越慢**有兩個原因。

第一個原因是 guest 記憶體被 GPU 吃光（不是 GPU 本身，也不是 GPU 過熱）：
- 普查（rig `vgpu-clients.py --sizes`）顯示每個 Metal 行程都有 4–10 個 64 MiB 的 resource。
  - 原因是 metal2vulkan 的子配置器每個 pool 固定用 64 MiB 的區塊，`keep_room` 還會在建立 device 時，先替每個 pool 各做一個。
  - 在 guest-alloc 模式下，這些區塊一建立就是 wired 的 guest 記憶體。主畫面的 GPU client 加起來就佔 2 GB，一開機 free 只剩 6 MB。
- 修正：fork `ed1f49e`（`patches/metal2vulkan/0009-growing-memory-blocks.patch`）。
  - 區塊從 4 MiB 開始，跟著 pool 成倍成長，上限 64 MiB；超過 32 MiB 的請求照舊獨立配置。
  - 開機時 GPU 佔用從 2 GB 降到 590 MiB，wired 從 2.4 GB 降到 1.7 GB。
- 結果：Car Chase 14.4 fps（853 分），第二次 14.0 fps，不再變慢。修正前是 9–11 fps，第二次會掉到 4.4 fps。
- 同一時期的 soak（前 4 項）：Aztec Normal 8.6 fps（553 分）、Manhattan 3.1 19.7 fps（1224 分）、T-Rex 28.3 fps。

第二個原因是 **手機的 CPU 被限頻**（02:30 才發現）：
- 大核 `scaling_max_freq` 是 1.71 GHz，硬體上限是 2.96–3.30 GHz。
- 當時螢幕亮著、DroidVM 在前景、省電模式也沒開。cooling device 都沒有作用，所以是 OPLUS 的電源 daemon 設的，
  上限會隨時間變動。
- guest 裡的 GFXBench 很吃 CPU，在這個上限下 Aztec Normal 只有 3 fps（不限頻時 8.6 fps）。
- 之前以「GPU 溫度正常、`thermal_pwrlevel` 0」排除過熱，但沒有看 CPU。所以這之前的效能比較，都要在相同的 CPU 上限下才成立。
- rig 的 `phone-hostmem.sh` 現在會記錄各叢集的上限，`gfx-soak.sh` 也會帶上（device `04de512`）。
- 我沒有去解除這個上限：那等於繞過廠商的溫控。

**host 端的殘留 GPU 映射**（virglrenderer 本機 `735e6936`，不在推送清單內，沒有推送）：
- drm2kgsl 刻意不在 free 時解除 VBO 綁定，context 結束時也不清它的 slice。
  - 對 host 配置的頁面這是安全的；但 guest-alloc 的頁面在 guest 釋放後會被重新配置，GPU 卻還留著映射。
  - KGSL mapped 5 GB，guest 實際活著的只有 1.15 GB。
- 修正：context 名稱以 `xnu:` 開頭的（iOS guest 驅動會這樣命名，device `fea1b94`）會這樣處理：
  - free guest-alloc BO 時，用 child id 解除它的範圍；
  - context 銷毀時，用 child 0 清掉整段 slice。
  - Linux guest 不受影響。修正後 KGSL mapped 持平。
- **手機上的 `libvirglrenderer.so` 是手動換上去的**，原檔是 `usr/lib/libvirglrenderer.so.orig`。從桌面打開 DroidVM App 時，
  splash 會因為 hash 不同重新解壓 runtime，把它換回原版。要長期使用，得照 `6_build_apk_prepare.sh` 的流程打包進 APK。

**guest 驅動**（device `fea1b94`）：
- `GEM_CLOSE` 原本每次都要等這個 client 的 GPU 工作全部完成，最多 5 秒，逾時就直接釋放。
- 現在改成延後釋放：等關閉前送出的 submit 都完成才釋放頁面。
- 加上 host 端的修正後，Aztec Normal 從 2.65 fps 提升到 7.1 fps，Driver Overhead 2 從 3 幀提升到 94 幀，Fill 2 跑出 6632 分。

**記憶體破壞（仍在查，尚未找到來源）：**
- 症狀：重負載 GPU 測試期間，行程隨機崩潰。被破壞的都是 malloc free list、`os_unfair_lock`、pthread signature、
  objc_sync 這類資料，也出現過 stack canary 失敗（dyld `trieWalk`、Safari `fileRead`）。
  - 受影響的不只 GPU client，askpermissiond、PerfPowerServices、Spotlight、UserEventAgent 也有。
  - 10-25 01:37 droidvm-gpu 還是預設時，Spotlight 就出現過一次。
- 已排除：
  - virtqueue 的配置；
  - 區塊裝置（NativeVirtioBlock、NativeRamBlock、DataStore 都經 bounce buffer 或 IOKit 複製，邊界都有檢查）；
  - compressor（崩潰期間壓縮量是 0）；
  - compressor 的 per-CPU scratch（`compressor_cpus` = 4）；
  - droidvm-gpu（目前沒有 client）。
- 新的 gfxprobe 診斷（device `6d08705`）全部乾淨，包括在 GFXBench 執行期間：
  - `memcheck`：會換手頁面的 256 MiB，11 萬次換手，0 錯；
  - `memidle`：閒置頁面，27 次檢查，0 錯；
  - `regcheck`：v0–v31 與 TSD 跨搶佔，360 萬輪，0 錯；
  - `atomcheck`：LSE 原子操作與 `os_unfair_lock`，2 萬輪，0 錯。
- 加上 0009 之後的第一輪（Car Chase ×2、Aztec High）沒有崩潰。但接著的 12 項 soak 中，前 4 項正常，之後 7 項裡有 6 項當掉，
  一旦開始就會一直出事。這些崩潰大多是 stack canary 失敗：在 `io_connect_method`（Turnip 呼叫 user client 的 MIG stub）、
  libGPUCompilerImplLazy，以及 dyld 的 `trieWalk`。canary 是跟 `__stack_chk_guard` 比對的，所以更像是存放它的資料頁被改了，
  不是 stack 真的溢位。
- 試過但已退回的兩個修改：
  - **compressor 模式**：ADT 沒有 `/defaults kern.vm_compressor`，所以 kernel 停在 CONFIG_FREEZE 的預設值 8（只給 freezer 用，
    匿名頁面完全不能回收，vm_stat 的 throttled 最高 1.8 GB）。改成 2 之後 compressor 確實啟用，memidle 驗證壓縮與解壓都正確；
    但那段時間剛好碰上 CPU 限頻，無法判斷效能的差異，所以先退回。ADT 的修改保存在 rig 的 `out/msl/vm-compressor-adt.patch`（`scripts/make-droidvm-adt.py` 的 /defaults 加上 `kern.vm_compressor` = 2）。
  - **編譯執行緒常駐、一次一個請求**：也碰上 CPU 限頻，看不出效果，已退回（NativeMetal `git stash`）。
- ReportCrash 每個行程每天最多寫 25 份報告，超過之後 GFXBench 的崩潰只會顯示成「no result」。把舊的報告搬走也沒有讓它歸零。
- 下一步：關掉 guest 的 en0，在同樣的 CPU 上限下跑 soak 比較崩潰次數。如果破壞消失，就是 virtio-net RX 的 DMA；如果還在，
  就看 guest kernel 的 pmap/VM。

**踩到的坑：**
- crosvm 的 stderr 進 daemon 的 console stream，上限約 1 MiB，超過後新的內容就被丟掉。vm.sh 的 `vm_console_clear` 少了 `stream`
  參數，所以從來沒有清成功，導致開機後的 GPU 錯誤全部看不到。已修正（rig `aca4d3e`）。
- logcat 的 ring buffer 只有 256 KiB，幾分鐘內就被 servicemanager 的訊息洗掉。
- crosvm 裡本來就沒有叫 `v_gpu` 的執行緒，不能把它的「消失」當成 worker 死掉。
- drm2kgsl 每個活著的 resource 會開 3 個 fd（crosvm 的 udmabuf、`dmabuf_fd`、export dup），所以 host dmabuf ≈ guest resource × 3
  不是洩漏。
- vmguard 遇到所有 secondary 連續空轉約 1 分鐘時，會停住 crosvm。純 CPU 的壓力測試要讓 vCPU 定期休息。
- 21:33 那次開機，backboardd 的 GPU 一開始就卡住（5 個 submit、8 次 fence 逾時、沒有出圖）。log 剛好被上限吃掉，原因不明，
  之後沒有再發生。

## 續報（2026-10-25 21:00，Claude）：GFXBench 的重型測試都能跑到出分

使用者回報「跑一跑就退到桌面，到不了出分的畫面」。這其實都是 App 當掉，依序修了六個原因：

1. **virtio-gpu 指令槽用完**（device `f9a129e`）：
   - 帶 fence 的 SUBMIT_3D 會占住槽位，直到 fence 觸發。64 個槽全被占住後，`post()` 等 5 秒就回 `kIOReturnNoResources`。
   - Turnip 把它當成 DeviceLost，`newBuffer` 拿到 nil，App 就當掉。
   - 修正：同樣 7.8 MiB 的 guest 記憶體切成 256 槽（12 個大槽）。沒有空槽時，只要還有指令陸續回來就一直等；60 秒都沒有指令回來才拒絕。
   - 新增計數器 `droidvm_virtio_gpu_slot_waits_long` 和 `droidvm_virtio_gpu_slot_wait_max_us`。GFXBench 執行時最高同時用到 8 槽，沒有長時間等待。
   - 使用者問過：iOS VM 的 `gpu_drm2kgsl_pool_mb`、`gpu_guest_pool_mb` 都是 0（64 MB 是 Ubuntu VM 的設定）。
     - msm 的 ccmd 包在 EXECBUFFER 裡，經由這些槽位送出；回覆放在 msm shmem blob。
     - BO 都是 guest 頁面（CREATE_BLOB 以 ≤4 MiB 的連續區塊，或 CREATE_BLOB_USER），以 udmabuf 匯入 KGSL。
     - 所以卡住的是槽位數，不是記憶體。
2. **`supportsFeatureSet:` 沒有實作**（NativeMetal `c9da401`）：
   - 這個舊 API 一律回 NO，GFXBench 還在用它。
   - Car Chase 因此回報 UNSUPPORTED_TC_TYPE（ASTC 屬於 iOS_GPUFamily2_v1），也看不到 tessellation（GPUFamily3_v2）。
   - 修正：iOS 的 feature set 改成照對應的 Apple family 回答。
3. **`llvm.bitreverse` 不支援**（fork `patches/metal2vulkan/0008-llvm-bitreverse.patch`）：
   - MSL 的 `reverse_bits` 會編成這個 intrinsic。Aztec 和 Car Chase 的 Hammersley 取樣有用到，pipeline 因此被拒（UnknownIntrinsic）。
   - 修正：對應到翻譯器原本就有的 ReverseBits。
4. **Metal compiler 的 stack 不夠**（NativeMetal `67e95fc`）：
   - 在 App 行程裡編譯時，compiler 跑在 512 KiB 的 dispatch worker 上，Aztec 在 libGPUCompilerImplLazy 裡觸發 `__stack_chk_fail`。
   - 修正：每次編譯改在一個 16 MiB stack 的執行緒上跑。
5. **少了帶 LOD clamp 的 sampler 綁定**（NativeMetal `45136ad`）：
   - 缺的是 `setFragmentSamplerState:lodMinClamp:lodMaxClamp:atIndex:`。Car Chase 的 occlusion culling 暖機時呼叫它，丟出 unrecognized selector。
   - 修正：每組 clamp 值做一個 sampler 分身並快取起來。sampler range 的各種綁定也一起補上。
6. **tessellation 完全沒接**（NativeMetal `69ed69a`）：
   - metal2vulkan runtime 本身已經實作 tessellation，這次把 bridge 和 frontend 接上：
     - pipeline descriptor 帶入 tessellation 狀態；
     - function 回報 `patchType` 和 `patchControlPointCount`；
     - 補上 factor buffer、factor scale，以及四種 patch draw。

分數（1366×1024，virtio-gpu）：

| 測試 | 分數 | fps |
|---|---|---|
| Car Chase（metal_4） | 652 | 11.0 |
| Aztec Ruins High（metal_5_high） | 477 | 7.4 |
| Aztec Ruins Normal（metal_5_normal） | 170 | 2.7（比 High 還慢：越跑越慢，見上面的續報） |
| Manhattan 3.1（metal_manhattan31） | 824 | 13.3 |
| Manhattan（metal_manhattan） | 865 | 14.0 |
| T-Rex（metal_trex） | 1803 | 32.2 |
| ALU 2（metal_alu2） | 1501 | 50.0 |

同一輪後面幾個測試越跑越慢（Aztec High 掉到 1.3 fps、Driver Overhead 2 只跑 3 幀），Tessellation（metal_tess）在
`TestWrapper::init0` 讀到 null（這版 iOS 建置沒有這個測試）。
- 找缺少的 selector：先跑 `guest-newlogs.sh`，在 app_ios 的訊息裡找「unrecognized selector」或「native-metal:」；
  crash report 的 `lastExceptionBacktrace` 會指出 GFXBench 的呼叫點。
- rig 新增 `gfx-suite.sh ID...`：依序跑每個測試，每個印一行結果；有新的 crash report 會標「NEW CRASH」。
- MobileSafari 那次 `__stack_chk_fail`（CoreFoundation `fileRead`）後來歸入記憶體破壞的調查，見上面的續報。

## 續報（2026-10-25 13:00，Claude）：Metal 預設改走 virtio-gpu＋drm2kgsl，GFXBench 快了 2.2 倍

- **M5**：kernel 新增 `CREATE_BLOB_USER`，把 client 自己的頁面當成 guest blob，turnip 因此支援 `VK_EXT_external_memory_host`。
  virtio-gpu 路徑的 MetalCheck 從 31/41 變成 41/41，IOSurface 和 no-copy buffer 都過。
- **M6**：board.toml 的 `vgpu-3d=1` 讓所有 Metal client（backboardd、SpringBoard、App）預設走 virtio-gpu；某個 process 設 `TU_DARWIN_VIRTGPU=0` 可以改回 droidvm-gpu。
  | | virtio-gpu（新預設） | droidvm-gpu |
  |---|---|---|
  | MetalCheck | 41/41 | 41/41 |
  | GFXBench ALU 2 | 1527、1499 frames（約 50 fps） | 680、660 frames（約 22 fps） |
  主畫面、widgets、桌布都正常渲染。
- 踩到的坑：
  - `plugin-redeploy` 只會重新打包 `build/mesa-tu-ios` 裡已經編好的 turnip。改了 shim 之後，要先在 tree 裡跑
    `ninja -C build/mesa-tu-ios src/freedreno/vulkan/libvulkan_freedreno.dylib`。
  - system client 匯入的 IOSurface 有些是唯讀映射，要照 NativeAdreno 的方式 wire（persistent、唯讀 fallback）。
- 手機的 `/data` 已用了 97%（剩 8.4 GB），Android 跳出空間不足的警告。
- 後續驗證：
  - 6 次開機都正常，guard 沒有觸發。
  - MetalCheck 在 virtio-gpu 上跑 5 分鐘壓力測試：PASS，約 24 萬次 submission，沒有拒絕，沒有 context 遺失。
  - Safari 能正確渲染 apnews.com。
  - 顯示 A/B（rig `display-ab.sh`：喚醒、解鎖，再開「設定」、按 Home）：兩條路徑的手機畫面都會跟著 guest 更新。
  - 手機上看到黑畫面或凍結畫面，原因是 guest 閒置後螢幕休眠，要先喚醒；daemon 重開 VM 也會關掉 App 的顯示畫面，要用 `show-vm.sh` 叫回來。
- 既有問題（兩條路徑都有）：「設定」清單的圖示只剩純色方塊，缺白色符號（General、Wallpaper 正常）。
  - 原因是 Core Image 的 GPU kernel 跑不起來。CoreImage.framework 的 `ci_stdlib`、`ci_filters` 是 Core Image 類型的 metallib，
    裡面是 stitchable function，metal2vulkan 回報 `LibraryKind(1)` 未實作；CI 執行時用 function stitching 合成 kernel 也跟著失敗。
  - IconServices 的 graphic icon 要靠 `blendWithAlphaMask` 把符號疊到底色上，所以畫壞了。快取清掉重畫後，圖示變成被白線切開的樣子。
  - 後來查清楚是兩個 bug，都已修好（2026-10-25 晚）：
    1. **function stitching**：CI 用 `ci_stdlib_stitchable.metallib`（一般 executable，載得進來）裡的函式組 DAG，
       再交給 Metal 的 `newLibraryWithStitchedDescriptor:`。Apple 的實作只接受自己的 function 物件（「does not conform to
       MTLFunction」），所以 CI 的每個 kernel 都失敗，圖示沒有符號。NativeMetal `3ce039a` 改成自己實作：DAG 文字沿用 base class
       的 `newDagStringWithGraphs:`，從 metallib 取出各函式的 bitcode，照 MTLLibraryBuilder 的格式（`dag `／`numf`／`bitc`）
       以 request 14 交給系統的 MTLCompiler，回來的 metallib 照常載入。
    2. **virtio-gpu 路徑的 tiling 參數**：drm2kgsl 沒有回報 UBWC swizzle 和 macrotile mode，Turnip 就用了 0 和 4-channel；
       KGSL 實際設定的是 sm8650 的 levels 2+3、8-channel（droidvm-gpu 驅動給的就是這組）。CPU 端 tile／detile（host image copy）
       因此放錯位置：每隔一個 16 列的帶，16 像素的區塊左右對調。shim 改成 capset 沒給時用 KGSL 的值（fork `3cdf439`）。
  - 新工具：`gfxprobe ci [SIZE [DIR]]`（device `dda8ea5`，gfxprobe 已加入 `droidvm-gpu-clients`）。iOS 會忽略 CI 的
    software renderer 選項，兩邊其實都跑在 GPU 上，所以要看 DIR 裡的原始輸出，或檢查漸層是否正確。
  - 修好後：漸層測試 0 個錯誤像素；「設定」的圖示完整正確；MetalCheck 41/41。
  - MetalCheck 新增 case 42（device `f297be7`）：同一張 tiled texture 由 GPU 寫、CPU 讀，再反過來，逐 texel 檢查位置。
    原本 41 個 case 抓不到這個 bug：07、08 都是同一邊來回複製，錯的 swizzle 剛好抵消。修好後 42/42。
    （沒有用舊的 Turnip 實際驗證 case 42 會失敗；它走的是 CI 出錯時的同一條路：GPU 寫 shared texture、`getBytes` 讀回。）
- **手機畫面停住（guest 照常 present）的原因找到了**，是 DroidVM App 的 bug，跟 GPU 無關：
  - 重新開啟 VM 的顯示畫面時（`am start --activity-clear-task`，或進入畫面時的方向切換），新 activity 先把 Surface 交給 crosvm，
    舊 activity 之後才 detach。舊的 `DisplayProvider.surfaceDestroyed` 會呼叫 `removeSurface`，但這個呼叫不指明是哪一個 Surface，
    結果把新的移除了，手機就停在最後一幀。
  - 重現：在畫面正常時再跑一次 `show-vm.sh`，3/3 卡住。恢復方法：按 Home，再 `am start --activity-reorder-to-front`
    （讓同一個 activity 依正確順序重送 Surface）。
  - rig 的 `show-vm.sh` 已改成每次開完都做一次這個動作，連續 2 次測試都正常。
  - App 的修正寫在本機 DroidVM repo 的分支 `wip/display-surface-owner`（`c187677`）：依 display service 記錄目前交出 Surface 的
    provider，只有它能 remove。
  - **已安裝**（使用者指出 SDK 在 `/root/android-sdk`）：以手機上那版 `309ede7` 為基礎，只 cherry-pick 這個修正
    （分支 `wip/display-surface-owner-309ede7` `852027a`，worktree `/root/gitrs/DroidVM/DroidVM-display-fix`）。
    prebuilts 與 `liblbx.so` 直接取自手機上的 APK，逐 byte 相同；簽章相同，用 `adb install -r`，資料保留。
    daemon（root）與 crosvm 沒有中斷，VM 沒有重開。
  - 驗證：關掉 rig 的繞過（`SHOWVM_NO_CYCLE=1`），在畫面正常時重開顯示畫面，4/4 都會跟著更新（修正前 0/3）；手機觸控照常送進 guest。
  - DroidVM App repo 不在約定的 push 清單裡，兩個分支都只在本機。
- **使用者回報三件事，都已處理（2026-10-25 晚）：**
  1. **DroidVM App 看不到 iOS VM**：App 的 VM 清單讀的是 `files/vms.json`，daemon 只提供狀態。iOS VM 是 rig 透過 IPC 建的，
     從來不在這個檔案裡。已把 rig 的 VM 設定加進去（備份 `vms.json.bak-20261025`，擁有者、權限、SELinux label 照舊），
     App 現在列出「UniXNU (DroidVM)」。daemon 也換成新版 App 的（停 VM、換 daemon、再開機），不再跳出「Outdated Daemon」。
     rig 的 `daemon-recover.sh` 修正：daemon 正常結束時不會留下 pid 檔，原本腳本會直接中止。
  2. **iOS 畫面轉了 90 度**：啟動 GFXBench 會讓 SpringBoard 把介面轉成直向（log：`outSwitcherOrientation: portrait`），
     guest 沒有方向感測器，結束後就停在直向。用 iPadOS 控制中心在橫向時打開旋轉鎖定，之後開關 GFXBench，主畫面都會回到橫向。
     `gfxprobe orient`（XCTest 用的 `BKSHIDServicesSetDeviceOrientationForAutomation`）實測沒有作用。GFXBench 本身仍是轉向顯示。
  3. **主畫面沒有 GFXBench**：lsdiag 把 owner App 註冊成 System，SpringBoard 會把不在預設圖示清單裡的 System App 藏起來
     （`-[SBApplicationInfo _configureTags:hasVisibilityOverride:]`），主畫面和 App 資料庫都看不到。改成 User（device `ec4bd8a`），
     重新註冊並重啟 SpringBoard 後，GFXBench Metal 和 MetalCheck 出現在第 2 頁，點圖示可以開啟。
- **GFXBench 畫面轉 90 度的原因與修正（device `f7ae401`）：**
  - `gfxprobe orient` 原本沒作用，是因為 backboardd 處理這個 MIG 訊息（6000013）時要求 `com.apple.backboardd.setDeviceOrientation`
    entitlement，沒有就直接丟掉。加上之後就能設定裝置方向。
  - 實測發現：我們的面板對 iOS 來說本身是橫的（1366×1024），所以 iOS 的「直向」（1）就是寬的正畫面，iOS 的「橫向」（3、4）
    反而是側躺。GFXBench 在 iPad 上只允許橫向，因此不管裝置方向怎麼設都會側躺；假的方向感測器也一樣，所以沒有做。
  - 修正：GFXBench 的 iPad 方向加上直向（建置腳本已改）。在 Mac 上用 guest 那一版的 bundle 重新簽章（資源完全相同，只差
    Info.plist），新增 `lsdiag owner-update` 只替換三個檔案。GFXBench 現在是正的（直向版面、兩側黑邊），ALU 2 1626 幀、54 fps。
  - 旋轉鎖定重開後仍保留，主畫面維持正的。其他只支援橫向的 iPad App 在這套環境裡也會側躺。
- **GFXBench 改成鋪滿全螢幕（device `ba9a596`）：** 黑邊是 SpringBoard 的 classic mode：我們的寬「直向」（1366×1024）對不上
  任何螢幕類型，App 就被放進 768×1024 的畫布（GFXBench 結果 JSON 裡寬度是 768）。帶有 `com.apple.UIKit.vends-view-services`
  的 App 會跳過 classic mode（`-[SBApplication _bypassesClassicMode]`）。加上後 GFXBench 拿到 1366×1024，版面跟著放大、沒有黑邊；
  ALU 2 1620 幀、54 fps。之後自己安裝的第三方 App 也需要同一個 entitlement。
- **Turnip 的 SIGSEGV（觀察中）：** 今天 17:55–18:23 GFXBench 當了 3 次，都在做方向／classic mode 實驗的時段。
  符號化後是 `tu_cs_end`（vkQueueSubmit → autotune `get_cs_for_fence`）和 `tu_cs_get_cur_iova`（`tu_BeginCommandBuffer` → `tu_init_hw`），
  兩者都是在 `bo_count` 為 0 時讀 `bos[bo_count - 1]`，索引溢位成 0xffffffff，位址恰好是 bos + 0x7fffffff8。
  修好方向與全螢幕後跑了 9 次（一般、背景再回前景、測試中轉 4 次方向）都沒有重現，先記錄、繼續觀察。
- 有一次開機（18:27）被 guard 擋下：v2 從開機起沒休息，launchd 在 `NativeVirtioBlock` 讀檔；四顆 CPU 都過了 a6，不是 MMU 關閉時的卡死。
  killvm 後重開正常。
- 另外記錄：MobileSafari 在背景當掉一次（StoreKit 讀檔時 `__stack_chk_fail`，`CFReadStreamRead`／`fileRead`），還沒查。

## 續報（2026-10-25 11:30，Claude）：第二種手機當機也修好了；M4 完成到 31/41

**第二種 watchdog 當機（secondary CPU 啟動卡住）已修好。**
- 現象：某顆 secondary vCPU 收到 CPU_ON 後，從沒走到 ArmCpu 的 `initCPU`（`smp_step` 停在 4），時間全在 guest 裡、沒有 exit，host 3–10 秒後當機。
- 根因：新 core 在 MMU 打開前用 uncached 方式讀幾個開機時寫入的值，Gunyah 不保證這種存取和 boot core 的 cache 一致。這幾個值是
  `ResetHandlerData`、`const_boot_args`、`sysreg_restore` 的 TCR、`cpu_ttep`。XNU 只 flush 了 cpu data，其餘若還髒在 cache 裡，新 core 就讀到舊值，在早期啟動程式碼裡空轉。
- 定位：在 `start.s` 加的每核進度標記（`droidvm_early_trace`，rig `early-trace.py`）顯示卡在 `start_cpu` 之後、MMU 打開之前。
- 修正：UniXNU `061d032`，`patches/xnu/non-apple-vcpu-start-flush.patch`。`cpu_start()` 先把上述資料寫回記憶體；早期例外向量改成記錄後停在 WFI。
- 驗證：修正後連續 12 次開機都沒卡住（之前約每 4–8 次會卡 1 次），每次都有 7–18 秒的四核滿載，host 都沒事。
- 防線：rig `vmguard2.sh`（手機上獨立執行，每 0.25 秒取樣）。任一顆 secondary 開機後 1 秒內都沒睡就凍結 VM。`boot-cycles.sh N` 可在它保護下反覆重開 VM。
- ArmCpu 也改成失敗時停在 WFI：Droid-VM/ArmCpu `c6b72b6`（新 fork），fork `4cec990`。

**GPU**
- 預設路徑（droidvm-gpu）：MetalCheck 41/41；GFXBench ALU 2 跑出 680、660 frames（droidvm-gpu 的忙等改回 3 ms，現在不用 WFE，對 host 安全）。
- virtgpu 路徑（`TU_DARWIN_VIRTGPU=1`）：MetalCheck 31/41（device `a1a729e`：guest blob 改成每塊最多 4 MiB 的連續區塊）。
  剩下 10 項全是 no-copy buffer 和 IOSurface，屬於 M5 的 host-memory import。

## 續報（2026-10-25 09:00，Claude）：手機 watchdog 當機的根因與修正；M4 進度

**手機當機（watchdog bite）已修好。**
- 根因：Gunyah 會 trap guest 的 WFI（把 vCPU block 住），但 WFE 直接在 guest 裡執行（`HCR_EL2.TWE=0`，寫死在 Gunyah，host 改不了）。
  XNU 在 `IODelay`、lock 自旋、commpage、idle、panic 都會停在 WFE，我們的驅動也在 `IODelay` 裡忙等 2–3 ms。
  guest 的 vCPU 不再 idle 時（開機負載、SpringBoard 一次 23 個 runnable 執行緒），0.2–35 秒內就有一顆跑 vCPU 的 host 核心不再處理中斷，watchdog 重開手機。
  今天早上約 9 次開機當了 5 次，卡住的核心有 CPU 7/2/3，不是特定核心。
- 修正：
  - UniXNU `ac4c602` 加入 `patches/xnu/non-apple-vcpu-park.patch`：非 Apple 平台一律不用 WFE；panic 時 CPU 用 WFI 停住。
  - device `670f95b`：驅動等待只忙等 200 µs，之後就睡眠。
- 驗證：四顆 vCPU 100% 滿載 35 秒（`yes`），以及四次開機各有 8–17 秒全部 vCPU 不睡的時段，host 都沒事。修正後 GFXBench ALU2 跑出 641 frames（基準 684–716）。
- 防線：rig 的 `vmguard.sh [SPINS]`（在手機上跑）記錄 vCPU 執行緒狀態；所有 secondary vCPU 連續 SPINS 個樣本不睡時，用 SIGSTOP 凍結 crosvm。凍結後的 guest 可以用 `guestcpus.py` 分析（每顆 CPU 的 process、syscall、kernel backtrace）。
- 細節在記憶檔 `droidvm-host-crash-2`。

**M4（turnip 走 virtio-gpu DRM context）進行中。**
- `TU_DARWIN_VIRTGPU=1` 時，turnip 已能開啟裝置（GET_CAPS 改成能容納整個 160 bytes 的 capset，device `6153420`）。
- buffer 配置仍被 kernel 拒絕，MetalCheck 0 項通過；拒絕的 op 已有紀錄可查（`droidvm_virtgpu_last_refusal`）。
- turnip patch 在 UniXNU `7d9c845`，ABI header 移到 NativeAdreno `0f786a4`。

## 續報（2026-10-25 05:10，Claude）：drm2kgsl 遷移，M0–M2 完成

計畫在 `plans/IOS_DRM2KGSL_MIGRATION.md`。主機原本就已經跑著 drm2kgsl（`--gpu virglrenderer,context-types=drm` 加 virtio-mmio GPU），所以 guest 端是從零開始做。
- **M0**：drm-host pool 已上線（`--pre-alloc drm-host-mb=8`，位址 0x1bf800000）。
  - `dram_size` 改為 0x13f200000（device `a65f143`）。
  - 這個參數加在 VM 的 `extra_options` 裡（rig 的 `unixnu-vm.config.json`，透過 `vm_modify` 套用）。
- **M1**：guest 的 virtio-gpu transport 改成非同步，64 個 slot 同時在途（device `584c038`）。顯示正常，0 錯誤。
- **M2**：開機自測（`vgpu-selftest=1`）已在 iOS kernel 建出 DRM native context，`GET_PARAM(GPU_ID)` 經 drm2kgsl 讀回 6770（device `c5b8cd3`）。
  - 結果在 `peek.py droidvm_virtgpu_selftest`，第 0 格 stage=9 表示全部通過。
- **M3**：user client 完成（device `f53dcb5`、NativeAdreno `e1272b7`）。`gfxprobe virtgpu` 從使用者行程跑完 context → shmem → ccmd（0.3 ms）→ guest BO → fenced NOP（0.2–1 ms）→ 關閉。
- NativeAdreno 現在 fork 在 Droid-VM/NativeAdreno（`wip/hackintosh`），fork 的 `.gitmodules` 已改指過去（`c08168a`）。
- 下一步：M4 turnip-virtio 加 `vdrm_iokit`。

## 續報（2026-10-25 04:20，Claude）：GFXBench 第一次跑出分數

**ALU 2（metal_alu2，1024×1366）：716 和 684 frames（23.9 和 22.8 fps），status OK，載入約 8.9 秒。**
- 這是 droidvm-gpu 路線的 baseline，之後 drm2kgsl 要和這個數字比。
- 畫面正確，曼哈頓街景加 64 個點光源（rig `out/msl/g2-all.png`）。
- 結果 JSON 在 guest 的 `/private/var/tmp/gfx-alu2.out`。

**修了兩個擋住 GFXBench 的問題：**
1. **執行時編譯 MSL（NativeMetal `40a57be`）。**
   - GFXBench 的 shader 全部用 `newLibraryWithSource:` 從原始碼編譯，Safari 的 WebGL（ANGLE）也是。frontend 之前沒有實作這個方法，所以 GFXBench 的結果都是 N/A。
   - 現在改呼叫 iPadOS 內建的 MTLCompiler.framework（`MTLCodeGenServiceBuildRequest`，request 13，格式參考 tinygrad），把原始碼編成 metallib，再走 `newLibraryWithData:` 載入。
   - 編譯錯誤回報為 `MTLLibraryErrorCompileFailure`；有 warning 時和 Metal 一樣，回傳 library 並附上 CompileWarning 錯誤。
   - MetalCheck case 41 在 guest 通過，guest 上 41 項全過。
   - 先用 gfxprobe 的 `msl` 指令驗證：guest 沒有 Apple GPU，也能把 MSL 編成 12 KB 的 metallib，耗時 1.7 秒。
2. **顯示器宣告只有一層（NativeMobileDisplay `3aa4b26`，kernel `727b866f`）。**
   - CoreAnimation 從顯示服務的 `IOMFBNumLayers` 屬性讀 `MaxNumLayers`（`AppleDisplay::update_display_limits`）。
   - 我們沒有發佈這個屬性，CoreAnimation 就把 GFXBench 的全螢幕 Metal 圖層 detach 給顯示器，並要求 IOSurfaceAccelerator scaler 做複製。guest 沒有 scaler，backboardd 因此 abort，所有 app 跟著被殺掉。
   - 現在發佈 `MaxNumLayers=1`，所有圖層都由 CoreAnimation 自己合成。任何全螢幕 Metal 遊戲都會受益。
   - 判斷依據：從 21H461 的 dyld cache 抽出 QuartzCore 反組譯（Mac 上 `/Volumes/DATA/scratch/dsc21H461`）。另一個做法是設定環境變數 `CA_DISABLE_DETACHED=1`（`CADefaultsGetFloat` 會先讀 getenv），但沒有採用。

**新工具（device `8310bec`、`3b08dab`、`bbf423a`）：**
- `lsdiag -u 501 launch-args OUT BUNDLE_ID ARG...`：用 FrontBoard 的 debug 啟動選項啟動 app，可以帶參數，stdout 和 stderr 寫到 `OUT.out`、`OUT.err`，NSLog 也會複製到 stderr。
  - 跑 GFXBench：`lsdiag -u 501 launch-args /private/var/tmp/gfx org.droidvm.gfxbench -t metal_alu2`。
  - 先解鎖畫面；跑完 GFXBench 會自己結束。
- MetalCheck 的 benchmark 新增單一 command buffer 的來回時間：4-byte fill 在 guest 是 2.3 ms（scheduled 1.35 ms），Mac 是 0.15 ms。
  - render server 每個 command buffer 35–45 ms，不是這段來回造成的。

**方向：使用者決定 iOS 的 3D 改走 virtio-gpu＋drm2kgsl（`plans/IOS_VIRTIO_GPU_SURVEY.md` 第 4–7 步）。**
- 不再優化 droidvm-gpu 傳輸本身：submit 延遲、context loss 根因、timestamp 繞回都不再處理。
- Vulkan 以上和顯示層的修正都會保留，包括 NativeMetal、metal2vulkan 修正、MetalCheck，以及這次的 IOMFBNumLayers。
- drm2kgsl 是和 Linux guest 共用的程式碼，iOS 需要的改動（例如跨 context 的 syncpoint）都要做成 opt-in。

**其他：**
- 本輪看到一份 CalendarWidgetExtension 的 crash report，還沒看內容。
- 上一次開機的 context loss（slot 0）原因未查，原因同上（不再追 droidvm-gpu）。

## 續報（2026-10-25 02:10，Claude）

**文字破圖找到原因並修好（NativeMetal `5b9e1d6`，fork `51c16fc`，device `72d4a15`，plugin md5 `b2940b19…` 已部署）。**
- 重現：GFXBench 的 Test selection 清單，取消勾選三列之後有 5 個標題變成亂碼，捲動後仍然是亂碼（rig `out/visual/run4/gfx16.png`）。
- 定位過程：
  - 用新的 render server 診斷（NativeMetal `fa62ad0`，預設關閉）把 backboardd 用到的 texture 清單和內容 dump 出來。
  - 標題是 A8 linear texture，建在 client 共享記憶體的 no-copy buffer 上，offset 64。dump 出來的遮罩全部是乾淨文字，所以參數和 CPU 端資料都正確，是 GPU 讀到別的頁。
- 原因：
  - metal2vulkan 會把「和一個還活著的 no-copy buffer 完全同位址、同長度」的新 buffer 放進舊 buffer 的 import（`host_aliases.rs`），也就是當初那批實體頁。除非呼叫 `Device::host_range_remapped` 告知該範圍已重新映射。
  - 真 Metal 每次 `newBufferWithBytesNoCopy:` 都會重新 wire 該位址當下的頁。
  - CoreAnimation 的 render server 會把 client 新的共享記憶體（以及 IOSurface）映射到舊映射的位址，而舊映射的 no-copy buffer 還留在它的 cache 裡。結果 GPU 畫出舊頁的內容，也就是別的文字遮罩。
- 驗證：MetalCheck case 40 在同位址 `MAP_FIXED` 換新頁、舊 buffer 保持存活的情況下，guest 上 4480 個 byte 全部讀到前一輪的內容，Mac 上通過。
- 修正：
  - bridge 的 no-copy 路徑在 buffer pin 住頁之後，記下該範圍每個 map entry 的 VM object id 和 offset（`mach_vm_region_recurse`）。
  - 下次在同範圍建 buffer 時，頁的身分若變了，或有頁還沒有 object，就先呼叫 `host_range_remapped`。
- 結果：
  - case 40 在 guest 通過，MetalCheck 40 項全過。
  - GFXBench 標題全部乾淨，捲動後也是（`gfx18.png`、`gfx19.png`）。
  - telemetry 新增一行 `N no-copy ranges checked 262 remapped 4`，只有少數範圍需要重新 import。
- 另外兩種破圖也一起好了：重跑 MetalCheck UI 5 分鐘壓測（+128 MiB），壓測後的結果文字整頁乾淨，狀態列時鐘也正常（rig `out/visual/run4/mcui-4-up.png`）。
- MetalCheck 新增 case 36–40（device `72d4a15`）。gfxprobe 的 `surfaces` 指令沒有 commit：IOSurface family 拒絕依 id 查詢，加 entitlement 也沒用。
- guest 的診斷開關（`/private/var/ngpu/debug/texture-log`、`dump-now`）已刪除，下次 backboardd 啟動後生效。

## 續報（2026-10-24 22:30，Claude）

**swap 卡住 5 秒會讓 kernel panic，已修好（NativeMobileDisplay `e51063d`，device `86ea138`，kernel sha256 `0280870c…` 已部署）。**
- panic 訊息：`NativeLegacyDisplay: leaf=345 … @LegacyDisplayProbe.cpp:453`。
- 原因：
  - backboardd 等一個 swap 等了 5 秒都沒完成時，IOMobileFramebuffer 的 `swap_wait_gated` 會印 "CommandWake didn't happen even after 5 seconds … cancelling swaps"。
  - 接著它呼叫 vtable 第 345 格，也就是平台那層的取消。family 裡這一格是 pure virtual，之後 family 才自己取消佇列（第 346 格）。
  - 我們的 NativeLegacyDisplay 在這一格放的是 guard，一呼叫就 panic。
- 修正：實作成 `cancelSwapsAfterTimeout()`，清掉自己記錄的未完成 swap，family 只拿回傳值印 log。health.py 的 `present` 行新增顯示 `swaps given up after 5 s`。
- 重現方式：打開下面的偵測器時，三次裡有兩次在開機約 126 秒、一次在 backboardd 重啟 12 秒後 panic。換上新 kernel 後，同樣情境跑了 6 分鐘都沒事。真實 GPU hang 時 producer 永遠不會完成，也會走到這條路徑，所以這個修正和 render server 自動重啟是互補的。

**文字破圖：又排除兩個方向，偵測器留著備用。**
- 新的 render server 偵測器（NativeMetal `fcdf854`，預設關閉）：
  - 開法：在 guest 建立 `/private/var/ngpu/debug/source-race` 後重啟 backboardd。
  - 作用：每個 command buffer 取樣的小型來源（IOSurface 或 no-copy buffer），在送出時和完成時各算一次雜湊。
  - 結果：MetalCheck 壓測結束的結果文字在畫面上破圖了（rig `out/visual/run3/s14.png`，有一行被換成別處的 `"rounds": [`），但偵測器一筆都沒記錄。所以不是 app 在 GPU 讀取期間改寫來源。
- MetalCheck case 32：同位址換新實體頁（`MAP_FIXED`）、同尺寸 IOSurface 重建，guest 和 Mac 都通過。所以不是位址重用造成的舊匯入。
- 已排除的方向：row pitch 對齊（case 30）、cache 一致性（case 31）、app 改寫的競爭（偵測器）、位址重用（case 32）。
- 下一個方向是 render server 自己的合成流程，例如 CoreAnimation 把小圖層併進 texture atlas 時，更新與取樣的先後順序。這要記錄 backboardd 對破圖區域呼叫的 Metal API 才能查。

**其他**
- MetalCheck CLI（32 項）在 guest 的 `/private/var/ngpu/bin/mc30/`，trust `d897705e…`。
- daemon 停機時曾經再死一次，處理方式是 `daemon-recover.sh` 再 `vm.sh start`。它讀的 `unixnu-vm.config.json` 已是 virtio-gpu 版。
- 萬花筒桌布每次開機都換圖案，`screen-check.py` 的 home 參考圖目前有 4 張（`ref-home*.png`），比對只看它們一致的約 27% 格子。

## 最新狀態（2026-10-24 20:45，Claude；優先於下方各段）

接手 Codex 19:15 的交接後做了四件事。VM 正在跑，hostwatch 開著。

**1. Mac 建置環境同步，加兩道防呆。**
- Mac 上的 device repo 原本是很舊的 commit 加上手動複製的檔案，DarwinBoot 也不是 virtio-gpu 版。這兩個 checkout 已用 git bundle 移到已推送的 commit，舊狀態打了 tag `mac-pre-sync-20261024`，差異檔備份在 Mac 的 `~/macsync-20261024/`。
- `package/Build/Out` 的 DarwinBoot.efi 換成正在跑的 virtio-gpu 版（`fd3404…`）。舊的 simplefb 版也備份在同一個目錄。
- 新增 rig 工具 `mac-sync-check.sh`：比對 Mac 和本機的 device repo、UniXNU（含 submodule、未 commit 的修改），以及 build tree 裡的複製檔。`payload-redeploy.sh`、`plugin-redeploy.sh` 建置前都會先跑它。
- `payload-redeploy.sh` 在停 VM 之前，會把新磁碟和正在跑的磁碟逐項比對：
  - DarwinBoot、UEFI、ADT（解碼後比，忽略 random seed）、Data seed 任一項改變，都要 `ALLOW_CHANGE` 明確允許。
  - 開機參數超過 1023 bytes 會在停機前就擋下。
  - 舊磁碟保留在 `out/droidvm-disk.prev.img`。
- `unixnu build payload` 原本把開機參數限制在 1000 bytes，但 board 的參數有 1004 bytes，所以 payload 根本建不出來。已改成 DarwinBoot 的實際上限 1023（fork `b08b2c4`）。

**2. board 重新能產生正在跑的 ADT（device `685361e`）。**
- 原因：已 commit 的 board.toml 和 FDT 還是 simplefb 版本，正在跑的 ADT 是手動做的。從 repo 重建的 payload 會缺 virtio-gpu 節點，記憶體也少 6 MB。這次部署時真的發生了：帶錯的 ADT 開機約 20 秒，我正常關機後換回正確的 ADT。
- 修正：
  - `package/crosvm-gunyah.dtb` 換成目前 VM 的 FDT。
  - `dram_size` 改成 `0x13fa00000`。
  - `[payload.adt]` 加上 `--virtio-gpu-mmio 0x0a009000 --boot-video-mib 8`。
- 現在 payload 產生的 ADT 除了 random seed 以外，和正在跑的一致。`swap-adt.sh` 也改成用同一組參數。

**3. 畫面驗收：Codex 記錄的「回主畫面卡在舊畫面」已不再發生。**
- 新工具 `screen-check.py`：同時看手機實際畫面（screencap）和 guest 所有 scanout surface（crosvm 的 udmabuf，用 `dmabufgrab` 讀）。和參考圖比對，失敗時能分出是「顯示路徑」還是「guest 合成」的問題。
- 參考圖可以存多張，比對只看各張一致的格子，所以不受萬花筒桌布每次開機換圖案影響。參考圖放在 rig `out/visual/ref-*.png`。
- 照原情境重跑（MetalCheck UI 壓測 5 分鐘＋128 MiB → Home → GFXBench → Home），每一步都正確，結果在 rig `out/visual/run1/summary.json`。
  - telemetry 顯示 `ROT imports 3=10`，也沒有 surface 拒絕，代表 rotation 修正有效。
  - GFXBench 現在能進到主選單（還沒跑 workload）。
  - 從直向 app 回主畫面後，主畫面會維持直向，因為沒有方向感測器把它轉回來。這是正確畫面，參考圖 `home-portrait` 就是它。
- 反例也測過：MetalCheck 在前景時判定「應該是主畫面」，工具會判 FAIL（guest 合成）。

**4. render server 的 GPU context 掉線後自動重啟（NativeMetal `c86107a`，fork `fe2050f`）。**
- backboardd 的 command buffer 以 DeviceLost 完成時，等 completed handler 跑完，0.5 秒後對自己送 SIGTERM。launchd 會重啟它和 SpringBoard，畫面回到鎖定畫面。其他 client 照舊只收到錯誤。
- 已部署：外掛 CDHash `0b64982e…`，md5 `bbe09e91…`，System 和 Data 兩個路徑都核對過。MetalCheck 31/31 通過。
- **完整流程還沒在真實 hang 中驗證**，因為沒有辦法人為讓 backboardd 掉線。兩段分別驗證過：錯誤會傳到 Metal（Codex 在真實 hang 時看到），SIGTERM 後會恢復（Codex 手動做過）。

**文字破圖（仍未解）。**
- 可重現：MetalCheck UI 壓測時，按鈕上方那行狀態文字（rig `out/visual/run1/status-zoom.png`）；19:51 也拍到狀態列時鐘破圖。
- 從 guest 的 scanout buffer 看，同一時間有的幀時鐘正常、有的破圖，所以是某些合成幀讀錯，不是 app 畫錯。
- 已排除兩個原因，guest 和 Mac 上都通過：
  - case 30：row pitch 不是 64 的倍數時的 blit 和 buffer texture 取樣。
  - case 31：CPU 寫 no-copy buffer 後 GPU 立刻讀，沒有讀到舊的 cache line。
- 下一步：在破圖當下讀出 app 的 backing store，確認它本身是否乾淨；並查 backing store 的「使用中」保護在 GPU 較慢時是否被突破（GPU 越忙越容易破圖）。
- 另一個觀察：MetalCheck 在前景時，狀態列時鐘停在 5:12，實際已經 5:16。

**現在部署的版本：**
- kernel `a308bca…`，crosvm md5 `a340264…`，外掛 `0b64982e…`。
- trust `976ff87c…`。在 Mac 的 `owner-trust-extra/metalcheck-installed-rollback.json` 裡保留了已安裝 MetalCheck app 的 CDHash（`e39e7583…`）。
- 31 項的 MetalCheck CLI 在 guest 的 `/private/var/ngpu/bin/mc30/`，用法：`MetalCheck --cli --library …/default.metallib`。
- 新的 heads：device `419021b`，fork `fe2050f`，NativeMetal `c86107a`。

**注意：**
- 在手機上跑任何非單一指令的東西，一律寫成腳本、`adb push` 後再執行。`adb shell su -c '…'` 會少一層引號，曾經在手機根目錄跑了 tar。
- `fbgrab.sh`、`frame-burst.sh` 讀的是 simplefb 的記憶體，virtio-gpu 之後已經不是螢幕內容。改用 `screen-check.py`。

## 最新交接（2026-10-24 19:15，以下狀態優先於歷史段落）

使用者要求修好已知問題，並在額度將盡時交接；19:09已補入新guest測試結果。隨後使用者授權commit與push：七個程式碼repo已推到Droid-VM的WIP分支並核對遠端SHA，下表與本文件由meta repo本次commit保存。未合併正式分支，未再部署或重啟VM。下一個session從下列視覺驗證繼續；不要重跑已完成的API回歸。

### 已提交與推送（2026-10-24 19:15）

| Repo | 遠端分支 | Commit |
|---|---|---|
| DroidVM meta | `wip/hackintosh` | 本次commit（含本文件與兩份survey） |
| NativeMetal | `wip/hackintosh` | [`f6b22c7fd`](https://github.com/Droid-VM/NativeMetal/commit/f6b22c7fdd0ff4fbac795b6bd3a6a895e5ab7de2) |
| NativeMobileDisplay | `wip/hackintosh` | [`4a78d78a0`](https://github.com/Droid-VM/NativeMobileDisplay/commit/4a78d78a049393c0069c7fdd226d9257666aa12c) |
| DarwinBoot | `wip/droidvm-virtio-gpu` | [`af934b218`](https://github.com/Droid-VM/DarwinBoot/commit/af934b218ab0e80fa3f1493bc15efa7b222f01de) |
| edk2-gunyah | `wip/hackintosh` | [`67b9dba4a`](https://github.com/Droid-VM/edk2-gunyah/commit/67b9dba4aaef7491e9339457131cd1367429bd33) |
| crosvm | `wip/virtio-mmio` | [`1ef32747d`](https://github.com/Droid-VM/crosvm/commit/1ef32747d57772b6e89af41a18be9495276e9a0c) |
| UniXNU | `wip/droidvm` | [`ee843ef3e`](https://github.com/Droid-VM/UniXNU/commit/ee843ef3ed9b61d7f0ab28f4c9b6c10d6466e079) |
| UniXNU-droidvm | `wip/hackintosh` | [`b24054b63`](https://github.com/Droid-VM/UniXNU-droidvm/commit/b24054b63496e08f7d25c3c7679a43c0ef2c7e64) |

- NativeMetal、NativeMobileDisplay、DarwinBoot已建立Droid-VM forks；UniXNU的`.gitmodules` URL與三個gitlink均指向已發布版本，可由遠端取得相依commit。
- 程式碼repo工作目錄乾淨；meta的既有`DroidVM_20260903.zip`未納入。rig私有設定、報告、影像、binary與Python bytecode未納入。
- GFXBench原checkout的12個tracked diff與唯一untracked testlist均完整收錄於device的`compat.patch`，不需另提交第三方checkout。patch hash與reverse-apply檢查通過。
- 本次保存前的檢查：Python／shell／TOML／JSON語法、rig privacy scrub與diff whitespace通過；UEFI保留既有CRLF，compat.patch保留上游context空白。沒有重跑昂貴build；沿用下列已完成的實機與Mac測試證據。

### 最新發現與修正

- **這次卡畫面已有明確的紋理建立錯誤證據。** backboardd telemetry 累計約6039次 IOSurface texture refusal；要求 `1024×1366`，rowBytes `5632`、allocation `0x580000`，runtime 回 `BufferTexture(PastBuffer)`。GPU lost mask、host request failure、UNBIND failure計數均為0。圖像卡住不能只靠GPU loss判斷。
- **NativeMetal bridge 確實漏傳旋轉相關 SPI。** 原 `NmbTextureDescriptor` 只傳10個公開欄位，丟掉 `rotation`、`framebufferOnly`、`isDrawable`；texture getter又硬回rotation0／framebufferOnlyNO。底層 metal2vulkan runtime 已實作旋轉IOSurface，包括按旋轉交換physical stored extent，原bridge卻走未旋轉的bounds check。
- 已補 C/Rust descriptor、兩向轉換、Objective-C descriptor讀取與texture getters，新增 `ROT imports`／refusal的surface尺寸與rotation診斷。**不猜測旋轉值、不改pool、不新增全域fence。** 仍需看實際backboardd的ROT計數與畫面，才能把這個已證實的API缺口與所有視覺問題完整連起來；文字破圖及較早的KGSL hang尚不能宣稱都修好。
- 新MetalCheck **第29項**使用256×64 physical IOSurface，測rotation1/2/3/4、非正方形logical extent、四象限顏色，直接逐像素核對IOSurface physical bytes；這是compositor使用的**private SPI**，非完整Metal conformance。

### 測試證據與尚未完成的驗證

1. **Mac：29 PASS／0 FAIL／0 SKIP，三項benchmark PASS。** `rig/out/rotation-fix/host-rotation.json`；case29約90ms。
2. **舊guest外掛：28 PASS、case29 FAIL**，`counted:261376 > length:65536`，與現場bounds錯誤同類。`rig/out/rotation-fix/before/{app.json,report.json,progress.log}`。
3. **熱換bundle的第一次after結果無效，實際仍載入舊外掛。** 已改名 `rig/out/rotation-fix/stale-overlay-attempt/`。Data路徑已是新md5，但System overlay仍是舊md5。bindfs會保留舊vnode，僅rename替換backing bundle不足以更新System讀到的版本。
4. **新guest外掛已通過：29 PASS／0 FAIL／0 SKIP，三項benchmark PASS。** 19:08再次核對System與Data兩個路徑md5均為新版本 `56e436a670304ccfe7ea3d9e6922b0ba`；實測結果在 `rig/out/rotation-fix/after/{report.json,app.json,progress.log,pressure.jsonl}`。case29四種旋轉的CPU逐像素oracle全過（474.83ms），原28項也全部通過，GPU/kernel錯誤計數檢查無新增失敗。`visual_check=NOT_ASSESSED`，**尚未證明桌面閃爍／卡畫面已消失**。切勿把stale-overlay-attempt算成新版本結果。
   - 此次offscreen端到端吞吐：render58.94M pixels/s、compute233.94M float-elements/s、blit3.293GB/s。單次短測且背景負載未控制，不能據此斷言效能回歸或改善。
5. 前輪壓測20輪／301.76秒API輸出正確但視覺FAIL的原證據仍在 `rig/out/metalcheck-guest-stress-final/`；`report-automated.json`是API/counter結果，`report.json`是補入視覺失敗後的總驗收。沒有刪除或改寫原始失敗證據。

### 當前實機／版本（原始碼已commit、push，見上表）

- 活躍rig：`/root/gitrs/UniXNU/droidvm`（下文 `rig/` 均指此目錄）。device repo：`/root/gitrs/UniXNU/UniXNU-droidvm`；fork：`/root/gitrs/UniXNU/orgrepos/UniXNU`。
- VM **pid26569**、backboardd **pid59**。`vm.sh restart` 已完成control-socket stop、10秒回收、pool2560/2560 active0後start；工具session37364已成功結束：display/input可達、無kernel panic／GPU loss／display command error，producer wait1、early retire0。不要另起VM。
- 舊hostwatch已不在；19:08已重新啟動rig `python3 hostwatch.py`，**host PID1759287／tool session48667**，確認VM pid26569仍在、pool served2560。所有VM生命週期繼續遵守 `hugepage-harness.md`；以下次實際ps／phone owner狀態為準。
- kernel仍 `a308bca0261049d5dbf98c69584b8d42e93471bf95a8a25646df3ef03bb14fee`；crosvm md5仍 `a340264b32b3bab69b5ff303aeedff5e`。
- 新plugin CDHash `2f26cd759fa463deb7be5f2c93adfa4a50b4d13b`，md5 `56e436a670304ccfe7ea3d9e6922b0ba`；新daemon hash `a599f9e0cb5e839b3af49080bcbb493571a2e817`（daemon未另行部署）；Turnip hash仍 `9010aa4629ec14adf4ad3844ba47584f0d981d61`。
- 新MetalCheck CDHash `e39e7583cc588d163820f05f1e52cea49fdbf092`。目前bootdisk trust SHA `4cfe75e276af2ca169198a161f19df4f5ba022d5fb7a3773f0a5c60415a78fd0`，保留舊hash供回退。
- device `board.toml` 已在此次commit中更新trust pin為目前部署的 `4cfe75e…`。**Mac device checkout尚未同步此次commit，仍可能是舊pin `f7975a7b…`。** 此前只把新trust mcopy進現有FAT，沒有重建payload；下次重建前先同步已提交source與Mac，勿用舊payload整包覆蓋目前bootdisk。
- pseudo-unprotected；guest BO pool仍512MiB（guest RAM內allocator，不是額外VRAM）；`tu_debug`仍是實驗性的 `nocb`；producer wait1、early retire預設0；Data seed12GiB未變。bootargs1004bytes，1023上限。
- 備份：guest `/private/var/ngpu/plugin-before-rotation` 是舊plugin；rig `out/rotation-fix/old-disk.img`／`old.trustcache`；新app/plugin/trust都在 `out/rotation-fix/`。

### 下一個 session 直接做

- 新guest29項與三項benchmark已通過，`rig/out/rotation-fix/after/`已存在，**不需重跑或覆寫此目錄**。剛才的runner已結束，目前僅hostwatch繼續運行；沒有持續benchmark。
- 先確認hostwatch活著與VM ready，不需重新開機。接著啟動GFXBench，觀察是否還有PastBuffer／舊畫面；讀 `native_adreno_metal_rows`（48×96 bytes）中的 `ROT imports`、`SR`與`P0`。目前telemetry table是全域、可能被其他process交錯寫入，勿把混雜字串當成可靠單一process結果。
- 若GFXBench可操作，選單只選低階ALU2測項；不要預設勾選整套。GFXBench的runtime `newLibraryWithSource`尚未驗證，出錯須保留原始錯誤，不能預先斷定compiler壞掉。
- 重跑5分鐘MetalCheck＋跨App／旋轉／Today View／Spotlight，**同時做視覺驗收**；原自動runner只驗API與kernel counters，明示 `visual_check=NOT_ASSESSED`。若文字破圖仍在，繼續取證，不宣稱旋轉缺口解決所有問題。
- 本輪新增source修改：NativeMetal的 `NativeBridgeMetalFrontend.mm`、`bridge/NativeMetalObjects.{h,rs}`；device `package/metalcheck/Core.mm`（case29）、README。當前Mac **build tree**已同步並成功build；Mac根checkout的NativeMetal尚未同步本輪rotation改動，重建tree前先從本機fork同步，避免被舊root覆蓋。
- build logs在Mac `$BUILD_OUT/plugin-rotation-fix.log`、`metalcheck-host-rotation.log`。使用rig `rigenv.sh`中的BUILD_HOST/BUILD_OUT，**不要列印rig.env或token**。

### 粗篩但未證實的其他風險（先不亂改）

- pooled BO release沒有scattered BO的user-pmap保留檢查，可能在舊CPU view存活時重用extent；未觀察到實際存活mapping，不可當根因。
- `DroidVMGpu.cpp::dropPieces()`忽略UNBIND/FREE失敗；本次現場相關failure counters為0。
- frontend `iosurfacePlane`硬回0；descriptor `swizzle`未傳，swizzled-view selector未實作。GPU plane import offset本身有傳對；先捕捉CA是否真的用非identity swizzle／plane getter再擴大修改。
- host顯示GUEST blob路徑的udmabuf、Vulkan import與AHardwareBuffer cache生命週期粗篩未找到直接錯誤；latent rebacking/remap invalidation缺口不在當前active路徑。

## 本輪進度（2026-10-24，實作中）

已接回 Codex session `01a16aa5-ff19-7362-96c6-ee7dfc26131d`。使用者在該 session 同意直接以
**virtio-gpu 顯示＋drm2kgsl 3D** 為目標，並要求**移除 simplefb device**；以下舊交接的「保留 simplefb」方案已被取代。

- 上輪已完成並編譯：crosvm `--virtio-mmio-gpu`、ADT 的 GPU 節點與獨立 boot-video RAM、DarwinBoot 的 BLT-only GOP 交接。
- 本輪新增：`DroidVMVirtioGpu.cpp/.h` 共用控制 queue／fence transport；`DroidVMVirtioGpuDisplay.cpp` 顯示 client，
  支援 classic 2D 與 guest-handle blob，持有 IOSurface 頁面到 RESOURCE_UNREF 完成，flush fence 完成才 retire swap。
  XNU kernel 已編譯通過；實機已能無 simplefb 開機、顯示鎖定畫面／主畫面／小工具／萬花筒桌布／設定，輸入與網路正常。
  scanout 走主機 udmabuf GPU blit，guest 的 `native_legacy_copy_n` 與 GPU fallback 都維持 0。
- crosvm 補上純 GUEST blob 的 iovecs；MMIO 裝置註冊補呼叫 `on_sandboxed()`，讓 GPU renderer worker 能啟動。
- edk2-gunyah 的 GPU 驅動補 `SetQueueNum()`：實測舊版在 MMIO 上把 queue size 留為 0，卡在 UEFI。
  `PcdVideoResolutionSource` 改為 unset，讓 GOP 採用 host 的 1366×1024。DarwinBoot 的 preferred boot-video 區域
  若已被韌體占用，改從上限以下配置對齊的空閒 RAM，再降低 XNU reclaim limit；實際位址以 handoff.env 為準。
- 首輪確認：實際 GPU 位址 `0x0a009000`，舊裝置位址不變；無 simplefb 時 RAM 為 `0x80600000+0x13fa00000`。
  全部 2560 大頁由池供應，各輪正常 stop 後全數歸還。3D 仍使用既有 droidvm-gpu proxy，尚未換成 drm2kgsl。
- rig：沒有本次開機的新 DarwinBoot handoff 就停止探測，避免拿上次 kernel 位址判斷；health 顯示 virtio-gpu 計數；
  show-vm 從 VM 設定選擇 gpu-0／simplefb 及解析度，不再寫死 simplefb。
- 既有映像與設定備份在 rig 的 `out/virtio-gpu-before/`；12 GiB Data seed 未變更。新韌體使用 VM 專屬
  `edk2-virtio-gpu.fd`。此輪各 repo 修改目前尚未提交。

接續順序：先驗證無 simplefb 開機與 blob 顯示 → XNU 3D context／資源／IOKit ABI → turnip `vdrm_iokit`
及 IOSurface 匯入 → 跨 client 同步 → 主畫面／設定／桌布／Safari 與幀時間驗收。

### 已知問題修正續行：旋轉紋理（2026-10-24）

使用者要求修好已知問題，已恢復追查display與GFXBench。直接讀backboardd的Metal telemetry找到6000多次IOSurface texture建立失敗：要求1024×1366，但row5632／alloc0x580000對應既有橫向surface；runtime回BufferTexture(PastBuffer)。原frontend與C/Rust DTO丟掉MTLTextureDescriptor的rotation/framebufferOnly/isDrawable，texture getter也硬回rotation0與framebufferOnlyNO。底層runtime已有rotated IOSurface路徑，故本輪補傳真正SPI值，不以尺寸猜旋轉、不新增全域fence。

新增MetalCheck第29項：256×64 physical IOSurface、四種rotation、四象限圖案，逐像素核對physicalstore；Mac29/29與三項benchmarkPASS。舊guest外掛明確29失敗（counted261376 >65536），其他28PASS：`out/rotation-fix/before/`。

新plugin已build/sign，CDHash2f26cd759fa463deb7be5f2c93adfa4a50b4d13b，md5 56e436a670304ccfe7ea3d9e6922b0ba；newMetalCheck CDHash e39e7583cc588d163820f05f1e52cea49fdbf092；trustSHA4cfe75e276af2ca169198a161f19df4f5ba022d5fb7a3773f0a5c60415a78fd0。新plugin與old都保留trust供A/B。

**部署陷阱實證：** 同一boot對`ngpu/addons/NativeAdrenoMetal.bundle` rename換目錄，Data讀到新md5，但`/System/Library/Extensions/NativeAdrenoMetal.bundle/NativeAdrenoMetal`仍是舊7aa886…（bindfs cached vnode）。所以`out/rotation-fix/stale-overlay-attempt/`不是新plugin測試結果。現正依harness正常restart，使systempath更新後再驗。未根據猜測改GPU pool、hostcache或更多fences。

### 14:49 接回 GPU benchmark／壓測（進行中）

使用者要求先停止不穩定的閃爍復現，回到 GPU 壓力測試。維持 pseudo-unprotected、512 MiB guest BO allocator pool、producer wait=1、early retire=0；未進行 pool=0 實驗，也未新增全域 fence。

- 新版 loss status 部署後仍曾發生 context loss；它傳遞錯誤，但不會自動重啟 compositor。`out/loss-status-news/` 的最後一次不是乾淨 News-only 測試：使用者同時操作 Safari。不能據此斷定 News 單獨觸發。
- 暫用 `/private/var/ngpu/tu_debug` 的 `nocb`（只停 concurrent binning、保留 GMEM）後，Safari→Home→News→Home 六輪沒有新增 loss；`out/mixed-apps-nocb/report.json`。仍屬實驗，尚非 hang 根因修復。
- Metal Check 舊 guest 26/28 揭露兩個真實 bridge 缺口：indirect compute selector 未接到 runtime，以及 render-pass resolve texture 完全未傳遞。NativeMetal 現已補 indirect dispatch、resolve texture／mip／slice／depth plane、depth/stencil resolve filter，並保留資源 lifetime。
- case 6 加強為前段 GPU blit 寫入 private indirect buffer 的非零 offset；case 19 改為 resolve 到 mip 1、array slice 1 並檢查全部像素。Mac 與 guest 都 28 PASS／0 FAIL／0 SKIP，三個 benchmark PASS；guest 報告 `out/metalcheck-guest-enhanced/report.json`，沒有新增 GPU loss。
- 該 guest baseline：render 74.76 M pixels/s、compute 252.55 M float-elements/s、blit 3.027 GB/s。這是指定 offscreen workload 的端到端吞吐，並非面板 FPS 或峰值 GPU 規格。
- 新 `metalcheck-run.py` 收集 app JSON、progress、GPU loss、pool／guest page counts、host memory PSI，且不修改 fence 策略。App 增加五分鐘 stress、額外記憶體 0／128／256 MiB、每輪驗證與停止控制；CLI 允許 1–86400 秒與 0–512 MiB。
- 首次 guest 長測 `out/metalcheck-guest-stress-300s/report.json`：303.98 秒，9 輪，28 項 correctness 與全部 workload／resident buffer byte checks 通過，沒有 loss、display errors 或 timeout。含桌面操作與一次明確 SpringBoard restart（研究安裝）；不是純效能 baseline。發現 CPU byte-check 每次迭代重查 Objective-C buffer length，已移到迴圈外；新 app 待重測。
- 兩個 App 已能以 installation dictionaries 註冊為 installed/valid，單用 `registerApplication:` URL API 不能建立完整新記錄。第一次註冊路徑 `/var/ngpu/apps` 遭 xpcproxy process-exec System Policy 與 iconservicesagent file-read-data 拒絕；正在改由 MCMAppContainer 保存 app，MCMAppDataContainer 保存 metadata，CLI 原路徑留 symlink。App 簽章的 no-container=true 保持一致，不能因此標成 IsContainerized=true。
- 新 helper `lsdiag owner-install` 僅搬動 org.droidvm apps，同 volume rename、拒絕現存目的地；`owner-register` 使用真實 XML signed entitlements 和 container metadata；`launch` 走 LSApplicationWorkspace，須先解鎖。GFXBench 的 UI 與 runtime source compilation 尚未驗證。
- 當前 kernel a308bca…、crosvm a340264… 沒變。Metal plugin CDHash `7929ff6731ad80117455e37c1102f4d595bebd3b`，md5 `7aa886f69f4f125ed1cf8034f222c12c`。本輪只更新 apps／plugin／trustcache，沒有重建 Data seed。最新版 MetalCheck CDHash `4c558c5375d54a7b8574c912b52a8155cc4da513`；lsdiag `9dedf86c03876da02ec908decd9a67414b1e03e6`；trust `71df10e69538231ce8733299dffbfec1d81d13cdc2aaa5b0405cf74e2d19d871`。

### benchmark 安裝與實測更新

- Metal Check／GFXBench 已用 MCMAppContainer 實際移至標準 bundle container；`ngpu/apps/*.app` 保留 symlink。Data seed 不變。舊位置被 System Policy 拒絕 UI exec，並非 Metal app 編譯失敗。
- MetalCheck 實際 UI（UID501）已啟動；Correctness + Performance 28/28 與三個 workload 都通過，`out/metalcheck/ui-performance.json`。停止控制在完成3輪後回傳 CANCELLED，`ui-stress-stop.json`；目前 report 保存 `/private/var/mobile/Documents/MetalCheck/latest.json`（簽章為 no-container）。
- 最終 app 長測 `out/metalcheck-guest-stress-final/`：301.76秒、20輪 API／resident buffer oracle PASS，active loss mask 0、歷史loss沒有增加。但畫面保留舊 MetalCheck內容及文字破圖，即使 Home 與 GFXBench foreground transition 在FBS logs已完成。結束後也未自動恢復。**整體驗收FAIL**；`report-automated.json` 保留原API/counter PASS，`report.json` 加入獨立視覺判斷並標FAIL。不是GPU hang根因定論，不能宣稱nocb解決閃爍。
- 視覺證據：`out/benchmark-home-after-gfx.png`、`out/metalcheck-post-stress-display.png`、`out/gfxbench-startup-logs.jsonl`。Android detach/reattach未恢復內容；明確SIGTERM backboardd58後恢復，GFXBench loading畫面可見。舊trace未取得backboardd role T，不是它當時已死的證據。
- rig `metalcheck-run.py` 現在明示 `validation_scope` 與 `visual_check=NOT_ASSESSED`，印出API/counter PASS，不自動宣稱畫面正確。
- GFXBench 在恢復後仍停在 loading，但NSUserDefaults的LastSuccessfulSync已更新，所有worker/main idle，表示初始化完成通知未讓controller跳轉。已補 NUIAppData.serviceReady、viewDidAppear補查與一次性segue guard；Mac增量build PASS，正在部署驗證。compat patch SHA變更為`f79c92798f54212851fbcd0a88ad3e6fe7dfc964752c70991f71fad255fbb9bf`，source pin與build script同步更新。
- 新GFXBench CDHash `a89f8f50ac8e113c9469ced0202cfe9f06e26659`，新trust SHA `f7975a7b29289ed85b83f74b83e076570e333990f61ca1542a42dd05647798bd`。標準bundle container受DataVault保護，root toybox mv仍被拒；實際以有AppBundles entitlement的lsdiag copy更新已停止的app，5檔均回done，接著checksum／sync／正常stop。沒有搬重複2.6GiBassets。`board.toml` trust hash已同步到Mac。

### 本輪收尾狀態

- GFXBench loading防通知遺失修正已部署；exec md5 `c412c0699ad9dc1bf8c793047c66aa43`。重開機後兩個MCM app記錄仍installed/valid，證明安裝資料已持久化。GFXBench服務LastSuccessfulSync更新，但畫面仍可能保留loading或前一個Home，與foreground logs不同；**不能認定通知競態就是此次卡畫面的根因**。該防競態修改未取得端到端UI通過證據。
- GFXBench目前只確認build/sign/install/processlaunch，**尚未成功執行任何GFXBench workload，也沒有有效GFXBench分數**；runtime `newLibraryWithSource`仍未驗證。root直接啟動UIKit command-line分支的最小ALU smoke在90秒後timeout且無輸出，已明確TERM該root診斷程序，不能把它當成shader compiler失敗證據。
- 使用者要求先回到壓測，故本輪不擴大修改display/fence/pool去追此卡畫面。MetalCheck UI已實測可用，壓測可透過UI或`metalcheck-run.py`啟動；當前CLI/app是含byte-loop優化的版本。GFXBench留作已安裝、未完成運行驗收的項目。

最後恢復：VM pid16351，backboardd450，MetalCheck重新以UI啟動；final health沒有kernel panic／GPU loss／display error，early retire0、producer wait1。GFXBench的root與UI診斷程序已TERM，無benchmark持續運行。hostwatch仍保持監視。最終摘要在rig `out/benchmark-final-status.json`；來源修改尚未提交。

### 動畫閃爍調查（同日，使用者要求優先處理）

可重現操作：主畫面右滑開今天概覽（背景模糊），回主畫面後下滑開搜尋與鍵盤。靜止後內容正確，動畫中圖示消失、
背景回到未模糊／只有桌布的中間階段。已確認同步鏈少了一段：

1. `native_legacy_gpu_offer` 交付 IOSurface 後直接發出 scanout，沒有等待寫入這一幀的 guest GPU 工作。
   Android display 的 Vulkan acquire barrier 也沒有帶 guest producer semaphore；它等待的 acquire fd 是**目標 AHB** 的 release fence。
2. crosvm 原有的 display release fence 超過 25 ms 便 `completing anyway`。原始測試開機 log 至少記到
   fence 5253、5263、5277、5283 四次，會讓 guest 提早重用仍被 host blit 讀取的來源。

實驗：已部署移除 25 ms 假完成的 crosvm。guest 增加 `droidvm_virtio_present_wait` 可切換的診斷版：
offer 時捕捉 droidvm-gpu 已提交的全域 timestamp；worker 在 scanout 前查 retired，開啟時等到 retired 到達目標。
**OP_WAIT 成功只代表當時阻擋 timeline 的最舊 context 完成，所以每次醒來仍須重讀全域 retired。**
producer wait 或 transport 失敗時保留 outstanding swap／頁面，不以 CPU fallback 假裝完成。

同一開機的有效 A/B（rig `out/flicker-home-{off,on}.{mp4,json}`，兩次都先用 Home 按鈕回主畫面）：
- off：399 次 probe 中 335 次 producer 未完成；影片可見只剩桌布、圖示消失的中間幀。
- on：408 次 probe，319 次需要等待；等待合計約 1.99 s（約 4.9 ms/probe，非總幀時間），中間幀閃爍明顯減少。
- 兩次 virtio command errors 都是 0；CPU copy／fallback 仍是 0。這是短時間診斷驗證，尚非全部畫面無閃爍的驗收。
- 早期 `flicker-strict-no-producer-wait`、`flicker-producer-wait-on` 影片因 native Surface 未連好而全黑，不作視覺 A/B 證據。
  若 activity 顯示 Connected 卻沒有 SurfaceFlinger buffer，先返回 Android 上一頁再跑 `show-vm.sh`。
  不要在 UEFI 接管期間提前 attach：UEFI→XNU 的 GPU reset 會換掉 surface；rig 已撤回該實驗。

**復現前狀態（2026-10-24）：** `droidvm_virtio_present_wait` 的編譯預設已改為 1，當時已部署並重啟驗證。kernel 為 unpatched kernel（sha256 `d1bd2fe2e018e7b0da94598a9b9e50ea9392f456771befa066a5001cf930f408`）；crosvm md5 維持 `6437f8035188c83721c9312b0b3bde15`。這只確認 producer wait 與錯誤計數器狀態，尚未證明視覺正確。

**歷史 soak（復現前）：** rig `out/display-soak-20261024-070523/report.json`，`passed: true`；30 輪、365.46 秒、8746 display frames。command errors、timeouts、CPU copy、fallback 的增量皆為 0；`backboardd` PID 57 全程未變。新增 crash 僅 `SiriSearchFeedback`。這個 passed 只代表當時的計數器與程序檢查通過，沒有檢查 `early_retire`，也不代表畫面視覺正確。

**歷史手勢效能對照（復現前）：** `out/display-profile-20261024-071145.json`，`passed: true`；ON/OFF/OFF/ON 各 3 輪。ON 1174 swaps、平均完成間隔 33.383 ms；OFF 1170 swaps、33.677 ms，約 29.95 vs 29.69 swaps/s。數值包含手勢間隔，代表 guest swap 完成速率，不是面板 FPS；短測不足以宣稱所有負載都沒有回歸。ON producer wait 平均 6.23 ms、P95 13.929 ms；OFF 平均 0.655 ms。當時 `sheng-early-retire` 仍為 1，這些數值保留作歷史紀錄，不能當成完整正確同步路徑的效能基線。

**07:24 再次閃爍（2026-10-24，驗證中）：** 使用者回報動畫再次閃爍；`out/flicker-recurrence.mp4` 與 contact sheet 清楚顯示主畫面和純桌布交替。錄影當時 producer wait 為 1、virtio display state 為 2、errors/timeouts 為 0，`backboardd` PID 57 沒有重啟，因此先前穩定的程序與錯誤計數器未能發現視覺錯誤。

漏查原因是 NativeMobileDisplay 原有 `sheng-early-retire` 預設為 1，`early_retire` 已累計約 27,800 次。保留 `IOMemoryDescriptor` 只保住 allocation，不會阻止 guest 重寫來源內容；先前 30 輪 soak 的 passed 只代表計數器檢查通過，不代表視覺正確性或完整同步路徑。

07:29 已在 `board.toml` 與當前 bootdisk 設定 `sheng-early-retire=0` 並重啟；health 顯示 `early_retires=0`、producer wait 1、state 2、errors 0。當前仍是 kernel sha256 `d1bd2fe2e018e7b0da94598a9b9e50ea9392f456771befa066a5001cf930f408`，靠 bootarg 0 修正。`NativeLegacyDisplay.cpp` 的 source default 0 已編譯成功，新 unpatched kernel sha256 `6f51b31caa771fcf0396aea9f9ef2a056caf8389b724cd3d5161d9b6d8cc9460` 尚未部署。後續 8 輪手勢已跑，但因期間發生 GPU Lost 而作廢。health/soak 現在會檢查 early retire 為 0，並追蹤 `boot_frames`。

NativeMobileDisplay submodule 剛初始化在 local commit `8666a9950c9699b368931d18cac92c0fdb2ce9c0`；其 `default=0` source 修改尚未提交。

**07:40 進一步定位：persistent flicker 是 3D context lost 後重播舊 surface。** 使用者已確認完全沒有操作，皆由 rig 控制。
host KGSL 在 UTC 23:23:33／23:30:22（台灣 07:23／07:30）報 GPU hang；crosvm 兩次均記錄
`client 0 lost its GPU context 23 (WAITTIMESTAMP ... os error 35)`。guest `droidvm_gpu_lost[0]=1`，
`gPresentSubmitted=2115` 停住，但 display counter 繼續增加，backboardd PID 57 仍活著。讀三個 udmabuf 的實際像素：
兩張有鍵盤、另一張沒有，都是 16:30 的舊內容，與 Android 錄影交替的畫面一致。
`out/display-soak-20261024-072955/` 的 8 輪及 `out/display-profile-20261024-073336.json` **作廢為效能／正確性證據**：
它們未檢查 3D context loss 與新 GPU 提交，只計到舊 surface 重播。約 1 ms 的等待與約 40 swaps/s 不是效能改善。
boot_frames 在該段沒有增加，因此該次交替也不是切回 boot framebuffer。

取證：rig `out/flicker-device-lost-{dmesg.txt,crosvm.log,backboardd.log,trace.txt}`、
`out/flicker-kgsl.snapshot`（4,863,040 bytes）、`out/surface-recurrence/{390,393,395}.png`。
udmabuf fd 不能直接 open `/proc/PID/fd/N`；診斷 helper `/tmp/droidvm-dmabufgrab.c` 用 pidfd_getfd 後 mmap 讀出。
07:45 對 backboardd PID57 送 SIGTERM，launchd 起新 backboardd PID439／SpringBoard PID441，
正常回到鎖定畫面；解鎖後提交已到 2408。這是人工恢復實驗，尚非自動恢復或 hang 根因修正。
恢復後有效的 3 輪 counter-soak `out/display-soak-20261024-074741/report.json` 通過：提交 2765→5620、context loss 1→1、1316 display frames／82.59 秒，errors／timeouts／early retires 增量為 0。這是計數器與提交前進證據，不是視覺驗收。
health 已加歷史 context loss 警示；soak 會拒絕新增 loss 或一輪手勢期間 GPU 提交完全不前進。
恢復後短測已完成，counter 結果見上方 3 輪報告。source retire/default 與 host 25 ms 假完成仍是應修的同步缺口，不能把它們當作此 hang 已解決。

**09:02 News 重現與部署：** 使用者回報「打開 Apple News、等待新聞載入、回桌面」後復發。
crosvm 在 01:02:56 UTC 記錄 client 0/context 23 的 GPU_COMMAND EDEADLK；本次 boot loss[0] 由 1→2，
backboardd 439／SpringBoard 441 未重啟。`out/flicker-current-0854.mp4`（實際約 09:05 錄影）顯示 News 與桌布反覆交替。
仍是舊 kernel／plugin；錯誤傳遞修正當時尚未部署。KGSL dmesg：ts184209，IB1=0x600a2c4000/0x44，
IB2=0x600b15a000/0。KGSL snapshot 無法映射 active IB，dump 本輪為空。

已用 cpu_ttep 與三個已知 kernel image 符號核對 4 KiB／38-bit VA page walk，讀出兩個仍存活的 BO、1612 筆 GPUVA mapping，
並在暫停 backboardd 後保存 512 MiB BO pool；資料在 `out/flicker-current-0854-gpu/`。
兩個 BO 的單獨讀取與 pool snapshot bytes 相同，mapping 在讀取前後一致；但這是 fault **之後**的內容，
不能排除 fault 到凍結期間曾被改寫。cffdump 已建置，IB2 可解碼為 GMEM→UBWC color resolve；尚非 hang 根因定論。

09:15 正常 stop，10秒後 pool2560/2560、active0。部署 kernel a308bca…、crosvm md5 a340264b32b3bab69b5ff303aeedff5e、
NativeMetal plugin md5 f8b4d5c4e206b3001282a3f2e8be24a9，以及含兩個 benchmark 的 owner trust be8eff89…。
Data seed／ADT／DarwinBoot／EFI hash 均與備份相同。首次開機因 boot args 1025 bytes 超過1023被loader拒絕，未進XNU；
移除與新kernel預設相同的 `sheng-early-retire=0` 後1004bytes，保留source預設0；rig deploy增加長度檢查。第二次開機驗證中。
GFXBench app與MetalCheck app已寫入Data `/private/var/ngpu/apps/`，GFXBench archive兩端SHA256 cda6c824…一致；
尚未註冊／啟動guest app，不能視為已完成預裝驗收。

目前尚無自動 GPU 恢復機制。producer／transport 逾時時保留 outstanding，不假裝完成。每個 IOSurface 精確綁定 producer 依賴是後續效能優化；接入 3D 前須隔離 renderer fence 與 display fence。

完整正確性驗收仍未完成。測試期間必須確認 early retire 為 0。把「producer fence → blit → 真實 display release fence → retire swap」設為必要條件；
先保留全域 timestamp 等待作保守實作，再把 producer fence 精確綁到 IOSurface／swap，避免等其他 client 無關的工作。
drm2kgsl 3D 接入時要一起銜接此依賴；renderer fence 與 display fence 亦不得互相提前完成。
逾時保留 outstanding，不假裝完成；自動 GPU 恢復尚未實作。驗收要重複兩組手勢，檢查畫面、fence、頁面生命週期與實際 FPS。

**08:45 待部署更新（2026-10-24）：** NativeMetal 新錯誤路徑用 typed `NSError`；iOS 將 `DeviceLost` 映射為
`MTLCommandBufferErrorAccessRevoked`（4），macOS 映射為 `DeviceRemoved`（11）。Rust unit、iOS syntax 與 plugin build 通過。
host wire 保留 `INFO legacy64v3`，新增 16-byte tagged capabilities query 與 `RETIRED` lost mask；guest 在 per-connection
`GetStatus`／`WaitFence` 前後回報錯誤。內部 cleanup 不 poison 整個 ring，也沒有新增 fence。
Mac kernel SHA256 `a308bca0261049d5dbf98c69584b8d42e93471bf95a8a25646df3ef03bb14fee` 已建置但未部署；crosvm Android
完整兩個 build 與三個抽取 metadata unit 通過，完整 Cargo devices build 仍被既有 dependencies 阻擋。
GFXBench pinned source 已 build、signed，含約 2.6 GiB assets，正在搬入 guest，尚未安裝／驗證。MetalCheck 的 M4 host
baseline 為 28 PASS、0 FAIL、0 SKIP 且三項 benchmark PASS；guest 尚未執行。`plans/HOST_PERIPHERALS_SURVEY.md` 已完成；
下一步依文件先定共同 protocol/capabilities，再做 battery provider；目前仍是方案，未實作或驗證外設。

> 先讀：本 repo 的 `hugepage-harness.md`（**每次開關 VM 都要照做**），以及裝置 repo 的 `tools/rig/README.md`（所有工具）。

---

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
- **Metal：** 經 droidvm-gpu 到主機 KGSL，最多 32 個 GPU client，每個 client 一個 KGSL context，跨 context 依序執行。
- **Data volume：** 12 GiB，會持續保存。
- **owner 工具：** 可以 ssh 進 guest；有 ownervisor 服務管理、toybox、zsh、lsdiag、gfxprobe。

**已知問題（依優先順序）：**
1. **歷史問題（已由新狀態取代）：動畫中畫面撕裂，且上限約 18 fps。**
   - 原因已查清：NativeLegacyDisplay 每一幀用 CPU 把 5.6 MB 寫進 Device 屬性的 simplefb，平均 56 ms；主機端 simplefb bridge 每 16.7 ms 盲目做一次 GPU blit。兩邊沒有同步。
   - 當時決定將顯示改成 virtio-gpu、不再用 simplefb；此項已完成，現況與驗收數據見本文動畫閃爍調查及第 7 節。
2. **偶發的文字破圖。**
   - 例：設定 app 第一次開啟後，側欄「一般」的文字變成每 3 行一個週期的錯位條紋，看起來像行距錯配，要等重繪才會恢復。
   - 無法照指令重現。
   - 常見的那種（文字被別的 label 的內容取代）已在 fork 9eb0d75 修好：render server 替它 texture 化的 IOSurface 計使用量。
3. **render server 的 DeviceLost 已再現，為目前優先問題。**
   - 現象：backboardd 的 client 0 收到 EDEADLK，整個畫面閃爍到重開機。
   - 2026-10-24 已再現兩次 host KGSL hang。人工重啟 backboardd 可重新開 context；目前沒有自動恢復機制。
4. **桌布圖庫的 Pride／Collections 預覽是黑的。**
   - 兩者都在外掛壞掉的那段時間 crash 過；已清掉 GalleryCache，Data 重設後還沒驗證。
5. **其他：**
   - 設定 app 第一次開啟要 10 秒以上。
   - WebKit.GPU 曾在開裝置時拿到 Vulkan -5。
   - 舊紀錄：開機時曾觀察到 apsd、imagent、siriactionsd 的 ExcUserFault，以及 OTAUpdate、SiriSearchFeedback、JetsamEvent；此項已由上方最新 soak 結果更新，目前新增 crash 僅 SiriSearchFeedback。
6. **Maps 刻意不放進 GPU client 名單。** 它曾經讓整個 GPU 掉線；後來加了每個 client 一個 context，但還沒用實際的錯誤驗證過。
7. **Data 剛重設（2026-10-24 改成 12 GiB）。** 桌布要在設定 app 裡重新選。

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

2026-10-24 最初交接時的head（歷史；最新commit見文件頂端）：
- meta：本 commit
- 裝置 repo：`512350a`（rig 工具）
- fork：`0fecbc8`
- crosvm：`61c47a469`

元件（NativeMetal、NativeAdreno、NativeMobileDisplay…）是 fork 的 `drivers/` submodule，先找各自的 dev 分支，再用 org 的穩定 droidvm 分支。
上游 UniXNU 每天有幾十個 commit。上一次合併是 fork 的 a3412ef（2026-10-23），重點：
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
| XNU patch | 在 Mac 的 `out/droidvm/tree/.cache/xnu-work` 改 → tree 裡跑 `scripts/save-xnu-patch.py NAME FILE` → 把 patch 複製回本機 fork。要換掉已套用的 patch，先用**絕對路徑**的 `git apply --reverse` 退掉舊版 |
| kernel 或板子程式碼（`package/*.c`） | 同步裝置 repo 的 `package/` **和 `scripts/`** 到 Mac → Mac 上 `PATH=/opt/homebrew/bin:$PATH ./unixnu build kernel` → rig 的 `deploy.sh` → `vm.sh restart`。編譯失敗後缺物件時，刪掉 `build/xnu/ios-obj/.../osfmk/DEVELOPMENT/startup.o{,.json}` 讓它跑 bootstrap pass |
| Metal 外掛（frontend、bridge、turnip） | `tools/rig/plugin-redeploy.sh`（`FORK` 指向本機 fork）。新加的 metal2vulkan／Mesa patch 要先在 Mac 的 `.cache/…` 手動 `git apply` 一次 |
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

**owner 工具：**
- **每個 owner 工具都要 ad-hoc 簽，而且要帶 `com.apple.private.security.no-container`**，否則會被 launch constraint 擋下。
- **lsdiag 要用 manual RC**（`-fno-objc-arc`）。
- **IONetworkingFamily 的子類別一定要 `-D__PRIVATE_SPI__`**，否則 MAC 位址會是 0。

**主機：**
- **Mac 的 `hdiutil attach` 在 `/Volumes/DATA` 上 over ssh 會被拒**，seed 相關的腳本要從 `/tmp` 的 root 跑。
  `seed-data-grow.py` 的磁碟辨識 bug 已在 fork `0fecbc8` 修好。
- **主機當機**都是 watchdog bite，而且都發生在 stop 之後立刻 start、大頁池還沒回收完的時候 → 一律照 `hugepage-harness.md` 做。

## 7. 下一步

本輪完成項：virtio-gpu 顯示已取代 simplefb 顯示，無 simplefb 開機與顯示已實測；過時的 simplefb 閃爍問題描述只作歷史背景，以上方新狀態為準。

1. **GFXBench：** 全部 Metal 測試都能跑到出分（Tessellation 測試除外：這版 iOS 建置沒有它）。待辦：
   - ~~記憶體破壞的來源~~：已修好（8 位元 ASID＋vCPU 遷移，fork zzxa-16bit-asid.patch，見最上面的續報）；
   - 把改過的 `libvirglrenderer.so` 正規打包進 APK；
   - ~~GFXBench 每次啟動都在行程內重新編譯所有 shader~~：已加入持久化 shader 快取（NativeMetal 3eb5926，fork 4675e62）。
     - 快取放在每個行程自己的 `Library/Caches/native-metal-shaders/`，key 是 MTLCompiler 的 UUID 加上請求內容的 SHA-256。
     - Car Chase 總時間從 232 秒降到 133 秒，fps 不變。
     - 第一次啟動仍會完整編譯。
     - `NATIVE_METAL_NO_SHADER_CACHE=1` 可以關閉。
     - 注意：GFXBench 的 container 在 `/private/var/mobile/Containers/Data/` 底下，guest 的 root ssh 沒有權限列出（Operation not permitted），所以看不到它的快取檔。gfxprobe 的快取在 `/var/root/Library/Caches/native-metal-shaders/`。
2. **Metal Check：** host／guest均28 PASS、0 FAIL、0 SKIP，三項benchmark PASS，UI啟動／保存／停止控制已驗證；兩次五分鐘壓測完成。最後20輪API/counters PASS但視覺FAIL（見上文），不是完整Metal或display conformance。
3. **通用外設：** `plans/HOST_PERIPHERALS_SURVEY.md` 已完成；實作未開始。下一步先定共同 protocol/capabilities，再按 survey 驗證 battery provider；transport 支援不代表 guest OS 原生 API 已接通。
4. **顯示效能：** 將 producer 依賴精確綁定每個 IOSurface，評估減少不必要的全域等待；接入 3D 前隔離 renderer／display fence。
5. **GPU 恢復與文字破圖：** 尚無自動 GPU 恢復；若文字破圖重現，立即截圖並記錄 backboardd 的 IOSurface 資訊。
6. **3D 改走 drm2kgsl**（survey 第 4-7 步），之後再評估 venus／gfxstream。

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
