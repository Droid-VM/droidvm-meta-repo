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

## 11-12 畫面局部閃爍：合成器的 GMEM pass 寫壞 framebuffer（根因：guest 合成器和 Android UI 同一個 KGSL ringbuffer，見「深夜」一節；修正 virglrenderer 5faa56fa）

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

### 11-12 傍晚：再排除一批（仍未找到）

強制 GMEM（`TU_DEBUG=gmem,nocb`）下每組 16 次退出/進入，括號內是仍出錯的次數。

- **指令流在執行中被改寫：排除。** drm2kgsl 加了診斷（`/data/local/tmp/nctx-stream-check` 存在時啟用）：送出時保存每段指令與第一層
  CP_INDIRECT_BUFFER 目標的副本，之後比對。3001 次提交、約 6 萬段，沒有一次在 KGSL 尚未 retire 時被改動（retire 之後才變的 2202 次，是正常重用）。
- **guest 太早重用記憶體／host 太早回報完成：排除。** `/data/local/tmp/nctx-retire-delay-ms` 寫 8，host 把完成通知延後 8 ms
  （log 有 `RETIRE-DELAY 8 ms`），照樣出錯（14/16）。host fence 等待統計正常（1932 次全成功，平均 6.6 ms）。
- **bin 可見性讀回讀到舊值：排除。** 上游 1c87c6018 說 A8XX 的暫存器讀取封包不等閒置；我們的 pass 在 binning 後用 CP_REG_TO_MEM 讀
  VSC_CHANNEL_VISIBILITY 來決定各 bin 的 load／store。實驗開關 `TU_DARWIN_COND_LS`：1＝讀回前 WFI（13/16）、2＝load／store 不看可見性（12/16）。
- **load／store 的 blit 路徑：排除。** `3d_load`（11/16）、`unaligned_store`（9/16）。
- **LRZ：排除。** `nolrz`（4/8）。
- **framebuffer fetch 缺 slice fence：排除。** 這個 pass 會讀 tile memory（每個 bin 載入 6 個指向 GMEM 的紋理單元）；上游 MR 44348
  （10b1ef466、cc1cf17c2、99200197c，`SUBPASS_SLICE_FENCE`）我們的基底沒有。`TU_DARWIN_COND_LS=4`＝每次繪製前發 SUBPASS_SLICE_FENCE（10/16）。
- 上游 78fd465ce（gen8 未用的 shader stage 會留著別的 process 的狀態，要寫 BASE 才會 latch）說明 gen8 上跨 context 的殘留狀態是真的會發生的；
  還沒 backport 測試。

**測試注意**：連跑多組會把手機記憶體吃光（每次重進 console crosvm 多佔約 25 MB；kswapd 滿載、負載 60），guest 出現 waitq lock timeout panic
一次。每組之間要重開 VM，並看 `uptime`／MemAvailable。`rast_order`、`forcecb` 那兩組因此作廢，沒有重測。

**5566 上的 Turnip 又多一個未提交的實驗補丁** `turnip-darwin-cond-ls-experiment`（`TU_DARWIN_COND_LS` 位元 1／2／4／8），下次正式重編前一併拿掉。
virglrenderer 的兩個診斷（預設關閉）已提交（d21d37be）。

### 11-12 晚：現場鑑識、和原廠驅動對照（仍未找到）

**直接讀 framebuffer 得到的幾何**（`fbgrab.py`：crosvm 每個 22380544-byte udmabuf inode 取一個 fd 讀全幅）
- 黑色矩形精確是 (0,0)–(1536,2400)，矩形外永遠正確；矩形內原有內容全部變 0，只剩該 pass 自己畫的。是 c0 的 LOAD 讀到零，
  而那個 pass 和前後正常的 pass 指令完全相同（使用者：滑動畫面矩形會變）。
- 條紋是 dirty rect 內的 32x8 區塊被搬走。把每塊和真正來源配對：來源單元 h（16 列的「場」：一個 32 列 tile 的偶數或奇數 8 列帶）
  6、8、9、11 依序落在目標單元 4、5、6、7（凡 h%3≠1 的都被搬、緊密排列），x 每單元多 96 px。即「按 3 個 slice 寫入的資料
  被當成只有 slice 0 與 2 兩個來讀」。tile 對齊 96x32 = 3 slice × 32。

**排除**（強制 GMEM，每組 16 次重進，括號內仍出錯次數）
- 別的 KGSL context 殘留暫存器：`kgslreg`（自己的 context 用 CP_REG_TO_MEM 讀）顯示每次提交開始時 context 暫存器都是 0，
  連同一個 context 自己上一次寫的值也不留。從另一個 context 反覆寫 RB_RESOLVE_GMEM_DIMENSION 也不影響 guest。
- `noubwc`（14）、IFPC／hwcg 關（14）、pass 拆開後重載 memoryless 附件（u_trace 顯示出錯時只有普通 pass：c12 l4 s4）。
- 原廠驅動有寫而 Turnip 不寫的：`RM8_PGMEM_ON`（16）、`RM8_PGMEM_OFF`（15）、`RB_RESOLVE_CR_CNTL=1`（11）、
  binning 前 `VSC_UNKNOWN_0D08=1`（10）。第一次送 PGMEM_ON 時切回 BR 漏了 CONCURRENT_BIN_DISABLE，host 多了 30 幾次 GPU fault
  （那是我的錯，不是標記造成的；修正後每輪 0–1 次）。

**原廠驅動的指令流怎麼抓**（5566 host，root）
- `mount -t debugfs debugfs /sys/kernel/debug`（原本沒掛）；`kgslcap TID N OUT`：ptrace 目標執行緒（launcher 的 RenderThread），
  在它的 IOCTL_KGSL_GPU_COMMAND 進入點讀出 IB 清單；IB 物件沒有可查的 useraddr（debugfs 位址被雜湊），所以在該執行緒內
  注入 IOCTL_KGSL_GPUMEM_GET_INFO（位址→物件 id）與 mmap(id<<12)（唯讀）來讀內容，遞迴抓 IB、draw state、amble。
  `cap2rd.py` 轉成 .rd，上游 cffdump 可解。launcher 不受影響、0 fault。
- 原廠的多 bin GMEM pass：韌體 bin 迴圈（CP_START_BIN／CP_END_BIN＋CP_SET_UNK_BIN_DATA，Turnip 是手動逐 bin），
  GMEM pass 前 RM8_PGMEM_ON、非 GMEM pass 前與指令流結尾 RM8_PGMEM_OFF，每個狀態區塊寫 RB_RESOLVE_CR_CNTL=1，
  clear／store 前寫 RB_RESOLVE_GMEM_DIMENSION／GMEM_BUFFER_CNTL／PARTITION／CNTL_4（多 bin 時皆 0；單 bin 整張在 GMEM 時
  DIMENSION=bin 尺寸、FULL_IN_GMEM），pass 之間 SUBPASS_FENCE＋WFI。GMEM 快取區排列順序和 Turnip 不同但大小一致。
- 兩邊寫的暫存器全表比對：原廠寫、Turnip 從不寫的 96 個；和 tile memory 有關且非零的只有 CR_CNTL 與 VSC_0D08。

**上游與社群**：上游 main 的 tile store 流程和我們相同，也不寫上述 gen8 暫存器（freedreno 註解 "gen8 TODO"）；
社群的 Android Turnip 版本說 A830 的 GMEM 會花、建議 sysmem。所以這很可能是上游在多 slice gen8＋KGSL 上的未解問題，
我們的止血（合成器 sysmem）和社群做法一致。

### 11-12 深夜：根因找到（drm2kgsl 的優先級對應，virglrenderer 5faa56fa）

**原因**：這個 VM 在 vms.json 設了 `DRM2KGSL_PRIORITIES=3`（只有 5566 有），drm2kgsl 把 guest 較高優先級的佇列（合成器）
對到 KGSL 優先級 4／5，也就是第二個 ringbuffer（KGSL 16 個優先級、每 4 個一個 ringbuffer）。Android 自己的 UI——launcher、
SystemUI，用原廠驅動——在同一個 ringbuffer 的優先級 4。同一個 ringbuffer 內、優先級不同的 context 之間，原廠 context 的工作會
插進 guest 一個 pass 的 bin 之間，tile memory 沒有被保存（不同 ringbuffer 之間是正規搶佔，有存檔／還原）。原廠驅動會把圖層
整張留在 tile memory（launcher 捲動頁面時 1536 寬；1536x2400 正是 1536 寬、每像素 4 bytes 能放進它快取區下方 0xE58000 的
最大 tile 對齊高度），所以 guest 的 framebuffer 出現固定的 (0,0)–(1536,2400) 零矩形，以及以 1536 列距讀出的位移區塊。
KGSL 的 preemption 開關不影響（不是那個搶佔）。

**怎麼找到的**
- 觸發條件其實是 host launcher 的動畫，不是重進 console：console 留在背景、launcher 左右滑 24 次，guest framebuffer 就壞。
  通知欄開關（SystemUI）觸發不了；自己寫的探針 context（`kgslpoke`，送原廠式的標記與暫存器）也觸發不了。
- `/sys/kernel/debug/kgsl/kgsl-3d0/ctx/*` 列出每個 context 的優先級：launcher／SystemUI VK 4、SurfaceFlinger GL 1、
  一般 app 8；crosvm 裡 guest 合成器是 5。
- 對照實驗（都在強制 GMEM 下）：拿掉 `DRM2KGSL_PRIORITIES`（guest 全部在 8）→ 重進 24/24 乾淨、launcher 滑 64 次零壞點；
  設回 3 並換上新對應（合成器 8、guest app 12）→ 16/16 乾淨、滑 40 次零壞點；Android 設定頁（VK 8，和合成器同優先級同
  ringbuffer）捲 30 次也零壞點。所以條件是「同 ringbuffer 且優先級不同」。

**修正**：`kgsl_priority_flags`——guest 只有一個優先級時全部用預設（不變，Linux guest 的情況）；有多個時較高的留在預設 8、
最低的（Turnip 的 medium／low，一般 guest app）用 12（第四個 ringbuffer，被預設的搶佔）。guest 佇列不再進第二個 ringbuffer。
效能（perfab.py，新對應）：sysmem 81.7 fps、autotune 78.7、gmem 80.5，GPU p50 7.4–8.6 ms，和舊對應同量級。

**還留著的**
- crosvm 行程裡 host 端的顯示 blit（app 的 Turnip，KGSL 優先級 5）仍在第二個 ringbuffer。它不寫 guest 記憶體，壞了只會是
  當下那一幀；要不要移出來還沒決定。
- 合成器的 sysmem 止血（NativeMetal e84d02f）還在；5566 上的 Turnip 帶著今天的實驗補丁（都是預設關閉的開關，外加上游
  78fd465c 與「GMEM 快取區配置對齊原廠」——後者預設開啟、未證實有益）。要做一次乾淨的重編再決定止血去留。
- 5567／5568 沒設 `DRM2KGSL_PRIORITIES`，不受影響；它們的 virglrenderer 還沒更新。
- 今天為了追這個做過、最後證明無關的：見上面三節。對上游有價值的副產品：原廠驅動 gen8 指令流的抓法、Mesa 的 gen8 GMEM
  快取區比原廠少保留頂端 0x78000（原廠 BV 位置緩衝固定在 0x1158000）。

### 11-13 凌晨：止血撤掉、同優先級也不行、backboardd 啟動時的 GPU hang

**止血撤掉了**（NativeMetal 312cde5，plugin a79f40fb 之後）：合成器回到 autotuner。預設設定 20 次重進＋40 次 launcher 滑動
零壞點，u_trace 看到 10962 個 GMEM draw pass 對 1890 個 sysmem；強制 GMEM 8 次重進也乾淨。Turnip 的實驗補丁全數移除，留下
上游 07ea9790（A840 2-slice）和 78fd465c（fork ac97948）。

**訂正「同 ringbuffer 且優先級不同」**：把合成器放在 KGSL 4（和 launcher／SystemUI 相同優先級、同一個 ringbuffer）再跑強制
GMEM 的重進，16 次裡大多數又壞。所以規則是「guest 的 GMEM context 不能進 Android UI 用的那個 ringbuffer」，和優先級是否相同
無關；先前 Settings（優先級 8）捲動乾淨只說明第三個 ringbuffer 沒事。機制仍不明。

**GPU hang**：驗證時重啟 backboardd 發現 host 記到 `gmu: GPU hang detected … ctx N ts M policy 2`（gpufaults 第二欄 +1）。
KGSL 跳過那筆、guest 停 1–2 秒後繼續，backboardd 不會死。重現：每 27 秒殺一次 guest 的 backboardd、數 gpufaults。

| 設定（每列一輪 VM 開機） | hang／重啟次數 |
|---|---|
| 8／12 對應、正式程式庫 | 3/32、1/40 |
| 同上、`DRM2KGSL_PWR_CONSTRAINT=0` | 1/40 |
| 同上、Turnip 在 cmdbuf 開頭重置各階段 CNTL_0（候選修正） | 6/80 |
| 全部 guest context 在 8（不用第四個 ringbuffer） | 第 2 次就 hang（之後中止） |
| 舊對應 5／8 | 0/20（樣本太少） |
| 診斷版 1（提交前複製指令流） | 3/17 |
| 診斷版 2（診斷版 1＋閒置 50 ms 後的提交前讀一次 gpufaults） | 0/83，另加針對性順序 0/80、冷快取 0/25 |
| 只在 cmdbuf 開頭不派工作給 BV | 1/21（中止） |
| 同上＋事件與等待封包只給 BR 執行 | 6/52（中止） |
| 完全不設 CBD | 開機 1 分鐘內 100 多次（BR 的 binning 沒有 visibility stream） |
| `nocb` 下完全不碰 BV（turnip-nocb-leave-bv-alone.patch） | 0/80，之後 1/20、開機 1/8 |
| 同上＋上限 8、任意位置切（實驗） | 55 次／6 次重啟 |
| 同上＋上限 8、只在 command buffer 開頭切（實驗） | 0/12 |
| **只在 command buffer 開頭切（fb9fb47），不含上一列的補丁** | **0/80** |

已排除（各自仍會 hang）：GMEM／sysmem、撤掉止血、只在 backboardd 開 `IR3_SHADER_DEBUG=noearlypreamble`、m2v pipeline 快取
冷熱（prime.log：熱 0.4–1 秒、冷 38–40 秒）、drm2kgsl 的每幀功耗限制、優先級 12／第四個 ringbuffer、優先級對應本身。
所以這不是這次修正引入的；很可能就是 PROGRESS「已知問題 1」那個偶發的 render server host KGSL hang。

**現場**（三份 KGSL snapshot 一致）
- BV 的微碼停在 `CACHE_CLEAN`（事件 0x31）處理常式的迴圈：輪詢控制暫存器 0x136 的 bit 20（cache clean 進行中），讀到
  0x00104e00，永遠不清。BR 停在 `THREAD_CONTROL(BOTH)` 或 `WAIT_FOR_ME`，等 BV。
- `RBBM_GFX_BV_STATUS` 0x00fc1006：BV pipe 的 HLSQ_BUSY 一直亮；`RBBM_MISC_STATUS` 0（沒有 SMMU stall，也沒有 page fault）。
- 兩個執行緒最後一個 IB2 每次都是某個 compute shader 的狀態區塊（帶 EARLYPREAMBLE，preamble 裡有 resinfo／ldc）。
- 事件記錄：hang 前常見的是另一個 guest context（優先級 12）剛跑過、接著合成器的第 1–3 筆正常、下一筆卡住；有時中間隔一次
  slumber，有時沒有。喚醒後第一筆要 33–45 ms 是正常的（GPU 在最低頻），不是異常。
- 上游已知同一類：`tu6_init_static_regs` 為了「別的行程留下的 FS early preamble 會被執行，hang 和 fault」重置
  SP_PS_CNTL_0；78fd465c 說沒鎖存的階段會去舊的 SP_xS_BASE 抓。我們所有 guest 行程共用 crosvm 一個 KGSL 位址空間（VBO，
  沒綁的範圍是零頁），舊位址不會 fault。但把重置擴到 VS/HS/DS/GS/CS 沒有用（6/80）。

**成因與修正**（11-13 早上定案。這一段先前寫過兩版，推論都只對一半，以下是改寫後的）

根因在 guest 端 Turnip 的 Darwin 驅動層（`tu_knl_darwin.cc` 的 `darwin_queue_submit`）：
- 一筆核心提交最多帶 128 個指令流 buffer（`NativeAdrenoAbiMaxBuffers`），更長的清單**每 128 個切一刀，不管切在哪**。一個
  command buffer 的指令流超過一個 BO 就是好幾個 buffer，所以會切在同一個 command buffer 的兩個區塊中間。
- 兩筆核心提交之間，ringbuffer 裡是核心自己的指令：重新指定執行緒（`THREAD_CONTROL BOTH`、不帶 CONCURRENT_BIN_DISABLE，
  也就是 concurrent binning 啟用），別的 context 也可能插進來跑。後半段開頭沒有自己的 thread control，BV 就跟 BR 一起執行
  它。BV 什麼都沒設定，遇到第一個 cache 事件或 `CP_BLIT` 就永遠停住（BV 的 HLSQ busy）；BR 停在那一段的下一個 thread
  control，在握手裡等 BV。
- 合成器啟動的頭幾幀一次提交幾百個 buffer，所以只在 backboardd 啟動時發生。
- 證據：13 份 snapshot 無一例外，卡住那筆的**前一筆剛好 128 個 IB**、最後一個是寫滿的區塊（0xffc–0x1000 字）；BV 的讀取
  指標在下一筆第一個 buffer 裡的事件或 `CP_BLIT` 上，BR 在它後面的 thread control 上（`snapsubs.py DUMP…`）。
- 對照實驗（同一個執行檔，用旗標檔把上限降到 8 並切換規則）：任意位置切，6 次重啟 **55 次** hang；只在 command buffer
  開頭切，12 次重啟 **0 次**。

修正（fork fb9fb47，`patches/mesa/turnip-darwin-submit-split-at-command-buffers.patch`）：一筆核心提交只在「下一個 buffer 的第一個
封包是 `CP_THREAD_CONTROL`」的地方結束——a7xx 起每個 command buffer 都這樣開頭（`tu_init_hw`），trace／autotune 的小指令流
跟著前一個 command buffer。連續 128 個 buffer 裡找不到這種開頭時照舊切，並警告一次。
結果（5566，每 27 秒殺一次 guest 的 backboardd，plugin 6c5f36ff）：**80 次重啟 0 hang**，4.2 萬筆提交，期間 host 記了約 7.3 萬次
ringbuffer 搶佔；修正前是 3/32、1/40、6/80、3/55、6/52。

還沒做／要留意：
- 單一 command buffer 自己就超過 128 個 buffer（指令流 2 MiB 以上）時仍會切在中間；要根治得把 ABI 的上限加大（guest 核心的
  NativeAdreno 也要跟著改）。目前只有警告。
- Linux guest 不受影響：它的 virtio 驅動層一次送出整份清單（`nr_cmds` 沒有上限）。host 端 app 的 Turnip（KGSL 後端）也是。
- 5567／5568 的 plugin 還是舊的（同一段切分程式碼），還沒換。
- 修正前這個 hang 在正常使用下很少見：host 的 dmesg 紀錄裡，11-06 到 11-11 六天共 4 次（之後兩天的 465 次都是測試打出來的）。
- PROGRESS「16 MiB block 會讓 render server hang」可能同因（block 小、buffer 多），修正後還沒重測。

走過的彎路（各自仍會 hang，或只是變少）：
- 「`nocb` 下完全不碰 BV」（fork b9d9df6，`turnip-nocb-leave-bv-alone.patch`）：每個 thread control 都帶 CBD、binned pass 不切 BV、
  cmdbuf 開頭不給 BV 東西。80 次重啟 0 hang，之後 20 次重啟 1 次、一次開機 1 次——它只是讓被切開的後半段更早遇到一個
  thread control（BV 停在那裡等 BR，握手之後回到略過模式），不是成因。它的 commit 訊息把成因寫成「每個 pass 的握手」是錯的。
  已移除（fork 5143df6）：它讓 Turnip 產生指令流的五個檔案偏離上游，卻不是必要的。留下的一個數字：沒有它時 host 記到的
  小搶佔（握手引起的 L1A）約 1.8 倍（80 次重啟 2729 對 1501），之後看合成器 pass 的效率時也許用得上。
- 只在 cmdbuf 開頭不派工作給 BV（1/21）、backboardd 不帶 `nocb`（1/58）、guest context 改 `PREEMPT_STYLE_RINGBUFFER`（1/24）、
  只加「閒置後提交前讀 gpufaults」（2/24）、事件與等待封包只給 BR（6/52）。
- 「完全不設 CBD、只切到 BR」：BR 在 CB 啟用的模式下做 binning 不會寫出 visibility stream 的大小，
  `CP_SET_BIN_DATA5_OFFSET` 讀到 0 就進微碼裡一個故意的無窮迴圈（BR 0x8ca），每個 binned pass 都 hang。BR 自己做 binning
  一定要 CBD。
- drm2kgsl 的 stream check 開著時 188 次重啟都不 hang：原因沒有驗證，推測是提交變慢後一次累積的 buffer 不到 128 個。

過程中弄清楚的微碼行為（之後查 BR／BV 問題用得上）：
- BV 在「略過模式」只執行 7 種封包（IB 進出、`THREAD_CONTROL`、`ME_INIT`、`SET_SECURE_MODE` 等；表在 BV 0x183、BR 0x347），
  BR 區段的事件與等待一概跳過。略過模式不跟進比「開始略過的那一層」更深的 IB。
- CBD 是狀態：控制暫存器 0x278 的 bit 31（CB 啟用），硬體暫存器 0xdf1 跟著它。`THREAD_CONTROL` 的 CBD 和目前狀態不同時
  BR 和 BV 握手（BR 寫 0x25e、BV 回 0x25f，先 0x117 再 0x8217），兩邊各自先排空自己的管線，BV 最後翻轉 bit 31。BV 在
  ringbuffer 層等 BR 時會觸發一次 skipsaverestore 搶佔（PREEMPT_TRIGGER，原因碼寫在 0x44c），在 IB 裡等則不會。
- 核心在每筆提交結尾：`THREAD_CONTROL BV; EVENT_WRITE7 CACHE_CLEAN+ts`（BV 的 fence），再 `THREAD_CONTROL BR;
  WAIT_TIMESTAMP`。fence 的值是每個 context 自己的計數，寫在每個 ringbuffer 共用的一格記憶體；新 context 從 1 數起，
  所以它的前幾百筆提交 BR 根本不等 BV（那格還留著舊 context 的大數字）。
- snapshot 裡看得到微碼的控制暫存器，位址＝0x780＋編號：0x9de／0x9df 握手、0x9f8＝0x278、0x9fc／0x9fd 是搶佔流程裡
  BR／BV 對步驟用的；0x900–0x903 是各 pipe 預取中的 IB1 位址／剩餘／大小，0x920–0x925 是預取佇列的讀寫指標（單位 4 字）。
  kgsl 在 dmesg 印的 `BR: … ib1 X/N` 也是預取位置，不是執行位置。

**工具**（已搬進 rig：`droidvm-5566-27/hang/`，裡面有 README）
- `snaplog.py DUMP [N]`：snapshot 的事件記錄（0x1a01：每筆 submit／retire 的 ctx、優先級、執行時間）、各 ringbuffer 指標、
  BR／BV 的 SQE_STAT（[0] 是微碼 PC）。`snapregs.py`：暫存器段（0x1503：`[0x80000000|first][last][值…]`）。
  ROQ（預取佇列）在 indexed regs 0x8f4（pipe 1＝BR、2＝BV）。snapshot 只留第一份沒讀走的：
  `cat /sys/class/kgsl/kgsl-3d0/snapshot/dump` 讀完才會收下一次。
- 微碼：`/vendor/firmware/gen80200_sqe.fw`（A840）＋上游 Mesa 的 `qrisc-disasm -v`，封包處理常式有標籤。
- drm2kgsl 診斷（flag `/data/local/tmp/nctx-stream-check`）：gpufaults 變動時把各 context 留存的提交寫到
  `/data/local/tmp/nctx-hang-*.bin`，`hangdecode.py` 轉 .rd 給 cffdump。問題是開了它就不 hang。
- `hangwatch.sh`：每 2 秒看 gpufaults，一變就把 snapshot 和 dmesg 拉到 `hangs/<時間>-fault-N/`，印出 BR／BV 的 PC。
  `snapsubs.py DUMP…`：讀取指標附近每筆提交的 IB 數與大小（找到 128 那個規律的工具）。
  `snaproq.py DUMP PIPE LO HI`：預取佇列解成封包（0x000 起是 ringbuffer 層、0x100 起是 IB1）。`snapcp.py DUMP LO HI`：
  各 pipe 的 CP 暫存器並排（0x900 起是 IB1 位址／剩餘／大小，0x9xx 是微碼的控制暫存器 0x2xx）。
  微碼的略過表與握手：BV `CP_THREAD_CONTROL` 在 0x110、握手 fxn448（0x1c0）；BR 在 0x2d0、fxn904（0x388）。
- `cfgtest.sh LIB VMJSON N`（換程式庫／VM 設定後跑 N 次重啟）、`bbfast.sh`。`dvmipc vm_modify` 可在不重啟 daemon 下換 VM 的
  環境變數。dmesg 的「Skipped access check」是 `kgsl_setup_dma_buf` 對每個 udmabuf import 印的，無害。

**還可以試的方向**
- c1／c2 的 CLEAR 事件是否打到 c0 的 GMEM：讓 memoryless 的 DontCare 載入不發 CLEAR（改 metal2vulkan 或 Turnip），看大矩形是否消失。
- 把 pass 拆小：限制 bin 大小或 GMEM 用量（darwin KMD 沒有 `TU_GMEM`，要加），看是否和「三附件幾乎用滿 GMEM」有關。
- 拿高通原廠驅動在同一顆 GPU 上跑類似 pass 的指令流對照（Android 端可抓）。
- 回報上游 Mesa（a8xx GMEM、多附件、局部 scissor）。

