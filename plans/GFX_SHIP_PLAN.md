# gfx 路線出貨前還差什麼

狀態:**五項驗收條件全部滿足**。最後一項(池子回收)於 2026-08-07 由「借出時持有參照」補上,
在兜底掃描關閉的條件下量到零損失。2026-08-07。

這份文件在 2026-08-04 寫成時列了四個 P0。三個關掉了;第四個(池子回收)**量出來仍然存在**,
但原本計畫的解法被證據推翻,改由 `POOL_HANDOFF_SURVEY.md` 接手。
保留那些條目的來龍去脈,因為「為什麼不做」和「怎麼做」一樣需要交代。

---

## 0. 現況:哪些是有證據的

同一份建置(crosvm `d5dcfd317` / gfxstream `e9a6bd75b` / mesa `cea499343cf` /
guest-additions `fc5d9d0`),在**乾淨父碟的新 overlay 上只裝兩顆 deb**:

| 項目 | 證據 |
|---|---|
| 兩顆 deb 安裝 | `apt-get install`,**不帶任何旗標**,得到 `2 upgraded` |
| KDE 桌面透過 zink→vk→gfxstream 出圖 | 截圖:桌布、面板、系統匣、時鐘;連續 6 次 session 重啟 **6/6**,stalls=0 |
| X11 可用 | `xdpyinfo` rc=0(cookie 取自 kwin argv);KDE on X11 全通,零 llvmpipe |
| 3D 加速 | vkmark **7012–13977**(七輪,crosvm 全程存活,零守衛開火) |
| Minecraft 26.2 | 進世界持續算繪 5 分鐘以上;`zink Vulkan 1.3(Virtio-GPU GFXStream (Adreno (TM) 830 ()) (MESA_TURNIP))` |
| 池子記憶體 | 六次生命週期各借出 2850 頁,回收率 **99.95%**(每輪丟 1.33 頁,見 1.4) |
| 手機負載 | MC 全速時 `user=149 sys=319 irq=16 timer=1878` = 真工作;21.3 小時取樣零空轉簽名 |

vkmark 的跨度很大是 GPU DVFS,不是不穩定——見 [`vkmark-duration-artifact`] 記憶,
**單次結果沒有意義**。

---

## 1. 原本的四個 P0,現在的狀態

### 1.1 沒有可信的可靠度量測 — **已解**

`gfxcheck.sh` 對一個 session 給單一判定(desktop / no-compositor / no-shell / x-wedged /
x-never-started / unreachable),`gfxrun.sh N` 跑 N 輪並統計。關鍵設計:

- 判定等 kwin 與 plasmashell 都在 D-Bus 上**註冊好名字**,不是等行程存在
- 每輪在 golden image 的**拋棄式 overlay** 上(反覆重啟會弄壞客體,之後量到的都是關於那顆碟)
- 手機負載看門狗:沉澱 60 秒再取樣,連兩輪 ≥90% 就停,不把手機逼到要重開
- 開跑前檢查 tap 在不在 bridge 上(手機重開後不會自動接回,會讓好好的桌面被判成 boot failed)

實測:2026-08-05 **20/20**,2026-08-06 **6/6**。

### 1.2 teardown 的執行緒標記機制 — **已解,走 (b)**

真兇不是標記機制本身,是 **puid 重用**:host 拿可重用的 virtio context id 當行程身分,
舊行程的非同步 teardown 把新行程**活著的** render thread 標成 exit
(見 [`gfxstream-puid-reuse-teardown-hang`])。

當初列的三條路裡選了 **(b)**:`markProcessRenderThreadsForExit` 只**回報**還在跑的執行緒,
不設 `m_shouldExit`,等待迴圈也移除。理由寫在該函式的註解裡,連同三種設定的實測數字
(20/20、1/6、0/6)——因為那面旗子沒有能力讓執行緒結束,只有能力把它卡住,
任何人「順手修好」比對邏輯都會把可靠度打回 1/6。

### 1.3 資源釋放不等舊 render thread — **守衛在,未再重現**

`destroyInstanceObjects` 的 SIGSEGV(fault 0x10)已加守衛。2026-08-06 連跑七輪 vkmark
(它在 vkmark 結束時觸發過一次)**沒有重現**,crosvm 全程存活、零 `GUARD-FIRED`。
順序本身仍然是鬆的,但沒有證據說它還會咬人。追蹤在 [`gfxstream-destroyinstance-segv`]。

### 1.4 關機會漏池子記憶體 — **2026-08-07 已解;以下保留當時的誤判過程**

解法是模組在借出 order-9 頁時持有一個自己的參照,直到那一頁閒置才放手,
於是頁面在「被歸還」到「被 hook 認領」之間不可能被拆散——不再需要偵測碎片化,因為它不發生。
設計、三條反轉的否決理由與驗收數字見 `POOL_RECLAIM_PLAN.md` §2b。
下面這段是解決之前的量測與誤判,保留是因為「三輪量到 0」這個陷阱很容易再踩一次。

原本的計畫是用 donate ioctl 取代模組的全系統 free hook。先複驗基準,結果分兩段——
先是三輪量到 0:

```
baseline (no VM): deficit=2  orphan_inuse=2
cycle 1/2/3:      deficit 2 -> 2   每輪借出 2850 頁,lost 0
final: deficit=2 avail=3070/3072
```

`deficit = total_served - total_refilled`,在全機無 VM 時讀。那個 2 是開始前就存在的
`orphan_inuse`(區塊已被別人占住,撿不回來),三輪都沒增加。

**但不要把這讀成「漏損已修好」。** 我一度歸因給模組的 `abb6157`——**那是錯的**,
它是 2026-07-16,在 07-30 那份基準**之前**,而模組從那天起就沒再改過。所以漏損機制
(order-9 free 停在 THP pcp list,而 hook 掛在 pcp 下游的 `__free_one_page`)原封不動還在,
模組的補救仍然是 destroy 後 `PCP_DRAIN_DELAY_MS` 的 `drain_all_pages` +
`served_reacquire_free_orphans()`。今天量到 0 只代表**這個配置、這幾輪,drain 每次都趕上了**。

**六輪複驗(同日稍後)推翻了那三輪**:`0, 2, 2, 2, 2, 0`,合計 8 頁,**1.33 頁/輪、
回收率 99.95%**,與 07-30 基準一致,而且 `drain recovered=0`。三輪不足以下結論。

donate ioctl 仍然不該做(理由見 `POOL_RECLAIM_PLAN.md` §1 的五條)。
完整的取捨、成本帳與唯一值得投入的方向見 **`POOL_HANDOFF_SURVEY.md`**。

範圍聲明:只量**優雅關機**路徑(`crosvm stop`)。SIGKILL 沒測也不會測——它漏的是 memparcel,
要手機重開才回來,那是另一個問題(見 [`gunyah-kill9-leaks-memparcels`])。
量測腳本 `poolcycle.sh`;舊的 `deploy/gfxstream/pool_leak_rate.sh` 依賴手機上一套已不存在的部署。

---

## 2. 效能:結論沒變

真正值錢的只有 **ring consumer 的退避階梯**(`271456d3f`,預設 `3000:0`)。
它在閒置 KDE 桌面上造成過每秒 28.9 萬次計時器中斷、手機 100% 忙碌,並把 vkmark 從 3632 壓到 1643。

其餘的自旋等待**在正常運作下根本不熱**,改了都是中性的:

- host seqno 的 100µs sleep 尾巴改 futex(`e9a6bd75b`):一次 vkmark 有 1626 次等待撞到
  4096 圈但**一次都沒到 8192**,尾巴走不到。裝置實測 futex 往返 8.4µs vs 自旋觀察 52ns
  (160 倍)——**不要把自旋本身換成 futex**。
- guest `backoff` 門檻 5000 萬 → 2 萬(`cea499343cf`):交錯 A/B 8793 vs 9219,雜訊內。

**下次要動等待迴圈之前,先量它在真實負載下有沒有被走到。**

「GNOME 只有 3400、記憶中 4500」那條**已經沒有缺口可解釋**:今天同一條路線量到 7012–13977。

---

## 3. 這一輪最後補上的兩件

### 3.1 游標座標(crosvm `c1e733604`、`d5dcfd317`)

virtio-gpu 的 `pos` 是**游標圖案左上角、客體已扣過 hotspot、而且有號**。實測:
指標 (700,400) 配 hot=(22,21) 到達主機是 (678,379);指標 x=2 到達是 -3。

兩個後端各讀錯一半:VNC 橋接把它當指標又扣一次 hotspot(往左上偏一整個 hotspot,
`<->` 上是 22px);全部當無號讀則讓貼左/上緣的座標變成約 4.29e9,而 `-1 == u32::MAX`
正好是 Android 後端的隱藏哨兵。

驗證用**不共用這個 bug 的參考**:LibVNCServer 畫在 `cursorX - xhot`,
抓一張宣告 RichCursor 偽編碼的(只有我們的)、一張沒宣告的(我們的＋它的),相減 **0 像素**。

**未驗證**:native(app UI)那條路徑需要 app 介面與實體滑鼠,從開發迴圈碰不到。
那邊的修法是把負座標夾在 0,所以游標會在離左/上緣一個 hotspot 處停住、不會再消失;
要做到正確裁切得動 app 那側的 `set_android_surface_position`(FFI 吃 u32,屬於 app)。

### 3.2 套件版本可排序(meta `1abda84`、guest-additions `fc5d9d0`)

版本尾巴原本是純雜湊,而雜湊不排序:`cea49934` 在 dpkg 眼中小於 `f80a84b5`,
所以升級要 `--allow-downgrades`,而 `apt upgrade` 會安靜地留著舊的。

改成 `+droidvm.r<commit數>.g<sha>`,髒樹再加時戳。**前面那個 `r` 不是裝飾**——
雜湊是十六進位、開頭最多到 `f`,要一個排在它後面的字母才能讓**換方案本身**也算升級。
客體上裝的正是最壞情況(兩顆都以 `f` 開頭),實測 `2 upgraded`,一個旗標都不用。

三顆出貨產物現在格式一致:
```
droidvm-guest-additions_1.0+droidvm.r23.gfc5d9d07
mesa-guest-gfxstream_26.0.3+droidvm.r217837.gcea49934
mesa-guest-drm2kgsl_26.3.0-devel+droidvm.r226620.g61624f40
```

---

## 4. 明確延後,不在這一輪

- **virtio-snd**(MC 關閉時 OpenAL 崩潰的正解):要從 crosvm 接到 Android 元件,
  多半得有一個專門的服務負責這件事。獨立的一塊工作。
- **兩份 guest mesa deb 路徑衝突**([`guest-mesa-variant-collision`]):只出 gfxstream 就沒事。
  兩個 package 已經互相 Conflicts,所以 dpkg 會擋下第二次安裝而不是靜默覆蓋。
- **native 游標路徑的正確裁切**:需要 app 側改動,見 3.1。

---

## 5. 出貨驗收條件 — 全部滿足

全部在**乾淨父碟的新 overlay + 只裝兩顆 deb** 上:

| # | 條件 | 結果 |
|---|---|---|
| 1 | 連續 N 次 session 重啟都拿到桌面 | 20/20(08-05)、6/6(08-06) |
| 2 | vkmark 跑完不崩 | 七輪全過,crosvm 存活,零守衛開火 |
| 3 | Minecraft 進世界並持續算繪 | 9 分鐘(08-05)、5 分鐘(08-06),退出後桌面完好 |
| 4 | 開關機後池子記憶體回到起始值 | **已滿足(2026-08-07)**:借出時持有參照,四輪 8484 頁全數對帳歸位,且在**兜底掃描關閉**下成立。見 `POOL_RECLAIM_PLAN.md` §2b 驗收 |
| 5 | 沒有已知會打死 VM 或手機的路徑 | 21.3 小時取樣零空轉簽名;唯一已知禁忌是 `kill -9 crosvm` |

第 5 條的但書:**絕不 `kill -9` crosvm**——洩漏的 memparcel 到手機重開才會回來,
而且會偽裝成「並發上限」的假象。正確關法是客體 `poweroff` 或 `crosvm stop`。
