# 池子 v2 架構:狀態機、轉換、執行者

2026-08-07。目標是**功能幾乎不變**的重構——把已經存在的行為,
重新按「狀態機 + 邊 + 執行者」組織,讓不變式在程式碼裡看得見。

現況分析見 `POOL_STATE_MODEL.md`(五套結構、22 個手動同步點、`pool_total` 冗餘等)。
這份只寫**要變成什麼樣子**。

---

## 0. 目標與非目標

**目標**

- 四個狀態、六條邊,每條邊**恰好一個函式**負責「更新該更新的一切」
- 兩個不變式寫成程式碼,所有驅動邏輯從 deficit 出發
- 分類軸明確,新人能回答「這段該放哪」

**非目標**

- 不改回收機制(持有參照 + free hook 晚攔截)
- 不改 CMA 儲備池的物理操作
- 不追求行為完全等價——§8 列出**刻意的**行為差異,其餘一律不變

---

## 1. 狀態機

一個 2MB 頁在任一時刻恰好處於四個狀態之一。

| 狀態 | 意義 | 誰持有 |
|---|---|---|
| `served` | 借給 VM | VM(GUP pin)+ 我們一份保護參照 |
| `avail` | 在池子裡待命 | 只有我們 |
| `cma` | 在 CMA 儲備池,借給其他 app | 其他 app(可逐出) |
| `external` | 系統的 | 系統 |

**`cma_able` 是 `avail` 的屬性,不是狀態。** 它由**鄰域**決定:CMA 的 pageblock 可能
大於 2MB(`CMA_SUBBLKS = 1 << (pageblock_order - 9)`),整個 pageblock 的每個子塊
都在 `avail` 才算 `cma_able`。SUBBLKS==1 時恆為真。

```mermaid
stateDiagram-v2
    avail --> served: E1 serve
    served --> avail: E2 return
    avail --> cma: E3 flip (需 cma_able)
    cma --> avail: E4 stage-in (需逐出)
    avail --> external: E5 release
    external --> avail: E6 acquire (需無 unmovable + 逐出)
```

`served → external` **不是一條邊**:它是 E2 之後 E5 立刻發生。
今天的程式碼就是這樣寫的(hook 先 `served_del`,`pool_want` 閘門立刻推出去),v2 維持。

### 1.1 不變式

```c
static int held_pool(void)  { return avail_count() + served_count; }      /* I1 左邊 */
static int held_total(void) { return held_pool() + cma_count(); }         /* I2 左邊 */

/* I1: held_pool()  == pool_want
 * I2: held_total() == pool_want_with_cma
 * Q : 最小化 avail_partial_count()(= avail 之中 !cma_able 的部分)  */
```

三者都是**導出量**,沒有對應的儲存變數。`pool_total` 刪除(見 `POOL_STATE_MODEL.md` §3.2)。

---

## 2. 分類軸:先按執行上下文,再按邊

這是這份設計的核心判斷。三個候選軸——按狀態、按邊、按執行上下文——
**按上下文分最有價值**,因為它切出的正是「寫錯會死機」的那條線:

> **六條邊裡只有兩條踩到 atomic 上下文,其餘四條都可以睡。**

| 邊 | 觸發 | 上下文 | 執行者 |
|---|---|---|---|
| E1 serve | 被動(VM 配置 order-9) | **atomic**(kretprobe、`raw_spin_lock_irqsave`) | serve hook |
| E2 return | 主動放參照 + 被動捕獲 | 放=可睡 / **捕獲=atomic**(`__free_one_page`,持 `zone->lock`、IRQ off) | release worker + free hook |
| E3 flip | 主動 | 可睡 | reconcile worker |
| E4 stage-in | 主動 | 可睡 | reconcile worker |
| E5 release | 主動 | 可睡 | reconcile worker |
| E6 acquire | 主動 | 可睡 | reconcile worker |

於是三層:

```
第 1 層  兩個 atomic 攔截點        只做 O(1) 的搬移,不配置、不睡
第 2 層  六個邊原語               每個負責「這條邊要更新的一切」
第 3 層  reconcile worker         從 deficit 驅動,決定要走哪條邊
```

**政策全部在第 3 層,機制全部在第 2 層,第 1 層只有反射動作。**
今天的問題正是這三層混在一起——`pool_take_frozen` 既是機制又含 `pool_want` 政策閘門。

---

## 3. 第 2 層:六個邊原語

```c
/* 每個函式負責:狀態結構、cma_able 索引、參照、統計 —— 全部。
 * 呼叫者不需要知道還要更新什麼。這是今天最大的隱性知識來源。 */

struct page *edge_serve(pid_t tgid);              /* E1  atomic-safe */
bool         edge_return(struct page *p);         /* E2  atomic-safe(捕獲半) */
int          edge_flip_to_cma(int nr);            /* E3  可睡 */
int          edge_stage_in(int nr);               /* E4  可睡 */
void         edge_release(struct page *p);        /* E5  可睡 */
struct page *edge_acquire(enum acquire_means m);  /* E6  可睡 */
```

### 3.1 E2 的三個出口收斂

今天 `served` 有三個出口、三種義務、沒有共用函式——**我踩過的 bug 就是這個**
(purge 移除了 entry 卻沒交還參照,那些頁再也不可能被 free)。v2:

```c
enum served_exit {
	SERVED_RETURNED,   /* 正常歸還:移除 entry,參照由 free hook 之後的流程處理 */
	SERVED_PURGED,     /* 放棄:移除 entry + 交還參照 */
	SERVED_UNLOAD,     /* 卸載:移除 entry + 交還參照 */
};
void served_remove(unsigned long pfn, enum served_exit reason);
```

**這是唯一一項「不做也會再出事」的改動,所以排第一。**

---

## 4. 資料結構:雙堆疊同時解掉兩件事

今天 `avail` 是單一 LIFO 陣列 `page_pool[]`,而 `cma_able` 的數量是另一個
增量維護的計數器 `pb_full_avail`。v2 把 `avail` 拆成兩個堆疊:

```c
static struct page *avail_partial[POOL_SIZE_MAX];  /* !cma_able:兄弟不齊 */
static struct page *avail_full[POOL_SIZE_MAX];     /*  cma_able:整個 pageblock 都是我們的 */
```

一次解決三個問題:

1. **serve 偏好**(語意:優先挑 `cma_able==false`)= 先 pop `avail_partial`,**維持 O(1)**。
   今天是純 LIFO,這條語意根本沒實作。
2. **`cma_able` 數量不再需要獨立計數器**:就是 `avail_full` 的長度。`pb_full_avail` 刪除。
3. **SUBBLKS==1 時 `avail_partial` 恆空**,整條路退化成今天的單堆疊,零成本。

### 4.1 代價:成員身分會因兄弟而變

服務掉 X 的兄弟 Y,會讓 X 從 full 掉到 partial。所以 push/pop 時要判斷歸屬,
而判斷要查兄弟——這正是 `pb_*` 索引存在的理由。

**張力必須講明**:`POOL_STATE_MODEL.md` §3.1 建議索引改成 rebuild-on-demand,
理由是「5 個讀取點都不在熱路徑」。**加上 serve 偏好之後這個前提就不成立了**——
E1 在 atomic 上下文要知道歸屬。

**解法**:索引仍然增量維護,但**只在一個地方**——`pb_track()` 今天已經算出
full↔partial 的轉換點(`pb_full_avail++/--` 那段),v2 讓它直接做**堆疊搬移**,
而不是更新一個平行的計數器。同步點從 22 個(散在四檔)收斂成 6 個邊原語內部。

---

## 5. 第 3 層:reconcile 是一張步驟表

今天 acquire 的階段順序寫死在 `acquire_worker()` 的控制流裡,
mode 1 少跑 Phase R 這件事只存在於註解(見 §8.2)。v2 讓順序變成**資料**:

```c
enum step_goal { GOAL_POOL, GOAL_TOTAL, GOAL_QUALITY };
enum step_cost { COST_FREE, COST_CHEAP, COST_EXPENSIVE };

struct reconcile_step {
	const char     *name;
	enum step_goal  goal;      /* 這步在服務哪個不變式 */
	enum step_cost  cost;
	bool          (*run)(void);/* true = 有進展 */
	bool            needs_cma; /* 沒有 CMA 能力就跳過,而不是整條路徑消失 */
};

static const struct reconcile_step steps[] = {
  { "stage-in (total met)", GOAL_POOL,    COST_CHEAP,     step_stage_in_if_total_met, true  },
  { "pair fill",            GOAL_QUALITY, COST_CHEAP,     step_pair_fill,             true  },
  { "drop slab",            GOAL_POOL,    COST_CHEAP,     step_drop_slab,             false },
  { "harvest free",         GOAL_POOL,    COST_FREE,      step_harvest_free,          false },
  { "stage-in",             GOAL_POOL,    COST_CHEAP,     step_stage_in,              true  },
  { "sweep",                GOAL_POOL,    COST_EXPENSIVE, step_sweep,                 false },
  { "reservoir fill",       GOAL_TOTAL,   COST_EXPENSIVE, step_reservoir_fill,        true  },
  { "quality",              GOAL_QUALITY, COST_CHEAP,     step_quality,               true  },
};
```

驅動就是一個迴圈:每步先問「我的 goal 還有 deficit 嗎」,有才跑。

**這個順序與今天完全相同**(Phase S → 1.5 → 0 → 1 → S2 → 2 → R → Q),
所以功能不變;差別是順序看得見、可審、可測。

### 5.1 acquire 的「版本」只換一步

`step_sweep` 依 `acquire_mode` 選手段——**其餘七步不受影響**:

| mode | 手段 | 需要的 symbol |
|---|---|---|
| 1 | `alloc_contig_pages` 盲掃 | `alloc_contig_pages` + `prep_compound_page` |
| 2 | sweep + 系統級 reclaim(A) | `alloc_contig_range` + `prep_compound_page`(+可選 `try_to_free_mem_cgroup_pages`、`mem_cgroup_from_task`) |
| 3 | sweep + 逐塊 evict(B) | 上列 + `folio_isolate_lru` + `reclaim_pages` |

這正是「數字越大越激進、依賴 symbol 越多」的規格,而且 v2 讓它**在結構上成立**
——今天 mode 1 走的是另一條函式,所以順手掉了 Phase R(§8.2)。

---

## 6. 觸發點 → worker:五個 work 收成兩個

今天有五個:`refill_work`、`pcp_drain_work`、`reclaim_release_work`、
`acquire_work`、`vm_owner_sweep_work`,彼此的取消順序有隱性依賴
(exit 路徑那段註解就是在交代這個)。

v2 兩個,分野是**延遲要求**:

| worker | 職責 | 觸發 | 特性 |
|---|---|---|---|
| `release_worker` | E2 的放參照掃描 | unshare kprobe、VM destroy kprobe | **要快**;退避重試;不可被 reconcile 擋住 |
| `reconcile_worker` | §5 的步驟表 | sysfs 寫入、release 完成後、VM destroy | 可長跑數分鐘;可取消 |

`vm_owner_sweep` 併入 reconcile 的一步;`pcp_drain` 併入 fallback 那一步。

**取消順序的隱性依賴一併消失**:只有兩個 work,且 release 不排 reconcile 以外的東西。

---

## 7. 檔案分割

| 檔案 | 內容 | 現況 |
|---|---|---|
| `gh_state.c.inc` | 四狀態的結構、六個邊原語、不變式 | 新增(從 gh_data 抽出) |
| `gh_hooks.c.inc` | **只有兩個 atomic 攔截點** + 它們的 kprobe 註冊 | 瘦身 |
| `gh_reconcile.c.inc` | 步驟表 + 兩個 worker + acquire 手段 | 新增(從 gh_cma 抽出政策) |
| `gh_cma.c.inc` | CMA 儲備池的**物理操作**,不含政策 | 瘦身 |
| `gh_subblk.c.inc` | SUBBLKS>1 的 cma_able 機構(756 行) | 集中;SUBBLKS==1 可整檔編掉 |
| `gh_sysfs.c.inc` | 旋鈕 | 大致不變 |

分割規則一句話:**能睡的和不能睡的分開,機制和政策分開。**

---

## 8. 刻意的行為差異(其餘一律不變)

功能「幾乎」不變的那個「幾乎」在這裡。每一項都要單獨驗。

### 8.1 serve 偏好(新增)
今天純 LIFO,v2 優先服務 `!cma_able`。**效果**:cma_able 的頁被保留給 E3,
`avail_partial` 先被消耗。SUBBLKS==1 無差異。

### 8.2 mode 1 是否補上 reservoir fill(**待你決定**)
今天 `acquire_worker_v1()` 只跑 pool 迴圈,**Phase R 完全不執行**——
在 mode 1 下儲備池永遠不會被填。這不是「手段不同」,是少一整條語意。
v2 的步驟表結構上會讓 mode 1 也跑到 `reservoir fill`。
**兩個選項**:(a) 照規格補上;(b) 維持現況,但寫成 `needs_cma` 之外的顯式條件,
而不是「因為走了另一個函式所以順手沒跑」。

### 8.3 暫存塊的歸還時機(**待你決定**)
你的規格是「acquire 完成後歸還」;今天是**老化 `LIMBO_MAX_AGE = 3` 個 pass 後**才放,
可以跨 acquire 存活。改成結束即歸還**更嚴格也更好推理**(不累積、不污染下一輪判斷)。

### 8.4 暫存容量
你寫「最多 8 塊」;今天 `LIMBO_MAX = 64`,`cma_phase_q` 的 8 是**輪數**,
`cma_pair_fill` 的 budget 是 **256 子塊**。三個數字要統一成規格。

### 8.5 `pair_fill` 的執行條件(**規格與現況相反**)
你寫「前兩個滿足後」才做;今天 `cma_pair_fill()` **只在 pool 還短時跑**
(`>= pool_want` 就 break)。`cma_phase_q` 的條件則與你一致。
我認為現況合理——配對本來就是「順便挑更好的位置抓」,在補 pool 的過程中做才有意義;
但要照規格改也可以,請明示。

---

## 9. 遷移順序

每一步都要能單獨部署與回退。**不做大爆炸式重寫。**

| # | 步驟 | 風險 | 為什麼這個順序 |
|---|---|---|---|
| 1 | `served_remove(pfn, reason)` 收斂三個出口 | 低 | 唯一「不做會再出事」的 |
| 2 | 不變式四函式(純新增),呼叫端逐步搬 | 低 | 後面每一步都要用 |
| 3 | 刪 `pool_total`,resize 柵欄改顯式旗標 | 中 | 依賴 2 |
| 4 | `avail` 拆雙堆疊 + serve 偏好 | 中 | 一併消掉 `pb_full_avail` |
| 5 | 六個邊原語,同步點收進去 | 中高 | 依賴 4 |
| 6 | 步驟表 + 兩個 worker | 中高 | 依賴 5;§8.2 在這裡定案 |
| 7 | 檔案分割 | 低(純搬移) | 最後做,避免搬到一半又改內容 |

**驗證**:每步都跑 `POOL_RECLAIM_PLAN.md` 的那組——boot → grow → shrink → stop,
`fallback_sweep=0`,看 `del_hit == released_idle`、`deficit` 歸零、兜底 0 次。
步驟 4 之後要另外驗 serve 偏好(SUBBLKS==1 上看不出來,需要人造 SUBBLKS>1 的環境)。

### 不要動的部分

- free hook 在 `__free_one_page` **晚攔截**:頁必須走完 `free_pages_prepare`
- **借出時持有參照**:這是 100% 回收的機制本身
- 配置側 kretprobe:發頁的必要手段,沒有替代品
