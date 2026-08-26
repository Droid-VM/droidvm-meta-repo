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

## 次級 bug：chmap 數量不符（修復揭露，未修，排隊中）

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
