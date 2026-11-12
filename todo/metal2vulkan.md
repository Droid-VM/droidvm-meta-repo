# metal2vulkan（Metal → Vulkan 執行期）

guest 的 Metal 由 NativeMetal plugin 交給 metal2vulkan，經 Turnip（virtio-gpu＋drm2kgsl）跑在手機的 Adreno 上。
本檔是 2026-11-08 GPU「正確性＋穩定性」收尾時的現況與瓶頸；效能先告一段落，下面的瓶頸是之後的起點。

## 現況

**來源與 patch 疊層**

- 上游 steelbrain/metal2vulkan（development），釘在 `624bab39`（`scripts/data/gpu-metal-vulkan-inputs.json`）。
  上游改寫過歷史：624bab39 不在任何分支上，development 上的對應是 `99a4604fb`（主旨、日期相同，約 700 行原始碼不同）；
  11-03 之後的 commit 雜湊不再變。
- 第一層：AdrenoMetal bridge patch 0001–0024（UniXNU 上游的，C ABI、stage trace、QoS、診斷開關等）。
- 第二層：board patch 0011–0038（我們的，fork `patches/metal2vulkan/`，清單與每個的說明在 `scripts/build-adreno-metal-bridge.py`）。
- 上游 commit 用手工回移植（`bp.sh`：`git apply -3` 後去掉計數器、測試、我們沒有的 draw_again／live dispatch）：
  0032 帶了 26 個，0035 是 ce204a121。
- 建置只套樹裡還沒套的 patch；要換掉 Mac 上已套的 patch，先在 `.cache/gpu-reference/metal2vulkan` 裡 `git apply -R` 舊的。

**board patch 一覽**

| 類別 | patch |
|---|---|
| 旋轉的 framebuffer（CoreAnimation 的 rot3） | 0011 2D engine 轉向、0014 quarter-turn plane row、0026 copy back 丟掉帶著的 shadow（毛玻璃） |
| iPadOS 27 的 shader 與 pipeline | 0015 未接的 color 讀成 0、0016／0018 specialized linked function、0037 cube 方向的平手處理 |
| 優先權 | 0012 queue global priority（render server 高優先） |
| 記憶體（每個 block 都是 wired guest 記憶體） | 0013 trim kept memory、0017 spare 限在位址空間內、0019 block 大小、0020 壓力下不留 room、0022 trim command pool、0027 keep_room 上限、0029 memoryless backing 共用、0030 idle merge scratch、0033 共享 used map |
| render pass 的 store | 0021 DontCare 存成 DONT_CARE、0024 依附件類別 |
| WebGPU（WebKit） | 0032 resident uses 一次一個 identity（回移植）、0034 encoder 層級 residency、0035 wide pointer 帶 root entry（回移植）、0036 device address 的字由同一位址索引、0038 GPU 寫完才在 commit 讀 ICB |
| 診斷 | 0023 dont-care-store、0025 full-barriers、0028 placement sites、0031 backing-cover 開關與 pool report |

**驗證狀態（11-08）**

- MetalCheck 41/41：5566（Adreno 840）與 5567（Adreno 750）都過。MetalCheck 不涵蓋 argument buffer 和 ICB，
  這兩塊靠 Safari 頁面與本機 `icb_scale`。
- WebGPU：webgpu-samples 28 個範例畫面都符合原始碼預期（5566）。
- WebGL 2（ANGLE → Metal）：get.webgl.org/webgl2、webglreport v2，three.js webgl_ubo、ubo_arrays、multiple_rendertargets、
  texture2darray、volume_cloud（3D texture）、animation_keyframes（skinning）都正確（5566）。
- GFXBench Metal：Aztec、Car Chase、Manhattan 在兩支手機都跑完。5567 的數字是 CPU 被壓到 1.4 GHz、GPU 上限 903 MHz 時量的
  （Manhattan 18.8、Car Chase 8.4、Aztec Normal 10.5 fps），不能拿來比效能。
- UI：backboardd、SpringBoard、桌布、小工具、毛玻璃、Safari 都正常；5567 的 render server 每幀都走 rotated 路徑。
- gpu-3d 的 fence waits timed out 只在單幀 GPU 工作超過 Turnip 的 100 ms 等待段時增加（例如 webgl_ubo_arrays 1 fps、GPU 99%），
  關頁就停，沒有 fence 遺失。

**沒有的功能（RuntimeGap 或我們沒接）**

- counter sample buffer → WebGPU 沒有 `timestamp-query`（上游也沒有）。見 [webgpu-webgl.md](webgpu-webgl.md#11-08-webgpu-沒有-timestamp-query)。
- 嚴格的 Apple4：raster order group、imageblock、tile shader、imageblock sample coverage、post-depth coverage 被拒；
  indirect／ICB 邊角、linear texture、depth/stencil resolve 有缺口。目前只對 WebGPU.framework 與 ANGLE 回答 Apple4。
- 強制 GMEM 會黑畫面（10-31，未查）。

## 瓶頸

### 1. 每個 draw 的 CPU 成本（最大的牆）

- 本機 lavapipe 的 `icb_scale`：host step 每個 draw 約 18 µs，encoder 直接畫同樣的 draw 約 15.6 µs；手機上約 56 µs。
- profile 是平的：`apart_uses`／`settle_resident`、tracker 的 HashMap／BTreeMap 每幀從空長到上萬筆、`bind_into`、`instantiate`、
  配置。沒有單一熱點。
- 影響：GFXBench Aztec 的 render 執行緒 93% CPU，82% 在 plugin 裡（`draw_resident` 約 51%），GPU 只忙 74%；
  WebGPU renderBundles 每幀 5000 個 draw。
- 方向：tracker 與各種 map 跨幀保留容量（不要每幀從空長起）；settle 的結果按 identity 快取；同一 pipeline 連續 draw 批次化 bind。

### 2. ICB 每幀重錄（renderBundles 2.6 fps，Chrome 59 fps）

- WebKit 的 ICB 不繼承 pipeline 和 buffer（`inheritPipelineState=NO`、`inheritBuffers=NO`、indexed draw），runtime 的 GPU 形式
  （`render/executions/gpu.rs`：繼承 pipeline、只有 DRAW）用不上，只能在 CPU 上逐一錄 5000 個命令。
- 0038 之後錄製移到 commit（寫入都完成才讀），不再擋排程執行緒：2.3 → 2.6 fps。每幀仍重錄一次。
- 上游 963f0e64 的 draw_again／kept chunks 排除讀 heap 的 draw（WebKit 的 bind group 都是），對這個模式沒有效果，所以不升級、不移植。
- 方向：ICB 內容與 residency 的 identity 都沒變時，重用上一幀錄好的 secondary command buffer（replay cache）；
  或做能帶每個命令 pipeline 與 indexed draw 的 GPU 形式。

### 3. 非 bundle 模式切出太多 render pass instance

- WebKit 每個 indexed draw 前跑 index clamp 再下 buffer barrier，metal2vulkan 每次都切 render pass instance；有 depth 附件的
  pass 不能 inline 錄製，第一幀 5000 個 secondary command buffer，峰值 467 MB（之後 258 MB）。
- 方向：讓有 depth 的 pass 也能 inline 錄後續 instance，或判定這種 barrier 不必切 instance（clamp 只寫 index buffer 的副本）。

### 4. 產生的 shader 比原生肥（GPU 端）

- GFXBench 每幀 GPU cycle 是原生的 1.7×（Aztec）、2.0×（Car Chase）、3.0×（Manhattan）（11-08，5566，同頻比較；原生中位數含降頻，是下限）。
- half 運算一律展開成 f32，鏈的兩端各一對 f32↔f16 轉換（上游 narrow.rs 的設計，大 FS 約 15%），沒動。
- 經由指標的存取：0035、0036 之後還剩每次存取各算一次 64 位元位址加 miss 檢查（沒走的分支裡有 atomic）；同一指標加常數位移
  （同一 struct 的欄位）各做一套；ir3 沒跑能合併它們的 nir pass。
- 迴圈讀 uniform／storage 陣列很慢：WebGPU deferredRendering 的光照 pass 44.5 ms（Chrome 同機 54.5 fps）、
  three.js webgl_ubo_arrays（200 盞光）1 fps、GPU 99%。
- 方向：先用 `irc/runirc.sh` 離線編同一個 FS，對照原生 metallib 的指令數，找出迴圈裡多出來的位址運算與檢查。

### 5. 排程與管線

- 排程器從不扣住批次：73% 的提交送出時 GPU 佇列是空的（10-31）。
- renderBundles 一幀是 WebKit 編碼 → metal2vulkan 錄製 → GPU 三段串行，GPU 有一半時間閒著，DCVS 因此只開 319–555 MHz。
- 方向：commit 錄製與上一幀的 GPU 工作重疊；需要時合併小提交。

### 6. 記憶體

- pool 碎片：backboardd 的 64 MiB block 只用 8–51%（約 200 MiB），桌布約 100 MiB；「先放最滿的 block」量不出差別。
- keep_room 留著的空 pooled block（render server 547–616 MiB，0019／0020／0027 已壓下來，但 trim 不釋放 `emptied=None` 的）。
- IOSurface 的 shadow 約 57 MiB：架構性，要 dma-buf import 才能省。
- block 改 16 MiB 會讓 GPU hang（3/5 vs 0/5），所以維持 64 MiB。
- no-copy buffer／texture 的模擬：Spotlight 的重幀大半是在複製。

### 7. 跟上游的距離

- 上游 development 一週動了 +99k／−22k 行；UniXNU 上游 11-07 已改釘 963f0e64（642c4fe），我們沒跟。
- 升級的代價：28 個 board patch 加 24 個 bridge patch 要重新對齊，0032–0038 有一部分是上游的回移植或與上游重疊。
- 963f0e64 量過：direct 89.6 ms（我們 82.4）、`each` 跑不完（我們的 0033／0034 修掉的 O(N²) 上游還在）。
- 做法：照需要回移植（`bp.sh`），每次用 `icb_scale` 與 core tests 對照 base／fix 的失敗清單。

## 工具

- `icb_scale`（本機 lavapipe）：MODE icb／direct／each，SHARED、MESHES、VIEWS、TEXTURES、WRITE_FRAMES 開關，印 ms 與 texel hash。
- GPU 行程 heap：plugin 的取樣 heap sites（client-mem）、`heapsym.sh`；量完要關掉，否則每個 GPU 行程都變慢。
- 手機上的 GPU 時間：Turnip u_trace；KGSL `gpu_busy_percentage`（要 root）。
- CPU profile：spindump 加新 plugin 的 dSYM（`atos`／`llvm-symbolizer --inlining`）。
- 回歸：`metalcheck-run.py`、`gfx-suite.sh`、webgpu-samples 的 `wgsweep.py`、three.js WebGL 2 範例。

## 11-12 畫面局部閃爍：合成器的 GMEM pass 寫壞 framebuffer（止血：合成器改 sysmem，NativeMetal e84d02f）

**現象**：畫面某一小塊（或一大片黑）每隔一幀閃一次。11-11 是狀態列黑塊，11-12 是左邊 32×8 的時鐘碎片和 1536×2400 的全零矩形。
使用者發現「app 端退出再進入 native display 有機率觸發；滑動有時清掉、有時只是變樣」。

**機制**：CoreAnimation 只重畫有變動的區域。合成器某個 pass 被 Turnip 的 autotuner 送去 GMEM 時，會在它畫的那張 framebuffer 留下
16×4 對齊的錯誤區塊（全零或別的 pass 的殘留），之後沒人重畫，兩張 framebuffer 輪流送出就閃。錯誤內容在 guest 記憶體裡
（用 dmabufgrab 從 crosvm 的 udmabuf 讀出確認），host 只讀不寫。退出/進入會打亂 framebuffer 輪替，補畫範圍變大，才進 GMEM。

**重現與 A/B**（5566，scratchpad `reentry.py`：HOME → `am start --activity-clear-task` 操作頁 → 錄 2 秒找交替區塊；每輪 8 次）：

| 條件 | 結果 |
|---|---|
| 原設定（autotune） | 3/8 觸發 |
| `TU_DEBUG=gmem,nocb` | 幾乎每次 |
| `TU_DEBUG=sysmem,nocb` | 16/16 乾淨 |
| 修正後（合成器 sysmem，其餘 autotune） | 24/24 乾淨 |

排除（都照樣觸發）：host Vulkan 複製 vs CPU 複製、BKForceMirroredOrientation=portrait、操作頁的感測器轉發、host KGSL preemption 關閉、
`nobin`、`nobinmerging`、DontCare 寫回強制 STORE（`debug/dont-care-store`）、`tu_dont_care_as_load=true`。framebuffer 2048×2732 符合
gmem_align 16×4，走的是標準 blit load/store，不是 unpadded 路徑。**GMEM 真正錯在哪還不知道。**

**修正**：外掛在 backboardd 預設 `TU_DEBUG=sysmem,nocb`，其他 process 維持 `nocb`（MSAA pass 在 sysmem 貴 4 倍，所以不全面改）。
效能（所有 process 都 sysmem 的最壞情況，翻頁＋開關設定，ABAB）：72.7／80.8 fps 對 77.3／74.3，GPU 每幀中位數 9.4／8.3 ms 對 7.9／8.2，
在雜訊內（當時手機 CPU 上限 1.2～1.6 GHz）。

**同一版外掛新增**：`/private/var/ngpu/debug/env`，每行 NAME=VALUE 在外掛預設值之前 setenv，Turnip driconf、TU_DEBUG、m2v 開關都不用重編就能試。

**還沒做**
- 找 GMEM 的真正原因：env 檔讓合成器回 `gmem,nocb`，開 u_trace（MESA_GPU_TRACES）和 `NATIVE_METAL_DUMP_CB` 重現一次，用 dmabufgrab 定位
  錯誤區塊，對出是哪個 pass 的 load／store；不夠再用 `TU_DEBUG=rd` 存指令流離線解碼。
- 5567、5568 部署這版外掛。5566 這次同時套了 BKForceMirroredOrientation=portrait（原本只有 5567 有）。
- 其他 process（app 自己的 drawable）在 GMEM 下有沒有同樣問題，沒測。
- 螢幕關著時 guest 仍以約 13 fps 畫時鐘（一晚 27 萬幀在 host 端顯示失敗），耗電，另案。
- 測試中 guest 兩次異常：強制 sysmem 後自己重開一次；強制 GMEM 測到一半卡住空轉、手機 load 到 70，停 VM 後恢復。原因沒查。

### 11-12 下午：追 GMEM 根因的結果（還沒找到，但範圍縮到 GPU 執行層）

**最硬的證據**（`debug/dump-cb-now` 的 pass 傾印，每個 command buffer 後讀回 framebuffer）：兩個連續送到同一張 framebuffer 的
command buffer 內容完全相同（同附件、同 scissor、同貼圖、同 draw 數），前一個之後 framebuffer 正常，後一個之後多出一大片
(0,0,0,0)。指令相同、結果不同 → 不是 CoreAnimation 或 metal2vulkan 送錯，是 Turnip 的 GMEM 指令在 A840 上執行的結果不穩定。

**pass 的實際樣子**（`FD_RD_DUMP=trigger` 存指令流，上游 cffdump 解碼；工具在 scratchpad `mesa-up-build2`）：
- 一個 pass、三個顏色附件：c0 framebuffer（BGRA8，LOAD／STORE，GMEM base 0）、c1（RGBA16F，memoryless）、c2（R32F，memoryless）；
  c1／c2 每個 bin 先用 BLIT_EVENT_CLEAR 清成 0（GMEM base 0x3f0000、0xbd6000）。
- bin 1056×928，2×3 共 6 個，有 binning pass。三個附件用到 0xF93000，GMEM 18 MB 頂端 0xfcc000 起是深度／顏色／VPC 快取，餘裕約 230 KB。
- 平常的時鐘更新就是這個 pass（scissor 約 192×96），出錯時也是它，沒有特別的大範圍重畫。

**兩種錯誤形狀**
- 條紋：192×8（寬度＝scissor 寬度），隔 8 列一條，內容是同一幀時鐘區域的像素，出現在別的位置（位移是 96 的倍數）。
- 大矩形：固定 1536×2400（螢幕座標，不是 bin 的整數倍），全 (0,0,0,0)。指令流裡找不到這個尺寸。`debug/no-inline-memoryless`
  開著時幾乎每次退出/進入都出現。兩張 framebuffer 都變黑後就不再「閃」，交替偵測（reentry.py）看不到，要看讀回的 black 計數。

**這一輪新排除的**（強制 GMEM 下都照樣出錯）：host preemption（這次確認開關生效）、`flushall`＋`syncdraw`、
`noconcurrentresolves,noconcurrentunresolves`（那輪 guest 中途卡住，只算大致排除）、bin 前後加 WAIT_FOR_IDLE／SUBPASS_SLICE_FENCE
（實驗開關 `TU_DARWIN_BIN_SYNC`）、`nobin` 對大矩形也無效、2-slice A840 設定（見下）。

**走錯的一步**：一度以為 5566 是 2-slice A840（上游 07ea97900，`0x44050A21`）被當成 3-slice。用 `/data/local/tmp/kgslid` 直接問 KGSL：
5566 `0x44050a31`（3-slice，設定本來就對）、5568 `0x44050001`、5567 `0x43051401`。強套 2-slice 設定讓 host GPU hang（gpufaults 15→159），已撤。

**順手修的**：drm2kgsl 不再把 chip id 最低位元組清掉（virglrenderer 5469ef02，5566 已換 `libvirglrenderer.so`，舊檔 `.bak-7054aca7`）；
guest 現在看到 `0x44050a31`。Linux guest 的 Mesa 還沒重新確認。

**5566 上現在跑的 Turnip 比原始碼多三個未提交的補丁**（Mac `fresh27` 的 mesa-work 與 pins）：上游 2-slice A840 項目（可留）、
`turnip-darwin-virtgpu-raw-chip-id`（遮罩拿掉後已不需要，`TU_DARWIN_CHIP_ID` 覆寫會讓 GPU hang，別用）、
`turnip-darwin-bin-sync-experiment`（無效）。下次正式重編前把後兩個從 mesa-work 和 pins 拿掉。

**還可以試的方向**
- c1／c2 的 CLEAR 事件是否打到 c0 的 GMEM：讓 memoryless 的 DontCare 載入不發 CLEAR（改 metal2vulkan 或 Turnip），看大矩形是否消失。
- 把 pass 拆小：限制 bin 大小或 GMEM 用量（darwin KMD 沒有 `TU_GMEM`，要加），看是否和「三附件幾乎用滿 GMEM」有關。
- 拿高通原廠驅動在同一顆 GPU 上跑類似 pass 的指令流對照（Android 端可抓）。
- 回報上游 Mesa（a8xx GMEM、多附件、局部 scissor）。

