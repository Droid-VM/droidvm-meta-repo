# pool 物件:方法表

2026-08-08。目標不是「把全域變數包起來」,而是**讓「想不到」變成可機械檢查的問題**:
每個方法對應狀態機的一條邊或一個查詢,於是漏想 = 有一條邊沒有方法,或有一個方法不對應任何邊。

今天找到的 ABA 就是反例:「排序後寫回」不是一條邊、沒有名字,所以它的驗證條件是臨時想的
(比較 `pool_count`),而那正是最容易 ABA 的值。**有名字的東西才會被審視。**

---

## 0. 這個物件要消滅的四類 bug

都是今天真實發生過的,不是假想:

| 類別 | 今天的實例 |
|---|---|
| **忘記同步某個衍生狀態** | purge 移除 entry 卻沒交還參照(代價:重開機);`pool_gen` 是事後補的 |
| **同一個判斷抄了很多份,然後漂移** | `held_pool() >= pool_want` 有四份,其中三份是死碼 |
| **臨時想的驗證條件** | 排序寫回比較 `pool_count` → ABA |
| **計數器各自遞增** | `total_refilled` 十一個站點五種來源,`deficit` 因此不是回收指標 |

方法表要讓這四類**在結構上寫不出來**。

---

## 1. 不變式(方法的契約)

```
I1  held()      == want          held() = avail_count() + served_count()
I2  held_all()  == want_all      held_all() = held() + cma_count()
Q   最小化 avail 之中 !cma_able
G   任一 pfn 恰好處於 avail / served / cma / external 之一
```

**每個變動狀態的方法都必須維持 G**,而且是它自己的責任,不是呼叫者的。

---

## 2. 方法表

### 2.1 查詢(不取鎖以外的副作用)

```c
int  pool_avail_count(void);        /* avail 有幾個 */
int  pool_held(void);               /* I1 左邊 */
int  pool_held_all(void);           /* I2 左邊 */
int  pool_cma_able_count(void);     /* Q 的分子;SUBBLKS==1 時 == avail_count */
int  pool_intake_room(void);        /* 還能收幾個 = want + slack() - held(),可為負 */
bool pool_is_sorted(void);
```

**`pool_intake_room()` 是關鍵的一個。** 今天四份 `held_pool() >= pool_want` 各自演化,
三份是「在自己該工作的狀態下停止」的死碼。收斂成一個查詢,漂移就寫不出來。

### 2.2 邊(每條邊一個方法,方法負責更新一切)

```c
/* E1 avail -> served。atomic-safe。挑選策略在物件內(優先 !cma_able)。 */
struct page *pool_to_served(pid_t tgid);

/* E2 served -> avail。捕獲半,atomic-safe。 */
bool pool_from_served(struct page *pg);

/* E3 avail -> cma。需 cma_able;從底端取(排序後 cma_able 在那裡)。 */
int  pool_to_cma(int nr);

/* E4 cma -> avail。 */
int  pool_from_cma(int nr);

/* E5 avail -> external。從頂端取(與 serve 同序:先丟不能翻的)。 */
int  pool_to_ext(int nr);

/* E6 external -> avail。means 決定手段,origin 決定記到哪個計數器。 */
int  pool_from_ext(enum pool_means means, enum pool_origin origin, unsigned long want_pfn);
```

**`origin` 是參數而不是四個函式**——今天五種來源各自 `atomic_inc`,結果
`total_refilled` 混成一個分不出東西的數。當它是參數,計數器就不可能被忘記或記錯。

### 2.3 E6 的四個手段(你列的 `ext2avail_0123`)

```c
enum pool_means {
	MEANS_ALLOC,        /* 0: alloc_pages,最便宜,隨緣 */
	MEANS_CONTIG_ANY,   /* 1: alloc_contig_pages,隨緣(拿不到指定位置) */
	MEANS_CONTIG_AT,    /* 2: alloc_contig_range,可指定 */
	MEANS_CONTIG_AT_EVICT, /* 3: 同上 + 逐塊 evict */
};

struct pool_means_desc {
	const char        *name;
	bool               can_target;   /* 0/1 為 false */
	const struct kcap *caps;         /* 載入時解析;缺 → 這個手段停用 */
};
```

`can_target` 讓「acquire 1 無法優先掃描不完整塊附近」變成**手段宣告的屬性**,
而不是一條獨立的程式碼路徑——今天 acquire 1 走獨立函式,所以順手漏掉了整條 Phase R。

`want_pfn` 在 `!can_target` 時被忽略,呼叫端不必分支。

### 2.4 走訪與批次更新(ABA 的結構性修法)

```c
struct pool_snapshot {			/* 呼叫者不得自行構造 */
	unsigned int gen;
	int          n;
	struct page **pages;
};

bool pool_snapshot_take(struct pool_snapshot *s);          /* 取快照 + 世代 */
bool pool_snapshot_commit(struct pool_snapshot *s);        /* 世代未變才寫回 */
```

**世代驗證在物件裡,不是呼叫者記得做。** 今天的 bug 就是呼叫者(我)自己想了一個
「比較 `pool_count`」的驗證,而那個值最容易回到自己。`commit` 拿的是 `take` 發的憑證,
所以「用錯的東西驗證」寫不出來。

另外提供分塊走訪,因為「取鎖 → 處理 64 筆 → 放鎖 → `cond_resched`」這個模式
我今天自己重推了兩次(排序、收尾),每次都要重新想邊界條件:

```c
int pool_for_each_chunk(int (*fn)(struct page **batch, int n, void *arg), void *arg);
```

### 2.5 除錯(用來抓「很難試出來」的那類)

```c
bool pool_check(void);   /* debug=1 時可呼叫:驗 G 與 I1;不變式破了就印出來 */
```

檢查項:`avail_count + served_count` 與實際走訪相符、沒有 pfn 同時在 avail 與 served、
`pool_gen` 單調遞增、`cma_able_count <= avail_count`。

**這是唯一能對付「想不到」的東西**:方法表讓已知的邊有紀律,`pool_check()` 抓未知的。
掛在 `pool_shed_excess()` / 排序 / reconcile 之後,debug 模式下每次都跑。

---

## 3. 上下文契約(必須寫在方法旁邊)

六條邊裡**只有兩條**踩 atomic 上下文,而那是最容易寫錯的地方(在 worker 裡寫慣了
就忘記那條路徑不能睡)。所以契約要跟著方法走:

| 方法 | 上下文 |
|---|---|
| `pool_to_served` | **atomic**(配置 kretprobe) |
| `pool_from_served` | **atomic**(`__free_one_page`,持 zone lock、IRQ off) |
| 其餘全部 | 可睡(worker) |

物件內部持 `pool_lock`;**任何可能睡的事(`put_page`、`alloc`、`__free_pages`)
一律在鎖外**,由方法自己安排,不是呼叫者。

---

## 3.5 呼叫端:hook 與 worker 怎麼用這個物件

### hook 的規矩:一條或零條

```
配置 kretprobe   → pool_to_served()      唯一動作
free tracepoint  → pool_from_served()    唯一動作
VM destroy       → 排一個 worker         不碰 pool
runtime unshare  → 排一個 worker         不碰 pool
```

**規則:一個 hook 要嘛呼叫恰好一個 atomic-safe 的 pool 方法,要嘛只排 worker,不會兩者都做,
也不做別的。** 今天的 free hook 違反了這一條——它在 atomic 上下文裡做了政策判斷
(`pool_want` 閘門)、統計歸類、還曾經挑受害者做 exchange。那些都該在 worker 側。

### worker 的規矩:可以重排自己,不可以排別人

這一條是針對你問的「worker 拉起其他 worker」。**我建議禁止。**

今天 `refill_worker` 的尾巴會排 `vm_owner_sweep_work`,而那正是為什麼卸載路徑需要
一整段註解交代取消順序:A 會排 B,所以拆的時候 B 必須排在 A 之後取消,否則
in-flight 的 A 會在 B 已被取消之後把它排回來,然後在池子已釋放後執行。
**那個順序是隱性知識,寫在註解裡就代表它會被違反。**

替代做法:**worker 可以重排自己,不可以排別人。**

```c
static void reconcile_worker(struct work_struct *w)
{
	bool more = run_step_table();          /* 每步回報有沒有進展 */

	if (more && !should_stop())
		mod_delayed_work(system_wq, &reconcile_work, next_delay());
}
```

自我重排是安全的:`cancel_delayed_work_sync()` 本來就處理這件事,而且**只有一個 work 需要排序**。
需要「別的工作」時,不是排另一個 work,而是**在步驟表裡加一步**——那也讓順序看得見。

於是卸載路徑收斂成一句話,不需要註解解釋:

```
卸掉 hook  →  取消兩個 worker  →  交還所有參照
```

### 觸發表:誰在什麼時候動什麼

**hook**(全部只做一件事):

| hook | 動作 |
|---|---|
| 配置 kretprobe | `pool_to_served()` — **唯一**碰 pool 的 atomic 方法 |
| free tracepoint | `pool_from_served()` — 同上 |
| runtime unshare(`gunyah_rm_mem_reclaim`) | 排 `release_worker` + 排 `reconcile_worker`,**不碰 pool** |
| VM 關機(`gunyah_vm_release`) | 同上 |

今天 VM 關機的 hook 排了**三樣**東西(pcp drain、refill、開寬限窗)。新版只排 worker,
`refill` 變成 reconcile 步驟表裡的一步——它本來就是兜底,不該有自己的計時器。

**sysfs 寫入**:

| 寫入 | 方向 | 動作 | 為什麼 |
|---|---|---|---|
| `pool_want` | **調小** | 記錄 + 排 reconcile | 還記憶體,無風險,該即時 |
| `pool_want` | **調大** | **只記錄,不排任何 worker** | 要記憶體有風險,由使用者按 acquire 承擔 |
| `pool_want_with_cma` | **調小** | 記錄 + 排 reconcile | 同上(reconcile 走 cma→avail→ext) |
| `pool_want_with_cma` | **調大** | **只記錄,不排** | 同上 |
| `acquire` | — | 排 reconcile,**開啟採集** | 這就是使用者承擔風險的那一下 |

這張表把先前只存在於程式碼行為裡的風險歸屬**變成明文**:
背景永遠只維持 `pool_total`(已證明安全的量),擴張一律要人按。
調大目標值不會讓模組自己去要記憶體——它只是把門檻放在那裡等使用者。

**另一個好處**:今天 `pool_do_resize()` 在 **sysfs 寫入路徑裡同步排掉幾千頁**。
搬進 worker 之後,寫入立刻返回,長操作不再卡在參數寫入上。

### 為什麼是「hook 排兩個 worker」而不是「release 排 reconcile」

歸還會改變 reconcile 該做的事,所以直覺是 `release_worker` 做完排 `reconcile_worker`。
**不要**——那就是「worker 排別人」,卸載順序的隱性依賴會長回來。

改成 **hook 一次排兩個**。`reconcile_worker` 先跑時會發現放參照還沒完成、無事可做,
然後**自我重排**;等 release 做完,下一次 reconcile 就看得到。代價是最多一個 tick 的延遲,
換到的是「worker 永不互相排程」這條可以絕對執行的規則。

### 兩個 worker,分野是延遲要求

| worker | 職責 | 觸發 | 特性 |
|---|---|---|---|
| `release_worker` | E2 的放參照掃描 | unshare / VM destroy hook | **要快**;退避重試;不可被長跑工作擋住 |
| `reconcile_worker` | 步驟表(acquire/收尾/排序/兜底) | sysfs、release 完成後 | 可跑數分鐘;可取消;自我重排 |

排序與收尾**不是獨立 worker**,是 `reconcile_worker` 步驟表裡的兩步——它們需要的是
「有東西變了之後」,不是自己的節奏。

### 物件是單例,方法不帶 pool 指標

只有一個池子,傳一個永遠相同的參數是雜訊。若將來真的出現第二個(例如 per-node),
那是機械式改動,不值得現在先付。

---

## 4. 明確不做的

- **不把 pool_lock 換成 per-object mutex**:E1/E2 在 atomic 上下文,只能用 raw spinlock。
- **不改成 tree/雙池**:插入點在 atomic 上下文;而且 SUBBLKS==1 是純負優化(見
  `POOL_ARCH_V2.md` 的討論)。
- **排序不做成獨立 worker**:今天五個 work 的取消順序已有隱性依賴,方向應該是收成兩個。
  排序需要的是「有東西變了之後」,掛在已知自己改了東西的 worker 尾巴更準確。
- **不宣稱物件化能防止競態**:C 裡沒有這種保證。它買到的是**衍生狀態的維護點收斂**,
  這才是今天四類 bug 的共同成因。

---

## 5. 遷移順序

物件化是大範圍搬移,**不要在有已知未解 bug 時做**——會把 bug 搬進新結構然後更難歸因。

**先決條件**:追出 `released_idle` 比 `del_hit` 多 2 的原因
(SUBBLKS=1 十幾輪從未破,一開子塊路徑就破)。

之後:
1. 查詢方法(純新增,呼叫端逐步搬)
2. `pool_snapshot_take/commit` 取代排序現在的手寫驗證
3. 六條邊的方法,同步點收進去
4. `pool_from_ext` 的手段表,取代 `acquire_mode` 的整數分支
5. `pool_check()` + debug 模式常駐呼叫

---

## 6. 完整呼叫圖與 worker 虛擬碼

### 6.1 hook 點位

```c
/* 配置側 kretprobe —— atomic。entry 只過濾,ret 才動 pool。 */
entry_handler(regs):
	if arg_order(regs) != PAGE_ORDER      return SKIP
	if pool_avail_count() == 0            return SKIP
	if !vm_owner_contains(current->mm)    return SKIP
	if !(arg_gfp(regs) & __GFP_MOVABLE)   return SKIP   /* 只服務會還回來的那條配置路線 */
	return TAKE

ret_handler(regs):
	pg = pool_to_served(current->tgid)     /* ← 唯一碰 pool 的呼叫 */
	if pg  set_return_value(regs, pg)

/* 釋放側 vendor tracepoint —— atomic,持 zone->lock、IRQ off。 */
free_one_page_cb(page, order, *bypass):
	if order != PAGE_ORDER                return          /* 全系統快路徑閘門 */
	if pool_served_count() == 0           return
	*bypass = pool_from_served(page)       /* ← 唯一碰 pool 的呼叫;閘門與統計都在裡面 */

/* VM 關機 kprobe —— 不碰 pool。 */
vm_destroy_pre(regs):
	vm_owner_note_gone(current->mm)
	arm(release_worker,   0)
	arm(reconcile_worker, RECONCILE_SETTLE_MS)

/* runtime unshare kprobe(gunyah_rm_mem_reclaim)—— 不碰 pool。 */
mem_reclaim_pre(regs):
	if pool_served_count() == 0           return
	arm(release_worker,   RELEASE_FIRST_MS)
	arm(reconcile_worker, RECONCILE_SETTLE_MS)
```

### 6.2 sysfs write

```c
write pool_want = N:
	old = want;  want = clamp(N, 0, size_max)
	if N < old   arm(reconcile_worker, 0)      /* 還記憶體:即時 */
	/* N > old:只記錄。要人按 acquire。 */

write pool_want_with_cma = N:
	old = want_all;  want_all = clamp(N)
	if N < old   arm(reconcile_worker, 0)
	/* 同上 */

write acquire = m (1..3):
	if !means_usable(m)                              return -ENOSYS
	if pool_intake_room() <= 0
	   && !reservoir_deficit() && !quality_deficit()  { stop_reason="already at target"; return 0 }
	means = m;  gathering = true;  stop_reason = "acquiring"
	arm(reconcile_worker, 0)
	return 0            /* fire-and-return:重活在 worker */

write acquire = 0:
	gathering = false   /* reconcile 下一輪自己看到並停 */

write reclaim_enable = 0/1:
	attach/detach free hook  (release_worker 會據此決定能不能交接)
```

### 6.3 `release_worker` —— 要快

```c
release_worker():
	if !free_hook_attached():
		return              /* 沒人接手就不放手:放了會流進 buddy 而 entry 留著 */

	released = pool_release_idle()      /* 排乾:一輪沒放掉任何頁才停 */

	if released > 0:
		tries = 0
		return

	/* 一頁都沒閒置:RM 往返與 unpin 可能還在路上。退避重看,有上限。 */
	if ++tries < RELEASE_TRIES:
		rearm_self(RELEASE_FIRST_MS << tries)
	else:
		tries = 0
```

### 6.4 `reconcile_worker` —— 可長跑、可取消

```c
static const step steps[] = {
  /* name                 goal      needs_cma  can_target_only */
  { "stage-in (total met)", POOL,     true,      false },
  { "pair fill",            QUALITY,  true,      TRUE  },   /* means 0/1 跳過 */
  { "drop slab",            POOL,     false,     false },
  { "harvest free",         POOL,     false,     false },
  { "stage-in",             POOL,     true,      false },
  { "sweep",                POOL,     false,     false },   /* 唯一依 means 分歧的一步 */
  { "reservoir fill",       TOTAL,    true,      false },
  { "quality",              QUALITY,  true,      TRUE  },
  { "refill (fallback)",    POOL,     false,     false },
};

reconcile_worker():
	if release_pending():
		rearm_self(SHORT_MS)        /* 讓歸還先做完,再決定要不要採集 */
		return

	progress = false
	for s in steps:
		if stop_requested()                     break
		if s.needs_cma && !cma_capable          continue
		if s.can_target_only && !means.can_target continue
		if !deficit_for(s.goal)                 continue
		progress |= s.run()

	pool_sort_if_dirty()        /* 兩個鍵:!cma_able 到頂端,同塊 pfn 相鄰 */
	pool_shed_excess()          /* 把鬆弛額度用剩的還掉;採集中不動 */
	if debug                    pool_check()

	if progress && gathering && !stop_requested():
		rearm_self(0)           /* 只重排自己,永不排別人 */
	else:
		gathering = false
		stop_reason = why_stopped()
```

### 6.4b 縮小的去向:由「哪個不變式變了」決定

之前只寫了「調小 → 排 reconcile」,沒交代 reconcile 要做什麼。目的地不是額外的政策,
**是從兩個不變式推導出來的**:

```
pool_want 調小,pool_want_with_cma 不變
    I1 held()     必須下降  → avail 要少掉
    I2 held_all() 必須不變  → 那些頁不能離開監護
    ⇒ 唯一解: avail → cma
    ⇒ CMA 未啟用/無處可去時退化為: avail → ext

pool_want_with_cma 調小
    I2 held_all() 必須下降  → 監護總量要少
    ⇒ cma → avail(拆儲備池)後 avail → ext
    ⇒ 不走 cma → ext 直達:avail 是樞紐,而拆下來的頁本來就要重貼 MOVABLE 標籤再釋放,
      走 avail 讓它與一般釋放共用同一條路
```

寫成步驟:

```c
step_shrink_pool():        /* I1 下降 */
	n = held() - ceiling
	if cma_capable && held_all() <= want_all:
		moved = pool_to_cma(n)      /* 監護權換形式,不放走 */
		n -= moved
	pool_to_ext(n)                      /* 剩下的還給系統 */

step_shrink_total():       /* I2 下降 */
	n = held_all() - want_all
	pool_from_cma(n)                    /* 先拆回 avail */
	/* 之後由 step_shrink_pool / pool_shed_excess 循上面那條把多的送出去 */
```

**今天的 `pool_do_resize()` 已經是這個行為**(`flip` 旗標的條件正是
`pool_want_with_cma > newt`,並以 `- cma_pool_cma_2mb()` 為上限避免灌爆儲備池)。
它只是從未出現在任何設計文件裡——所以這節是把既有行為寫下來,不是提案。

搬進 worker 之後多一個好處:今天這段在 **sysfs 寫入路徑裡同步排掉幾千頁**。

### 6.5 每個 goal 的欠債判定(唯一來源)

```c
deficit_for(POOL)    = pool_intake_room() > 0
deficit_for(TOTAL)   = held_all() < want_all
deficit_for(QUALITY) = pool_cma_able_count() < pool_avail_count()
```

今天這三個判斷各有 2–4 份手寫副本,其中三份是「在自己該工作的狀態下停止」的死碼。
