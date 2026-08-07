# 池子回收:退出路徑與攔截點

狀態:設計定案,未實作。2026-07-30。

目標是「crosvm 跟模組拿記憶體、還給模組,不要每次關機都漏一點」。
這份文件的一半篇幅是**被證據推翻的設計**,因為它們看起來都很合理,不寫下來會被重新提案。

---

## 0. 實測基準線

`deploy/gfxstream/pool_leak_rate.sh`,purepool 模式,每輪借出 ~2565 頁(2MB/頁):

| 模式 | 借出 | 收回 | 永久損失 |
|---|---|---|---|
| poweroff 1 | 2565 | 2563 | 2 |
| poweroff 2 | 2564 | 2563 | 1 |
| sigterm 1 | 2563 | 2562 | 1 |
| sigterm 2 | 2565 | 2564 | 1 |

**每次關機丟 1–2 頁(2–4 MB),poweroff 與 sigterm 無差別,`served_reacquire_free_orphans()` 每次撿回 0 頁。**
`acquire` 補得回來(代價是一次頁面遷移,壓力下會失敗),所以症狀是「池子慢慢變小 + 補回來的成本」,
不是「池子歸零」。任何改動都要對著這張表驗。

---

## 1. 被推翻的:donate ioctl(不要再提案)

提案是:crosvm 退出前呼叫模組 ioctl,模組把頁面**從 crosvm 還活著的 mapping 裡直接拿走**,
`folio_get()` → zap → 重建 order-9 → 進池,全程不碰 buddy。

### 1.1 致命:guest memory 是 memfd,頁面屬於 inode 不屬於 mapping

crosvm 的 guest memory 走 `SharedMemory::new` → `memfd_create`,所以模組借出去的 order-9 folio
是 **shmem page-cache folio**。page cache 自己就持有 `folio_nr_pages()` = **512 個 ref**
(`SM8750/mm/shmem.c:788`、`mm/filemap.c:264-266`)。

zap 只掉 per-PTE 的 ref,**模組永遠不會變成唯一擁有者**。而 `rebuild_order9_compound()`
(`parts/gh_hooks.c.inc:33-38`)會 `set_page_count(head, 1)` + `prep_compound_page()` ——
在 xarray 仍指向該 folio 的情況下這麼做就是**立即的記憶體毀損**。

### 1.2 致命:唯一導出的 zap primitive 用不了

`zap_vma_ptes` 在 `mm/memory.c:1955-1957` 開頭就 `if (!(vma->vm_flags & VM_PFNMAP)) return -EINVAL`。
memfd VMA 不是 PFNMAP,匿名 VMA 也不是。其餘 zap 路徑(`zap_page_range_single` 等)未導出。

### 1.3 就算改成「正確版 donate」也沒有解決問題

正確版是 crosvm 自己對 memfd 打洞(`FALLOC_FL_PUNCH_HOLE`),頁面正常走 kernel free path 回來。
但那樣**真正把頁面接住的仍然是 hook**,donate 只是把「何時 free」提早,不是「誰接住」。
拿不到提案想要的「不需要 hook」。

### 1.4 致命:「close VM fd」不是一個 close,而且 reclaim 是非同步的

- VM fd 被 dup 約 **3×vcpu + 3** 次(`hypervisor/src/gunyah/mod.rs:593/:656/:884`、
  `devices/src/irqchip/gunyah.rs:142`),vcpu fd 另外也 pin 住 driver 的 VM object。
  driver 只在**最後一個** close 才跑 `gunyah_vm_release`。
- RM reclaim 在那之後仍是非同步的 —— `gunyah_share_66.c:197-220` 自己就 retry 2s×60,那是證據。

所以 signal handler 裡「close VM fd → 立刻 ioctl」既不同步也不可靠:handler 幾乎必然在頁面回來之前
就 `_exit` 了。

### 1.5 致命:程序死亡時的順序跟需求相反

`exit_mm` 在 `exit_files` **之前**。也就是 kernel 先拆 mm(頁面已經開始還)才關 fd(VM 才被釋放)。
donate 需要的順序(先關 fd、再趁 mapping 還在把頁拿走)在非自願路徑上根本不成立。

---

## 2b. 【2026-08-07 復活】借出時持有一個 refcount —— 這是「機制上 100%」的唯一走法

下面 §2 在 2026-07-30 否決了這個設計。**那三條理由在今天的證據下全部反轉**,而且它是目前
唯一能把回收從「偵測」變成「所有權」、因而可以**整個拆掉兜底**的做法。

### 為什麼偵測永遠做不到 100%

今天的回收靠「在 `__free_one_page` 看到那一頁回 buddy」。它會漏,而且漏得有結構性:

- **folio 被拆**:遷移失敗會退回去 `split_folio`,512 個 order-0 free 對 order-9 的 hook
  完全隱形。模組自己的 scavenger 註解就寫著 *e.g. a split THP freed as order-0s*。
- served entry 在 free 抵達前被 purge(grace 邊界)。
- 頁面走了 hook 沒涵蓋的釋放路徑。

所以才需要 `drain_all_pages` + `alloc_contig_range` 的兜底,而兜底**依定義**是 best-effort:
`alloc_contig_range` 只有在整個 2MB 窗口都還空著時才成功。

### 機制:借出時 `folio_get()`,收回時看 refcount

一個額外的參照讓那一頁同時變成**拆不開、搬不走、別人放不掉**:

| 想擋的事 | 核心怎麼擋 | 位置 |
|---|---|---|
| 拆分 | `if (!can_split_folio(folio, &extra_pins)) ret = -EAGAIN;` | `mm/huge_memory.c` |
| 遷移 | `folio_ref_freeze(folio, expected_count)` 失敗即中止 | `mm/migrate.c:439/458` |
| 被別人釋放 | `shmem_evict_inode` → `shmem_truncate_range` 只把 folio 移出 page cache 並放掉快取的 ref,**不要求 refcount 歸零** | `mm/shmem.c` |

於是回收不再是「偵測一個可能錯過的釋放」,而是「它一直是我們的,只要知道別人何時放手」:
**`folio_ref_count(folio) == 1 && folio->mapping == NULL`**。

### §2 的三條否決理由為什麼反轉

| 原否決理由 | 今天 |
|---|---|
| 破壞 folio split(punch-hole 需要) | **split 正是損失來源,擋掉它才是目的**。crosvm 上了 `F_SEAL_SHRINK` 且 `--no-balloon`,沒有路徑會 punch-hole |
| 破壞遷移,連自己的 `alloc_contig_range` scavenger 一起關掉 | **scavenger 就是要拿掉的兜底** |
| 移除模組唯一的回收事件 | **不再需要事件**——頁面沒離開過我們手上 |

### 附帶好處:釋放側的全系統 tracepoint 可以整個拆掉

頁面永遠不進 buddy,所以 `android_vh_free_one_page_bypass`(全系統每頁回 buddy 都打一次)
不再需要。**兩個全系統攔截點去掉一個**,只剩配置側的 kretprobe——那是發頁的必要手段。

### 要付的代價(動手前先接受)

- **借出期間的 punch-hole 會靜默失效**:`shmem_undo_range` 對部分範圍會 `split_folio`,
  失敗就跳過,那段範圍不會被釋放。**這不是成本**——balloon 在 gunyah 平台上目前根本做不到,
  而且**balloon 與這個模組永遠互斥**:要能 balloon 就要高通官方支援 4K 小頁,
  而那一天到來時就不需要這個模組了(池子存在的理由正是 gunyah 的映射數量上限逼著用 2MB)。
  所以「擋住 split」不會擋到任何我們將來想要的東西。
- **`rmmod` 必須放掉所有持有的 ref**,否則就從「池子漏頁」升級成「真的洩漏」。
  拆卸序列本來就有註解寫明順序,這一步要進清單。
- **時機仍是非同步的**:需要一個有界的 sweep(destroy → 行程退出 → 掃 served 表)。
  但那是**時機不確定,不是結果不確定**——頁面跑不掉,只會晚到。這正是機制與 best-effort 的差別。
- 客體 RAM 的 swap/reclaim 會失敗——今天已經如此(被 gunyah pin 住)。

### 驗收

- `served == refilled`,且**把 `drain_all_pages` 與 `served_reacquire_free_orphans` 拿掉之後仍然成立**。
  今天的 0 損失是「有兜底」的 0;這個設計要的是「沒有兜底」的 0。
- `dbg_take_fail`、`orphan_inuse` 恆為 0。
- 用 `deploy/gfxstream/poolprobe/ghhr_probe` 確認殘留 entry 為空。

---

## 2. 被推翻的:借出時持有一個 refcount(**已於 §2b 復活,先讀那節**)

提案是模組借出時自己留一個 ref,mapping 消失時 refcount 掉到 1 而不是 0,頁面永不進 buddy,
連 SIGKILL 都 100% 涵蓋。

三個獨立的致命問題:

1. **永久破壞 folio split**(`mm/huge_memory.c:3364`、`:3487` 檢查 expected refcount)。
   而 crosvm 的 `FALLOC_FL_PUNCH_HOLE` 需要 split。
2. **永久破壞遷移**(`mm/migrate.c:433/439/464` 的 `expected_count`),而這正好會**停用模組自己的
   `alloc_contig_range` scavenger** —— 把唯一的補救手段也一起關掉。
3. **移除模組唯一的回收事件**:有 ref 撐著,memfd teardown 永遠到不了 free path,hook 從此不再觸發。
   模組會變成「頁面確實沒被別人拿走,但模組也不知道它自由了」。

另註:`FOLL_LONGTERM` **不會**把 folio 移出普通的 `MIGRATE_MOVABLE` pageblock ——
`folio_is_longterm_pinnable()` 只對 MIGRATE_CMA / MIGRATE_ISOLATE / ZONE_MOVABLE / device-coherent 回 false。
所以先前擔心的「CMA 池頁 pin 不起來」只在真的 CMA 來源時才發生。這條擔憂降級,但不是消失
(`CONFIG_DMA_CMA=y`、`CMA_AREAS=16`,dma-buf heap 是活躍呼叫者)。

---

## 3. 被推翻的:拿掉 system-wide hook

**這個目標在這顆 kernel 上拿不到。** 沒有任何其他事件表示「這塊 2MB 剛剛變 free」,
userspace 也遞不了頁面。能做的只有換一個攔截點、或改變掛載時機。

唯一的真出路是把 pool 頁面**完全移出 buddy 的管轄**(開機時 reserve / CMA 專區 + 自有 allocator),
那是另一個設計,不在這份 plan 裡。

---

## 4. 要做的:攔截點前移(唯一的真修正)

### 4.1 為什麼今天會漏

`pcp_allowed_order()` 對 `order == pageblock_order`(=9)回 true,所以 **2MB 的 free 會先進 THP pcp list**,
要等 drain 才碰到 `__free_one_page` 的 hook。這中間 `rmqueue_pcplist` 可以把頁面直接發給任何人 ——
hook 從頭到尾不觸發。模組現有的補救是 destroy 後 3 秒的 `pcp_drain_worker`,
**那 1–2 張就是在 drain 之前被搶走的**。

### 4.2 改法

這棵樹(6.6.118)有兩個更早的 bypass hook,都在 `free_pages_prepare()` 之後、**任何 pcp 插入之前**:

| hook | 位置 | 涵蓋 |
|---|---|---|
| `android_vh_free_folio_bypass` | `mm/page_alloc.c:2713`,`free_unref_folios` 第一迴圈 | VM fd 先關 → truncate 走 folio_batch |
| `android_vh_free_page_bypass` | `mm/page_alloc.c:2653`,`free_unref_page` | memfd 先關 → `__folio_put_large` |

**兩個都必須註冊**:crosvm 死亡時 `exit_files` 關 fd 的順序是 fd table 順序,不可控,兩種順序走不同的 free path。

頁面狀態(compound 已拆、refcount 凍結在 0、mapping 已清)與今天 `__free_one_page` 看到的**完全相同**,
所以 `pool_take_frozen()` / `pool_take_frozen_exchange()` 原封不動重用。

TP_PROTO:`SM8750/include/trace/hooks/mm.h:490-495`;export:`drivers/android/vendor_hooks.c:579-580`。
注意 order 是 `unsigned int`(舊 hook 是 `int`),kCFI/BTF preflight 會抓型別不符。

### 4.3 三個都掛,不要做 primary/fallback 推舉

綜合設計原本主張「按符號存在與否推舉一個」。**那是錯的**:走哪條 free path 是 runtime 由別的廠商模組
(`android_vh_customize_thp_pcp_order`)決定的,insmod 時推舉必然判斷錯。

`served_del()` 是 raw spinlock 下的原子摘除(`gh_data.c.inc:548-575`),重複觸發不會雙重回收。
成本問題用分站點計數器量完再砍,不要先砍。

### 4.4 成本方向可能是反的 —— 必須量

新 hook 點的觸發次數**嚴格多於**舊的:`__free_one_page` 收不到「進 pcp 後又被 pcp 配走」的頁,
而 `free_unref_page` / `free_unref_folios` **每一次 free 都收**。

所以 §4 是**正確性修正,不是成本改善**。不能同時宣稱兩者。
最低限度:新舊並行掛一段時間,用分站點的 `dbg_o9_seen` 比對觸發次數與 order 分佈,再決定要不要拿掉舊的。

順帶記錄真正的成本結構(先前被我低估過):

| | 機制 | 位置 | 頻率 |
|---|---|---|---|
| 配置側 | **kretprobe** | `__alloc_pages`(`parts/gh_hooks.c.inc:765`) | 全系統每次配置 |
| 釋放側 | vendor tracepoint | `__free_one_page`(**不是** `free_one_page`) | 全系統每頁回 buddy |

arm64 **不選 `HAVE_STATIC_CALL`**,所以 tracepoint 是 `__traceiter_*` out-of-line + 每 probe 一次
kCFI 檢查的間接呼叫。而且 **kretprobe 那個更貴**,本 plan 動不到它。

---

## 5. 要做的:reaper 收斂

現況 `pcp_drain_worker` 是一次性的。改成會重試的 reaper,但避開三個坑:

- **最後一輪必須 purge,不是放棄。** 今天唯一會 purge 的 `served_do_reconcile()` 只有兩個呼叫點,
  **都是 sysfs**。無人操作的手機上,回收失敗的 entry 會永遠留著。tries 用完就 `served_del` + 記 lost。
- **`tries` 只在 outstanding 由 0 變正時重置**,不是每次 destroy。否則「一次 kill = 很多個 gunyah fd」
  加上部署腳本反覆重啟 VM,會讓 `drain_all_pages(NULL)` 變成永久 0.5Hz 的全系統 IPI。
- **自己的 workqueue**(`alloc_workqueue(WQ_UNBOUND | WQ_FREEZABLE)`),不要佔 `system_wq`;
  `drain_all_pages` 只在第一輪做;retry 間隔指數退避。

### 5.1 rmmod 拆卸序列必須一起改

`hugepage_reserve_exit` 的順序是刻意設計並寫了註解的。新增的 work item / waitqueue / chardev
不進拆卸清單就是 **use-after-free**。新順序:`misc_deregister()` 最前面(且 `fops.owner = THIS_MODULE`),
新 work 進 cancel 清單並維持「probe 先、work 後」的相依,cancel 前 `wake_up_all()`。

---

## 6. 可選:advisory kick ioctl

`/dev/gh_hugepage_reserve` + `GHHR_IOC_VM_GONE`。語意是**催一下**:同步跑一次 drain+reacquire,
回報 outstanding / recovered / pool_avail。**永遠 return 0,絕不能是正確性的必要條件。**

- 必須是 `wait_event_interruptible_timeout`。不可中斷的版本會做出**打不死的 D-state crosvm**,
  而本專案的規則是「絕不 kill -9 crosvm」—— 操作者會被逼進死角。
- timeout 上限 **≤5 秒**。超過還沒回來的頁 reaper 本來就會處理,阻塞呼叫者沒有意義。
- key 用 tgid。對「同一 tgid 連開多個 VM」沒有防護,多 VM 並存時要改成 create 時發 token。

---

## 7. 被推翻的:§2「只在有 VM 時才掛 hook」

自我抵銷。它的解除條件(`served_count == 0`)跟 hook 自己的 early-out 條件**是同一個**:

- gate 允許卸載時,hook 早就是兩個比較的 no-op
- hook 真的在做事時,gate 永遠禁止卸載

現況的 early-out 已經是最便宜的答案。真要動態化,gate 必須改成「有沒有 tracked owner」,
並且接受 `served_count > 0` 時卸載會**永久放棄那些頁**(改由 reacquire 全權負責)—— 那是另一個取捨。

也**不要**用 `static_key_disable()` 去 NOP 掉 tracepoint 的 key:tracepoint 自己用
`static_key_slow_inc/dec` 記數,會打架,unregister 時 jump_label negative count。

---

## 8. crosvm 側:全部可選,而且大多要刪掉

模組的回收率**不依賴 crosvm 任何改動** —— `gh_vm_free` 的 kprobe 在 SIGKILL/OOM/強殺下照樣觸發。

被推翻的三項:

- **punch-hole:純風險零收益。** crosvm 幾個敘述之後就 `process::exit`,memfd 本來就會被銷毀;
  而任何還活著的 mapper 會把剛打的洞**重新 fault 成全新的頁**,在拆機當下反而配記憶體。
  另外 shmem 的 PUNCH_HOLE 分支不檢查 `signal_pending` 且持 `inode_lock`。
- **join simplefb display thread:會永久掛住。** 那條 thread 根本沒有 stop 機制
  (`simplefb_display.rs:61`),join 之後連新的 SIGTERM handler 也救不回來,只剩 kill -9(= 洩漏 memparcel)。
  要控制 `GuestMemory` 釋放時機就在 `run_control` 內自留一份 clone,那一步就夠了。
- **signal handler 裡 close-all-fds / donate ioctl / VM fd registry:不要做。** 見 §1.4、§1.5。

值得做的一項:**SIGTERM/SIGINT handler**(全樹目前完全沒有),理由是 memparcel 洩漏而非頁面回收。
但不能照字面寫 `exit_evt.signal()` —— crosvm Linux 沒有 exit_evt,退出訊號走 `SendTube`
(serde 序列化 + 配置),那正是 handler 裡不能做的事。正解:
run_control 進 loop 前建一個 `Event`,raw fd 存進 `static AtomicI32`(初值 -1),
`wait_ctx.add` 給一個 `Token::Signal`;handler 只做 `write(fd, &1u64, 8)`(先存 errno 再還原)。
fd 生命週期兩端都要守:`<0` 時改用 `signal(sig, SIG_DFL) + raise(sig)` 恢復預設處置(不要靜默吞掉),
離開 run_control 時先 Release-store `-1` 再 drop 那個 Event。

---

## 9. 獨立的真 bug:fatal signal handler 只有 SIGABRT 生效

跟本 plan 無關,但在同一次調查中查出來,而且**推翻了先前「SIGABRT 不再打死主機」的涵蓋範圍宣稱**。

- `install_crash_handler()`(`crosvm/src/main.rs:770`)**覆蓋掉** `install_fatal_signal_handlers()`
  (`:979`)對 SIGSEGV/SIGBUS/SIGILL/SIGFPE 的設定。**今天只有 SIGABRT 真的走到 `_exit`。**
  (先前那次 1281-fd 的 SIGABRT 實測結果仍然成立 —— 測的正好是唯一生效的那個。)
- `crash_signal_handler` 帶 `SA_RESETHAND` 且正常返回 → 故障指令重跑 → 進 tombstone,
  也就是那條實測會把手機打重開的 userspace crash 路徑。
- 更糟:它會 **malloc**。handler 裡 malloc 可以死鎖 → 程序不死也不 exit → `exit_files` 永遠不跑 →
  **模組一張頁面都收不回**。這直接打穿「kernel 會免費幫我們做」的地基。
- `base::linux::register_signal_handler`(`base/src/sys/linux/signal.rs:301-312`)只設 `SA_RESTART`,
  **沒有 SA_ONSTACK、沒有 altstack** —— stack overflow 造成的 SIGSEGV 跑不了 handler。
  而且 altstack 只有 `base::WorkerThread` 開的 thread 有,vcpu thread / simplefb / VNC /
  gfxstream 自己開的 thread 都沒有。

修法:保留 crash handler 的診斷但砍到 async-signal-safe ——
只用固定 buffer + raw write 印 signum/tid/pc/lr(`panic_hook.rs:250-270` 已經是這種寫法),
`:290` 之後所有會 malloc 的整段刪掉,然後立刻 `_exit`。
`sa_mask` 要 `sigaddset` 全部四個 fatal signal,讓巢狀變成致命而非遞迴。

---

## 10. 未驗證(動手前要先確認)

- crosvm 的 memfd region 實際上**有沒有拿到 order-9 folio**。kretprobe 是在 `__alloc_pages(order==9)`
  攔截,所以「服務出去的那一刻」一定是 order-9;但之後 shmem 會不會 split(partial punch-hole、
  partial munmap、`split_huge_page`)**沒有量過**。split 之後 hook 完全接不到,只剩 `alloc_contig_range`。
- `gh_vm_free` / `gunyah_vm_release` 這個 kprobe 點距離真正的 `unpin_user_page`
  (`vm_mgr.c:978`)有多遠。reaper 的上限要用實測的收斂時間校正,不要猜。
- unpin 之後、free 之前那段,folio 仍可能被 `alloc_contig_range`/CMA 遷走。理論上來源 folio 被
  `folio_put` 釋放時仍會打到我們的 hook(pfn 還在 served table),但**沒有實測過**,值得加計數器。
- `android_vh_free_folio_bypass` / `android_vh_free_page_bypass` 在 6.6.118 樹與
  `abi_gki_aarch64.stg` 裡都在,但**不在 `abi_gki_aarch64_honor` 清單裡**(只有 `free_one_page_bypass` 在),
  也未確認 6.1 / 6.12+ GKI 是否都有。必須靠 kapi preflight 偵測 + fallback,不能假設。
- `free_unref_folios` 第一迴圈設 skip 之後 folio 不會進第二迴圈的批次 —— 讀碼確認過,
  但這是 kernel 內部結構,**任何 GKI uprev 都要重讀** `mm/page_alloc.c`,BTF preflight 抓不到。

---

## 11. 相關

- `deploy/gfxstream/pool_leak_rate.sh` —— 基準線量測,任何改動用它驗
- `deploy/gfxstream/sigkill_blast_radius.sh` —— 死亡路徑的爆炸半徑
- `deploy/gfxstream/harness/preflight.sh` —— 讀 orphan 計數前必須先 reconcile,否則舊值會黏住擋掉每一輪
