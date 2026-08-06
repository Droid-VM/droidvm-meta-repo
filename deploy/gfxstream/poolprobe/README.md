# 池子洩漏的兩支診斷模組

這兩支模組把「每個 VM 生命週期漏 2 個 2MB 頁」從**猜了五次都猜錯**變成一次定案。
留著是因為同一類問題(池子頁沒回來)只有這條路能問到底。

## 為什麼是獨立模組,不是加進 gh_hugepage_reserve

換那個模組的新版要先 `rmmod`,而那會把 6GB 池子還給 buddy;在已經碎片化的手機上
**重新 acquire 3072 個 order-9 頁正是池子存在的理由所在**——拿不回來就要重開機才能再開 VM。
所以這兩支用 kallsyms 讀它的私有狀態,**完全不寫**。

## ghhr_probe — 殘留 served entry 的頁面真實狀態

一次性:`insmod` 後把結果印進 dmesg 然後回 `-EAGAIN`(不常駐,所以沒有拆卸路徑會出錯)。

```
insmod ghhr_probe.ko          # 會回 "Try again",那是正常的
dmesg | grep ghhr_probe
```

**跑之前先關掉 VM,而且不要寫 `reconcile`**——過了 grace 期的 reconcile 會 purge 掉
entry,那正是要看的東西。

輸出每筆:`pfn / count / mapcount / order / BUDDY LRU ANON SLAB LARGE DMA-PINNED / flags`,
外加它在不在模組自己的 `page_pool[]` 或 `limbo_pages[]` 裡。
`walked` 與 `served_count` 必須相符,不符代表 `struct served_node` 的佈局漂移了,輸出不可信。

判讀:

| 樣貌 | 意思 |
|---|---|
| `count=0` + `BUDDY` | 只是還在 buddy,scavenger 本來就該撿走 |
| `order=0` | folio **被拆過**,order-9 的 hook 結構上看不見 |
| `LRU` / `ANON` / `mapcount>0` | 已經是別人的頁 |
| `DMA-PINNED` | 有 GUP pin 壓著 |
| `count=1` `mapcount=0` 無旗標 只有 `PG_head` | **乾淨的 compound,被單一參照握著** ← 實際看到的 |

## ghhr_sites — order-9 配置的呼叫者直方圖

常駐收集,`rmmod` 卸載。回答「誰在要 order-9 的頁」。

```
insmod ghhr_sites.ko
echo 1 > /sys/module/ghhr_sites/parameters/sites     # 歸零
# ...跑一輪 VM...
cat /sys/module/ghhr_sites/parameters/sites
rmmod ghhr_sites
```

`page_owner` 本來是更直接的工具,但這支核心雖然 `CONFIG_PAGE_OWNER=y` 卻沒開,
而且 cmdline 帶著 `stack_depot_disable=on`,要開得改開機參數。這支不用重開機。

## 這兩支查出來的答案(2026-08-07)

```
total=2850 sites=4
    2784  dbgvm            __folio_alloc+0x18/0x38
      63  crosvm_vcpu0     __folio_alloc+0x18/0x38
       1  blockingPool0    __folio_alloc+0x18/0x38
       2  v_gpu            qcom_sys_heap_alloc_largest_available+0xb4/0x258 [qcom_dma_heaps]
```

`2784+63+1 = 2848` 走 `__folio_alloc`,**正好等於 hook 每輪回收的數字**;
剩下 2 頁由 crosvm 的 `v_gpu` 執行緒走**高通的 dma-buf system heap** 配置,**從來不還**。

那些頁在 `ghhr_probe` 眼中是完整 order-9、`count=1`、`mapcount=0`、只有 `PG_head`、
不在 pool/limbo——不進 buddy,所以 hook 看不到、scavenger 也撿不到。
而且**每輪的 pfn 都是新的**,所以是逐輪累積的真洩漏,不是同幾頁被借走。

詳見 `plans/POOL_HANDOFF_SURVEY.md` §4.9。
