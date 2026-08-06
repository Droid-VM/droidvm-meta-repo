# 池子的拿取與歸還:有沒有可靠的路徑(含成本帳)

Survey,2026-08-06。問題:退出路徑上補「主動歸還」有沒有用、udmabuf 是不是多一條歸還路徑、
專用的 `/dev/gh_udmabuf` 能不能保證 100%、以及**這些攔截各自的綜合性能代價**。

## 結論先講

1. **主動歸還解不了實測到的損失。** 損失的原因不是「還得太晚」也不是「被拆散」,
   而是**頁面以 order-9 被 free 了,卻停在 per-CPU 的 THP free list,而 hook 掛在它的下游**。
2. **把現有 memfd 包成 udmabuf 沒有用**;但「模組自己配置、自己 export」是真的新路徑。
3. **在你的性能限制下,結論會翻轉**:唯一「便宜又對得上機制」的修法(把 hook 前移到 pcp 之前)
   **觸發次數嚴格更多**,所以它買到 0.047% 卻要付更多錢——**不該做**。
   要同時拿到正確性和性能,只有讓頁面**根本不進 buddy**。
4. **那條路的地基卡在一個已經由原始碼回答的問題上**:客體 RAM 必須被 GUP pin,
   而**所有 in-tree 的 dma_buf exporter 都設 `VM_PFNMAP`,GUP 對這種 VMA 無條件 `-EFAULT`**。
   所以它不能是一個「照慣例做的 dma_buf」,必須是自有 chardev + `vm_insert_page`。

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

### 2.3 「`/dev/gh_udmabuf` 專供 order-9,能保證 100% 嗎?」

方向對——它就是 POOL_RECLAIM_PLAN §3 說的「唯一的真出路:把 pool 頁面完全移出 buddy 管轄
+ 自有 allocator」。但**它不能是一個照慣例做的 dma_buf**,原因如下。

#### (a) 硬性阻擋:dma_buf 的 CPU mapping 不可被 GUP pin

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

出路:自有 chardev,`mmap` 用 **`vm_insert_page`**(refcounted struct page、`VM_MIXEDMAP`、
**不設** `VM_PFNMAP`)。這偏離 dma_buf 慣例,但我們自己的裝置可以這樣做。
(慣例的理由也很清楚:dma_buf 要 exporter 能控制 buffer 的搬移與釋放,
允許 long-term GUP pin 會拿掉那個控制權——而我們**正好想要**那個 pin。)

#### (b) 這看起來像被否決過的「借出時持有 refcount」,但不是同一件事

POOL_RECLAIM_PLAN §2 否決過「模組借出時自己留一個 ref」,三個理由是:
①破壞 folio split(punch-hole 需要)、②破壞遷移(連自己的 `alloc_contig_range` scavenger
一起關掉)、③移除模組唯一的回收事件。

**對「模組自有、永不進 buddy」的頁面,三個理由都不轉移:**

- ① punch-hole 已經被 `F_SEAL_SHRINK` 封死了(§2.1),我們沒有在用它。
- ② 我們**不希望**這些頁被遷移;而且不再需要 scavenger,因為根本不會弄丟。
- ③ 回收事件變成 `vm_ops->close` / 最後一個 ref 掉落,那是確定性的。

這一段必須寫下來,否則下一個讀 §2 的人會以為這是在重提被否決的設計。

#### (c) 仍然不是 O(0):歸還時機受 pin 牽制

最後一個 ref 掉落才能回收,而 gunyah 在 reclaim 之前一直 pin 著。
所以歸還變成**確定會發生,但不是立刻**——模組仍需要一個有界的等待/重試,
只是它等的是「pin 放掉」而不是「猜頁面回 buddy 了沒」。這是好交易,別宣稱成瞬時。

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

### ❌ 不要做:把 free hook 前移到 pcp 之前

這棵 kernel 有兩個更早的 bypass hook(`android_vh_free_page_bypass` @ `free_unref_page`、
`android_vh_free_folio_bypass` @ `free_unref_folios`),它們在**任何 pcp 插入之前**,
直接命中 §0.2 的機制,而且快路徑閘門一樣是 `order != 9 → return`。

**但它們的觸發次數嚴格多於現在**:今天的 hook 收不到「進 pcp 後又被 pcp 配走」的頁,
而 `free_unref_page` **每一次 free 都收**——那正好是熱路徑上最常見的情況。
它是**正確性修正,不是成本改善**,買到的是 0.047%。

**在「要考慮綜合性能」的前提下,這個交易不划算。** 保留在文件裡是為了說明為什麼不做。
(如果哪天決定要做:三個都掛、不要做 primary/fallback 推舉——走哪條 free path 是 runtime
由別的廠商模組 `android_vh_customize_thp_pcp_order` 決定的;並且這兩個符號不在
`abi_gki_aarch64_honor` 清單裡,要靠 kapi preflight 偵測。細節見 POOL_RECLAIM_PLAN §4.2–4.4。)

### ✅ 值得做:自有 chardev + `vm_insert_page`,頁面永不進 buddy

它同時解決兩件事,這是它勝過所有其他選項的地方:

| | 現況 | 改後 |
|---|---|---|
| 配置側 | kretprobe on `__alloc_pages`,**全系統每次配置** | **拆掉**(模組自己配置) |
| 釋放側 | tracepoint on `__free_one_page`,每頁回 buddy | **拆掉**(頁面不進 buddy) |
| 歸還率 | 99.95%,每輪固定丟 ~1.33 頁 | 100%(池子頁面這一層) |
| SIGKILL | 靠 kernel free path,會漏 | 涵蓋(`exit_files` 保證關 fd) |
| 遷移/拆散 | 靠 pin + 封印擋住大部分 | 不適用(頁不在 buddy 管轄內) |

前提是 §2.3(a):`mmap` 必須用 `vm_insert_page`,不能是 `VM_PFNMAP`。

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

---

## 5. 不要再提案的(已有證據推翻,細節在 POOL_RECLAIM_PLAN.md §1、§2、§3、§7)

| 提案 | 為什麼不行 |
|---|---|
| donate ioctl(退出前把頁從 mapping 裡拿走) | memfd 頁屬於 inode,page cache 持有 512 ref,模組永遠不是唯一擁有者;唯一導出的 zap primitive 要求 `VM_PFNMAP`;正確版只是把 free 提早,接住的還是 hook |
| 對 **memfd 頁**在借出時多留一個 refcount | 破壞 folio split 與遷移(連自己的 scavenger 一起關掉),且 teardown 從此到不了 free path,模組再也收不到回收事件。**注意:對「模組自有、永不進 buddy」的頁面,這三條都不轉移,見 §2.3(b)** |
| 拿掉 system-wide hook 但仍用 memfd | 這顆 kernel 上沒有其他事件表示「這塊 2MB 剛剛 free 了」。只能換攔截點,不能不攔 |
| 只在有 VM 時才掛 hook | 自我抵銷:gate 的解除條件跟 hook 自己的 early-out 條件是同一個 |
| signal handler 裡 close-all-fds / donate | `exit_mm` 在 `exit_files` 之前;VM fd 被 dup 多次;RM reclaim 非同步 |
