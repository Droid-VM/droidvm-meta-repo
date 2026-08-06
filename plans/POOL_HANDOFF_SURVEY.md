# 池子的拿取與歸還:有沒有可靠的路徑(含成本帳)

Survey,2026-08-06。問題:退出路徑上補「主動歸還」有沒有用、udmabuf 是不是多一條歸還路徑、
專用的 `/dev/gh_udmabuf` 能不能保證 100%、以及**這些攔截各自的綜合性能代價**。

> **直接讀 §4.7。** 這份文件對 `MIGRATE_ISOLATE` 來回過三次(§2.4 推薦 → §4.5 作廢 →
> §4.6 恢復 → **§4.7 最終否決**)。前面的段落保留是為了記錄每一步被什麼證據推翻,
> **動手前只以 §4.7 為準。**

## 結論先講

1. **損失的成因**:頁面**以 order-9 被 free 了、沒有被拆散**,但它停在 per-CPU 的 THP free
   list,而 hook 掛在它的下游(`__free_one_page`)。實測 **1.33 頁/輪、回收率 99.95%**。
2. **crosvm 側做不到 100%**。它能影響的只有 free 的**時機**,而時機只能改善兜底
   (`drain_all_pages` + scavenger)的命中率——那是 best-effort,不是可靠路徑。
   「主動 pin 再 munmap/free」不但無效,還會把 free 推遲到那唯一一次 drain 之後,**更糟**。
3. **要確定性只有三條路**,而且**最便宜的那條先前沒有被考慮過**:
   - **A(首選)**:把池子的 pageblock 標成 `MIGRATE_ISOLATE`。`free_unref_page` 對 isolate
     **直接轉呼 `free_one_page`,完全繞過 pcp**,而現有 hook 正是 `__free_one_page` 的第一件事。
     **零新增攔截、零新增觸發頻率、模組側改動、不動 crosvm。**
     副作用是好的:漏掉的頁會落到 isolate freelist(誰都配不走),失敗模式從永久損失降級成可回收。
   - **B(備案)**:掛 `android_vh_free_unref_page_bypass`(pcp 插入之前)。確定性,
     但觸發次數嚴格更多,在性能限制下不是首選。
   - **C(終點)**:讓頁面根本不進 buddy(自有 chardev),**唯一涵蓋 SIGKILL**,
     而且同時拆掉配置側那個最貴的 kretprobe。
4. **C 的地基已由原始碼回答**:客體 RAM 必須被 GUP pin,而 in-tree 三個 dma_buf exporter
   全都設 `VM_PFNMAP`、GUP 對這種 VMA 無條件 `-EFAULT`。所以它**不能是照慣例做的 dma_buf**,
   必須是自有 chardev + `vm_insert_page`。

---

## 0. 三個要先修正的前提

### 0.1 「hook order-9 alloc 保證 alloc 之後到交給 RM 之前都是 pin 住的連續狀態」

**不成立。** pin 只從 `pin_user_pages_fast(..., FOLL_LONGTERM)` 那一刻開始;在那之前它是一個
**普通的 movable shmem THP folio**,compaction、khugepaged、`split_huge_page` 都動得了。

| 環節 | 事實 | 位置 |
|---|---|---|
| 客體 RAM 後端 | `SharedMemory::new` → `memfd_create` | `crosvm/vm_memory/src/guest_memory.rs:473` |
| 所以頁面是什麼 | shmem page-cache folio,屬於 inode 不屬於 mapping | POOL_RECLAIM_PLAN §1.1 |
| 交給 gunyah 的形式 | **使用者位址** `userspace_addr` | `crosvm/hypervisor/src/gunyah/mod.rs:134-139` |
| 誰 pin | `pin_user_pages_fast(uaddr, npages, FOLL_LONGTERM)` | `gunyah_host_mod/gunyah_host_share/GKI6.6/gunyah_share_mod.c:408-411` |

註:`FOLL_LONGTERM` **不會**把 folio 搬出普通的 `MIGRATE_MOVABLE` pageblock
(`folio_is_longterm_pinnable()` 只對 CMA / ISOLATE / ZONE_MOVABLE / device-coherent 回 false)。
pin 之後擋得住 split 與遷移,是**因為 pin**,不是因為它來自池子。

### 0.2 「歸還時只能猜系統會用 order-9 放回 buddy,拆散了就拿不回來」

方向對,但**不是實測到的損失來源**。模組自己的註解已經寫下真正的機制
(`gh-hugepage-reserve/parts/gh_hooks.c.inc:669-677`):

> Teardown frees order-9 folios through `free_unref_page`, which can park a few of them in pcp
> lists **indefinitely on an idle system** — they never reach `__free_one_page`, so the reclaim
> hook never sees them … (a steady ~2-page loss per killed VM, observed).

**頁面沒有被拆散,它是以 order-9 被 free 的**;它停在 per-CPU 的 THP free list,
而 hook(`android_vh_free_one_page_bypass`,即 `__free_one_page`)在 pcp 的**下游**。
損失的形狀是「free 了但我們沒聽見」,而且實測都記在 `orphan_inuse`
(owner 已消失、**區塊已被別人占住**)——與「被 pcp 直接配給下一個要求者」一致。

拆散的情況模組另有補救:`served_reacquire_free_orphans()` 在 drain 後用 `alloc_contig_range`
重組碎片(同檔 `:684-690` 註解直說 `e.g. a split THP freed as order-0s`)。

### 0.3 回收率的真實數字

| 日期 | 配置 | 每輪借出 | 每輪永久損失 |
|---|---|---|---|
| 2026-07-30 | purepool,poweroff / sigterm 各兩輪 | ~2565 頁 | 1–2 頁 |
| 2026-08-06 | devvm 優雅關機,**六輪** | 2850 頁 | `0, 2, 2, 2, 2, 0` |

六輪共丟 8 頁 = **1.33 頁/輪,回收率 99.95%**,與 07-30 的基準一致。
`drain recovered=0`——**scavenger 一頁都撿不回來**,所以那 2 頁是真的永久損失。

兩點提醒:

- 模組從 2026-07-16(`abb6157`)起沒有再改過,所以兩次量測之間變的不是模組。
- **不要用 3 輪下結論**:本輪前三輪曾經連續量到 0,那是抽樣運氣;六輪才顯出穩定的 1.33/輪。
- 「90+%」如果是指 `pool_avail / pool_want`,那量到的是**補貨追不上**
  (`acquire_stop_reason=cma sources exhausted`),跟歸還率是兩本帳。分開看:
  歸還率 = `total_refilled / total_served`;池子水位 = `pool_avail + served` vs `pool_want`。

---

## 1. 成本帳:兩個攔截點各付什麼

這是決定後面所有取捨的那張表。**兩側的快路徑閘門都很便宜,貴的是機制本身。**

| 側 | 機制 | 快路徑 | 觸發頻率 |
|---|---|---|---|
| 配置 | **kretprobe** on `__alloc_pages` | `order != 9 → return 1`(3 個比較) | **全系統每一次配置** |
| 釋放 | vendor tracepoint at `__free_one_page` | `order != 9 → return`(2 個比較) | 每一頁回 buddy,不分 order |

程式碼:
```c
/* entry_handler, parts/gh_hooks.c.inc:609 */
if ((unsigned int)regs_get_kernel_argument(regs, 1) != PAGE_ORDER) return 1;

/* gh_free_one_page_cb, parts/gh_hooks.c.inc:291 */
/* Fires for every buddy free system-wide: the cheap gates come first. */
if (order != PAGE_ORDER || !page) return;
```

**所以「free hook 因為 order==9 判斷不通過就直接退出,還可接受」這個判斷是對的。**
但同樣的邏輯要套到配置側時結論不同:閘門一樣便宜,**kretprobe 的機制本身**
(arm64 上走 trap 或 ftrace trampoline + kretprobe instance 管理)遠比 tracepoint 的一次
間接呼叫重,而且掛在最熱的配置函式上。**成本的大頭在配置側,不在釋放側。**

補充一條:arm64 **不選 `HAVE_STATIC_CALL`**,所以 tracepoint 是 `__traceiter_*` out-of-line
呼叫 + 每個 probe 一次 kCFI 檢查,不是 patched static call。

---

## 2. 逐題回答

### 2.1 「瓶頸是不是 RM 歸還之後、userspace free 之前被拆散?」

**不是,而且就算是,在退出路徑上加 userspace free 也解不了。**

1. **問題在「我們在哪裡聽」,不在「何時 free」。** free 已經以 order-9 發生,只是落在 pcp;
   把 free 提早一樣先進 pcp。
2. **程序死亡的順序跟需求相反。** `exit_mm` 在 `exit_files` **之前**:kernel 先拆 mm
   (頁面開始還)才關 fd(VM 才被釋放)。「先關 VM fd、再趁 mapping 還在主動歸還」
   在非自願路徑上排不出來。
3. **VM fd 不是一個 fd,RM reclaim 是非同步的。** VM fd 被 dup 約 `3×vcpu + 3` 次,
   driver 只在最後一個 close 才跑 `gunyah_vm_release`;RM reclaim 之後仍要 retry
   (`gunyah_share_66.c:197-220` 自己 retry 2s×60)。

順帶回答「userspace 手段能不能阻止 runtime 被拆散」——**大部分已經擋住了**:

- crosvm 已對 memfd 上 `F_SEAL_SHRINK`(+GROW+SEAL,`vm_memory/src/guest_memory/sys/linux.rs:34-38`),
  **punch-hole / truncate 被封死**,那是 userspace 造成 partial split 的主要來源。
- lend 期間 gunyah 的 `FOLL_LONGTERM` pin 讓 `can_split_folio()` 的 refcount 檢查失敗
  (`mm/huge_memory.c:3352-3363`),**split 與遷移都做不到**。

剩下的暴露窗口只有「fault 進來到被 pin 之前」和「unpin 之後到 free 之前」,
而實測損失落在後者、且成因是 pcp 停留。**所以拆散不是現在的瓶頸。**

### 2.2 「改用 udmabuf,是不是多了一條 userspace 歸還路徑?」

**(A) 把現有 memfd 包成 udmabuf ——沒有用。**
udmabuf 只是從 memfd 的 page cache 取頁並 pin 住,`ukv_release` 逐頁 `put_page`。
頁面仍屬於 shmem inode,仍走同一條 free path 回 buddy,仍會停在同一個 pcp list。
它只是**多一個 pin**(擋 split/遷移)和**把歸還時間往後推**;接住頁面的還是同一個 hook。

**(B) 模組自己配置、自己 export ——這才是真的新路徑。**
歸還點變成**我們的程式碼**,而 fd 的關閉由 `exit_files` 保證,**任何死法都會跑,含 SIGKILL**。
頁面從頭到尾不進 buddy,於是:不需要猜 order、不需要 pcp drain、不需要
`alloc_contig_range` 重組,**而且兩個全系統攔截點都可以拆掉**。

### 2.3 「crosvm 側有沒有手段讓正常關機路線的匹配率到 100%?」

先釘住決定一切的那條規則:**free 走哪條路由 folio 的 order 決定**。

```c
static inline bool pcp_allowed_order(unsigned int order)   /* mm/page_alloc.c */
{
        if (order <= PAGE_ALLOC_COSTLY_ORDER) return true;
#ifdef CONFIG_TRANSPARENT_HUGEPAGE
        if (order == HPAGE_PMD_ORDER) return true;          /* ← order-9 就是這條 */
#endif
        return false;
}
```

order-9 **就是** `HPAGE_PMD_ORDER`,所以它天生走 pcp。crosvm 改不了 folio 的 order,
也就改不了走哪條路。逐條:

| 手段 | 效果 |
|---|---|
| **主動 pin 再 munmap/free** | **無效,而且有害。** pin 不改變 free 路徑;退出時多一個 LONGTERM pin 只會把 free **推遲到模組那次 +3s drain 之後**,正好加大漏的窗口 |
| **sbrk / brk** | 不適用。客體 RAM 是 memfd 的 `mmap`,不在 heap 上 |
| **punch-hole 整段 memfd** | 已被 `F_SEAL_SHRINK` 封死;就算解封,放出來的 folio 一樣進 pcp |
| **先 split 再 free** | 更糟:變成 order-0,**全部**進 pcp |
| **以非 pcp-eligible 的 order 釋放** | 做不到:不能把一個 compound folio 拆成 order-4..8 去 free |
| **控制 drop 順序 + 退出時踢一次回收** | **唯一有作用的槓桿**(見下),穩態成本為零 |
| **另創新路徑(頁面不進 buddy)** | 見 §2.5,連 SIGKILL 都涵蓋 |

**所以 crosvm 沒有辦法讓匹配率變成 100%。** 它能影響的只有 free 發生的**時機**,
而時機只能改善兜底(`drain_all_pages` + `alloc_contig_range` 的 scavenger)的命中率——
那條路本質上是 best-effort,不是可靠路徑,不該拿它當答案。

### 2.4 三條**確定性**路徑(這才是問題的答案)

要在正常路徑上必定命中,只有三種做法。全部都是「改變 free 的路由」或「讓頁面不進 buddy」,
沒有第四種。

#### 選項 A:把池子的 pageblock 標成 `MIGRATE_ISOLATE`(**模組側,零 crosvm 改動,成本最低**)

`free_unref_page` 的第一個逃生口就是它:

```c
migratetype = get_pfnblock_migratetype(page, pfn);
trace_android_vh_free_unref_page_bypass(page, order, migratetype, &skip_free_unref_page);
if (skip_free_unref_page) return;
if (unlikely(migratetype > MIGRATE_RECLAIMABLE)) {
        if (unlikely(is_migrate_isolate(migratetype))) {
                free_one_page(page_zone(page), page, pfn, order, FPI_NONE);
                return;                          /* ← 完全繞過 pcp */
        }
```

而 `free_one_page()` 無條件呼叫 `__free_one_page()`,**現有的 hook 就是那個函式的第一件事**
(在 `account_freepages` 與所有 `VM_BUG_ON` 之前)。所以路由變成:

```
teardown free → free_the_page → free_unref_page → [isolate] → free_one_page → __free_one_page → 我們的 hook
```

**全程不碰 pcp,確定性命中,而且不需要任何新的攔截點。**

為什麼成本趨近於零:

- `is_migrate_isolate` 在 `mm/page_alloc.c` 裡只出現在 free/accounting 路徑
  (那些檢查本來每次 free 都會跑)與 `alloc_contig`/isolation 專屬碼裡,
  **不在配置熱路徑**(`rmqueue` / `get_page_from_freelist`)上。
- `zone->nr_isolate_pageblock` 只被 `mm/page_isolation.c` 與 `mm/memory_hotplug.c` 碰,
  `page_alloc.c` 完全不讀它——所以「有 isolate 區塊」不會讓整個 zone 走慢路徑。
- **pageblock 就是 2MB,與 order-9 頁 1:1 對應**,所以每個池子頁剛好獨占一個 pageblock,
  不會有「同一個區塊裡混著別人的頁」的問題。

順帶一個很好的副作用:**失敗模式降級**。萬一 hook 仍然漏掉一頁,它會落到
**isolate freelist——誰都配不走**,變成「停在那裡等 scavenger 撿」而不是「被別人占走」。
今天的 `orphan_inuse`(永久損失)在這個設計下不存在。

**跨 GKI 版本的可行性(四棵樹都查過:6.1.157 / 6.6.118 / 6.12.58 / 6.18.21)**

| | 6.1 / 6.6 / 6.12 | 6.18 |
|---|---|---|
| isolation 存在哪 | migratetype 欄位的一個值 | **獨立 pageblock bit** `PB_migrate_isolate` |
| 設定 | `set_pageblock_migratetype(page, MIGRATE_ISOLATE)`,**非 static**、未 export | `set_pageblock_isolate()` → `set_pfnblock_bit(page, pfn, PB_migrate_isolate)`,**非 static**、未 export |
| 舊寫法在 6.18 | — | **被明確拒絕**(`VM_WARN_ONCE` + `return`),且該函式已改成 `static` |
| 讀取 | `get_pfnblock_migratetype()` | 同一個函式,**仍回報 `MIGRATE_ISOLATE`**(相容層),且 `EXPORT_SYMBOL_GPL` |
| free 路徑的 isolate 逃生口 | ✓ | **✓ 原封不動** |
| `android_vh_free_one_page_bypass`(現用) | ✓ | **✓ 四版全在** |
| `android_vh_free_unref_page_bypass`(選項 B) | ✓ | ✓ |

**機制本身四個版本全部成立**;要改的只有設定端,而兩種介面都有**非 static、未 export**
的具名符號可用 kallsyms 取得——模組本來就是這樣拿 `prep_compound_page` /
`drain_all_pages` / `alloc_contig_range` 的,不是新的風險類別。

> **會咬人的陷阱**:6.18 的 `set_pageblock_migratetype(page, MIGRATE_ISOLATE)`
> **不回報失敗給呼叫者**——只印一行 `VM_WARN_ONCE` 然後 return。版本分支寫錯的話,
> 行為是「什麼都沒發生」而不是編譯錯誤:池子照跑、漏損照舊、零訊號。
> 所以 preflight **必須設完之後回讀 `get_pfnblock_migratetype()` 確認真的變成
> `MIGRATE_ISOLATE`**,不能只驗「符號有沒有拿到」。

要驗證的風險(動手前逐條確認):

1. `set_pageblock_migratetype()` 沒有 export → 要走 `kallsyms_lookup_name`
   (模組已經在用,`disable_kapi = kallsyms_lookup_name`)。
2. **`rmmod` 必須還原**,否則 3072 個 pageblock(6GB)會永久留在 isolate 狀態。
   拆卸序列本來就有註解寫明順序,新增這一步要進清單。
3. 若別的東西對同一範圍呼叫 `start_isolate_page_range` / `undo_isolate_page_range`,
   `nr_isolate_pageblock` 的記帳會對不上(我們是直接設型別、沒有增減那個計數)。
   手機上機率低,但要想清楚要不要走正規的 isolate API。
4. 我們自己的 `alloc_contig_range` scavenger 與 isolate 區塊的互動要重測——
   `alloc_contig_range` 內部本來就會 isolate,兩者疊加的行為要驗。
5. watermark:isolate 的**空閒**頁不計入 `NR_FREE_PAGES`。我們的頁不是空閒的
   (不是被服務出去就是在池子裡,兩者都是 allocated),所以理論上不受影響——但要量。

#### 選項 B:掛 `android_vh_free_unref_page_bypass`(模組側,確定性,但觸發更頻繁)

同一段程式碼的上一行就是這個 vendor hook,在**任何 pcp 插入之前**,而且帶 `order`,
所以快路徑閘門一樣是 `order != 9 → return`。確定性命中。

代價是**觸發次數嚴格多於今天**:今天的 hook 收不到「進 pcp 後又被 pcp 配走」的頁,
而 `free_unref_page` 每一次 pcp-eligible 的 free 都收——那是熱路徑上最常見的情況。
在「要考慮綜合性能」的前提下,這是選項 A 的備案而不是首選。

ABI 注意(**這裡更正 `POOL_RECLAIM_PLAN.md` §4.2 的兩個錯誤**):

| 符號 | `abi_gki_aarch64.stg` | `abi_gki_aarch64_honor` |
|---|---|---|
| `android_vh_free_unref_page_bypass` | 有 | **沒有** |
| `android_vh_free_one_page_bypass`(現用) | 有 | 有 |
| `android_vh_free_folio_bypass` | **這棵樹沒有** | 沒有 |

舊文件寫的 `android_vh_free_page_bypass` / `android_vh_free_folio_bypass` 兩個名字,
在 6.6.118 上一個名字不對、一個不存在。要用就用 `android_vh_free_unref_page_bypass`,
並且因為它不在 honor 清單,必須靠 kapi preflight 偵測 + fallback。

#### 選項 C:頁面根本不進 buddy(crosvm + 模組,涵蓋 SIGKILL)

見 §2.5。它是唯一能連 SIGKILL 都涵蓋的,而且**同時拆掉配置側那個最貴的 kretprobe**。
代價是動 crosvm 的記憶體後端。

#### 不成立的:「hook unmap」

unmap 不是頁面被釋放的時刻。客體 RAM 是 shmem page-cache folio,`munmap` 只掉 PTE 的 ref,
**頁面仍留在 page cache 裡**(inode 持有 `folio_nr_pages()` 個 ref),要到 memfd 的 inode
被銷毀才真的釋放。所以 unmap hook 會在錯誤的時間點觸發,而且那時我們也還不是擁有者。

### 2.5 「`/dev/gh_udmabuf` 專供 order-9,能保證 100% 嗎?」

(這是上面的選項 C。)方向對——它就是 POOL_RECLAIM_PLAN §3 說的「唯一的真出路:把 pool 頁面完全移出 buddy 管轄
+ 自有 allocator」。但**它不能是一個照慣例做的 dma_buf**,原因如下。

#### (a0) 先講清楚:fd 不是現在缺的東西

模組**已經有**可靠的拆機觸發——`gunyah_vm_release` / `gh_vm_free` 上的 kprobe,
**SIGKILL / OOM / 強殺都照樣觸發**(POOL_RECLAIM_PLAN §8)。再加一個 dma_buf fd
只是多一個同樣可靠的通知,**不會改變任何事**。

缺的是 **ownership**:memfd 的頁屬於 shmem inode,page cache 自己持有
`folio_nr_pages()` = 512 個 ref,模組永遠不是唯一擁有者,只能等 kernel 的 free path
把它交回來——而 §5.3 證明那條路每輪固定漏 2 頁。

所以「把大頁當 dma_buf 發給 crosvm」有沒有幫助,**取決於它有沒有改變誰擁有那些頁**,
而不是取決於那個 fd。close 觸發回收是「頁面本來就是我們的」之後才成立的收尾動作。

#### (a) 硬性阻擋:dma_buf 的 CPU mapping 不可被 GUP pin(選項 C 的擋門)

`mm/gup.c:949` 的 `check_vma_flags()`:

```c
if (vm_flags & (VM_IO | VM_PFNMAP))
        return -EFAULT;
```

**無條件**。而 in-tree 三個 exporter 全都設 `VM_PFNMAP`:

| exporter | 作法 |
|---|---|
| `udmabuf` | `vm_flags_set(vma, VM_PFNMAP | ...)` + `vmf_insert_pfn` |
| `heaps/cma_heap` | `vm_flags_set(vma, VM_IO | VM_PFNMAP | ...)` |
| `heaps/system_heap` | `remap_pfn_range()`(它自己會設 `VM_PFNMAP`) |

我們自己的 `gunyah_host_mod/udmabuf/udmabuf.c:238-251` 也一樣。
而 §0.1 已確定客體 RAM 是**以使用者位址交給 gunyah、由驅動 GUP** 的。

**所以照 dma_buf 慣例做的 `/dev/gh_udmabuf`,客體 RAM 一頁都 lend 不出去。**

**出路:不設 `VM_PFNMAP`——這是正當的,而且核心裡有正規先例。**

- `dma_buf_mmap()` **完全沒有碰 `vm_flags`**,只驗 offset 就交給 `dmabuf->ops->mmap`。
  所以 PFNMAP 是 in-tree exporter 的**慣例,不是框架要求**。
- `remap_vmalloc_range_partial`(`mm/vmalloc.c:3920`)就是把**核心自有頁面**映射給
  userspace 的標準做法:`vm_insert_page` + `VM_DONTEXPAND | VM_DONTDUMP`,**沒有 PFNMAP**。
- 慣例的理由對我們是**反的**:exporter 設 PFNMAP 是為了保留「隨時能搬走/釋放 buffer」的權利,
  不讓別人拿到它不知道的參照——而我們**正是要 gunyah 的 LONGTERM pin 拿得到**。

**安全性不是靠旗標,是靠構造。** `insert_page_into_pte_locked` 做的是
`folio_get()` + `inc_mm_counter(mm_counter_file)` + `folio_add_file_rmap_pte()`,
頁面因此是有 refcount、有 rmap、算進 RSS 的正常頁。但模組用 `alloc_pages` 配出來的頁
**從來不在任何 LRU 上**,而 vmscan 只走 LRU(`lru_to_folio`),遷移也只處理 LRU folio 或
`__PageMovable`——兩者都不是,compaction 遇到它們是「隔離失敗、跳過」而不是搬走。

要跟著處理的四件事:

1. **refcount 變成契約**:每個 PTE 持有一個 ref,模組必須等**所有**參照消失
   (PTE、gunyah 的 pin)才能把頁放回池子。見 (c)。
2. **要設 `VM_DONTCOPY`**:否則 crosvm 若為 sandbox 而 fork,會複製出額外的 ref 拖住回收。
3. **RSS 記帳**:映射算進 crosvm 的 file RSS。今天 memfd 也是,多半無變化,
   但 Android 側若有 OOM score / 記憶體上限邏輯要確認。
4. **絕不能兩個旗標都設**:`vm_insert_page` 對 `VM_PFNMAP` 會 `BUG_ON`,
   `vmf_insert_pfn_pmd` 對「兩者並存」會 `BUG_ON`。

#### (b) 這看起來像被否決過的「借出時持有 refcount」,但不是同一件事

POOL_RECLAIM_PLAN §2 否決過「模組借出時自己留一個 ref」,三個理由是:
①破壞 folio split(punch-hole 需要)、②破壞遷移(連自己的 `alloc_contig_range` scavenger
一起關掉)、③移除模組唯一的回收事件。

**對「模組自有、永不進 buddy」的頁面,三個理由都不轉移:**

- ① punch-hole 已經被 `F_SEAL_SHRINK` 封死了(§2.1),我們沒有在用它。
- ② 我們**不希望**這些頁被遷移;而且不再需要 scavenger,因為根本不會弄丟。
- ③ 回收事件變成 `vm_ops->close` / 最後一個 ref 掉落,那是確定性的。

這一段必須寫下來,否則下一個讀 §2 的人會以為這是在重提被否決的設計。

#### (c) release 可能早於 unpin

gunyah **pin 的是 page,不是 dma_buf**,所以 fd 關掉、release 跑起來的時候那些頁可能
還被 `FOLL_LONGTERM` pin 著。模組**絕不能把還被 pin 的頁放回池子**再發給下一個 VM,
必須先確認 refcount / `folio_maybe_dma_pinned()`。歸還因此是**確定會發生,但不是立刻**
——它等的是「pin 放掉」而不是「猜頁面回 buddy 了沒」。這是好交易,別宣稱成瞬時。

#### (c2) 映射粒度:先分清楚「2MB」是哪一層的 2MB

**只有一層會被影響,而客體那層完全不受影響。**

| 哪一層的 2MB | 誰在用 | 用 chardev 後 |
|---|---|---|
| **實體連續** | memparcel entry 512:1 合併,撐住 RM 的 per-parcel 上限 | **不變** |
| **客體 stage-2 映射** | gunyah 用 2MB block descriptor | **不變** |
| **host userspace PTE 粒度** | crosvm 自己讀寫客體記憶體時的 TLB | **只有這層變** |

前兩層不變的證據在我們自己的 share 模組(`gunyah_share_mod.c:452-458`):entry 是靠
**GUP 拿到的 `pages[]` 陣列的實體連續性**合併出來的
(`page_to_phys(pages[i]) == page_to_phys(pages[i-1]) + PAGE_SIZE`)——**與 host PTE 粒度無關**。
註解自己就寫著 *THP/mthp-backed buffers (2MB folios) collapse 512:1, which is what keeps
large blobs under the RM's per-parcel resource limits*。

第三層的代價:6GB ≈ 150 萬個 PTE(~12MB page table),加上 crosvm 實際碰到的那些頁走
4K TLB 而不是 2MB TLB。**是真的成本,但只落在 host 側,且只在 crosvm 觸及的工作集上。**

**而且這層在 6.18 上已經沒有問題了:**

```c
vm_fault_t vmf_insert_folio_pmd(struct vm_fault *vmf, struct folio *folio, bool write)
{
        if (WARN_ON_ONCE(folio_order(folio) != PMD_ORDER))
                return VM_FAULT_SIGBUS;
        return insert_pmd(vma, addr, vmf->pmd, fop, vma->vm_page_prot, write);
}
EXPORT_SYMBOL_GPL(vmf_insert_folio_pmd);
```

吃的是 **refcounted folio**、唯一條件是 `folio_order == PMD_ORDER`(池子的頁正好是 order-9),
而且**已 export**,模組直接呼叫、連 kallsyms 都不用。

| | PMD 級 + refcount 正確的介面 | 結果 |
|---|---|---|
| **6.18+** | `vmf_insert_folio_pmd`(已 export) | **PMD 映射與 refcount 契約兼得,沒有技術債** |
| 6.1 / 6.6 / 6.12 | 無 | 要嘛 `vm_insert_page`(4K,refcount 正確),要嘛 `vmf_insert_pfn_pmd`(PMD,但 pfn map、PTE 不持 ref,回收觸發要改用 `vm_ops->close`) |

**所以我們今天出貨的 6.6 反而是比較麻煩的那個版本,不是未來的 6.18。**
6.6 上「PMD 與正確 refcount 二選一」這件事要列進 §4.1 的擋門實驗
(`vmf_insert_pfn_pmd` 建出來的 PMD,GUP 走不走得通)。

#### (d) crosvm 側的代價

- 客體 RAM 要改成從這個 fd 取得而不是 memfd(`SharedMemory` 是 memfd 專用的:seals、`MemfdSeals`)
- balloon:crosvm 靠 punch-hole 還記憶體,而 **`F_SEAL_SHRINK` 目前已經把它封死了**,
  所以這條**不是新增的損失**——但要確認樹上沒有其他路徑依賴它
- snapshot / restore 對 memfd 的假設要一起看

#### (e) 涵蓋範圍要說清楚

dma_buf / chardev 的 release 涵蓋 SIGKILL,但**不涵蓋 memparcel**。
`kill -9 crosvm` 洩漏的 gunyah memparcel 要手機重開才回來,那是 RM 側的帳
(見記憶 `gunyah-kill9-leaks-memparcels`)。「100% 歸還」只能宣稱在**池子頁面**這一層。

---

## 3. 選項排序(套用性能限制之後)

### ✅ 首選:選項 A(isolate pageblock)——確定性,而且幾乎不加成本

見 §2.4。它把 free 的路由改掉,用**現有的** hook 就能確定性命中,
順帶把「被別人占走」這個失敗模式整個消除。**先驗證 §4.4 的五條風險。**

### ⚠️ 備案:選項 B(`android_vh_free_unref_page_bypass`)

這棵 kernel 有兩個更早的 bypass hook(`android_vh_free_page_bypass` @ `free_unref_page`、
`android_vh_free_folio_bypass` @ `free_unref_folios`),它們在**任何 pcp 插入之前**,
直接命中 §0.2 的機制,而且快路徑閘門一樣是 `order != 9 → return`。

**但它們的觸發次數嚴格多於現在**:今天的 hook 收不到「進 pcp 後又被 pcp 配走」的頁,
而 `free_unref_page` **每一次 free 都收**——那正好是熱路徑上最常見的情況。
它是**正確性修正,不是成本改善**,買到的是 0.047%。

**確定性有了,但觸發次數嚴格更多**——所以它是選項 A 失敗時的備案,不是首選。
真要做:不要做 primary/fallback 推舉(走哪條 free path 是 runtime 由別的廠商模組
`android_vh_customize_thp_pcp_order` 決定的,insmod 時推舉必然判斷錯),
並且它不在 `abi_gki_aarch64_honor` 清單裡,要靠 kapi preflight 偵測 + fallback。

### ✅ 值得做:自有 chardev + `vm_insert_page`,頁面永不進 buddy

它同時解決兩件事,這是它勝過所有其他選項的地方:

| | 現況 | 改後 |
|---|---|---|
| 配置側 | kretprobe on `__alloc_pages`,**全系統每次配置** | **拆掉**(模組自己配置) |
| 釋放側 | tracepoint on `__free_one_page`,每頁回 buddy | **拆掉**(頁面不進 buddy) |
| 歸還率 | 99.95%,每輪固定丟 ~1.33 頁 | 100%(池子頁面這一層) |
| SIGKILL | 靠 kernel free path,會漏 | 涵蓋(`exit_files` 保證關 fd) |
| 遷移/拆散 | 靠 pin + 封印擋住大部分 | 不適用(頁不在 buddy 管轄內) |

前提是 §2.5(a):`mmap` 必須用 `vm_insert_page`,不能是 `VM_PFNMAP`。

### ⚪ 過渡:先量,別先改

在投入之前,§4 的兩個量測可以用很小的成本把剩下的不確定性收掉。

---

## 4. 動手前的決定性實驗

### 4.1 `vm_insert_page` 的 mapping 真的能被 `FOLL_LONGTERM` pin 嗎(擋門)

原始碼已經回答了「PFNMAP 一定不行」,但「`vm_insert_page` + `VM_MIXEDMAP` 一定行」還沒實測。
不需要先寫 allocator:

1. 寫一個最小 chardev,`mmap` 用 `vm_insert_page` 給幾個 order-9 頁(不設 `VM_PFNMAP`)。
2. 對那段 VA 呼叫我們自己的 `/dev/gunyah_share` 的 `GHSM_SHARE_BLOB`
   (`gunyah_share_mod.c:61`),它就是 `pin_user_pages_fast(..., FOLL_LONGTERM)`。
3. 成功 = §3 的地基成立;失敗 = 整條路收掉。

順便對照組:同一支測試指向現有的 udmabuf mapping,**預期 `-EFAULT`**(驗證測試本身有效)。

成本:一個小 kmod + 數十行 userspace 測試。比先寫 allocator 便宜兩個數量級。

### 4.2 損失到底是 pcp 被搶走還是被拆散

`orphan_inuse` 的語意(owner 沒了、區塊被別人占住)已經偏向前者,但模組現在分不出來。
加一個 debugfs,對每個 orphan 的 pfn 印 `PageCompound` / `compound_order` / `page_count`:

- 仍是 order-9 compound、owner 換人 → **pcp 被搶走**
- 已是 order-0 碎片 → **真的被拆散**

這個數字決定「§3 的 ❌ 選項如果做了能拿回多少」,也是唯一能讓那個交易被重新評估的證據。

### 4.3 如果真要評估前移 hook 的成本,量它而不是猜

新舊並行掛一段時間,用**分站點**的 `dbg_o9_seen` 比對觸發次數與 order 分佈。
POOL_RECLAIM_PLAN §4.4 已經寫了這個方法。沒有這個數字之前,「貴多少」是猜的。

### 4.4 選項 A 動手前要逐條確認的五件事

1. `set_pageblock_migratetype()` 沒有 export → 走 `kallsyms_lookup_name`(模組已在用)。
2. **`rmmod` 必須還原**,否則 3072 個 pageblock(6GB)永遠留在 isolate 狀態。
3. 與正規 isolate API 的記帳:我們直接設型別、不動 `zone->nr_isolate_pageblock`,
   若別處對同一範圍呼叫 `undo_isolate_page_range` 會對不上。
4. 與自家 `alloc_contig_range` scavenger 的互動(它內部本來就會 isolate)要重測。
5. watermark:isolate 的**空閒**頁不計入 `NR_FREE_PAGES`;我們的頁不是空閒的,理論上不受影響,但要量。

### 2.6 「VM 關機後、crosvm 退出前的那個窗口呢?」

**窗口是真的,而且是刻意留的**:`mem::drop(linux)` 在 `crosvm/src/crosvm/sys/linux.rs:4751`
(註解:*Explicitly drop the VM structure here to allow the devices to clean up*),
之後 crosvm 還會繼續跑(drop hotplug manager、metrics cleanup + join)才返回。
這和**死亡路徑**不同——死亡路徑上 `exit_mm` 在 `exit_files` 之前,順序排不出來;
這裡 crosvm 活著、在控制中、**可以阻塞**,是唯一能做同步握手的地方。

**但這個窗口對本問題沒有用,兩個理由:**

**(a) ownership 沒有改變。** memfd 的頁仍然屬於 shmem inode,直到 inode 被銷毀。
`mem::drop(linux)` 做的 munmap + close(memfd) 讓 folio 走的還是**同一條 free path**,
一樣 `free_unref_page` → pcp。「VM 已關機」不改變任何路由。

**(b) 那個窗口在 free 之前就結束了。** 實測(§5.4):**頁面是在 crosvm 行程退出、
mm 被拆掉的那一刻才 free 的**——`tracked` 正好在 crosvm 消失的同一個取樣點從 2850 掉到 2。
`mem::drop(linux)` 之後、行程還活著的那段,**guest RAM 根本還沒被釋放**
(devices/metrics 那些 drop 與 join 還沒跑完,memfd 的 inode 還在)。

所以在那個窗口裡阻塞等待「模組回報歸零」是**等一件還沒發生的事**;真正的 free 要等到
`run_control` 返回、main 收尾、行程退出。要讓握手有意義,得把等待放到**行程真的放掉
guest memory 之後**——而那已經在 `run_control` 之外,回到 POOL_RECLAIM_PLAN §1.4/§1.5
判死的那個順序問題裡。

**而且窗口本身有代價**:gunyah 一 unpin,folio 就變回普通的 movable shmem THP,
split 與遷移都恢復可能。把窗口拉長是**增加**暴露而不是減少——若之後真要在這裡加等待,
必須是等模組的掃描結果,不能是單純 sleep。

---

## 4.5 **重大更正(2026-08-06 稍晚):那 2 頁從沒被 free 過**

下面 §3 的排序、以及 §2.4 選項 A 的推薦,**建立在「頁面被 free 了但走進 pcp」這個假設上。
更精確的量測推翻了它。** 保留原文是因為推理鏈本身有用,但**不要照著它動手**。

### 新證據

| # | 觀察 | 方法 |
|---|---|---|
| 1 | 每輪服務 2850,hook 精確回收 **2848**,永遠少 2 | 六輪以上,`del_hit` 固定 `+2848` |
| 2 | 那 2 頁在 crosvm 消失後 **`page_count != 0`** | scavenger 專撿 `page_count==0` 的 served 頁;以 4Hz 觸發 27 次橫跨 6.75s,一次都沒撿到,`orphan_freed` 全程 0 |
| 3 | **沒有人事後把它們 free 掉** | **唯讀**輪詢五分鐘(完全不寫 `reconcile`,entry 因此不會被 purge),`tracked=2` 紋風不動 |
| 4 | 是**實體損失**不只是記帳 | `served − refilled` 每輪 +2,池子必須向系統重新 acquire 補回 |
| 5 | **不是 share 模組** | `gunyah_host_share_gki_6.6` 的 `outstanding` = `total=0 dying=0 parked=0` |
| 6 | **不是 crosvm** | 取樣顯示行程在 `tracked` 掉到 2 的同一刻就消失了 |

### 這對前面的結論代表什麼

- **選項 A(`MIGRATE_ISOLATE`)不再被支持。** 它改變的是「free 往哪走」,而證據指向
  **根本沒有 free 發生**。§2.4 與 §3 的推薦作廢。
- 選項 B(前移 hook)同理無效——沒有 free 就沒有東西可攔。
- 選項 C(頁面不進 buddy)**仍然有意義**,但理由回到它原本的那個:拆掉配置側的 kretprobe。
  它是否也修掉這個洩漏,取決於下面兩個候選是哪一個。

### 兩個候選,現有 sysfs 分辨不了

- **(A) 核心側參照洩漏**:某個物件從沒放掉 ref,頁面永遠不會被 free。
  crosvm 與 share 模組都已排除,剩下 stock gunyah 驅動的 lend 路徑(GUP pin 沒 unpin 到)
  或 udmabuf。
- **(B) free 了但立刻被長壽的新主人配走**:free 繞過 hook(pcp),新主人一直不放。
  **只有這種情況 isolate 才有用。**

### 下一步(唯一該做的)

加一個 debugfs,把每個**殘留的 served entry** 印出 `pfn / page_count / PageCompound /
compound_order`,再對照 `/proc/kpageflags`(必要時開 `page_owner=on` 拿配置堆疊)。
這原本是 §4.2 的「可選」項,現在是**先決條件**——在拿到 pfn 之前,任何修法都是在猜。

## 4.6 **再更正:機制找到了,isolate 的推薦恢復**

§4.5 從「`page_count != 0`」推論「那 2 頁從沒被 free 過」。那個觀察有**兩種**解釋
(沒被 free / free 之後立刻被別人拿走),我挑錯了。分開兩者的是下面這個實驗。

### 決定性實驗:改顯示解析度

| 設定 | `held`(服務出去) | 缺口(`held − del_hit`) |
|---|---|---|
| `--mem 4096` + 1280×720 | 2850 | **2**(六輪全部) |
| `--mem 2048` + 1280×720 | 1826 | **2**(三輪全部) |
| `--mem 4096` + 640×480 | **2849** | **0 / 1** |

兩個關鍵讀數:

- **缺口與客體記憶體大小無關**(4GB 與 2GB 都恰好 2)。
- **改顯示解析度,`held` 少 1、缺口跟著掉**。

而 `held` 一直等於「客體 RAM + `gfx-host-mb` + `gpu-guest-mb` + N」:
4096→`2048+192+608+2`、2048→`1024+192+608+2`、640×480→`2048+192+608+1`。
**漏掉的就是那 N 個額外配置,而 N 跟顯示緩衝區的大小走**
(1280×720×4 = 3.5MB → 跨 2 個 2MB 頁;640×480×4 = 1.17MB → 1 個)。

### 為什麼這排除了「參照洩漏」

那幾個額外配置是 **crosvm 自己的匿名記憶體**,不是客體 RAM 也不是池子。
**匿名記憶體在 `exit_mmap()` 一定會被釋放**——除非被 GUP pin 住,
而 crosvm 私有堆上的顯示緩衝沒有任何人 pin 它。所以它們**確實被 free 了**。

### 完整機制

1. `exit_mm()` **先**跑(`kernel/exit.c:876`):crosvm 自己的匿名 THP(顯示緩衝)被釋放,
   是**最早的那幾個 order-9 free**。
2. 它們落進一個**空的** per-CPU THP list,停在沖刷門檻以下。
3. `exit_files()` **後**跑(`:884`):memfd 的 inode 被 evict → `shmem_truncate_range` →
   2848 頁洪水般湧入,把 pcp 灌爆、經 `free_pcppages_bulk` 溢流到 `__free_one_page`
   → **被 hook 接住**。
4. 最早那 N 頁一直留在 list 底部,之後被別的 THP 配置從 pcp 直接取走 →
   `page_count != 0` → scavenger 再也撿不回來 → 永久損失。

這解釋了全部觀察:**恰好 N 頁、六輪完全確定、與客體記憶體大小無關、隨顯示解析度改變、
以及事後永遠讀不到 `page_count == 0`。**

### 結論

**§2.4 選項 A(`MIGRATE_ISOLATE`)的推薦恢復**,而且現在有機制支撐:
池子頁的 free 一律不進 pcp,那 N 頁就會跟其他 2848 頁走同一條路進 hook。
§4.5 對選項 A / B 的作廢**撤回**;§4.5 其餘的排除(crosvm 行程、share 模組)仍然有效。

**仍然值得做 §4.2 的 pfn debugfs**——不是為了決定修法,而是為了在改完之後**證實**
缺口真的歸零、以及確認那 N 頁的身分(用 `page_owner` 拿配置堆疊最直接)。

### 但更便宜的修法在 crosvm 這邊

那 N 頁是 **crosvm 自己的顯示緩衝**。它們**根本不需要**池子的頁——
不需要實體連續、不會被 lend 給客體、不進 memparcel。是 kretprobe「看到 order-9 就服務」
把它們一起吃掉的。

所以有兩個獨立的修法,而且第一個便宜得多:

| | 做法 | 成本 | 副作用 |
|---|---|---|---|
| **crosvm 側(建議先做)** | 對顯示/VNC 緩衝下 `madvise(MADV_NOHUGEPAGE)`(或改成非 order-9 的配置) | 幾行,純使用者空間,**不動核心** | 順便**不再浪費 2 頁池子**在不需要的地方 |
| 模組側 | pool pageblock 標 `MIGRATE_ISOLATE`(§2.4 選項 A) | 需版本分支 + preflight 回讀 | 對**所有**早於 memfd 的 order-9 free 都有效,不只顯示緩衝 |

兩者不衝突:crosvm 側消滅這個特定來源,模組側則對「任何在 `exit_mm` 階段被釋放的池子頁」
都成立——包括未來新增的、我們還不知道的配置。
**先做 crosvm 側驗證缺口歸零,再決定要不要投入模組側。**

## 4.7 **最終機制:THP 被拆成 order-0 釋放,hook 根本看不見**

§4.6 說那幾頁「落進空的 pcp list 停在門檻以下」。**讀完 pcp 的程式碼之後,那是錯的。**

### 為什麼不是 pcp 殘留

```c
/* free_pcppages_bulk */
page = list_last_entry(list, struct page, pcp_list);   /* 尾端 = 最早進來的先走(FIFO) */
__free_one_page(page, pfn, zone, order, mt, FPI_NONE); /* ← hook 在這裡 */
```

- pcp 是 **FIFO** 沖刷,最早 free 的**最先**出去,不是留在底部。
- `drain_all_pages()` 會把整個 list 清空。模組在 destroy+3s 有一次 drain,
  我又用 reconcile 讓 `alloc_contig_range`(內部也 drain pcp)跑了幾十次。
  **只要它們在 pcp 裡,任何一次 drain 都會把它們沖進 hook。** 沒有。

### 真正的機制(模組註解早就寫了)

> any served entry whose page reads free AFTER the drain is a hook-missed free
> (**e.g. a split THP freed as order-0s**)

**那幾個顯示緩衝的 THP 在拆解時被拆成 512 個 order-0 頁釋放,不是一次 order-9。**
而 hook 的第一行就是 `if (order != PAGE_ORDER || !page) return;` ——**它從頭到尾沒看見。**

三個獨立證據:

| # | 觀察 | 推論 |
|---|---|---|
| 1 | `o9_seen` 每輪只有 **2848 + 雜訊**,不是 2850 | hook 連「看見一個 order-9 free」都沒有,不只是沒配對上 |
| 2 | 任何 drain 都救不回來 | 排除 pcp 殘留 |
| 3 | scavenger **有時候**救得回來(淨損失 0 的輪次) | 它的條件是 `page_count==0` 且 `alloc_contig_range` 能收回整個 2MB 窗口——**正是「拆成 512 個 order-0、碰巧都還 free」的簽名**;輸的時候是窗口已被別人破壞 |

### 對修法的影響

- **`MIGRATE_ISOLATE` 最終否決。** 它改變的是 order-9 free 的路由,而這裡**沒有 order-9 free**;
  isolate 之後那 512 個 order-0 一樣走 `__free_one_page(order=0)`,hook 一樣第一行就 return。
  §2.4 選項 A、§4.6 的恢復,**全部作廢**。
- **選項 B(前移 hook)同樣無效**,理由相同。
- **crosvm 側的 `MADV_NOHUGEPAGE` 不受影響,而且現在是唯一乾淨的解**:
  顯示緩衝不再是 THP → 不會被 kretprobe 服務 → 沒有東西可漏,順帶不再浪費池子的頁。

### 還沒回答的(不影響修法)

**為什麼那些 THP 會被拆?** 候選:配置器歸還記憶體時的 partial `MADV_DONTNEED`、
VMA 被切開、deferred-split shrinker。修法不需要知道答案,但如果要根治
「任何被拆的池子頁都收不回」這個通則,就需要——那要靠 §4.2 的 pfn debugfs
加上 `page_owner` 拿配置堆疊。

---

## 5. 本輪實測

### 5.1 漏損速率(六輪,`poolcycle.sh`)

```
cycle 1..6 lost: 0, 2, 2, 2, 2, 0     →  8 頁 / 6 輪 = 1.33 頁/輪,回收率 99.95%
```
**三輪不夠**:同一份建置的前三輪曾經連續量到 0。任何關於這個數字的結論都要 ≥6 輪。

### 5.2 兜底救不回來(四輪,`poolkick.sh`)

假說是「損失的頁只是晚到,錯過了模組那唯一一次 +3s drain」。測法:從**關機之前**就開始
每 0.25 秒寫一次 `reconcile`(它會跑 scavenger,而 `alloc_contig_range` 內部會 drain pcp),
一路持續到 crosvm 消失後 55 秒。

```
cycle 1..4: 每輪仍然 lost 2 pages    →  兜底一頁都沒救回來
```

**所以「調整兜底的時機」不是出路**,這也是為什麼 §3 的首選是改變 free 的**路由**而不是時機。

**但這個測法有一個混淆,必須寫下來**:`reconcile` 過了 `RECONCILE_GRACE_MS` 會**purge**
served entry,而模組自己的註解就說 purging reconcile「會丟掉它們待處理的 free,
hook 之後就配不上了」。所以有可能是猛踢 reconcile **自己造成**那 2 頁。
分辨方法很便宜——看 `del_miss`:

| 觀察 | 判讀 |
|---|---|
| `del_miss` 每輪 +2 | 頁面**有**走到 `__free_one_page`,只是 entry 已被 purge → 病在 entry 生命週期,**選項 A 幫不上** |
| `del_miss` 不動 | 頁面**從沒走到** hook,被 pcp 交給別人 → 病在路由,**選項 A 正中要害** |

### 5.3 判定:病在路由(三輪,`poolwhere.sh`)

全程不手動 reconcile,只讓模組自己的 +3s worker 跑,最後才結帳一次:

```
              lost   del_hit   del_miss      (每輪服務 2850 頁)
cycle 1        1     +2848      +32
cycle 2        0     +2848      +19
cycle 3        1     +2848      +22
```

兩個結論:

**(a) `del_hit` 每輪固定 +2848,恰好比服務出去的 2850 少 2。** 這一輪沒有任何提早的 purge,
entry 在 free 到達時都還活著,所以一個「有走到 `__free_one_page`」的頁必定會記成 del_hit。
它沒有 → **那 2 頁根本沒走到 hook**。`del_miss` 的 +19~32 是系統其他 order-9 free 的雜訊,
量級對不上。**病在路由,不在 entry 生命週期 → 選項 A 正中要害。**

**(b) 猛踢 reconcile 反而更糟:2/輪 → 0.67/輪。** §5.2 的混淆是真的。
`reconcile` 過了 grace 會 purge,而 free 還在陸續到達,被 purge 掉的 entry 之後就配不上了。

> **production 意涵**:模組註解提到「DroidVM 使用量面板每 ~2 秒 reconcile 一次」。
> 若屬實,那個輪詢會在每次關機後的 grace 邊界上 purge 掉還沒回來的 entry,**放大損失**。
> 這是一個獨立於本 survey、可以馬上檢查的東西:把面板的輪詢間隔拉長,或讓它讀一個
> 不會 purge 的唯讀入口。

### 5.4 精確時序:free 發生在 crosvm 退出那一刻(`poolwindow.sh` / `poolwhen2.sh`)

以 0.25 秒在手機上取樣,同時記 `tracked`、crosvm 是否還活著、`MemFree`:

```
 t(s)   tracked       crosvm   MemFree
 0.00   tracked=2850  alive    419480 kB
 3.00   tracked=2     gone     497656 kB      （之後 15 秒不再變動）
```

**crosvm 在 `crosvm stop` 之後還活著約 3 秒,而 `tracked` 正好在它消失的那一刻掉下來。**
所以頁面是在**行程退出、mm 被拆掉**的瞬間才 free 的,不是早就 free 然後在 pcp 裡躺了三秒。

機制因此很清楚:2850 個 order-9 free 同時湧向 `free_unref_page`,**pcp 的 THP list 一下就滿**,
超出的部分經 `free_pcppages_bulk` 溢流到 `__free_one_page`,2848 頁幾乎立刻被 hook 接住;
**剩下 2 頁停在 pcp 門檻以下,永遠沒被沖出來**——正是模組註解寫的
*can park a few of them in pcp lists indefinitely on an idle system*。

**這解釋了為什麼每輪恰好是 2**(`del_hit` 六輪全部 `+2848`):那不是機率性的偷竊,
是 pcp list 的殘留水位,**結構性的**。

兩個推論:

- **把 `PCP_DRAIN_DELAY_MS` 調小沒有用,甚至更糟**。free 發生在 t≈3s,而 drain 是從
  VM destroy 起算的;調小只會讓 drain 更早於 free。要用兜底修就得是**會重試的 reaper**
  (POOL_RECLAIM_PLAN §5),而那仍然是 best-effort。
- **isolate 的理由更強**:那 2 頁不是「來不及撿」,是**從一開始就不該進 pcp**。
  isolate 讓它們跟其他 2848 頁走同一條路、在同一瞬間進 hook,不需要 drain 也不需要 reaper。

> **更正**:本文件早先一版寫「free 在 250ms 內完成」,那是把 awk 只印變動行的取樣序號
> 讀錯了(第 13 個樣本是 t=3.0s)。同樣的誤讀也讓「crosvm 退出後才 free」的推測站不住——
> 實際上 free 與退出是同一刻。`poolwindow.sh` 的 `alive` 欄位另外被 `pgrep -f` 自我匹配
> 污染,`poolwhen2.sh` 用 `[c]rosvm` 修好了。

### 5.5 提早 scavenge 沒有幫助(三輪,`poolearly.sh`)

在 `RECONCILE_GRACE_MS` **之內**每 0.25 秒觸發一次 scavenger(grace 內不 purge,安全),
等於把掃描從 +3s 提前到 +0.25s:

```
cycle 1: lost=2  del_hit=+2848   tracked: 2850@0.0s → 2@3.5s
cycle 2: lost=0  del_hit=+2848   tracked: 2850@0.0s → 2@3.2s
cycle 3: lost=0  del_hit=+2848   tracked: 2850@0.0s → 2@3.5s
```

提早掃描**完全沒有改變時序**——因為那時候頁面根本還沒被 free(見 §5.4)。
`del_hit` 依然固定 `+2848`。淨損失 0~2 的差別來自事後 scavenger 撿不撿得回那 2 頁。

---

## 5. 不要再提案的(已有證據推翻,細節在 POOL_RECLAIM_PLAN.md §1、§2、§3、§7)

| 提案 | 為什麼不行 |
|---|---|
| donate ioctl(退出前把頁從 mapping 裡拿走) | memfd 頁屬於 inode,page cache 持有 512 ref,模組永遠不是唯一擁有者;唯一導出的 zap primitive 要求 `VM_PFNMAP`;正確版只是把 free 提早,接住的還是 hook |
| 對 **memfd 頁**在借出時多留一個 refcount | 破壞 folio split 與遷移(連自己的 scavenger 一起關掉),且 teardown 從此到不了 free path,模組再也收不到回收事件。**注意:對「模組自有、永不進 buddy」的頁面,這三條都不轉移,見 §2.3(b)** |
| 拿掉 system-wide hook 但仍用 memfd | 這顆 kernel 上沒有其他事件表示「這塊 2MB 剛剛 free 了」。只能換攔截點,不能不攔 |
| 只在有 VM 時才掛 hook | 自我抵銷:gate 的解除條件跟 hook 自己的 early-out 條件是同一個 |
| signal handler 裡 close-all-fds / donate | `exit_mm` 在 `exit_files` 之前;VM fd 被 dup 多次;RM reclaim 非同步 |
