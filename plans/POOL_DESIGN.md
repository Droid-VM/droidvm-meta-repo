# 大頁池:設計

2026-08-08。**這是現行設計的單一來源。** 取代散在
`POOL_STATE_MODEL.md` / `POOL_ARCH_V2.md` / `POOL_OBJECT_API.md` / `POOL_PROPOSAL_V3.md`
的片段(那幾份保留為推導過程與被推翻的方案紀錄)。

一句話:**從系統取得 2MB 連續頁的監護權,在「借給 VM」「留著待命」「借給其他 app」
「還給系統」之間搬移,並且每一步都要能說出這一頁現在算誰的。**

---

## 1. 狀態

| 狀態 | 意義 | 誰持有 |
|---|---|---|
| `served` | 借給 VM | VM 的 GUP pin + 我們一份保護參照 |
| **`released`** | **已放手,去向未定** | 沒有人;正走在 free 路徑上或已落入 buddy |
| `avail` | 池中待命 | 只有我們 |
| `cma` | CMA 儲備池,借給其他 app | 其他 app(可逐出) |
| `external` | 系統的,我們已放棄 | 系統 |

### 1.1 為什麼需要 `released`

**Linux 沒有 served→avail 這條路。** 歸還的實作是「放掉 → 撈回」:
放掉最後一份參照後,頁走**完整的一般 free 路徑**(`free_pages_prepare` 拆 compound、
清 flags、memcg 結算),我們的 tracepoint 只在 `__free_one_page` 併入 buddy **之前**
有一次機會攔截。攔不到就真的進 buddy 了。

所以中間必然存在一個「已放手、還沒定案」的狀態。少了它,
`released_idle`(離開 served)與 `in_hook`(到達 avail)的差就會被誤讀成不變式被破壞
——那個誤讀在 2026-08-08 之前耗掉一整天。

### 1.2 `cma_able` 是 `avail` 的屬性,不是狀態

一頁能否翻進 CMA 取決於**鄰居**:CMA pageblock 可能大於 2MB
(`CMA_SUBBLKS = 1 << (pageblock_order - 9)`),整塊的每個子塊都在 `avail` 才算數。
`SUBBLKS == 1` 時恆真,整條相關路徑退化成不存在。

### 1.3 不變式

```
I1  held()      == pool_want              held()     = avail + served
I2  held_all()  == pool_want_with_cma     held_all() = held() + cma
Q   最小化 avail 之中 !cma_able
G   任一 pfn 恰好處於五狀態之一
```

**全部導出,不設對應的儲存變數。** 同一個事實存兩份遲早分歧
——今天唯一的例外 `pool_total` 不是 I1 的快取,是另一個量(見 §2.3)。

---

## 2. 轉換

```
                  ┌────────────┐
      E1 serve    │   served   │
   ┌─────────────▶│            │
   │              └──────┬─────┘
   │                     │ E2 release        放掉最後一份參照
   │                     ▼
   │             ┌──────────────┐
   │             │   released   │  已放手,去向未定
   │             └──┬────┬───┬──┘
   │      E3a hook  │    │   │ 沒人接到 → 逾時後 purge
   │      (依身分)   │    │   └──────────────────────┐
   │  ┌─────────────┘    │ E3b sweep                │
   │  │                  │ (依位址,best-effort)      ▼
   │  ▼                  ▼                      ┌──────────┐
   │ ┌──────────────────────┐   E5 to_ext       │ external │
   └─┤        avail         ├──────────────────▶│          │
     │  屬性 cma_able        │◀──────────────────┤          │
     └────┬─────────────▲───┘   E6 from_ext     └──────────┘
   E4a to_cma │         │ E4b from_cma
              ▼         │
          ┌───────────────┐
          │      cma      │
          └───────────────┘
```

| 邊 | 前置條件 | 失效時 |
|---|---|---|
| E1 serve | 有 avail;能記錄歸屬 | 記不下 → **拒絕服務**(寧可池子短,不可有追蹤不到的借出) |
| E2 release | refcount 只剩我們 且 `!mapping` 且 **free hook 掛著** | 否 → 保持 served,下輪再看 |
| E3a hook | 攔到的 order-9 free 的 pfn 在 served 表中 | 沒攔到 → 留在 released |
| E3b sweep | 該窗口整塊讀為 free | 失敗 → 留在 released |
| E4a to_cma | `cma_able` | 否 → 跳過該頁 |
| E4b from_cma | 逐出借用者成功 | 失敗 → 留在 cma |
| E5 to_ext | — | — |
| E6 from_ext | 依 means;整塊無 unmovable + 逐出成功 | 失敗 → 換一塊;連續失敗達門檻 → 本輪放棄 |
| released→external | `released` 逾時(即 purge) | — |

**貫穿原則:失效一律是「停在來源狀態」。**
「離開來源但沒到達目標」是唯一會真正遺失頁的形狀,今天踩過一次,代價是重開機。

### 2.1 E1 的挑選、E4a/E5 的挑選

排序後 `!cma_able` 在**頂端**,同塊 pfn **相鄰**:

- **E1 serve / E5 to_ext 從頂端取** —— 先用掉/丟掉本來就不能翻的
- **E4a to_cma 從底端取** —— 那裡才是 `cma_able`

同塊相鄰讓 serve 一次吃掉整塊,而不是每塊咬一口把全部弄殘
(實測:借出 2049 頁,殘缺塊始終只有 1–2 個)。

### 2.2 縮小的去向由不變式決定

```
pool_want 調小,pool_want_with_cma 不變
    I1 必須降、I2 必須不變  ⇒  avail → cma        (監護權換形式,不放走)
    CMA 未啟用/無處可去      ⇒  avail → ext

pool_want_with_cma 調小
    I2 必須降               ⇒  cma → avail 後 avail → ext
                               (不走 cma→ext 直達:avail 是樞紐)
```

### 2.3 三個量,不要混

| 量 | 意義 | 誰瞄準它 |
|---|---|---|
| `pool_want` | 使用者要的量 | 使用者按 acquire 時 |
| `pool_total` | **已證明安全的天花板**(帶遲滯) | **背景**採集 |
| `held()` | 實際持有 | — |

`pool_total` **不可導出**:背景停在 `held() >= pool_total`,導出化會讓它恆真、
背景永不執行且無錯誤訊息。它由**使用者觸發的成功**抬高——那就是「已證明安全」的意思。

---

## 3. 分層

**六條邊只有兩條踩 atomic 上下文**,這條線決定架構:

```
第 1 層  兩個反射動作      O(1)、不配置、不睡
第 2 層  邊原語            每個負責「這條邊要更新的一切」
第 3 層  gather 步驟表     從 deficit 驅動,決定走哪條邊
```

政策全在第 3 層,機制全在第 2 層,第 1 層只有反射。

---

## 4. pool 物件的方法

### 4.1 查詢

```c
int  pool_avail_count(void);
int  pool_served_count(void);
int  pool_in_flight(void);       /* released 狀態的居民:放手了、還沒定案 */
int  pool_held(void);            /* I1 左邊 */
int  pool_held_all(void);        /* I2 左邊 */
int  pool_cma_able_count(void);  /* Q 的分子;SUBBLKS==1 時 == avail_count */
int  pool_intake_room(int ceiling); /* ceiling + slack() - held(),可為負 */
bool pool_is_sorted(void);
```

`pool_in_flight()` 取代今天要對三個計數器做減法才看得出來的量。
`pool_intake_room()` 取代今天四份各自演化的 `held() >= want`(其中三份是死碼)。

### 4.2 邊

```c
struct page *pool_to_served(pid_t tgid);            /* E1  atomic-safe */
bool         pool_release(struct page *pg);          /* E2  可睡(put_page) */
bool         pool_catch(struct page *pg, origin_t o);/* E3a/E3b  atomic-safe */
int          pool_to_cma(int nr);                    /* E4a */
int          pool_from_cma(int nr);                  /* E4b */
int          pool_to_ext(int nr);                    /* E5 */
int          pool_from_ext(means_t m, origin_t o, unsigned long at); /* E6 */
void         pool_purge_expired(void);               /* released → external,逾時承認 */
```

**`origin` 是參數而不是多個函式**:今天五種來源各自 `atomic_inc`,
結果 `total_refilled` 混成一個分不出東西的數,並且讓一次讀數被誤判。

```c
enum origin { ORIGIN_HOOK, ORIGIN_SWEEP, ORIGIN_CMA, ORIGIN_USER, ORIGIN_BACKGROUND };
```

### 4.3 手段(E6)

```c
/* 現行的五級,原樣保留。不新增更弱的一級——保留現行行為。 */
enum means {
	MEANS_ALLOC_LIGHT,   /* alloc_pages(GFP_KERNEL|__GFP_NORETRY):輕度;今天 grab_free(false) */
	MEANS_ALLOC,         /* alloc_pages(GFP_KERNEL|__GFP_RETRY_MAYFAIL):會回收+壓縮;
	                      * 今天 prefill / refill / grab_free(true) 都用這個 */
	MEANS_CONTIG_ANY,    /* alloc_contig_pages:隨緣,拿不到指定位置;今天 acquire 1 */
	MEANS_CONTIG_AT,     /* alloc_contig_range + 系統級 reclaim;今天 acquire 2 */
	MEANS_CONTIG_EVICT,  /* 同上 + 逐塊 evict;今天 acquire 3 */
};

struct means_desc {
	const char        *name;
	bool               can_target;   /* 前三個為 false */
	const struct kcap *caps;         /* 載入時解析;缺 → 此手段停用 */
};
```

`can_target` 是**手段宣告的屬性**,不是獨立程式碼路徑
——「優先掃描不完整塊附近」的那兩步靠它自動跳過。
今天 acquire 1 走獨立函式,於是順手漏掉了整條 reservoir fill。

### 4.4 批次(ABA 的結構性修法)

```c
struct pool_snapshot { unsigned int gen; int n; struct page **pages; };

bool pool_snapshot_take(struct pool_snapshot *s);    /* 發憑證,含世代 */
bool pool_snapshot_commit(struct pool_snapshot *s);  /* 只吃自己發的憑證 */
int  pool_for_each_chunk(int (*fn)(struct page **, int, void *), void *arg);
```

世代驗證在物件裡。今天的 ABA 就是呼叫者自己想了一個「比較 `pool_count`」的驗證
——而那正是最容易回到自己的值。

### 4.5 除錯

```c
bool pool_check(void);   /* debug=1:驗 G 與 I1;破了就印 */
```

驗:走訪計數與 `avail_count + served_count` 相符、沒有 pfn 同時在兩個狀態、
`cma_able_count <= avail_count`、`pool_gen` 單調。
**方法表管已知的邊,`pool_check()` 抓想不到的。**

### 4.6 上下文契約

| 方法 | 上下文 |
|---|---|
| `pool_to_served` | **atomic**(配置 kretprobe) |
| `pool_catch` | **atomic**(`__free_one_page`,持 zone lock、IRQ off) |
| 其餘 | 可睡(worker) |

物件內部持 `pool_lock`;**任何可能睡的事(`put_page`/`alloc`/`__free_pages`)
一律在鎖外**,由方法自己安排,不是呼叫者。

---

## 5. 觸發

### 5.1 hook —— 一條或零條

```c
/* 配置側 kretprobe:entry 只過濾,ret 才動 pool */
entry_handler(regs):
	if arg_order != PAGE_ORDER          return SKIP
	if pool_avail_count() == 0          return SKIP
	if !vm_owner_contains(current->mm)  return SKIP
	if !(arg_gfp & __GFP_MOVABLE)       return SKIP   /* 只服務會還回來的配置路線 */
	return TAKE

ret_handler(regs):
	pg = pool_to_served(current->tgid)                 /* 唯一碰 pool 的呼叫 */
	if pg  set_return_value(regs, pg)

/* 釋放側 vendor tracepoint:atomic,持 zone->lock、IRQ off */
free_one_page_cb(page, order, *bypass):
	if order != PAGE_ORDER              return         /* 全系統快路徑閘門 */
	if pool_in_flight() == 0            return
	*bypass = pool_catch(page, ORIGIN_HOOK)            /* 閘門與統計都在裡面 */

/* 這兩個不碰 pool */
vm_destroy_pre(regs):
	vm_owner_note_gone(current->mm)
	arm(release_worker, 0)
	arm(gather_worker,  SETTLE_MS)

mem_reclaim_pre(regs):                                  /* runtime unshare */
	if pool_served_count() == 0         return
	arm(release_worker, RELEASE_FIRST_MS)
	arm(gather_worker,  SETTLE_MS)
```

**hook 不排 hook,不做政策判斷。** 今天的 free hook 在 IRQ 關閉下做了
`pool_want` 閘門與統計歸類,那些搬進 `pool_catch()`。

### 5.2 sysfs write —— 縮小即動,放大等使用者

```c
write pool_want = N:
	old = want;  want = clamp(N, 0, size_max)
	if N < old   arm(gather_worker, 0)        /* 還記憶體:即時 */
	/* N > old:只記錄。要人按 acquire。 */

write pool_want_with_cma = N:
	old = want_all;  want_all = clamp(N)
	if N < old   arm(gather_worker, 0)
	/* 同上 */

write acquire = m (1..N):
	if !means_usable(m)                                return -ENOSYS
	if !any_deficit(user_ctx(m))                       { stop="already at target"; return 0 }
	gather_ctx = user_ctx(m);  gathering = true
	arm(gather_worker, 0);     return 0                /* 一個迴圈都不跑,立刻返回 */

write acquire = 0:
	gathering = false                                  /* gather 下一輪自己停 */

write reclaim_enable = 0/1:
	attach/detach free hook                            /* E2 據此決定能不能交接 */
```

### 5.3 insmod 的首次取得是同一條邊

今天 `module_init` 裡是這樣:

```c
for (i = 0; i < pool_want; i++) {
	page_pool[i] = alloc_pages(GFP_KERNEL|__GFP_COMP|__GFP_NOWARN|__GFP_RETRY_MAYFAIL, 9);
	if (!page_pool[i]) break;
	if ((i + 1) % 50 == 0) cond_resched();
}
```

**同步、沒有 worker、有 loop、用的是 `MEANS_ALLOC`(會回收+壓縮)。**
也就是說 prefill / refill / acquire 是同一條邊的三個呼叫者,各寫一份。

v3 之後它就是:

```c
gather_sync(&(struct gather_ctx){ pool_want, MEANS_ALLOC, .may_promote = true });
```

開機用 `MEANS_ALLOC` 而不是 cheap 版是**對的**:那是這台機器一輩子記憶體最乾淨的時刻,
而且 insmod 參數本身就是使用者授權。`may_promote = true` 讓拿到多少就成為背景的天花板
——這正是 `pool_total = i` 那一行今天在做的事,只是換成參數表達。

### 5.4 清 cache:只丟 slab,不丟 page cache

現行 acquire 的 Phase 0 已經在做這件事,而它的理由比「清 cache 提高成功率」精確:

> drop reclaimable slab (dentry/inode) once. **That slab is not on the LRU so no acquire
> path can reclaim it**, yet a single dentry page poisons a whole window.

**只丟 slab 是刻意的,不是做不到別的:**

| | 在 LRU 上? | acquire 碰得到嗎 | 該不該先丟 |
|---|---|---|---|
| dentry/inode slab | **否** | **碰不到**——遷移與回收都走 LRU | **要**,否則一個 dentry 頁永久毒化整個 2MB 窗口 |
| page cache | 是 | 碰得到,可以**搬走**而不是丟掉 | **不要**——先丟等於把遷移能保住的東西白扔 |

所以 `echo 3 > drop_caches` 的兩半裡,模組只需要 slab 那一半。
我先前寫成「清整個 cache」是錯的,已改。

定位仍照使用者的決定:

- **背景永遠不做**。丟掉使用者的 dentry/inode cache 是全系統可感的代價,
  背景採集的存在前提就是不自作主張。
- **只在使用者按 acquire 時**——那一下就是授權。
- **在 worker 裡,不在寫入路徑**;觸發點只記錄意圖然後返回。
- **仍有欠債才做**(今天也是這樣 gate 的:「Skipped when Phase S already met the target」)。

---

**縮小即動、放大不動**把風險歸屬變成明文:背景永遠只維持 `pool_total`,
擴張一律要人按。調大目標值不會讓模組自己去要記憶體。

---

## 6. worker

**只有兩個,分野是延遲要求。永不互相排程,只能重排自己。**

**兩個 worker 共用方法,但不互相排程。** `pool_release_idle()` 是 pool 的方法,
兩邊都能呼叫,靠方法內的 mutex 互斥:

- `release_worker` 存在的理由是**延遲**——unshare/關機要快回應,不能排在長跑的採集後面。
- `gather_worker` 把它當**第一步**,因為縮小目標值時應該先收回「VM 已用完、我們還沒掃到」
  的頁,再決定要丟什麼;否則會先排掉 avail、那些頁稍後才回來、可能又超過新目標再排一次。

這也是為什麼縮小 `pool_want` / `pool_want_with_cma` **只排 gather 就夠了**:
它自己會先做 release 那一步。分派原則是**按成因**——
release_worker 回應 VM 的動作,gather_worker 回應目標值的改變。

今天 `refill_worker` 尾巴排 `vm_owner_sweep_work`,那正是卸載路徑需要一整段註解
交代取消順序的原因——**寫在註解裡的順序就是遲早會被違反的順序**。

### 6.1 `release_worker` —— 要快

```c
release_worker():
	if !free_hook_attached():
		return         /* 沒人接手就不放手:放了會進 buddy 而 entry 留著,
		                * 重新啟用後還可能把別人的頁匹配進池子 */

	released = pool_release_idle()     /* 排乾:一輪沒放掉任何頁才停 */
	if released > 0:
		tries = 0
		return

	/* 一頁都沒閒置:RM 往返與 unpin 可能還在路上。退避重看,有上限 */
	if ++tries < RELEASE_TRIES:
		rearm_self(RELEASE_FIRST_MS << tries)
	else:
		tries = 0
```

### 6.2 `gather_worker` —— 可長跑、可取消

風險由 ctx 的兩個參數界定,而不是一個數字加一句註解:

```c
struct gather_ctx {
	int  ceiling;      /* 拿到多少為止 */
	int  max_means;    /* 拿多兇 */
	bool may_promote;  /* 成功後可否抬高 pool_total */
};

BACKGROUND = { pool_total, MEANS_ALLOC,       false };  /* 現行行為 */
user_ctx(m) = { pool_want,  m,                 true  };
```

```c
static const step steps[] = {
  /* 依「成本」排序,不依「種類」。每步先問自己的 goal 還有沒有欠債。 */
  /* name                  goal      需要      means(多數是步驟自己的屬性) */
  { "release idle",         -,        always,   -               },  /* 與 release_worker 共用方法 */
  { "purge expired",        -,        always,   -               },  /* released 逾時 → external */
  { "sweep released",       POOL,     always,   CONTIG_AT       },  /* 拿回自己的:去 released 原址搶 */
  { "light intake",         POOL,     always,   ALLOC_LIGHT     },  /* 向系統要:最便宜的一級,失敗即停 */
  { "shrink pool",          POOL,     always,   -               },  /* §2.2 的去向規則 */
  { "shrink total",         TOTAL,    cma,      -               },

  { "drop slab",            POOL,     user_run, -               },  /* 只有使用者觸發;不丟 page cache */
  { "stage-in (total met)", POOL,     cma,      -               },
  { "stage-in",             POOL,     cma,      -               },
  { "gather",               POOL,     always,   ctx.max_means   },  /* ★ 唯一吃 ctx 的一步 */
  { "pair fill",            QUALITY,  target,   CONTIG_AT       },
  { "reservoir fill",       TOTAL,    cma,      -               },
  { "quality",              QUALITY,  target,   CONTIG_AT       },
};

/* 一步可以回報「還太早」,而不是由誰去排它。 */
enum step_result { STEP_DONE, STEP_NOTHING, STEP_DEFER };   /* DEFER 帶 delay_ms */

gather_worker():
	progress = false;  soonest_defer = NEVER
	for s in steps:
		if stop_requested()                        break
		if s.needs == cma      && !cma_capable     continue
		if s.needs == target   && !means_can_target(ctx.max_means) continue
		if s.needs == user_run && !ctx.may_promote continue   /* 背景不丟 slab */
		if !deficit_for(s.goal, ctx)               continue
		r = s.run(ctx)
		if r == STEP_DEFER   soonest_defer = min(soonest_defer, r.delay)
		if r == STEP_DONE    progress = true

	pool_sort_if_dirty()
	pool_shed_excess()
	if debug                  pool_check()

	if ctx.may_promote && held() > pool_total:
		pool_total = held()           /* 使用者觸發的成功 = 已證明安全 */

	if stop_requested():
		gathering = false;  stop_reason = why_stopped()
	else if progress:
		rearm_self(0)                 /* 還在推進 */
	else if soonest_defer != NEVER:
		rearm_self(soonest_defer)     /* 沒進展,但有步驟說「太早」 */
	else:
		gathering = false;  stop_reason = why_stopped()
```

**兩件事靠「有進展就重排自己」自然發生,不需要在表裡重複列:**

1. **丟掉 slab 之後那批剛解毒的窗口,由下一輪的 `cheap intake` 撿走。**
   不必把 cheap intake 列兩次——丟 slab 算「有進展」,worker 重排,下一輪從頭跑。
   `drop slab` 自己記 `ctx.slab_dropped`,一輪 gather 只做一次。
2. **昂貴的 `gather` 只在便宜的都用盡之後才輪到**,因為每步都先問欠債,
   而 cheap intake 會把欠債補掉一部分。

### 6.2a hook 怎麼「叫起」worker:一個 ctx + 一條優先權規則

序列**不必傳進去**,因為序列就是步驟表。而且大部分步驟的 means 是**它自己的屬性**,
不是 ctx 給的:

- `sweep released` 一定是 `CONTIG_AT` —— 它結構上就需要指定位置(去 released 的原址搶)
- `refill` 一定是 `alloc` 系列 —— 它本來就不指定位置
- **只有 `gather` 那一步吃 `ctx.max_means`** —— 那才是使用者選的東西

所以 hook 不說「先 A 再 B」,只說「發生了 VM 事件,用背景 ctx 跑你的表」。
「先掃再買」是自然發生的:`refill` 在 `pool_in_flight() > 0` 時回 `DEFER`,
還有頁在路上就輪不到它。

**「ctx 變數只能寫一個」不需要 list,需要的是優先權規則:**

```c
static struct gather_ctx gather_ctx;          /* 只有一個 */
static bool              gather_active;
static DEFINE_SPINLOCK(gather_req_lock);

void gather_request(struct gather_ctx req)
{
	spin_lock(&gather_req_lock);
	/* 使用者的請求涵蓋背景的:ceiling 較高(pool_total <= pool_want)、
	 * means 較強。所以背景請求撞上進行中的使用者請求時,什麼都不必做。 */
	if (gather_active && gather_ctx.may_promote && !req.may_promote) {
		spin_unlock(&gather_req_lock);
		return;
	}
	gather_ctx = req;  gather_active = true;
	spin_unlock(&gather_req_lock);
	mod_delayed_work(system_wq, &gather_work, 0);
}
```

反方向也對:背景正在跑時使用者按 acquire,ctx 直接升級,
而 worker 每一輪都重讀 ctx,所以進行中的那一輪下次迭代就換成使用者的參數。

`pool_total <= pool_want` 這個前提由 resize 維持(縮小時 `pool_total = newt`),
所以「使用者請求涵蓋背景請求」不是假設,是不變式。

---

### 6.2b 為什麼是 `STEP_DEFER` 而不是 `next_tasks`

背景那兩階段(先把還回得來的撈回來,撈不滿再去買)之間需要的**不是「排下一個任務」,
是「現在還太早」**。

`refill` 該等的不是一段時間,是**等 `released` 排空**:頁還在回家路上時就去買替代品,
等於白買。今天 `refill_delay_ms = 5000` 猜的就是這件事,而五狀態模型讓它可以直接問:

```c
step_refill(ctx):
	if pool_in_flight() > 0        return STEP_DEFER(1s);   /* 還有頁在路上,別急著買 */
	...買替代品...
```

**條件驅動,延遲只是輪詢間隔**,不是一個猜出來的數字。

`next_tasks` 那種任務佇列更通用,但這裡用不到它多出來的能力:

| | 需要佇列嗎 |
|---|---|
| 排序階段 | 不必——步驟表本來就是順序 |
| 階段間的延遲 | 不必——`STEP_DEFER` 表達得更準(它說的是條件,不是時間) |
| **後階段需要前階段算出的參數** | **會需要**——但目前沒有這種情況:
`sweep` 要掃的 released pfn 清單是 pool 的狀態,步驟自己讀得到,不必有人傳給它 |

而且佇列會讓「這個 worker 接下來要做什麼」變成**執行期狀態**,
teardown 就得多考慮「佇列裡還有東西」;`STEP_DEFER` 只多一個重排延遲,
仍然是一個 work item、一次取消。

**真的出現「後階段需要前階段的參數」時再加佇列**,而且加的時候要限制
只能排給自己,否則就是 worker 互相排程換了個寫法。

### 6.2c 排序原則:先拿回自己的,再向系統要

不是「配置成本由低到高」。`sweep released` 的機制較貴(`CONTIG_AT` 要指定位置),
但它**不從系統拿任何東西**——它去把我們自己放掉的頁從原址搶回來;
而 `light intake` 再便宜,都是向系統要新的。

排好之後,兩個序列**自動從表裡長出來,不必傳、也不必新增 means 等級**:

| ctx | 實際跑的順序 |
|---|---|
| 背景 `{pool_total, ALLOC, false}` | `sweep released`(CONTIG_AT)→ `light intake` → `gather`(ALLOC) |
| 使用者 `{pool_want, m, true}` | `sweep released` → `light intake` → `drop slab` → `gather`(m) |

**「一律先試 light」是一個恆常執行的步驟,不是一個 means 等級。**

這也是為什麼不需要 `light2`:讓 light 排在 `CONTIG_EVICT` 之上,
會把**「最多可以多兇」(上限)** 和 **「按什麼順序試」(序列)** 塞進同一個序數。
enum 一旦不再依強度排序,`can_target`、能力檢查、`means <= ctx.max_means`
全部失去意義。上限歸 ctx,序列歸表,兩者不要混。

`ctx.max_means == ALLOC_LIGHT` 時 `gather` 會與 `light intake` 重複——
它找不到東西、回 `STEP_NOTHING`,無害。

**表是依「先自己再系統」排序,不是依種類。** 這讓「先撿現成、再解毒窗口、最後才遷移」
成為結構,而不是每個呼叫者自己記得的順序。

### 6.3 欠債判定 —— 每個 goal 唯一來源

```c
deficit_for(POOL,    ctx) = pool_intake_room(ctx.ceiling) > 0
deficit_for(TOTAL,   ctx) = pool_held_all() < pool_want_with_cma
deficit_for(QUALITY, ctx) = pool_cma_able_count() < pool_avail_count()
```

今天這三個各有 2–4 份手寫副本,其中三份是「在自己該工作的狀態下停止」的死碼
(入口守衛、Phase Q、pair_fill)。

### 6.4 卸載

```
卸掉 hook  →  取消兩個 worker  →  交還所有參照
```

不需要註解解釋順序。

---

## 7. 明確不做

- **不把 `pool_lock` 換成 mutex**:E1/E3a 在 atomic 上下文,只能 raw spinlock。
- **不改 tree / 雙池**:插入點在 atomic 上下文;`SUBBLKS == 1` 上是純負優化。
- **排序不做成獨立 worker**:它需要的是「有東西變了之後」,不是自己的節奏。
- **不宣稱物件化能防止競態**:C 裡沒有這種保證。它買到的是**衍生狀態的維護點收斂**,
  那才是已發生的四類 bug 的共同成因。

---

## 8. 待決

- **背景改用 `MEANS_ALLOC_CHEAP` 是這份設計裡唯一使用者會直接感受到的行為變更。**
  今天背景用的是 `alloc_pages(GFP_KERNEL|__GFP_COMP|__GFP_NOWARN|__GFP_RETRY_MAYFAIL, 9)`
  ——`GFP_KERNEL` 允許 direct reclaim,`__GFP_RETRY_MAYFAIL` 在 order-9 上拉起 compaction,
  也就是**背景會回收使用者的 page cache、會做記憶體壓縮**。
  這與 `pool_total` 的存在理由(模組不准自作主張把系統推到記憶體不足)直接矛盾,
  所以降到 cheap 是把實作拉回設計意圖。但它**會讓背景補得比較慢**、碎片化時補不滿。這是刻意的,
  但**要先量**:現在背景每輪補幾頁,換成不回收之後補幾頁。
  差多少決定使用者多久要按一次按鈕——這是唯一會被直接感受到的取捨。
- **`pool_in_flight()` 要能分辨「還在路上」與「已經丟了」**。前者會自己消失,
  後者要等逾時。可能需要進入該狀態的時間戳,而不是只有計數。
- **`released` 的命名**:`released` / `handover` / `ext_served_before` 未定。
