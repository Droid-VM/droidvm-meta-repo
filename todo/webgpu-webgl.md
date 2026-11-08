# WebGPU 與 WebGL

Safari WebGPU／WebGL 的未解項目完整細節，從 `PROGRESS.md`「未解／待查」移來（原文照錄，只分段）。

## 11-08 renderBundles bundle 模式太慢

renderBundles（bundle 模式）2.2 fps，同一支手機的 Chrome 59 fps：每幀約 450 ms 是三段串行，WebKit 編碼約 70 ms、metal2vulkan 排程執行緒的 host step 約 280 ms、GPU 約 70 ms（1.2 GHz 時；GPU 閒置多，DCVS 會把它調到 319–555 MHz）。WebKit 的 ICB 是 `inheritPipelineState = NO`、`inheritBuffers = NO`，又有 indexed draw，每幀還先跑一個寫 ICB 的 clamp compute，所以不符合 runtime「完全在 GPU 上執行」的條件（要繼承 encoder 的 pipeline、只有非 indexed draw，見 render/executions/gpu.rs），只能等 GPU 做完再由 host step 在 CPU 上把 5000 個 draw 逐一走完整的 draw 路徑：每個約 56 µs（Aztec 的直接 draw 約 5 µs），分散在 uses（apart_uses_into、settle_resident）、tracker 的 HashMap／BTreeMap（每幀從空的長到 15000 個資源）、綁定、pipeline 實例化等十幾處。要大幅改善得讓 GPU 路徑支援逐命令的 pipeline 與 indexed draw，或在 ICB 內容與狀態不變時重用上一幀錄好的命令。

11-08 續查：(1) WebKit 的 clamp 只在 index 驗證還沒快取時才跑（`canSkipDrawIndexedValidation`），穩定後每幀並沒有寫 ICB；每幀都進 host step 是因為 `IndirectCommandBuffer::gpu_written` 一旦被任一次「可寫 residency」標記就永遠為真。

(2) 本機 lavapipe 的 icb_scale（5000 draw、2 萬 resident）：host step 每個 draw 約 18 µs，和 encoder 直接畫同樣的 draw（15.6 µs）差不多，所以成本在共用的 draw 路徑本身，不是 host step 特有；profile 很平（draw_resident 56%，底下十幾項各 2–7%，另有每筆約 4 KB 的 CommandRecord 被複製三次約 8%）。

(3) UniXNU 上游 11-07 已把 metal2vulkan 釘到 963f0e64（含 draw-again 與 kept chunks）；同一基準下 direct 89.6 ms（我們 82.4）、`each` 跑不完（我們 0033／0034 修掉的 O(N²)）、icb 每幀 commit 約 115 ms 且 `chunks kept 0`：上游的 kept 路徑把透過 heap 讀貼圖的 draw（WebKit 的 bind group 正是）排除在 plain 之外，對 WebKit 的模式沒有效果，所以不升級也不移植。要改善只能自己做：把 `gpu_written` 改成「還有未完成的寫入路徑」，再在 commit 時重用上一次錄好的命令（icb_scale 已有 `WRITE_FRAMES=k` 模擬 WebKit 穩定狀態）

11-08 之後：0038（fork 62d0b11）讓 `gpu_written` 只在還有未完成的寫入時成立，寫完後由 commit 直接錄製，不再擋排程執行緒，2.3 → 2.6 fps；每幀仍重錄 5000 個命令。下一步（重用上一幀的錄製）與每個 draw 的 CPU 成本見 [metal2vulkan.md](metal2vulkan.md#2-icb-每幀重錄renderbundles-26-fpschrome-59-fps)。

## 11-07 renderBundles 非 bundle 模式第一幀

renderBundles 非 bundle 模式的第一幀：WebKit 每個 indexed draw 前跑一次 vertex-only 的 index clamp、再下 buffers 範圍的 barrier，metal2vulkan 每次都得切 render pass instance；pass 有 depth attachment，不能走 inline 錄製（render/inline_first.rs 的條件），所以每次切分是一個 secondary command buffer，一幀 5000 次、峰值 467 MB。要再降：讓有 depth 的 pass 也能 inline 錄製後續 instance，或讓這種 vertex 寫入 → indirect 讀取的 barrier 不必切 instance。

bundle 模式剩下的成本是 host step 每幀重錄 5000 個 ICB 命令（上游「GPU 寫入的 ICB 命令沒變時沿用上次的錄製」一系列還沒移植）

## 11-07 GPU 行程拿不到 WebGPU adapter

Safari 的 GPU 行程偶爾拿不到 WebGPU adapter（requestAdapter 回 null，行程裡沒有建任何 Metal device），結束 Safari／WebKit 行程重開就好；hide-vmm 對 com.apple.WebKit.GPU 是生效的（同一個 binary 換名字讀 hv_vmm_present 會從 1 變 0）。

11-08：不是開機才有（剛跑完長時間 WebGPU 後連開 8 次失敗 2 次，之後 40 次加一次冷開機都正常）。失敗的 GPU 行程在 Safari 啟動 0.2 秒內就起來，但從來沒映射 Metal plugin、沒開 virtio-gpu client，之後也沒有任何 GPU 工作：是 WebContent 端先放棄了 GPU 代理（RemoteGPUProxy 的 m_lost：等 WasCreated 15 秒逾時或回 false），不是 plugin 開裝置失敗。guest 裡讀不到 WebContent 的日誌，原因未明

## 11-08 Safari 連開 WebGPU 頁凍結

Safari 連續開很多 WebGPU 頁之後偶爾整頁凍結（5566，兩次：一次在約 25 頁後，generateMipmap 先丟出 JS `RangeError: Range consisting of offset and length are out of bounds`（`getMappedRange()` 回了空的 ArrayBuffer），接著 cornell 凍結；一次是掃完 28 個範例後停在 cornell 約 60 秒時凍結，畫布變黑）。

兩次 WebContent 主執行緒都在 JS 的 Full GC 回收**舊頁面**的 WebGPU 物件（`JSGPUTextureView::destroy`、`JSGPUBindGroupLayout::destroy` → `Remote*Proxy` 解構送 destroy 訊息），卡在 `IPC::StreamClientConnectionBuffer::tryAcquire`（串流 ring buffer 滿了）；GPU 行程沒崩潰、所有執行緒閒置，對應的「WebGPU work queue」幾分鐘沒被喚醒，log 在凍結後完全沒有輸出、也沒有 `buffer refused`。

每換一頁 GPU 行程就多一條 work queue（舊頁的 RemoteGPU 等 GC 才放），guest 記憶體壓縮器很忙（140 萬次壓縮）。

同一個新的 Safari 只開 cornell 跑 5 分鐘不會凍結；全新行程裡 generateMipmap 正常。

iPadOS 27.0.1 的 WebKit 早於上游 2026-08 對串流 IPC 初始化與 `IPC::Signal` 的修正（bugs.webkit.org 321584：client 等待／server 喚醒 semaphore 的「容易出錯的初始化等待」、`signal()` 卡住），log 裡也有 `IPC::Signal::signal Could not send mach message, error 10000003`，傾向是原廠 WebKit 的問題被較慢的 VM 放大；要排除我們這邊（共享記憶體頁在壓縮後兩邊不一致）得在凍結時比對兩個行程看到的 ring buffer 標頭（debugserver 取 `tryAcquire` 的 this，`export.py mem` 讀標頭）

11-08 結論（判定為原廠 WebKit，不修；userland 保持原廠）：log 裡喚醒 server 的 `IPC::Signal::signal` 送訊失敗是 0x10000003（`MACH_SEND_INVALID_DEST`，喚醒用的 port 已失效），正是上游 321584 修的那段 semaphore 初始化與 `signal()`。串流 buffer 是 WebKit 的 `SharedMemory`（一般匿名 VM，兩個行程對到同一份 cacheable 實體頁），不經我們的 GPU blob 或 IOSurface 映射，同一個 guest 內不會有快取不一致。沒做到的：沒在凍結當下比對兩個行程看到的 ring 標頭（要先重現，約 25 頁以上）。若 iPadOS 更新帶來新版 WebKit 後還會凍結，再回來查。

## 11-08 WebGPU 沒有 timestamp-query

WebGPU 沒有 `timestamp-query`：plugin 對 `supportsCounterSampling:` 回 NO（metal2vulkan runtime 本身沒有 counter sample buffer，`RuntimeGap::CounterSampleBuffers`，上游也是），WebKit 因此不開這個 feature（timestampQuery 範例顯示「Timestamp queries are not supported」，畫面照常）；真 iPad 有。

要做：timestamp counter set、stage boundary 取樣（render pass 的 start／end of vertex／fragment、compute pass 的 start／end of encoder → vkCmdWriteTimestamp2）、blit 的 `resolveCounters`（vkCmdCopyQueryPoolResults）、`sampleTimestamps:gpuTimestamp:` 的校準，WebKit 還會在 resolve 前後下 shared event 的 signal／wait
