# 大頁池:設計 v2(worker 骨架由使用者重寫,本版補完)

2026-08-09。**單一來源。** 前一版的分層/步驟表/DEFER 模型全部作廢——它前後矛盾且無法在腦中模擬。
本版骨架:兩個**週期性** worker + `run` 倒數 + ctx 交棒。
使用者寫了骨架與 ext→avail 的三個 stage;§9 列出我補完的部分,review 時先看那節。

---

## 1. 狀態與不變式(不變,壓縮重述)

| 狀態 | 意義 | 在哪個結構 |
|---|---|---|
| `served` | 借給 VM(GUP pin + 我們一份保護參照) | served 表,`released_at == 0` |
| `released` | 已放手,去向未定 | served 表,`released_at != 0` |
| `avail` | 池中待命 | `page_pool[]` |
| `cma` | 儲備池,借給其他 app | `cma_blocks[]` |
| `external` | 系統的 | 不追蹤 |

```
held      = avail + served 表全部 entry 數(含 released ← 關鍵,見下)
held_cma  = held + cma

I1  held     == pool_want
I2  held_cma == pool_want_with_cma
Q   最小化 avail 之中 !cma_able
```

**held 把 released 也算進去**:released 的頁大概率會回來(hook 幾微秒內接到,
或 precise stage 撿回)。不算它,VM 關機瞬間 diff 會暴增,worker 就去買
一堆「正要回家的頁」的替代品。**放棄 = purge(entry 移除)那一刻,deficit 才真的打開。**

`released` 的頁**仍在 served 表**,只是 `released_at != 0`;
`GRACE` = released 狀態的存活上限,逾時 → purge(→external,由後續採集買替代品)。

---

## 2. pool 物件:內部狀態與鎖

```c
/* ── 鎖分三把,依「誰在什麼上下文碰」──────────────────────── */

/* (a) pid 註冊表 —— rwlock,與 pool 鎖完全獨立。
 *     serve 熱路徑先查這個,pid 不對就提早返回,不動 pool 的鎖。 */
static DECLARE_RWLOCK(pid_lock);
static struct vm_owner  owners[VM_OWNER_MAX];   /* pid/mm、served 計數 */

/* (b) pool 核心 —— raw spinlock(serve/catch 在 atomic 上下文)。 */
static DEFINE_RAW_SPINLOCK(pool_lock);
static struct page *page_pool[POOL_SIZE_MAX];   /* avail:LIFO 堆疊 */
static int          pool_count;
static unsigned int pool_gen;                    /* 每次變動 ++;排序寫回前驗證 */
static bool         avail_sorted;                /* 變動時清 false */
static struct served_node { pfn, tgid, released_at, next } served[];  /* pfn 雜湊 */

/* (c) CMA / 候選 —— 只有 adjust_worker 碰,mutex 即可。 */
static DEFINE_MUTEX(cma_lock);
static unsigned long cma_blocks[];               /* 已翻進儲備池的 block 基址 */
static unsigned long cma_cand[CMA_SUBBLKS];      /* 候選 FIFO,見 §7 cma_complete */
static int           cma_cand_n;

/* pb 索引(SUBBLKS>1 才存在):block → avail/served 遮罩,cma_able 由此導出 */
```

排序不變:`!cma_able` 在頂端、同塊 pfn 相鄰;serve/shed 從頂端拿,flip 從底端拿。
排序本身:快照 → 鎖外排 → `pool_gen` 沒變才寫回(ABA 防護),由 adjust_worker 每輪尾巴做。

---

## 3. pool 方法表

```c
/* ── hook 用(atomic-safe)────────────────────────────────── */
struct page *pool_to_served(pid_t pid);   /* avail→served。pid 沒註冊/池空 → NULL */
bool         pool_catch(struct page *pg); /* released→avail。pfn 不在表中 → false */

/* ── release_worker 用 ──────────────────────────────────── */
int  pool_release_idle(void);      /* served 且 refcount==1 && !mapping → put_page,
                                    * 蓋 released_at 時間戳。回傳放掉幾頁。
                                    * free hook 沒掛就整個拒跑(放了沒人接)。 */
int  pool_purge_dead(void);        /* owner 已死 && refcount>1 && 已過寬限 → 放棄:
                                    * 移除 entry + 交還參照(SERVED_PURGED,記 purge_log) */
int  pool_purge_expired(void);     /* released_at 逾時 GRACE → 移除 entry(頁早已在 buddy) */

/* ── adjust_worker 用(可睡)──────────────────────────────── */
list pool_released_pfns(void);           /* precise 的目標清單 */
list pool_gap_pfns_sorted(void);         /* main(ranged)/cma_complete 的目標:
                                          * avail/served 部分持有的 block 的缺口位址,
                                          * 同塊相鄰、依址排序(456 89 11 13) */
bool pool_from_ext_alloc(gfp_flavor f);  /* alloc_pages;f = LIGHT(NORETRY) 或 FULL(RETRY_MAYFAIL) */
bool pool_from_ext_contig_any(void);     /* alloc_contig_pages,拿不到指定位置 */
bool pool_from_ext_contig_at(pfn);       /* alloc_contig_range 指定 2MB 窗 → avail */
bool pool_sweep_catch(pfn);              /* 同上,但目標是自己 released 的頁:
                                          * 成功記 ORIGIN_SWEEP 而非 ORIGIN_USER */
int  pool_from_cma(int nblocks);         /* cma→avail:逐出借用者、拆一個 block 回池 */
int  pool_to_cma(int nblocks);           /* avail→cma:從底端取 cma_able 的整塊翻入 */
int  pool_to_ext(int npages);            /* avail→ext:從頂端 free(先丟 !cma_able) */
bool pool_cand_push(pfn);                /* cma_complete 專用,見 §7:候選 FIFO */
void pool_cand_flush(void);              /* 候選清空:全部 free 回 buddy */
void pool_sort_if_dirty(void);
bool pool_check(void);                   /* debug=1:驗 G/I1,破了就印 */

/* ── rmmod 專用(同步,不經 worker)─────────────────────── */
int  pool_served_to_ext_all(void);  /* 每個 entry:
                                     *   released_at != 0 → 只刪 entry。參照早已放掉,
                                     *     對 Linux 而言那頁已經是 ext,不需要任何路徑。
                                     *   released_at == 0 → put_page + 刪 entry
                                     *     (SERVED_PURGED,記 purge_log)。頁若仍被 VM pin,
                                     *     它跟著 VM 活,VM 退出後自然回 buddy——不逐出誰。 */
int  pool_cma_to_ext_all(void);     /* 放棄監護:block 標籤翻回 MOVABLE 即完成。
                                     * 借用中的頁留給借用者(本來就是 movable),
                                     * 空閒的隨標籤回一般 freelist。不逐出、不遷移。 */

/* ── 查詢 ─────────────────────────────────────────────── */
int pool_avail(void); pool_served(void); pool_in_flight(void);
int pool_held(void);                     /* avail + served 表全部(含 in_flight) */
int pool_cma(void); pool_noncma_able(void);
```

`origin`(in_hook/in_sweep/in_cma/in_user/in_refill)計數照舊,由各方法內部記。

---

## 4. 觸發總表

```
action:
  insmod   → 初始化 pool → 掛 hook → adjust_trigger(approach=alloc_pages)   /* prefill 非同步 */
  rmmod    → 卸 hook → 停兩個 worker → 同步 *→ext(§8),不經 worker

hook(全部「一個 pool 方法或只碰 run」,不做政策):
  vm_boot      → pid_register(current)                       /* 只動 pid_lock */
  vm_shutdown  → release_run(10);  adjust_trigger(BACKGROUND) /* 補 purge 造成的缺口 */
  vm_unshare   → release_run(10)
  serve(kretprobe ret) → pg = pool_to_served(pid);  NULL → 不覆寫,回歸原始 alloc
  free(tracepoint)     → bypass = pool_catch(page)

sysfs write:
  pool_want / pool_want_with_cma → 記下新值 → adjust_trigger(BACKGROUND)
  acquire = 0                    → adjust_run(0)              /* 中斷,見 §5 */
  acquire = {approach, evict}    → run!=0 → -EBUSY
                                    否則寫 ctx(approach/evict) → adjust_trigger(USER)
```

`serve` 的快路徑:先 `read_lock(pid_lock)` 查 pid,不對就返回——**不碰 pool_lock**。

---

## 5. worker 模型(兩個都遵守)

```
ctx 裡有一個特殊變數 run:
  - 任何人任何時刻可寫(寫 0 = 中斷;寫 N = 啟動/續命)
  - 其他 ctx 變數:只有 run==0 時外部可寫;run>0 期間只有 worker 自己更新
每輪:
  讀 run,==0 就停;否則 run-- 、做一小片工作、存 ctx、排下一輪(間隔 N ms)
```

`run` 同時是**開關**和**看門狗**:寫 0 立即中斷(最多再跑完當輪一小片),
而 run 有限保證 worker 不可能永遠跑(不變量達不成時,倒數耗盡自然停)。

```c
release_worker: 間隔 1000ms,run 初值 10(觸發時寫入,重複觸發=重新寫 10)
adjust_worker:  間隔 10ms, run 初值 ADJUST_RUN_MAX(夠跑完一次大採集,例如 60000)
```

實作:`{run, ctx}` 用一把小 spinlock 保護狀態轉換;
worker 輪內工作在鎖外,輪首/輪尾短暫取鎖讀寫 run 與存 ctx。

```c
adjust_trigger(profile):        /* profile = BACKGROUND 或 USER(帶 approach/evict) */
	lock;
	if (run == 0) { ctx = init_ctx(profile); run = ADJUST_RUN_MAX; schedule(); }
	else          { run = ADJUST_RUN_MAX; }   /* 進行中:只續命。
	                                           * USER 撞上進行中 → -EBUSY(§4),
	                                           * 使用者要先 acquire=0 再重新設定。 */
	unlock;

init_ctx(profile):
	stage    = 全部 true
	precise_target_pages = main_target_pages = nil
	non_ranged_acquire_retry_hp = 8
	approach/evict = profile 給的(BACKGROUND: alloc_pages / 無 evict)
```

---

## 6. release_worker

職責:**served → released**(全部它管,adjust 不碰這條邊),外加放棄處理。

```c
release_round():                          /* 每 1000ms */
	lock; if (run == 0) return; run--; last = (run == 0); unlock

	pool_release_idle()
	/* served 且 refcount==1 && !mapping → put_page + 蓋 released_at。
	 * put_page 觸發完整 free 路徑,free hook 幾微秒內 pool_catch 接回 avail。
	 * refcount>1 = VM/gunyah 的 pin 還沒放 → 這輪不動它,下輪再看。
	 * 這就是為什麼 run=10、間隔 1s:給 unpin 十秒,取代舊的加倍退避。 */

	if (last):
		pool_purge_dead()      /* 十秒過了還抓著、且主人已死:放棄。
		                        * 移除 entry + 交還參照,記 purge_log。
		                        * 這會讓 held 下降 → adjust(還在跑)看到缺口 → 補。 */
	else:
		schedule(+1000ms)
```

## 7. adjust_worker

職責:盡力達成不變量。**除 avail→served(hook)與 served→released(release)外,
所有轉換都是它做。**

```c
/* ctx ─────────────────────────────────────────────────── */
struct adjust_ctx {
	int   run;
	struct { bool precise, stage_in, cheap_acquire,
	              main_acquire, cma_complete, flip, shed; } stage;
	list  precise_target_pages;     /* nil = 尚未初始化 */
	list  main_target_pages;
	enum  { ALLOC_PAGES, ALLOC_CONTIG_PAGES, ALLOC_CONTIG_RANGE } approach;
	enum  { EVICT_MEMCG,           /* try_to_free_mem_cgroup_pages */
	        EVICT_ISOLATE }        /* folio_isolate_lru + reclaim_pages */  evict;
	int   non_ranged_acquire_retry_hp;   /* 初值 8 */
};

adjust_round():                            /* 每 10ms */
	lock; if (run == 0) return; run--; unlock

	pool_purge_expired()                   /* 記帳:released 逾時 → 放棄(每輪,O(in_flight)) */

	/* 每輪重算,絕不快取 —— 目標值與池況隨時在變 */
	held           = pool_held()           /* 含 in_flight,見 §1 */
	diff_want      = pool_want          - held
	diff_want_cma  = want_cma_eff       - (held + pool_cma())
	                 /* want_cma_eff = cma_capable ? max(want_cma, want) : want */
	new_page_need  = diff_want_cma
	reserve_target = want_cma_eff - pool_want
	cma_excess     = pool_cma() - max(reserve_target, 0)

	st = 第一個仍為 true 的 stage 旗標
	if (沒有):
		if (所有不變量已達成 || run 即將耗盡) { run = 0; stop_reason = ...; return }
		stage = 全部 true                   /* 還有缺口:再跑一個 campaign。
		                                     * run 倒數是總上限,不會無窮迴圈 */

	switch (st):

	/* ── ext→avail ──────────────────────────────────────── */
	case precise:        /* 撿回自己 released 的頁:免費,誰都不痛,永遠第一 */
		if (!cap(contig_range) || pool_in_flight() == 0) { stage.precise = false; break }
		if (precise_target_pages == nil)
			precise_target_pages = pool_released_pfns()
		pfn = pop(precise_target_pages)
		pool_sweep_catch(pfn)              /* 失敗:留在 released,等逾時 purge */
		if (empty(precise_target_pages))   stage.precise = false

	case stage_in:       /* cma→avail:儲備池超過應有大小時,先拿自己的回來 */
		/* 兩種情況走到這:pool 短而總量已足(再向外拿會衝破 I2,這是唯一合法來源);
		 * 或 want_cma 被調小(儲備池要拆)。統一條件就是 cma_excess>0。 */
		if (!cma_capable || cma_excess <= 0) { stage.stage_in = false; break }
		pool_from_cma(1)                   /* 一輪一塊:拆塊要逐出借用者,慢 */

	case cheap_acquire:  /* 向系統要,最便宜的一級:撿現成,失敗即停 */
		if (new_page_need <= 0)            { stage.cheap_acquire = false; break }
		repeat 至多 CHEAP_BATCH(=64) 次:
			if (!pool_from_ext_alloc(LIGHT)) { stage.cheap_acquire = false; break }
			if (--new_page_need <= 0)        { stage.cheap_acquire = false; break }

	case main_acquire:   /* 使用者授權的等級 */
		if (new_page_need <= 0)            { stage.main_acquire = false; break }
		if (approach == ALLOC_PAGES || approach == ALLOC_CONTIG_PAGES):
			ok = (approach == ALLOC_PAGES) ? pool_from_ext_alloc(FULL)
			                               : pool_from_ext_contig_any()
			if (ok)  hp = min(hp + 3, 8)
			else if (--hp == 0)            { stage.main_acquire = false; break }
			/* hp:連續失敗的忍耐值,成功回血。取代舊 fail_score,語意相同 */
		else:            /* ALLOC_CONTIG_RANGE:可指定位置,配 evict */
			if (main_target_pages == nil)
				main_target_pages = pool_gap_pfns_sorted()
			pfn = pop(main_target_pages)
			run_evict(evict)               /* EVICT_MEMCG: try_to_free_mem_cgroup_pages
			                                * EVICT_ISOLATE: folio_isolate_lru+reclaim_pages */
			pool_from_ext_contig_at(pfn)
			if (empty(main_target_pages))  stage.main_acquire = false

	/* ── ext→avail(湊齊 CMA):Q 目標,取代 limbo ──────────── */
	case cma_complete:
		if (!cma_capable || !cap(contig_range) ||
		    pool_noncma_able() == 0)       { stage.cma_complete = false; break }
		if (main_target_pages == nil)      /* 復用同一種清單:缺口位址,同塊相鄰 */
			main_target_pages = pool_gap_pfns_sorted()
		if (empty(main_target_pages))      { pool_cand_flush(); stage.cma_complete = false; break }
		pfn = pop(main_target_pages)
		run_evict(evict)
		if (pool_from_ext_contig_at_raw(pfn))   /* 先不入池 */
			pool_cand_push(pfn)
		/* pool_cand_push:FIFO 長度 = CMA_SUBBLKS。
		 *   推入後檢查:此頁的 block 是否已由 served/avail/候選 湊滿?
		 *   湊滿 → 候選成員轉入 avail,同時 pool_to_ext(k) 從頂端 free 掉
		 *          k 個 !cma_able 頁(k = 剛轉入的候選數)→ held 不變,Q 改善。
		 *          頂端優先正是 !cma_able,所以「丟最爛的」自動成立。
		 *   FIFO 滿 → 擠掉最舊的候選,直接 free 回 buddy。
		 *          清單同塊相鄰,湊得齊的塊其候選必然連續入隊,
		 *          所以被擠掉的 = 它的塊湊不齊(中間有一格 grab 失敗)。自清。 */

	/* ── avail→cma ──────────────────────────────────────── */
	case flip:
		/* 條件:avail 超過 I1 份額(diff_want<0)且儲備池未達應有大小。
		 * 對應「pool_want 調小而 want_cma 不變」:監護權換形式,不放走。 */
		if (!cma_capable || diff_want >= 0 ||
		    pool_cma() >= reserve_target)  { stage.flip = false; break }
		b = 池底端整塊;  if (!cma_able(b)) { stage.flip = false; break }
		pool_to_cma(1)

	/* ── avail→ext ──────────────────────────────────────── */
	case shed:
		/* 最後一步:此時該翻的已翻、該留的已留,還多的才是真正要還系統的 */
		if (diff_want >= 0)                { stage.shed = false; break }
		pool_to_ext(min(-diff_want, SHED_BATCH=32))

	/* ── 輪尾 ───────────────────────────────────────────── */
	pool_sort_if_dirty()
	if (debug) pool_check()
	存 ctx;  schedule(+10ms)
```

### 7.1 stage 順序的理由(一句話版)

```
precise      免費且是自己的 → 永遠第一
stage_in     總量已足時唯一合法的來源;want_cma 調小時的必經路
cheap        向系統要之中最便宜的
main         使用者授權的力度
cma_complete Q 目標,只在 I1/I2 滿足後有意義(new_page_need 已 <=0)
flip / shed  分配結果:先換形式,再還多餘
```

## 8. insmod / rmmod 序列

```c
insmod:
	解析 kapi 符號 → 建 pool 結構 → pid/pool 鎖初始化
	掛 serve kretprobe + free tracepoint + vm_boot/shutdown/unshare kprobe
	adjust_trigger(BACKGROUND)            /* prefill 非同步:cheap 一輪 64 頁,
	                                       * 開機記憶體乾淨,幾秒內到位 */

rmmod:                        /* 全同步。worker 停掉之後就沒有 worker 可用了 */
	卸全部 hook                 /* 不再有新 serve/catch/VM 事件 */
	release_run(0);  adjust_run(0);  cancel_work_sync ×2

	pool_served_to_ext_all()   /* served→ext;released 只清 entry(頁對 Linux 早已是 ext) */
	pool_cma_to_ext_all()      /* cma→ext:放棄監護,不逐出任何人 */
	pool_cand_flush()          /* 候選 FIFO → buddy */
	for each avail: __free_pages()      /* avail→ext,分批 + cond_resched */
	釋放結構
```

卸載順序仍是鐵律:**先卸 hook,再停 worker,最後交還參照**。

**served→ext 與 cma→ext 是 rmmod 專用的直達邊**,不違反「avail 是樞紐」:
執行期的縮小走 `cma→avail→ext`,因為那是**要把記憶體拿回來**(逐出借用者、收回、再釋放);
rmmod 走直達,因為意圖相反——**停止監護**,借用者留著他們正在用的頁,誰都不被逐出。
兩種意圖、兩條路,同名不同事。也因此 rmmod 的 `*→ext` 全部同步完成:
它不需要逐出、不需要遷移,每一步都是 O(entries) 的簿記加 free,沒有慢的部分。

---

## 9. 我補完/新增的部分(review 先看這裡)

| # | 內容 | 為什麼 |
|---|---|---|
| 1 | **`stage_in`(cma→avail)整個 stage** | 原稿缺這條邊。沒有它:(a) pool 短而總量已足時,唯一合法來源(向外拿會衝破 I2)不存在;(b) `want_cma` 調小時儲備池拆不掉。統一條件 `cma_excess > 0` 蓋住兩者 |
| 2 | **`held` 含 in_flight(released 仍在 served 表)** | 不含的話 VM 關機瞬間 diff 暴增,worker 買一堆正要回家的頁的替代品。放棄=purge 那刻 deficit 才打開 |
| 3 | **purge 的歸屬**:`purge_dead` 在 release 最後一輪;`purge_expired` 在 adjust 每輪記帳 | release 十輪 = 十秒寬限;逾時的 released 隨時可能出現,放 adjust 輪首 |
| 4 | **vm_shutdown 也觸發 adjust** | 原稿只啟動 release。但 purge 造成的缺口要有人補(舊 refill 的職責),adjust 的 cheap/main 就是補的人 |
| 5 | **候選 FIFO 溢出 = free 最舊** | 原稿只說長度 SUBBLKS 與結束時 flush。溢出規則讓「湊不齊的塊」自清:清單同塊相鄰,湊得齊的候選必然連續入隊,被擠掉的就是湊不齊的 |
| 6 | **湊滿時 free k 個 !cma_able(k=轉入的候選數)** | 原稿說「free 掉 non cma_able 的塊」沒說幾個。k 個才守恆;不足 k 個就少 free,多的由 shed 收(diff_want<0 會出現) |
| 7 | **`run` 統一為倒數看門狗 + campaign 重啟規則** | 原稿 release 有倒數、adjust 只說 exit 時 run=0。統一:stage 全消耗完但不變量未達 → 重設全部 stage 再跑,run 倒數保證有界 |
| 8 | **USER 撞上進行中 → -EBUSY** | ctx 規則(run>0 時外部不可寫)的直接推論:要改 approach 得先 acquire=0 |
| 9 | **cheap/shed 的每輪批次**(64/32) | 一輪一頁的話 prefill 3072 頁要 30 秒;cheap 很便宜,批次不傷中斷延遲(run=0 最多等一輪) |
| 10 | **cma_complete 需要 contig_range 能力**,沒有就整段跳過 | acquire 0/1 的裝置(不能指定位置)本來就做不到湊塊 |

## 10. 明確不做 / 待決

- 不做 tree/雙池(atomic 插入點);不宣稱物件化防競態(它買到的是維護點收斂)。
- 排序照舊在 adjust_worker 輪尾,不是獨立 worker。
- **待決**:`released` 命名(released/handover);`GRACE` 具體值(現 3s 級);
  `ADJUST_RUN_MAX` 與各批次常數要在真機上調。
