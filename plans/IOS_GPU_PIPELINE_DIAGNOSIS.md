<!-- Codex (gpt-6-astra) read-only diagnosis, 2026-10-27, from the measurements in PROGRESS.md 2026-10-27 08:30; kept as written. -->
這條 iPadOS 路徑確實有同步等待，但不是「每次 GEM_SUBMIT 都等 GPU 完成」：一般提交已非同步；明確的串行點在 **Darwin 將 submit 的 semaphore dependencies 轉成 CPU fence wait**，以及 **display 一張一張執行全域 producer wait → present/flush → completion**。另外，metal2vulkan 的多 command-buffer 組織會觸發 Turnip 每個 command buffer 結尾的 CCU clean；這是 Today/blur 應優先量測的 GPU 內部成本。

目前不能從程式碼斷言「約 16 ms 就是某個 CP_WAIT」；也不能把 500–700 次 WAIT_FENCE timeout 當成同樣次數的 guest↔host round trip。下文將已確認的機制與尚待量測的影響分開。

本次於 2026-10-27 只讀本機原始碼、PROGRESS.md，以及經 `ssh hujk@192.168.68.67` 讀取 build Mac 原始碼；唯一寫入為本報告。未操作 phone、VM、rig、build 或 git。本文的數值來自題目，並非我重新量測。引用是讀取當時的 source tree，未驗證所有檔案都等於當前 deployed binaries；尤其 Linux comparison tree 已有本專案的效能修改，不能全部當成 upstream Mesa 的原始行為。

以下路徑縮寫用於 `file:line` 引用；每項都可由此還原完整路徑。

| 縮寫 | 原始碼位置 |
|---|---|
| M | Mac `/Volumes/DATA/UniXNU/orgrepos/UniXNU/out/droidvm/tree/.cache/mesa-work/src` |
| R | Mac `/Volumes/DATA/UniXNU/orgrepos/UniXNU/out/droidvm/tree/.cache/gpu-reference/metal2vulkan/crates/metal2vulkan-runtime/src` |
| T | Mac 同一 metal2vulkan tree 的 `crates/metal2vulkan/src` |
| N | 本機 `/root/gitrs/UniXNU/orgrepos/UniXNU/drivers/NativeMetal` |
| D | 本機 `/root/gitrs/UniXNU/orgrepos/UniXNU/drivers/NativeMobileDisplay` |
| K | 本機 `/root/gitrs/UniXNU/UniXNU-droidvm/package` |
| V | 本機 `/root/gitrs/DroidVM/DroidVM_wip_gpu/crosvm_build/external/virglrenderer/src` |
| C | 本機 `/root/gitrs/DroidVM/DroidVM_wip_gpu/crosvm_build/external/crosvm` |
| A | 本機 `/root/gitrs/DroidVM/DroidVM_wip_gpu/crosvm_build/packages/modules/Virtualization/libs/android_display_backend/crosvm_android_display_client.cpp` |
| L | 本機 `/root/gitrs/DroidVM/DroidVM_wip_gpu/crosvm_build/external/mesa3d/src`；Mac 的裁切 tree 未提供 vdrm 實作，故此部分改讀本機 Linux tree，版本可能不同 |

依目前證據，建議依下列順序查證。排序兼顧已量到的時間與修正能否改善穩態 fps；條件性項目一旦證實，可往前移。

| 優先 | 等待／成本 | 已確認程度與可能影響 |
|---|---|---|
| 1 | display 全域 producer wait 與 flush 串行，單張 latch | 機制與量測吻合；已有每張約 10–22 ms + 12–22 ms 的成本，是明確 throughput 限制 |
| 2 | Darwin submit 在 CPU 等輸入 semaphore，持有 device submit mutex | 程式碼確定；真實 frame 的 wait_count、等待時間未知。若常觸發，會直接餓住 GPU，甚至阻塞 commit caller |
| 3 | 完成通知鏈、1 ms polling、host/vCPU scheduling | 機制確定；MetalCheck 的短 GPU 工作／長 completion latency 支持它值得優先分段量測，但不能把全部差額歸給 polling |
| 4 | encoder/barrier 各自成 command buffer → CCU clean、WFI、split pass LOAD/STORE | 機制確定；Today 場景影響尚待 pass／packet timing。最能解釋真正落在 batch 內的 stalls，未證實是 16 ms 主因 |
| 5 | NativeMetal 每次 commit、completion 都 flush 整個 IOSurface allocation | 機制確定；受 CPU 限頻影響，可能增加數 ms 與記憶體流量；已有 counters 可快速排除 |
| 6 | BO create/control requests 同步；回收混入 fence poll；16-IB submit 分塊 | 機制確定；8 blobs/s 讓它較像 spikes 而非每張主因，但大量回收可能放大完成延遲 |
| 7 | host KGSL priority 未傳遞、worker 共用處理路徑 | flags/結構確定；trace 的 prio 8、rb 2 與它相容，但 vendor kernel 的選擇與 16 ms 成因未核實 |

**1. Display 是實際的串行 critical path；retire-on-offer 沒有解除單張 latch。**

`K/DroidVMVirtioGpuDisplay.cpp:210–216` 接受 offer 時取 `droidvm_virtgpu_submitted()`，記下的是所有 client 的最新 fenced submission order。`K/DroidVMVirtioGpu3D.cpp:598–617` 檢查所有 client 的 pending submissions，只要有 order ≤ 此值尚未回報完成，display 就不能進行；甚至某個 client 的 lock 拿不到，也直接判為尚未完成。這不是「此 IOSurface 的最後一個 writer fence」。因此不相關的 wallpaper、其他 app/context，或一個正在做同步 BO method 的 client 都可能拖住 display。

worker 在 `K/DroidVMVirtioGpuDisplay.cpp:151–188` 依序做：每 1 ms 檢查 producer → `surface(frame)` → `present()` → `native_legacy_gpu_complete()`；每輪尾端還有 `IOSleep(1)`（194）。沒有讓下一張 frame 的 producer check 與這張 flush 並行的 worker state machine。

`D/NativeLegacyDisplay.cpp:263` 的 `transferred` 會阻止下一次 offer；319–330 接收 frame 後即設為 true。retire-on-offer 只做 `retireSwap()`，沒有清掉它。直到 `finishGpuSwap()` 的 393–399 才清除並 kick 下一張。因此可讓 CA 預先準備下一張，但下一張交給 display 的時刻仍由上一張 flush completion 決定；這與已有約 +10% 的改善相容。

量測名稱還有兩個需修正的細節：

- `flush_us` 在 `K/DroidVMVirtioGpuDisplay.cpp:167–171` 包住整個 `present()`，不是只有 RESOURCE_FLUSH。`present()` 的 110–123 在 resource 改變時先同步 SET_SCANOUT_BLOB/SET_SCANOUT，再同步 RESOURCE_FLUSH；double/triple buffering 常會改 resource。
- `surface(frame)` 在 166，位於 producer wait 計時之後、flush 計時之前。cache miss 時的 display resource create/release 時間沒有落入這兩欄；不可將兩欄相加就當完整 frame cycle。

host 的正常 GPU display 路徑已有非同步機制：`A:2502–2527` 可把 BufferQueue acquire fence 匯入 GPU semaphore，`A:2533–2553` 將同一 blit completion fence 一份交 queueBuffer、一份留給 source。`C/devices/src/virtio/gpu/mod.rs:1018–1078` 將 flush descriptor 留待該 fence；1515–1532 用 fd event 喚醒，不是固定 16 ms timer。`A:2759–2775` 也已嘗試設定零 dequeue timeout，滿了便 drop frame（2478–2490）。所以不能未量就把 flush 的 12–22 ms 全歸為 vsync/dequeue。

仍有條件性的同步 fallback：async blit 未啟用會 `vkQueueWaitIdle`（`A:540–548`），acquire import 不支援會 CPU poll（2508），in-flight slot 被占用會 wait fence（694–695）。此外，即使 CPU 不等 acquire，blit 的 GPU wait 仍可能等 Android target release，source-completion 自然也會跟著延後。

確認／反駁實驗：請 Claude 對每張記錄 offer、worker take、producer-ready、surface-ready、SET_SCANOUT begin/end、RESOURCE_FLUSH begin/end、NativeLegacy complete；producer scan 多記最後阻擋的 client/context、order/fence，以及 try-lock failure 次數。host 同時收 `crosvm_display.dequeue_buffer`、`queue_submit`、`queue_buffer`、`target_fence_wait`、`queue_wait_idle`、`in_flight_wait`（這些 ScopedTrace 已在 A），加 blit completion fd signal 與 flush add_used 時間。若主要等不相關 context，成立的是全域依賴問題；若 GPU 已完成但 ack 晚，轉查優先 3；若 target acquire 晚，才是 Android buffer reuse 的依賴。

建議變更：將 producer fence 精確綁到 scanout surface；允許至少兩個 display jobs，讓 N+1 的 producer readiness 與 N 的 host blit 重疊，維持 buffer ownership。**不能只刪 producer wait，也不能在 N 的 source 尚被讀取時，讓 N+1 的 swap retirement 釋放 N**。要把「可開始等下一張」與「可完成下一次 swap／重用上一張」分開。同步 SET_SCANOUT 若量到顯著成本，可改為按 virtqueue 順序連續 post SET_SCANOUT、FLUSH，分別追蹤 reply，而非每步 round trip。

**2. 最接近使用者描述的同步設計，確實在 Darwin queue submit 的 semaphore 處理。**

`M/freedreno/vulkan/tu_knl_darwin.cc:909–915` 明寫「one ring and no GPU-side waits」，逐個 `darwin_sync_wait(..., UINT64_MAX)` 後才提交。對 pending fence，746–785 最後走 CPU `dw_wait_fence_locked_free()`；不會把 dependency 交到 execbuffer。此呼叫還在 `M/freedreno/vulkan/tu_queue.cc:436,556–591` 的 `device->submit_mutex` 範圍內，會阻擋同 device 其他實際提交。

Darwin 的 timeline 不是 native kernel timeline：`tu_knl_darwin.cc:1134–1137` 用 `vk_sync_timeline_get_type()` 包 binary sync；`M/vulkan/runtime/vk_device.c:68–69,232–234` 因此選 EMULATED／DEFERRED。**DEFERRED 不代表有背景 submit thread**：`M/vulkan/runtime/vk_queue.c:1136–1138` 直接呼叫 `vk_device_flush()`，672–707 對可提交的項目呼叫 driver；587–623 將 timeline point 解成 underlying sync，未完成的 dependency 最後仍進上述 CPU wait。僅設 `MESA_VK_ENABLE_SUBMIT_THREAD` 不能假定解決；此環境變數的分支在 ASSISTED mode（`vk_device.c:236–244`）。

它可能阻塞 Metal commit caller：`N/bridge/NativeMetalObjects.rs:1823–1826` 直接呼叫 runtime commit。`R/scheduler/mod.rs:4–18,239–270` 在 scheduler lock 可用時，讓 committing thread 自己 submit ready batches；另有 pass 正在跑才交 inbox。故「有 scheduler thread」不等於 render thread 永不等 GPU。

觸發來源也不是臆測的 per-encoder semaphore：`R/command_buffer/submit.rs:367–419` 組入 event waits、外部 binary semaphores、after-all waits、跨 VkQueue resource dependencies、新資源 first-work dependencies、binding dependencies；多處使用 ALL_COMMANDS。事件的 signal ordering 還可能使尾端 submit 等前一 signal（437–440）。但一般同 queue、無 event 的一批工作不一定有 wait；runtime 每批 signal 自己的 timeline，不代表下一批一定 CPU wait 它。**必須量 wait_count 與非零等待，不能由 timeline 的存在推定每幀序列化。**

確認／反駁實驗：在 `darwin_queue_submit()` 入口記 submit id、wait_count、每個 sync 的 state/fence、等待前後時間、提交返回時間；在 M2V 給 wait 標來源（event、tracker、after_all、first-work、binding）。同步記 Metal commit begin/end 及 scheduled callback。若幾乎所有 submits 的 wait_count=0，或 total CPU wait 接近 0，這項就不是當前場景主因；若下一批的 post 總發生在上一 fence 被 guest 看見後，且中間 GPU 空閒，便直接證實。

建議變更：先對「已提交、同一有序實體 ring」的 dependencies 設計 queue-order fast path，保留需要的 memory visibility/cache barriers，避免為已可由同 ring 次序保證的工作等待 CPU completion。跨 ring/context 或尚未提交的 dependency 要有真正的 async dependency queue／kernel in-fence 支援，不能無條件略過。將提交搬離 caller 可改善 caller latency，但若 dependency 仍是 CPU 完成後才放行，GPU bubble 仍存在。

**3. 1 ms fence slicing 可以解釋 timeout 次數；完成通知鏈必須分段量，不能直接聲稱有 16 ms polling。**

`M/freedreno/vulkan/tu_knl_darwin.cc:208–225` 把長等待切成每次 `timeout_ns=1,000,000` 的 ABI 呼叫；`tu_knl_darwin_virtgpu.cc:512–517` 轉給 guest WAIT_FENCE。`K/DroidVMVirtioGpu3D.cpp:478–488` 只 reap used ring、檢查 completed，未完成就 `IOSleep(1)`；**沒有送出 WAIT_FENCE ccmd 給 host**。且 timeout counter 只在 `timeoutUs != 0` 時增加（487），所以這個 470–690/s counter 不是所有 zero-timeout retirement polls 的總和。

直觀數量級：40 submits/s，每個平均等候約十餘個 1 ms slice，就能有數百次 timeout/s。一次原本正常的長 fence wait 可產生很多 timeout；這不代表 GPU fault，也不代表幾百次獨立 host request。這裡的主要成本是 Mach/IOKit 往返、locks、sleep/wakeup 和 vCPU scheduling；`IOSleep(1)` 並不保證恰好 1 ms 後獲得 CPU。

guest 明確禁用 virtqueue interrupts：`K/DroidVMVirtioGpu.cpp:140–146` 設 NO_INTERRUPT；65–69 說明 used ring 是 guest RAM，poll 本身不用 VM exit；但 reap 有完成時還會讀 MMIO interrupt status（100）。一般 command wait 先 spin 200 µs，再 sleep 1 ms（69,233–247）。這是 latency/CPU 取捨，不能把 slice 設短就保證更快，尤其目前有 CPU 頻率與排程壓力。

host fence 正常是 event-driven：

- `V/drm/drm2kgsl/drm2kgsl_renderer.c:197–203` 在 A750 預設 timestamp wait，除非設定 `NCTX_NO_WAITTS`；1904–1921 也有 sync_file 路徑。
- `V/drm/drm_fence.c:93–127` 在獨立 timeline thread 上等 condition／`WAITTIMESTAMP` hook／`poll(fd,-1)`，醒來立刻 retire。`drm2kgsl_renderer.c:2408–2419` 的 3000 ms 是 ioctl **最長 timeout**，不是每 3 秒掃一次。
- context fence callback 直接從 `V/virglrenderer.c:193–200` → `C/rutabaga_gfx/src/virgl_renderer.rs:230–244` → `C/devices/src/virtio/gpu/mod.rs:409–447` 的 add_used/signal_used。因此此 native-context GPU fence 並非一定要等 main GPU worker 下一次 epoll；它仍可能等 callback 所需 locks 或 sync-thread CPU。
- `R/command_buffer/completion.rs:70,137–152,560–586` 有 per-VkQueue waiter 與 completion thread；100 ms 是可被 fence 提早結束的 wait 上限，不是固定 completion period。

確認／反駁實驗：對相同 fence 串起以下時間點，而非只比總 latency：KGSL ioctl enter/return → GPU 第一個/最後一個實際 timestamp → KGSL retire → `kgsl_timeline_wait_timestamp` return（或 sync_file readable）→ context fence callback/add_used → guest reap → `darwin_sync_wait` return → M2V completion observed → NativeMetal callback／handler。host 可用 ftrace/perf/Perfetto 的 sched_switch、sched_wakeup 與 ioctl timing；guest 在上述函式加 memory ring timestamps，再由 Claude 擷取。兩邊先各自算差值，以 `(context, ring, fence, command-buffer id)` 關聯；沒有時鐘校準前別直接減 host 與 guest wall clock。

已有 MetalCheck 的 `K/metalcheck/Core.mm:2405–2435` 會量 empty、fill-4B 的 commit→scheduled、commit→completed、GPU duration，可先與 512×512 render 比較，再以 1／2／4 個 in-flight command buffers 測 throughput：若增加深度顯著提高 throughput，而每個 latency 仍高，便是等待／通知或排程造成的 bubble，而非單純 shader 成本。它與實際 CA 的 dependency pattern 仍需分開解讀。

建議變更：guest fence completion 改 interrupt/event wakeup，長等待不要反覆進出 IOKit；提供可讀 completed seqno page／GPU-written completion marker 的 fast path。Linux tree 已有這類做法，見後面的比較。先量 host retire→used、used→guest 的差額，再選擇改 host sync mode、thread placement 或 guest notification。可由 Claude A/B `NCTX_NO_WAITTS` 對 timestamp mode；不要用 `NCTX_NO_FENCE` 的假完成作為正確渲染效能證據。

**4. 一個 Metal frame 能變成很多 Vulkan command buffers，並在每個邊界 flush；這是 batch 內 stalls 的具體候選。**

`R/encoder.rs:1–20,246–260` 每個 encoder 開自己的 VkCommandBuffer，end 後收進 Metal command buffer；不是每個 encoder 都呼叫 queue submit。`R/command_buffer/submit.rs:301–334` 又把中間 barriers 放進獨立 command buffers，再夾入 encoders 的 raws；463–470 另有結尾 barrier buffer。一般 batch 的 work/end 是同一 `vkQueueSubmit` 的多個 SubmitInfo（486–553），可被 Mesa merge；event waits/signals 與 host steps 才可能把一個 Metal command buffer 拆成多批。不能用 render encoder 數直接當 KGSL submit 數。

這個組織與 Turnip 有明確成本交集：`M/freedreno/vulkan/tu_cmd_buffer.cc:5389–5413` 在每個 command buffer 結尾 defensively clean CCU color/depth，註解也明講 multiple command buffers 之間會有不必要 flush。begin cache tracking 則預設所有 invalidate pending（4406–4413）。所以「把 Vulkan command buffers 一起提交」沒有自動消除這些已錄好的 cache packets。

barrier 本身也有可縮小的範圍：`R/tracker.rs:305–327` 每 batch 的開頭是 `NONE → ALL_COMMANDS / MEMORY_READ|WRITE`，末端是 `ALL_COMMANDS / MEMORY_WRITE → HOST_READ|WRITE`；332–342 的 `everything()` 是完整 memory dependency，shadow copies 會使用（`R/render/pass_steps.rs:126–129`）。364–388 所有這些 barrier 經 legacy global VkMemoryBarrier 發出，非 per-resource barrier；但不能因此說所有 encoder 間都是 full barrier，普通 hazard 的 mask 仍由 tracker 規劃。

Turnip 如何落到 GPU：`tu_cmd_buffer.cc:5718–5792` 將 access dependencies 轉 cache clean/invalidate；6205–6231 的 backward stage dependency 會設 WAIT_FOR_IDLE，`358–420` 發出 clean/invalidate events、CP_WAIT_MEM_WRITES、WFI、WAIT_FOR_ME。這些可能讓 command processor「有 batch 在執行」，但 shader cores 不忙。是否足以吃掉 16 ms 要靠 GPU timestamps／packets／stall counters 判定。

render-pass 另有擴張：`R/render_target.rs:40–48,408–422` split instance 中間強制 LOAD/STORE，只有 first/last 才採原 Metal actions。`R/render/pass_steps.rs:74–98` 可有 reload、shadow、format copies、額外 resolve instances；`render_target.rs:761–776` exact/copy resolve 可強制 store。尤其 `render_target.rs:329–355` 在 driver 沒有相應 measured fact 時，Metal DontCare／MultisampleResolve 的原 attachment 也會走 STORE；`T/device/driver_facts.rs:1917–1963` 這兩個 facts 列的是特定 MoltenVK、RADV、Intel，未列 Turnip。因此此 tree 的普通 Turnip application-held attachments 預設有這個保守 store 成本；memoryless/內部未持有 attachment 有例外（`render_target.rs:361–365,764–776`）。實際 CA 用多少 DontCare、MSAA、shadow 或 split instances 未知。

`TU_DEBUG=nocb` 只關 concurrent binning（`M/freedreno/vulkan/tu_device.cc:1950–1953`），**不等於強制每個 pass 使用 GMEM**。`tu_cmd_buffer.cc:1371–1448` 還會因 attachments 放不下、disable_gmem、tessellation 或 autotune 選 sysmem。不能從環境字串就推論 Today 的 pass 全在 GMEM。

對「等待 events」的負面結果：runtime src 搜尋未找到 `cmd_wait_events`／`cmd_set_event` 呼叫；Metal event 主要轉成 batch/semaphore dependencies（`R/command_buffer/mod.rs:1355–1357`、`submit.rs:376–379`）。Turnip 自己的 `tu_CmdWaitEvents2` 確會發 CP_WAIT_REG_MEM（`M/freedreno/vulkan/tu_event.cc:144–185`），但不能據此斷言 CA batch 使用了它。concurrent-binning 的 on-chip wait 也有條件 gate（`tu_cmd_buffer.cc:512–514`），在 nocb 下不是首要嫌疑；普通 WFI/cache waits 仍存在。

確認／反駁實驗：先讀 NativeMetal 現有 `K... rp/dr/kpx/cs/bl`、`E... scheduled` records（`N/NativeBridgeMetalFrontend.mm:3132–3138`），同時擷取 M2V WorkCounts 的 queue_submissions、command_buffers_submitted/begun、internal/staging_submissions（`R/work_counts.rs:799–835`）。對 Today 的一張代表 frame，再記 Vk pass instances、load/store/resolve actions、render area、shadow copies、Turnip gmem_disable_reason、tile 數、IB 數；在每 encoder／barrier 前後放稀疏 GPU timestamp，或用 Turnip u_trace。只抓短區段，與關閉 tracing 的 baseline 對照，避免 dump 改變時間。

兩個可控 microbench：固定總 draw/pixel 數，改 1／4／16／32 encoders；以及固定 encoder 數，改 barrier 數／hazard pattern。如果時間跟 encoder 邊界而非 shader/pixel 數增加，且 clean/WFI 區段很大，則此項成立。若 frame 的 raw GPU duration 很短，這項就不能解釋長 host retire interval。

建議變更：合併可合併的 encoder recordings，將必要 barrier 放進同一 primary command buffer，減少 barrier-only command buffers；讓 dependency scope 對應實際 producer/consumer，不要全域加重。針對 split render-pass 與 DontCare store，先用語義／影像比對證明可省，再保留 attachment 或避免 store/load。不要直接刪 Turnip 的 CCU clean／WFI：部分是可見性與 hardware correctness 所需。選 sysmem/GMEM 的 A/B 也應同時記 bytes、pass mode 和視覺正確性。

**5. NativeMetal 沒有常態 max-in-flight=1，但 cache maintenance 與完成 handler 仍可能卡 caller／下一張。**

`N/NativeBridgeMetalFrontend.mm:2004–2029` 的一般 commit 只註冊 callbacks 並呼叫 runtime commit，沒有尾接 waitUntilCompleted。`waitUntilCompleted` 是獨立 API（2037–2042）；`commitAndWaitUntilSubmitted` 只等 scheduled（1840），不過優先 2 使「提交完成」本身也可能晚。

queue 也非只允許一張：`R/queue.rs:36,160–162` 預設 64 command buffers；271–296 只有滿額才 block。frontend 的 `newCommandQueueWithMaxCommandBufferCount:` 甚至忽略 count、使用一般 queue（`N/NativeBridgeMetalFrontend.mm:2634`）。`gInFlight` 是 lifetime/resource tracking set，非 per-frame semaphore。

真正可疑的成本在 `N/NativeBridgeMetalFrontend.mm:700–712`：收集所有 IOSurface 的 base＋**整個 IOSurfaceGetAllocSize**，只去掉完全相同範圍，然後逐範圍 `sys_dcache_flush()`。commit 前呼叫一次（2019），GPU completion 後再呼叫一次（1971），不依讀寫用途或 dirty rectangle 篩選。這會阻塞 commit caller／completion 處理，且隨 surface 數、bytes 與 CPU clock 變化。host import 已標 IOCOHERENT/WRITEBACK（`V/drm/drm2kgsl/drm2kgsl_renderer.c:2300–2305`），guest map 也宣告 write-back（`K/DroidVMVirtioGpu3D.cpp:451–452`），值得檢查是否重複維護，但 source flags 本身不足以證明整條 IOSurface mapping 路徑完全 coherent。

還有明確的 resource wait API：`N/NativeBridgeMetalFrontend.mm:1181–1193` 掃已提交的 command buffers，有 storage dependency 或 unknown 就 waitUntilCompleted。它已非「所有 resource 都等所有 buffers」；應量 CoreAnimation 是否呼叫它及 dependency 命中率。

runtime 另有同步 internal submissions：`R/device/submit.rs:1–9,214–240` 對部分 texture host copies／live-buffer clear 提交後立即 wait fence；`R/texture/staging_copy.rs:85,119` 的 staging copy 也有自己的 submit 路徑。這不是一般 Metal commit 都做的事；`R/texture/host_copy.rs:1–2,36–39` 另有純 CPU copy、無 GPU wait 的路徑。應以 internal/staging_submissions 差分及呼叫堆疊確認 CA 的 replaceRegion/getBytes 是否觸發同步 copy，再決定是否重用 staging、合批上傳或避免來回 readback。

完成 handler 交付為 `finish()` 收集 handlers 後，若 queue.completionQueue 存在就 dispatch_async，否則在 runtime callback thread 執行（1970–2002）；`waitUntilCompleted` 還等 `_handlers` group。因此 completionQueue backlog 或 handler 自己耗時，也可讓 caller 的 wait 晚於 GPU。現有 `ctc` 在 callback 進入時、`finish()` 之前記錄（2056–2067），不含後面的 surface flush 與使用者 completed-handler 執行時間。

確認／反駁實驗：對 5 秒相同 drag 取差分 `J surface cache n/bytes/us/max`、`J resource wait`、`J scheduled wait`、`J completed wait`（`N/NativeBridgeMetalFrontend.mm:3092–3098`），另記 commit enter/return、callback enter、finish cache end、handler begin/end。若 cache us、resource-wait us 很小，直接降級；若 callback→handler 的時間長，別誤算成 GPU latency。對 coherent imports 做限縮 A/B：只在已核對 IOCOHERENT 且使用相同 backing pages 的類型測省略冗餘 cache op，仍測 CPU→GPU、GPU→CPU、IOSurface 跨 process 讀寫與 blur 畫面。

建議變更：依 ownership transition、memory type 與 access direction 做必要範圍的 maintenance，減少整個 allocation 的重複 flush；completion tracking、使用者 handler delivery 與 resource cleanup 分離。不要用全域「永遠不 flush」代替 coherence contract。

**6. control／BO 路徑仍有逐步同步；回收還可能把這個成本藏進 fence observation。**

`M/freedreno/vulkan/tu_knl_darwin_virtgpu.cc:149–176` 的 `vg_ccmd()` 逐條非 fenced EXECBUFFER、等待 host response/seqno，沒有 Linux 的 reqbuf batching。但目前直接使用它的 GET_PARAM、SUBMITQUEUE_NEW 在 open（230–260），不是每個 frame 的 GEM_SUBMIT。題目的 13638/13688 fenced 比例也與「一般提交非同步」一致。

BO create 是較實際的慢路徑：`K/DroidVMVirtioGpu3D.cpp:391–405` 先 `submitCommand(GEM_NEW)` 等 reply，再 allocate/wire/zero guest pages；423–425 再同步 RESOURCE_CREATE_BLOB。`submitCommand()` 本身 post 後 wait（251–256）。這些在 client lock 下執行（532 起），Darwin `dwv.lock` 也包住 BoMap/create 與 Submit（`tu_knl_darwin_virtgpu.cc:532,566–597,627`），所以可擋住同 process 後續提交。普通 guest blob map 用既有 guest pages（`K/DroidVMVirtioGpu3D.cpp:433–456`），不是每次 CPU map 都新增 host round trip；只有 host-visible blob 才走 MAP_BLOB。

BoFree 已有 deferred retirement，不應再指控為每個 free 都 wait idle：`M/freedreno/vulkan/tu_knl_darwin.cc:616–637` 只有 256 entries 滿才 pressure wait；kernel `closeResource()` 在有 pending work 時也 defer（`K/DroidVMVirtioGpu3D.cpp:491–509`）。但 deferred **不代表免費**：

- `dw_wait_fence_locked_free()` 成功後立即 `darwin_collect_retired()`（`tu_knl_darwin.cc:231–236`），可同步呼叫多個 BoFree（298–342）。
- kernel `reapPending()` 會釋放 closed resources（`K/DroidVMVirtioGpu3D.cpp:228–243`）；`releaseResource()` 做同步 unmap/unref 才 drop pages（263–273）。因此一個本意只是觀察 fence 的呼叫，也可能額外等待 resource control responses。
- display 的 `droidvm_virtgpu_finished()` 在持有 gClientsLock／client lock 時呼叫 reapPending（607–614）。註解雖強調不等 client lock，reap 的 cleanup 仍可觸發上述同步工作；應直接量這段 lock hold，不能只相信註解的低延遲意圖。

提交分塊也與 Linux 不同：本機 `/root/gitrs/UniXNU/orgrepos/UniXNU/drivers/NativeAdreno/NativeAdrenoABI.h:15` 的 MaxBuffers=16，`M/freedreno/vulkan/tu_knl_darwin.cc:918–931` 每 16 個頂層 IB 一次 fenced submit。不是每個 IB 一次，也不會無條件等前一 chunk。kernel 實際 MaxPending=256（`K/DroidVMVirtioGpu3D.cpp:163,465`），transport 有 256 slots／12 large slots（`K/DroidVMVirtioGpu.cpp:20–26`）；Darwin 那句「eight kernel jobs」及 inflight[8] 是舊 backend 的記帳／busy retry，不能拿來宣稱 virtgpu 現在只容許八張，更不能說一張。

確認／反駁實驗：把 CREATE_BLOB/GEM_NEW/UNREF/MAP 的次數、每次耗時、lock hold、retired queue depth、pending count、submit 的 IB/chunk 數與 frame 對齊；分開計 `reapPending()` 的 fence scan 與 resource cleanup。用預先配置且重用 BO 的相同 workload 對照 allocation churn。若真是 8 blobs/s、回收也很少且控制命令小於 ms，便不應為它優先重寫整條 transport。

建議變更：有序但不需 response 的 control ccmds 合批／async post；將 resource cleanup 交獨立 reaper，fence observation 先發布 completion，且在 host unref ack 前保持 pages pinned。若大量 submits 卡在 16-IB 切片，擴充 ABI 的 IB list 大小或先合併 command buffers。不能只提早 free backing pages。

**7. drm2kgsl 一次 GEM_SUBMIT 就是一次 IB-list ioctl；priority 與 host worker 延遲要分開查。**

`V/drm/drm2kgsl/drm2kgsl_renderer.c:1722–1767` 建 kcmds array，1878–1887 以 `numcmds=n` 一次呼叫 `IOCTL_KGSL_GPU_COMMAND`；cmd 沒填 synclist/numsyncs。沒有 per-IB wait，也沒有在此等 GPU 完成。之後只安裝 timestamp／fence tracking（1904–1921），由獨立 timeline thread 等待。host CPU call 當然仍可能因 KGSL driver 內部排程、queue pressure、memory 管理而阻塞；目前未讀到此裝置的 vendor KGSL implementation，不能由 userspace code 排除它。

priority 參數確實被捨棄：`kgsl_drawctxt_create(..., UNUSED uint32_t prio, ...)` 在 1240–1255 只設 SAVE_GMEM、NO_GMEM_ALLOC、PREAMBLE、USER_GENERATED_TS；註解記錄加入某些 flags 曾回 EINVAL。`M/freedreno/vulkan/tu_knl_darwin_virtgpu.cc:256–264` 的 priority 0／virtio ring 1 不是 host hardware priority 0／ringbuffer 1。host trace 所見 prio 8、rb 2 是另一個命名空間，與「沒傳 priority、由 KGSL 預設」相容；不應把 virtio ring_idx 與 hardware rb 對號入座。

worker 同時處理 control commands、display 與 flip completion；`C/devices/src/virtio/gpu/mod.rs:1647–1670` 先處理 control queue/resource bridges，再 sweep display flip fences。若其中有慢 host ioctl 或 display fallback，會延後新的 submit／flush ack。但 native-context GPU fence callback 有前述獨立路徑，不能一概說所有 fence 都排在這個 worker 後面。source 的 RT priority 也不是無條件啟用：同檔 1904–1907 在沒有 CROSVM_GPU_RT_PRIO 時不設 RT。

確認／反駁實驗：請 Claude 將 main ctx、其他 guest ctx、Android ctx 的 kgsl submit/retire 與 sched_switch 對齊，量 `GPU_COMMAND` syscall wall/on-CPU time、worker runnable delay、kgsl-sync runnable delay、同 context 的排隊深度、higher-priority context 占用區間及 preemption/context-switch 次數。`submitted_to_rb→start` 的約 17.6 ms 可能只是同 context 前一 batch 的正常排隊；先把前驅 batch 排除，才算 priority starvation。

另外確認沒有開昂貴診斷：`NCTX_IB_SCAN` 會掃 IB、查 object table、掃 IB2 並 cache clean/invalidate（`V/drm/drm2kgsl/drm2kgsl_renderer.c:1815–1865`）；`NCTX_IB_CHECK` 也讀 IB／做 cache maintenance（1775–1807）。這些都是條件分支，未確認 runtime env，不能假定已開。對 72% worker CPU，stack sampling 比猜「epoll 很慢」有效。

建議變更：依 profile 拆掉 worker 上的實際阻塞；若 priority starvation 證實，再依當前 vendor kernel 支援的 flags／properties 傳遞 queue priority，保留 Android compositor 的正常運作。不要直接把所有 contexts 改最高優先權。pinning 對 page drag 有效而 Today 幾乎無效，支持存在至少兩種 workload-dependent 成本，不能用單一 CPU affinity 結論涵蓋兩者。

**與 Mesa Linux drm native-context 路徑的對照。**

使用者記憶的方向是對的：Linux 的優勢包含非同步 dependencies、ccmd batching 與較便宜的 completion observation。但 iOS 並不是把每個 Linux async GEM_SUBMIT 改成同步 RPC；差別在以下位置。

| 項目 | Linux comparison code | 此 Darwin 路徑 |
|---|---|---|
| 一般 GPU submit | `M/freedreno/vulkan/tu_knl_drm_virtio.cc:1654–1677` 使用 GEM_SUBMIT + vdrm_execbuf | `tu_knl_darwin_virtgpu.cc:394–412` 同樣 GEM_SUBMIT，fenced EXECBUFFER post 即回；`K/DroidVMVirtioGpu3D.cpp:459–476` 證實非同步 |
| submit dependencies | `tu_knl_drm_virtio.cc:1588–1606,1668–1674` 傳 in/out syncobj handle＋timeline point；`L/virtio/vdrm/vdrm_virtgpu.c:45–62` 支援 in/out fence fd 與 syncobj fields，交 kernel 處理 | ABI 沒傳 in dependencies；`tu_knl_darwin.cc:909–915` 在 CPU 等實際 completion。不能假設 Linux kernel 一定把所有 dependency 都下推成 KGSL GPU syncpoint，但 userspace 不需這樣逐項等待 |
| 無 response 的 ccmd | `L/virtio/vdrm/vdrm.c:89–105,135–159` enqueue reqbuf，sync=false 可直接回；flush 再一起送（`vdrm_virtgpu.c:75–92`） | `vg_ccmd()` 每條送出且等回應；本次 tree 大多用於 initialization，BO create 也逐步同步 |
| 必須讀回的控制操作 | Linux `virtio_simple_ioctl()` 也 `vdrm_send_req(...,true)`（`tu_knl_drm_virtio.cc:83–109`），並非全無同步 | GET_PARAM/queue-new 的同步屬合理控制面；應優先消除每幀／每 dependency 的等待 |
| fence fast path | Linux 在尾端加入 GPU `CACHE_FLUSH_TS` 寫 userspace seqno（`tu_knl_drm_virtio.cc:1452–1469,1537–1554`），直接讀它可判 ready（444–448）；此 tree 還有 300 µs poll-first＋syncobj fallback（615–690） | 沒有這個 shared GPU-completion fast path；每次進 IOKit，等 host fence callback→used ring→guest poll |
| empty submit | 此 Linux tree 有同 queue fence inheritance／sync payload copy，免 host round trip（`tu_knl_drm_virtio.cc:726–759,1506–1519`） | Darwin 無 IB 時繼承 queue fence（`tu_knl_darwin.cc:934–942`），但在此之前仍先 CPU 等 waits |
| BO retirement | Linux zombie VMA batching 的目的直接寫在 `tu_knl_drm_virtio.cc:65–74` | 已 deferred，但 reaping 仍含同步 unref；觀察 fence 與回收未充分分離 |
| IB packing | Linux 建完整 commands payload（`tu_knl_drm_virtio.cc:1556–1561,1665–1666`） | NativeAdreno ABI 每次 16 IB，較容易增加 kernel/host submit 次數 |

`L` 的 vdrm 版本與 Mac `M` 不一定完全相同；上表僅引用實際可讀到的各段機制，沒有假稱兩者是同一 checkout。Linux 的 poll-first／empty-submit 部分明顯已有本專案 tuning，移植時應當作既有設計參考，不能直接套用它的 vkmark 成績預測 iOS fps。

**約 16 ms 的下一步：先建立一張可核對的時間帳。**

題目「idle 231 MHz 與 drag 903 MHz 都約 16–17 ms」非常值得查，但兩者不是相同 workload，尚不是固定工作量的 DVFS A/B。CPU polling 會延長 completion 被看到的時間，通常不會增加真正 GPU begin→end timestamp 差值；若 trace 的 active interval 是 kernel 軟體邊界、含 preemption 或 retire observation delay，就又不同。這次沒有取得該 vendor 的 tracepoint 定義及分析 script，故不能把名稱 active 當成 shader busy 的證據。

請 Claude 最先做以下可確認或反駁的三分測試，維持 CPU/core placement、解析度、畫面狀態一致：

1. 對相同 batch 加首尾 **raw GPU query timestamps**，另保留 KGSL start/retire 與 guest completion。若 raw GPU 差只有 <1–2 ms、KGSL interval 卻約 16 ms，優先查 trace 定義、host retire/notification 與排程；不應先改 shader/barriers。注意本 Darwin transport 的 GetTimestamp 回傳 CPU time 換算值（`M/freedreno/vulkan/tu_knl_darwin_virtgpu.cc:495–500`），不能拿它當獨立 GPU clock calibration。M2V 無 calibration 時會將 GPU timestamp 差值放在 completion 時刻之前（`R/gpu_time.rs:38–40`）；絕對 GPUStart/EndTime 可能晚，應以 raw query 差值為準，並確認沒有啟用 gpu_times_from_host（59–66）。
2. 若 raw GPU 差也約 16 ms，對**同一固定工作**在兩個 GPU clocks 重測，保持 CPU、記憶體/bus clocks 與 submit pattern 可比。若時間不縮短，量 CP wait/cache、memory bandwidth、preemption、power/clock transition；若會縮短，原 idle/drag 對比是 workload 混淆。再用優先 4 的 encoder/barrier/pass timestamps 定位。
3. 對每 frame 關聯 Metal command buffers、Darwin chunks、KGSL timestamps 與 display source resource。ctx 21 有 37 batches/s、display 約 22–23 fps，不代表每 frame 只有一批，也不能將每批 median 相加當 frame 時間。若同一 frame 的 producer 真耗 16 ms，僅消除 frame 外的 bubble 也未必達 120 fps；120 fps 需要平均每 8.33 ms 產出一張，還須降低 GPU 工作／stalls 或改變跨 frame 重疊方式。

實驗的最小紀錄欄位建議為：`process/context, MetalCB id, batch index, IB/chunk count, kernel fence, global order, display resource id, wait_count/source, timestamp, thread id`。先各取短的 idle、page drag、Today drag，報 p50/p90/max 與每秒次數；加總只用同一 frame 的相連區間，避免 median 相加、把多執行緒重疊時間重複算入。這會直接決定應先改 display pipelining、Darwin dependencies、notification，還是 batch 內的 rendering/cache 行為。
