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

## 修法（host 端，小改動）

主程序自己 fork+exec `device snd`（它知道 protection type，也控制 argv）：
給 snd 裝置參數加一個旗標（如 `access_platform=true`），protected VM 時傳入，
`SndBackend::new` 據此用 `base_features(protection_type)`。或最簡單：backend 無條件
宣告 ACCESS_PLATFORM（非保護 guest ack 後多走一層 DMA API，成本可忽略）。

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

## 驗證計畫（fix 落地時）

u26（stock kernel + restricted pool）+ 修過的 crosvm：
1. `--virtio-snd ...` 起機 → pcivu-sound activate 不再報 lent memory；
2. guest `aplay` 出聲 / `arecord` 有樣本（端到端過 pool 反彈）；
3. 對照：feature 未修的 crosvm 同 config 必現 activate failed（陽性對照）；
4. 非保護 VM 迴歸：聲音照常。
