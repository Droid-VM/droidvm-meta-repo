# 為什麼 protected VM 裡 stock Linux virtio-snd 會炸 lent memory（2026-08-26 調查）

錯誤：`pcivu-sound activate failed: failed to get host address: host access to lent
memory region at 0x105600000 (purpose=GuestMemoryRegion) in protected VM`

## 結論先講

**stock Linux virtio-snd 沒有「不吃 swiotlb」的問題；它根本沒被告知要吃。**
swiotlb/restricted-pool 的決定不在 snd 驅動手上，而在 guest virtio core——它按「這個
裝置有沒有協商到 `VIRTIO_F_ACCESS_PLATFORM`」逐裝置決定（`vring_use_dma_api()`）。
我們的 vhost-user snd backend 從不宣告這個 feature，guest 於是（正確地）跳過 DMA API，
vring 配置在普通（=LEND 給 guest 的）記憶體，crosvm frontend 在 activate 翻譯 ring
位址時就炸了。**Linux guest 驅動端沒有東西要移植；要修的是 host 端的 feature 直通。**

## 因果鏈（全部對到行號）

1. DroidVM 把 virtio-snd 跑成獨立 vhost-user backend 子程序（`crosvm device snd`，
   為了以 app uid 拿 AAudio；fork 樹 commit 6dacf00dc）。裝置名 `pcivu-sound` =
   `pci`（virtio_pci_device.rs:728）+ `vu-sound`（vhost_user_frontend/mod.rs:394）。
2. backend 寫死非保護模式：
   `devices/src/virtio/vhost/user/device/snd.rs:95`
   `let avail_features = virtio::base_features(ProtectionType::Unprotected) | ...`
   → 永遠不含 `VIRTIO_F_ACCESS_PLATFORM`（base_features 只在 protected 時加它，
   devices/src/virtio/mod.rs:287）。
3. frontend 用 AND 遮罩：`vhost_user_frontend/mod.rs:159`
   `avail_features = allow_features & backend_client.get_features()`
   → 即使 VM 是 protected、allow 裡有 ACCESS_PLATFORM，也被 backend 的集合遮掉。
4. guest virtio core 看不到 ACCESS_PLATFORM → 不走 DMA API → vring/緩衝直接用
   guest 物理位址（lent 記憶體）。同一台 guest 的 blk/net/gpu 是 crosvm 內建裝置，
   有 ACCESS_PLATFORM，全部經 restricted pool 反彈，所以只有 sound 炸。
5. frontend activate 時翻譯 ring GPA → `vm_memory/src/guest_memory.rs:84` 的
   "host access to lent memory region"。**在任何 PCM 流量之前**，所以是 ring 而不是
   資料緩衝的問題——這也解釋了為什麼是 activate failed 而不是播放中斷。

同檔案其他 hardcode（現在沒用到，將來會咬人）：`vhost/user/device/fs.rs:66`、
`vhost/user/device/wl.rs:114`。

## 修法（host 端，小改動）——已排程，enc50 驗收後執行

參數通道現成：`snd_helper::launch` 把整個 `SndParameters` serde 成 `--config-json`
傳給子程序，而呼叫端 `create_unprivileged_virtio_snd_device(protection_type, ...)`
（device_helpers.rs:615）**手上就有 protection_type**。三步：

1. `devices/src/virtio/snd/parameters.rs`：`Parameters` 加 `pub access_platform: bool`
   （serde default false，舊 JSON 相容）。
2. `device_helpers.rs` 呼叫端：launch 前
   `snd_params.access_platform = protection_type != ProtectionType::Unprotected`。
3. `vhost/user/device/snd.rs:95`：`access_platform` 為真時 OR 進
   `1 << VIRTIO_F_ACCESS_PLATFORM`。

不動 in-process 路徑（common_backend 的 base_features 由呼叫端給，本來就對）；
fs.rs/wl.rs 的同款 hardcode 不在本輪（沒用到，留註記即可）。

**修復後唯一要實測的殘留變數**：`set_mem_table`（vhost_user_frontend/mod.rs:257）把
**所有** region 連 shm fd 原樣送給 backend，含 lent 區域。guest 反彈後 backend 只會
「解參考」pool 內位址，但它會不會在 SET_MEM_TABLE 時就因 mmap lent fd 而失敗要開機
驗證；若失敗，補一刀：protected 時只送 host 可存取的 region（backend 對洞洞位址
translate 失敗即可，反正流量都在 pool 裡）。

## 給 app 提醒（任務 1）的正確表述

這個 log 簽名的兩種真因：
- guest kernel 沒開 `CONFIG_DMA_RESTRICTED_POOL`（什麼都不反彈）→ 換核心；
- 該「裝置」的 guest 驅動沒走 DMA API →
  - Windows：確實要裝移植驅動（gunyah-guest-drivers-windows）；
  - Linux stock virtio-snd：不是驅動的錯，是上面的 host bug——修好 host 後
    stock 驅動應直接可用（droidvm-guest-additions 目前也只有 gunyah_guest +
    virtio-gpu，沒有 snd 移植，正確：不需要）。

## 次級 bug：chmap 數量不符（已修，crosvm 048f7374e；u26 實機出聲驗證通過）

ACCESS_PLATFORM 修復落地後，u26（stock kernel、protected）**lent memory 錯誤消失、activate 過關**，
但 guest `virtio_snd` probe 隨即 **-22 (EINVAL)**；host backend 同一時刻（時間戳逐秒吻合）報
`[Card 0] start_id(0) + count(4) must be smaller than the number of chmaps (2)`
（async_funcs.rs:960，處理 VIRTIO_SND_R_CHMAP_INFO）。修復前 activate 就死，驅動走不到 chmap
查詢，這 bug 一直被遮著。

**根因**（common_backend/mod.rs）：
- config space 宣告數（line 558）：`chmaps = num_output_devices*3 + num_input_devices`
  ——一條硬編公式，假設每個 output device 拿滿 3 個 layout。
- 實際 chmap_info（line 757-779，`push_chmaps`）：按 device 的 `channels_max` **過濾**
  `LAYOUTS = [(2ch),(4ch),(6ch)]`（`if channels > max_channels { continue }`）。這個過濾是
  **對的且有意的**（line 718 註解：不給 stereo endpoint 宣告 6ch map，否則 Linux 把最寬的
  map 交給 ALSA，guest 端就看得到不一致）。
- 這台 output/input 都 2 聲道（AAudio 原生 stereo）→ 各只容 (2ch) 一個 → 實際 1+1=**2**；
  config 公式算成 1×3+1=**4**。guest 信 config 查 [0,4)，backend 只有 2 → 回錯 → probe -22。
- 連 test line 1367 `assert_eq!(..., 11); // (Output = 3*3)` 都洩露這假設，只在「所有 device
  支援滿 6 聲道」時才碰巧正確。

**修法**：config 的 chmaps 數量必須等於實際 `chmap_info.len()`。把 per-device 的「LAYOUTS 中
channels<=channels_max 的個數」抽成一個函式，`hardcoded_virtio_snd_config` 與 `hardcoded_snd_data`
共用，取代 line 558 的硬編公式；同步修 line 1367 的測試期望（不再是 3*3+1，而是按 caps 實算）。
排在 single-port crosvm 改動之後（同一棵樹，避免建置飛行中改檔 + 混淆驗收）。

**驗證**：u26 重開 → guest `cat /proc/asound/cards` 有卡、`dmesg` 無 -22；host 無 chmap 錯誤；
非保護 VM 迴歸。SSH 進 guest 走 `root@<guest-ipv6>`（u26 IPv6 見使用者提供，會輪替）。

## 驗證計畫（fix 落地時）

u26（stock kernel + restricted pool）+ 修過的 crosvm：
1. `--virtio-snd ...` 起機 → pcivu-sound activate 不再報 lent memory；
2. guest `aplay` 出聲 / `arecord` 有樣本（端到端過 pool 反彈）；
3. 對照：feature 未修的 crosvm 同 config 必現 activate failed（陽性對照）；
4. 非保護 VM 迴歸：聲音照常。

## Windows viosnd 驅動 vs stock virtio-snd 對齊審查（2026-08-26，讀碼完成）

背景：viosnd 無 virtio-win 上游（vendored 自第三方 317764920/viosnd + DroidVM 自寫檔）。
審查基準＝virtio-snd spec 與 stock 裝置（QEMU 類）行為。原則：只有延遲機制是 DroidVM
獨有，其餘須 follow spec。

**結論：未發現會讓 stock virtio-snd 不工作的讀取錯位。** 各軸：

| 軸 | 判定 |
|---|---|
| chmaps | config 的 chmaps 數**只印 log**（ViosndVirtio.cpp:1514），`VIRTIO_SND_R_CHMAP_INFO` 定義了但**從不發出** → crosvm 的 chmap 虛報對 Windows 無影響（**這就是 w11 一直有聲、Linux 卻 probe -22 的原因**）；對 stock 也無影響，不查詢是 spec 合法的 |
| channels | 從 PCM_INFO 的 channels_min/max 協商（ViosndFormat.cpp:394：hint 無效→範圍涵蓋 2 就選 2，否則 min）→ stock 的 1..N 範圍正確處理 |
| formats/rates | 枚舉位序與 spec 逐一一致（IMA_ADPCM=0 起） |
| direction | OUTPUT=0 / INPUT=1，對 |
| nid 分組 | dedupe 是 **per (direction, nid)**（ViosndFindEndpoint(Set, capture, deviceIndex)）→ QEMU 全部 nid=0（1 out + 1 in）各建 endpoint，正確。限制：同方向同 nid 的第二條 stream 當 surplus 丟棄（stock 多 stream 配置會少露 endpoint——容量限制，非故障） |
| vendor block | magic+version 把關（ViosndVirtio.cpp:822），stock 裝置讀到垃圾→歸零→「using defaults」；hint 索引有雙重邊界檢查 |
| PCM_INFO 空回應重試 | 容忍 DroidVM backend 冷啟動的 zeroed 首答（race→wait）；stock 首答即正確，零依賴 |
| feature bits | 只 mask VERSION_1 \| ACCESS_PLATFORM，不要求任何非 spec 位 |
| jacks | 只 log 不查詢 → jacks=0（QEMU）OK |
| rdmapool | 顯式退路：無池 → STATUS_NOT_FOUND → 普通 AllocateCommonBuffer；ViosndRdma.h 註解明寫「That is what runs on QEMU/KVM and on a pseudo-unprotected Gunyah VM」 |


### stock host 相容補充軸（同日，讀碼完成——這四項 QEMU 端會嚴格驗）

| 軸 | 判定 |
|---|---|
| virtqueue 索引 | `VIRTIO_SND_VQ_CONTROL=0/EVENT=1/TX=2/RX=3`（VirtioSnd.h:77-81），逐一符合 spec 順序 |
| SET_PARAMS 整除性 | `BufferBytes = PeriodBytes × NotificationCount`、period 先取整到整數 frame（ViosndPcm.cpp:99-112）→ buffer 恆為 period 整數倍，QEMU 的 `buffer % period` 檢查必過 |
| PCM xfer 框架 | `sg[0]`=xfer header+payload（out）、`sg[1]`=status（device-writable in）、`add_buf(...,1,1,...)`（ViosndVirtio.cpp:1952-1955）——spec 標準框架 |
| 狀態機順序 | SET_PARAMS→PREPARE→START→STOP→RELEASE；capture 的 RELEASE-without-STOP 已在移植時修正（見既有記錄）|

結論不變且更強：**驅動對 stock virtio-snd host 相容**，包括 QEMU 端嚴格驗證的部分。

DroidVM 獨有機制全部是「有就用、沒有走預設」的加層（vendor hints / rdma staging /
outstanding_packets 延遲參數），符合原則。使用者裁定（08-26）：允許保留的 DroidVM
獨有機制＝延遲參數 **加上 preferred_output/input vendor hints**——兩者都以 magic/version
把關、缺席走預設，不影響 stock 相容。兩個註記：
1. 同方向同 nid 多 stream 只取第一條（見上）；
2. vendor block 從 spec config 之後的固定偏移讀——stock 裝置 config 區較短，讀出界按
   virtio-PCI 慣例回 0（magic 不符→預設路徑），慣例安全而非規格保證。

## chmap 修復驗證（2026-08-26，完成）

修法落地為結構保證：config 的 `chmaps` 直接取建好的 `SndData.chmap_info.len()`
（兩個呼叫點都先建 SndData 再導出 config），不再有第二條公式可漂移。測試的期望值
仍是 11（該設定 fallback 輸出是 6 聲道，舊公式在此碰巧吻合），但補上了真正能抓
這類 bug 的斷言：`cfg.spec.chmaps == snd_data.chmap_info.len()`。

實機（5568 u26，stock kernel，protected）：
- `/proc/asound/cards`：card 0 = VirtIO SoundCard 出現；dmesg 零 virtio_snd 錯誤
- host 本次開機 log：chmap／lent memory／activate failed 皆 0 筆
- `speaker-test` 端到端：host 端 `AudioTrack: stop(72): 2,721,600 frames delivered`、
  `AudioFlinger::unRegisterAudioTrackClient uid 10355`（snd backend 的 app uid）——
  真實聲音資料流進了 Android 音訊系統

## viosnd 端點通用化（使用者裁定 1+2，agent 實作中）

裁定（08-26）：PR 未提、無現有安裝要顧——只做 (1) 端點鍵改 stream_id、
(2) 同 nid 撞鍵按序配對；命名只要求唯一（stream_id 衍生即可），
`VIOSND_MAX_ENDPOINTS`（每方向 4，恰容 app 的 4+4）不動。
建置約束：本機無 EWDK，編譯驗證需 push 分支觸發 repo CI（待使用者放行）
或使用者自有的建置管道。
