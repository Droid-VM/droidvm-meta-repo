# gfx 路線出貨前還差什麼

狀態:功能已達標,可靠度與回收未達標。2026-08-04。

## 0. 現況:哪些已經是有證據的

同一份建置(gfxstream `ef009ad0d` / crosvm `ac6608177` / mesa `f80a84b5c10` / guest-additions `fd9b8d0`),
在**乾淨父碟 `ubuntu-2026-kde.qcow2` 的新 overlay 上只裝兩顆 deb**:

| 項目 | 證據 |
|---|---|
| KDE 桌面透過 zink→vk→gfxstream 出圖 | VNC 截圖:桌布、面板、系統匣、時鐘 |
| X11 可用 | `xdpyinfo` rc=0(cookie 取自 kwin argv) |
| 3D 加速 | vkmark 1400–1900,裝置報 `Virtio-GPU GFXStream (Adreno 830)` |
| Minecraft 26.2 | 主選單 + 進世界算繪正常 |
| 原本的 stream 死鎖 | `SEQNO-ABORT` / `PARK-WITH-PARTIAL` 在所有量測中皆為 0 |

**所以「能不能動」已經不是問題了。** 底下全部是「能不能交到別人手上」的問題。

---

## 1. P0:擋出貨的

### 1.1 沒有可信的可靠度量測 —— 這是其他所有項目的前提

session 重啟的成功率在 **3/5 到 8/8 之間漂**,而失敗的那幾次裡:

- kwin 17 執行緒、plasmashell 12 執行緒(都健康),只有 `xdpyinfo` 回 1
- 或 ssh 整個逾時(診斷開啟時客體變慢)

也就是說**目前分不出「系統壞了」和「探針搶跑了」**。已知的三個假數據源已記錄在
`xwayland-x11-probe-traps`,但還不夠:

- [ ] 判定必須等 session 真的就緒(等 `plasmashell` 的 D-Bus 服務註冊,而不是等行程存在)
- [ ] X 探針要能區分「XWayland 還沒被 kwin 生出來」與「生出來但不回應」
- [ ] 每次判定要順便記錄 host 端的 `SEQNO-ABORT` / `PARK-WITH-PARTIAL`(已有)**和**客體端 journal 的失敗原因
- [ ] 反覆重啟會弄壞 overlay(兩次 VM 失聯後 plasmashell 就再也起不來),所以長跑測試要能自動重建乾淨 overlay

**先做這個。** 在它之前做的任何「修好了」都不可信 —— 今天就有一輪四次建置部署測量跑在過期二進位上,
數字每輪都在變,看起來完全像改動有效果(見 `devvm-push-stale-package`)。

### 1.2 teardown 的執行緒標記機制是死碼,而且「修好」它會更糟

`FrameBuffer::markProcessRenderThreadsForExit` 目前**一次都比對不中**:
`VirtioGpuFrontend::createContext` 呼叫兩次 `createGraphicsProcessResources`
(一次在 `VirtioGpuContext::Create` 內、一次在 SEQNO-FORK 區塊),各遞增一次實例編號,
所以 context 記到 N、它自己的執行緒記到 N+1。實測 `MARK-EXIT` **102 筆全部 `left alone`**。

`ea6f2b4c0` 之所以把 0/8 變成 8/8,**不是因為只標記正確的人,而是因為從此沒標記過任何人**。

拿掉重複遞增讓比對真的對上(126 筆全 `-> exit`)之後:**8/8 掉到 1/6,客體會整個失聯**。
因為 `m_shouldExit` 唯一的消費者是 VkDecoder,它的反應是放棄手上的封包、之後永遠回傳 0,
而 `RenderThread` 根本不讀這面旗子 —— 旗子沒有能力讓執行緒結束,只有能力把它卡住。

三條路,擇一:

- [ ] **(a) 給 RenderThread 一條能離開的路**:讓它在讀取迴圈裡檢查 `tInfo->m_shouldExit` 並跳出,
      然後才修重複遞增。這是唯一能讓「等舊執行緒結束再釋放資源」真正成立的做法。
- [ ] **(b) 整組刪掉**:不標記、不等待,並在註解寫清楚 render thread 是靠客體關閉 stream 結束的。
      比現況誠實,但 1.3 的窗口會一直在。
- [ ] (c) 維持現況 —— 不可接受,因為任何人「順手修好」那個重複遞增就會把可靠度打回 1/6。

細節見記憶 `gfxstream-shouldexit-is-inert-and-harmful`。

### 1.3 資源釋放不等舊 render thread

因為 1.2,`cleanupProcGLObjects` 的等待迴圈實際上立刻結束,接著就去銷毀該 puid 的資源。
今天那次 `destroyInstanceObjects` 的 SIGSEGV(fault 0x10)就是這個窗口 —— 已加守衛
(`ef009ad0d`)所以不會再崩,但順序本身仍然是鬆的。

- [ ] 1.2 選 (a) 的話這條自然解決;選 (b) 的話要逐一檢查 `cleanupProcGLObjects_locked` 和
      per-process cleanup callbacks 裡每一個「假設沒有人還在用」的地方

### 1.4 關機會漏池子記憶體(既有 task #7)

每次關機丟 1–2 頁(2–4MB),poweroff 與 sigterm 無差別,scavenger 撿回 0。
長期使用會逼使用者重開手機 —— 對「可出貨」是硬傷。設計已定案在 `plans/POOL_RECLAIM_PLAN.md`,未實作。

- [ ] 實作統一退出路徑,把池子還給模組
- [ ] 驗收:連續開關機 20 次,`served`/`pool_avail` 回到起始值

---

## 2. P1:效能

### 2.1 兩個自旋等待改成 futex/condvar

這是目前最大的一塊,而且和「KDE 只有 GNOME 一半分數」是同一個根源
(同一份 host 二進位:GNOME ~3400、KDE ~1250–1900;每次 vkmark 的長停頓 504 vs 11843)。

**host `VkDecoder` 的 seqno 等待**:前 4096 圈純自旋,每圈一個 `seq_cst` 載入
(aarch64 `LDAR`,而那條 cache line 正被另一顆核心寫),4096 圈後才 `yield()`,65536 圈後才睡 100µs。

**客體 `AddressSpaceStream::backoff`**:前 **5000 萬圈**完全不睡,之後才 `usleep(1)`,
要再五千萬圈才把睡眠加倍。這也是卡死的 XWayland 連 SIGTERM 都殺不掉的原因(沒有逾時)。

兩者等的都是「同一行程另一條執行緒即將寫入的值」——在四顆 vCPU 上自旋等鄰居產出,
是直接把產出者餓死。

- [ ] host:seqno 計數器改成 futex(或 condvar),保留短暫自旋當快路徑
- [ ] guest:backoff 的門檻從 5000 萬降到合理值,並加逾時(讓卡死的客戶端能被殺掉)
- [ ] 順手:`seqnoRepairEnabled()` 用 `std::call_once`,等於每圈多一次原子操作,提到迴圈外

### 2.2 GNOME 今天只有 3400,記憶中是 4500

25% 的落差沒有定位。可能是手機熱/DVFS 狀態,也可能是真的回歸。
**要等 1.1 有可信量測之後才值得 bisect**,否則只會得到另一組漂移的數字。

---

## 3. P2:整理與複查

- [ ] 刪死碼:`seqnoRepairEnabled` 那條(四種變體全部失敗、預設關閉),
      註解裡的四條死路移到 plans/ 保存
- [ ] 複查繼承來、從未單獨驗證的改動:turnip `b43c434e`(sparse VMA)、`bf2112ca`(KHR_display,
      當初的問題其實是 build config)、mesa `7177dd271f7`(同源)、mesa MAP_LOW 系列、
      crosvm `fa1612b9f`(blessed blob arena,在 protected Gunyah 上已證實不通)
- [ ] guest-additions deb 要重打(`fd9b8d0` 的 `droidvm_trace` module param 還沒進 deb)

### 明確延後,不在這一輪

- **virtio-snd**(MC 關閉時 OpenAL 崩潰的正解):要從 crosvm 接到 Android 的元件,
  多半得有一個專門的服務負責這件事。那是獨立的一塊工作,以後做。
- **兩份 guest mesa deb 路徑衝突**(`guest-mesa-variant-collision`):只出 gfxstream 就沒事,
  等真的要同時提供 drm2kgsl 再處理。
- **drm2kgsl 路線本身**:這一輪只做 gfx。

---

## 4. 出貨驗收條件

全部在**乾淨父碟的新 overlay + 只裝兩顆 deb** 上:

1. 連續 20 次 session 重啟,每次都拿到桌面(kwin 合成 + plasmashell 面板 + X11 客戶端可連)
2. vkmark 跑完不崩,分數穩定(`duration>=6`,暖機後三次波動 <15%)
3. Minecraft 進世界並持續算繪 10 分鐘
4. 連續開關機 20 次,池子記憶體回到起始值
5. 沒有已知會打死 VM 或手機的路徑

前四項目前都還沒有達到「連續 N 次」的證據 —— 那正是 1.1 要先做的原因。
