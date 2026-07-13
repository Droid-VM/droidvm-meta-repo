# gfxstream host-visible folio backing — 實作記錄(task #15)

目標:gfxstream production 化。host-visible 記憶體的 share/RM 交易變成
「乾淨、有界、可回收」:每個 host VkDeviceMemory ↔ n 個 2MB order-9 folio,
生命週期綁定(create = order-9 alloc,destroy = unshare + free 回 reserve 池)。
user 定案 2026-07-11(取代原 blessed-pool arena 設計)。

## 定案設計(單一機制)

host `on_vkAllocateMemory` udmabuf 分支(所有 emulateHostVisible 都走這):
memfd 向上取整 2MB 倍數 → `MADV_COLLAPSE` 成 order-9 folio(**必須在建 udmabuf
之前**,udmabuf 會 pin 頁擋掉 collapse)→ udmabuf → dmabuf import 照舊。
free = 現行 on_vkFreeMemory:SharedMemory 銷毀 → blob unshare → memfd close
→ folio 整顆 order-9 free → gh_hugepage_reserve free hook 回收進池。

供頁迴路(現成,RingBlob 已驗證):crosvm 是 tracked gunyah-VM owner,
order-9 分配被模組攔截、從 reserve 池供給(吃 VM reserve 額度,不搶 app RAM);
order-9 free 被 hook 回收。**folio 不可拆**(不能 partial unmap/hole-punch
2MB 塊,否則 4K free 池看不到,頁流失到 owner 死亡)。

## 為什麼不是「全部擴 2MB」(user 顧慮:1000 個 8K/512K 撐不住)

guest ICD 尺寸規則(已核實 guest ResourceTracker.cpp:3200-3211):
- 非 dedicated:`max(round-1MB, 16MB)` → host 看到一律 ≥16MB 塊,folio 化零浪費。
- dedicated(BDA flag):只對齊 64KB(`kLargestPageSize`)→ 以原始尺寸抵達 host。
  這條路小分配多起來會付 2MB 稅 → **閾值擋掉**:小分配留在 4K 動態路
  (entry 本來就少:8KB=2 條、512KB≤128 條,RM 扛得住)。
- guest 空塊立即死(shared_ptr 歸零即析構)、BDA 全繞過子分配 → churn 頻率
  由 app 決定,本機制讓每筆交易乾淨化(8 條 entry/16MB,失敗不毒化),
  不是消滅 churn。若長期測試仍見 RM 退化,可在同機制上疊「免 unshare 回收
  快取」(= arena 變成可選 cache 層,和本機制不衝突)。

## Config(env,全可調)

- `GFXSTREAM_ARENA_MB`:folio 總配額(MiB,預設 1024;測試時設 = BAR 大小)。
  超額:threshold 模式降級 4K 路,strict 模式回 OOM。
- `GFXSTREAM_ARENA_THRESHOLD_KB`(預設 **1024 = 1MB**,最壞浪費率 50%,user 接受):
  - `>0`:分配 `>= threshold` → folio 背書;quota 滿/collapse 失敗 → 降級 4K 路
  - `0`:全關(現行 4K 行為)
  - `-1`:strict 全 folio;quota 滿或 collapse 失敗 → `VK_ERROR_OUT_OF_DEVICE_MEMORY`

## 改動(gfxstream repo,base 5d72b52aa)

- `host/vulkan/HostVisibleFolio.h`(新,header-only):config/fromEnv、
  `HostVisibleFolioQuota`(process-global atomic 配額)、`HostVisibleFolioCharge`
  (RAII,early-return 自動退款,`transfer()` 移交給 MemoryInfo)、
  `CollapseMemfdToFolios()`(RingBlob 配方:PMD 對齊暫時映射 + MADV_HUGEPAGE
  + memset fault-in + MADV_COLLAPSE,回傳 errno)。
- `VkDecoderGlobalState.cpp`:udmabuf 分支 alignedSize 後路由+取整+charge;
  createNoMapping 後、`handleFromSharedMemory`(udmabuf 建立)**前** collapse;
  `memoryInfo.folioBytes = folioCharge.transfer()`;
  `destroyMemoryWithExclusiveInfo` 釋放配額(涵蓋 freeMemory + device teardown)。
- `VkDecoderInternalStructs.h`:`MemoryInfo::folioBytes`。
- blob export 不受影響:crosvm 拿到的是 memfd(`STREAM_HANDLE_TYPE_MEM_SHM`),
  guest 只 map 自己的 blob size,rounded 尾巴透明。

## 驗收(user 定,2026-07-11)

llama 小模型推理(qwen2.5-1.5b)+ Minecraft OpenGL(zink) + Minecraft VK
三者運作;關閉後記憶體回收:gfxstream free → 模組 reclaim →
`gh_hugepage_reserve/parameters/pool_avail` 回升、`gunyah_share_66/outstanding`
回落。host log 觀測:`VKFOLIO:` 行(mode/collapse errno/used quota)。

## 遺留

- 遠端 Droid-VM/gfxstream `wip-3d-accel` 還停在被丟棄的 scaffold commit
  (d3d42c1),下次推送需 `--force-with-lease`(user 說先不推)。
- guest 端可選優化(後續):CoherentMemory 空塊滯留池(hysteresis)降 churn 頻率。
- strict(-1)模式是測試用;生產建議 threshold 模式。
