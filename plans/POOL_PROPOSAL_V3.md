# v3 提案:一個採集器,風險由兩個參數界定

2026-08-08。整合五狀態模型(`POOL_STATE_MODEL.md` §0b)與
「`refill_alloc` 其實是 acquire 的一個組態」這個觀察。

---

## 1. 起點:一個矛盾

`pool_total` 的意義是**背景可以瞄準的天花板**,存在理由是「模組不准自作主張把系統推到記憶體不足」
(見 `POOL_STATE_MODEL.md` §3.2)。

但實際上背景那條路徑用的是:

```c
alloc_pages(GFP_KERNEL | __GFP_COMP | __GFP_NOWARN | __GFP_RETRY_MAYFAIL, 9)
```

`GFP_KERNEL` 允許 direct reclaim,`__GFP_RETRY_MAYFAIL` 在 order-9 上會拉起 compaction。
**背景補充會回收使用者的 page cache、會做記憶體壓縮。**

天花板限制了**拿多少**,完全沒有限制**拿多兇**。設計意圖與實作在這裡分岔,
而且分岔的方式沒有任何症狀——池子補滿了,看起來一切正常。

---

## 2. 提案核心:採集只有一個,由 ctx 界定

`refill_alloc` 與 `acquire` 是同一件事(external→avail),差別可以完全參數化:

```c
struct gather_ctx {
	int  ceiling;      /* 拿到多少為止 */
	int  max_means;    /* 可以拿多兇 */
	bool may_promote;  /* 成功後可否抬高 pool_total */
};

static const struct gather_ctx BACKGROUND = {
	.ceiling     = pool_total,        /* 已證明安全的量 */
	.max_means   = MEANS_ALLOC_CHEAP, /* 只撿現成的,不回收、不壓縮 */
	.may_promote = false,             /* 背景不能自己提高天花板 */
};

static struct gather_ctx user_run = {
	.ceiling     = pool_want,         /* 使用者要的量 */
	.max_means   = <使用者選的 0..3>,  /* 使用者授權的兇度 */
	.may_promote = true,              /* 成功 = 證明安全,天花板跟著抬 */
};
```

**風險歸屬因此變成兩個被強制執行的參數,而不是一個數字加一句註解。**

| | 拿多少 | 拿多兇 | 可否抬高天花板 |
|---|---|---|---|
| 背景 | `pool_total` | **只撿現成** | 否 |
| 使用者 | `pool_want` | 使用者授權的等級 | 是 |

`may_promote` 取代了今天「`pool_push_grow` 只給 acquire 用」這條**靠註解維持**的規則。

### 手段等級要重新定義

```c
MEANS_ALLOC_CHEAP  alloc_pages(GFP_NOWAIT | __GFP_NOWARN | __GFP_COMP)
                   撿現成的 order-9;不回收、不壓縮、不阻塞。背景唯一可用。
MEANS_ALLOC        alloc_pages(GFP_KERNEL | __GFP_RETRY_MAYFAIL)  今天 refill 的行為
MEANS_CONTIG_ANY   alloc_contig_pages           隨緣,拿不到指定位置
MEANS_CONTIG_AT    alloc_contig_range           可指定
MEANS_CONTIG_EVICT 同上 + 逐塊 evict
```

**今天的背景行為 = `MEANS_ALLOC`,提案把它降到 `MEANS_ALLOC_CHEAP`。**
這是行為變更,而且是把實作拉回設計意圖,不是相反。
代價:背景補得比較慢、碎片化時補不滿。那正是「要更多就自己按」的意思。

---

## 3. 五狀態帶來的第二個修正:`released` 要有查詢與逾時

五狀態模型指出 served 與 avail 之間有一個真實狀態(已放手、去向未定),
它的居民數今天只能手算:

```
in_flight = released_idle − (in_hook + in_sweep)
```

提案:**做成一級查詢** `pool_in_flight()`。三個直接後果:

1. `reconcile_worker` 開頭的「歸還做完了沒」不必猜延遲,直接問。
2. **purge 就是這個狀態的逾時**——`RECONCILE_GRACE_MS` 是 `released` 的存活上限。
   這樣命名之後它是明顯正確的,而不是一個看起來像啟發式的數字。
3. `released → external` 的流量變成可讀的量,而不是要對三個計數器做減法才看得出來
   (那個減法今天讓「差 2」被誤讀成不變式被破壞,追了一整天)。

---

## 4. 收斂之後的 worker

**兩個,而且職責用一句話講得完:**

```
release_worker    把已閒置的借出頁放手     要快;退避重試;只重排自己
gather_worker     照 ctx 採集 + 收尾       可長跑;可取消;只重排自己
```

`refill_work`、`pcp_drain_work`、`acquire_work`、`vm_owner_sweep_work` 全部消失:

| 今天 | 去處 |
|---|---|
| `refill_work` | `gather_worker(BACKGROUND)` |
| `acquire_work` | `gather_worker(user_run)` |
| `pcp_drain_work` 的前半(放參照) | `release_worker` |
| `pcp_drain_work` 的後半(兜底掃描) | gather 步驟表的一步 |
| `vm_owner_sweep_work` | gather 步驟表的一步 |
| `refill_delay_ms` 計時器 | 步驟的前置條件(`vm_owner_gone()`),不是計時器 |

觸發:

```
VM 關機 / unshare  →  arm(release);  arm(gather, BACKGROUND)
pool_want   調小   →  arm(gather, BACKGROUND)      只縮,不採集
pool_want   調大   →  只記錄
acquire = m        →  arm(gather, user_run(m))
```

---

## 5. 這個方案消掉的東西

| 消掉 | 原因 |
|---|---|
| 「背景不會壓迫系統」是**願望** | 變成 `max_means` 強制執行 |
| 「`pool_push_grow` 只給 acquire」靠註解 | 變成 `may_promote` 參數 |
| 四個 work 的取消順序 | 剩兩個,且永不互相排程 |
| `refill_delay_ms` 這個猜出來的數字 | 變成前置條件 |
| `RECONCILE_GRACE_MS` 像啟發式 | 正名為 `released` 狀態的逾時 |
| 「差 2」這種要手算三個計數器的量 | `pool_in_flight()` |

---

## 6. 風險與未決

- **`MEANS_ALLOC_CHEAP` 會讓背景補不滿。** 這是刻意的,但要先量:
  現在背景每輪補幾頁(`in_refill`),換成不回收之後補幾頁。差多少決定使用者多久要按一次。
- **`pool_in_flight()` 要能分辨「還在路上」與「已經丟了」。** 前者會自己消失,後者要等 purge。
  可能需要進入該狀態的時間戳,而不是只有計數。
- 命名:`released` / `handover` / `ext_served_before` 未定。
