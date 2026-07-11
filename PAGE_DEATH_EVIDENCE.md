# Guest 頁面死亡(lent-page loss)證據包
2026-07-10 全天觀測彙整。供 gh_hugepage_reserve / LEND 路徑側調查使用。

## 2026-07-11 深夜更新:機制鎖定(見文末「深夜破案進度」)
- MC「無聲秒退」= 同一疾病:SIGBUS(BUS_OBJERR)→ JVM 寫 hs_err 時**連環再踩死頁**(G1 block_start / strrchr / frame walk 全 fault)→ 判定遞迴 → `os::abort()` → SIGABRT、無 hs_err、無 crash report。core + `VMError::_id=7`/`si_code=3` 實錘。
- **死亡是暫態的**:core dump 時 si_addr 位址已可讀(內容為合法 JIT 碼)——fault 當下 stage-2 不在,數百 ms 後回來。
- **時間相關釘死**:三個獨立窗口,MC 死亡秒 == share66 SHARE/UNSHARE 大型散裝 parcel(1500+ pages、entries≈pages)churn 秒;該窗口 guest 零 MEM_ACCEPT(vram 復用);穩態 GPU 負載(vkcube 80s)無 churn 無死亡。
- guest RAM 本 boot 100% 預先 LEND+pin(Phase1-4 全覆蓋 3968MB、16 slots)——排除 demand-paging 池空;gpa_watch(開 MC 前分配的 1GB,持續巡讀)全程無恙 → 死亡不隨機打舊頁。
- 機制假說:RM reclaim/share 的 `platform_memparcel_reclaim`/protect(QC SCM assign)對散裝 4K 實體頁範圍操作時,暫態影響同顆粒內相鄰 lent guest RAM 的 stage-2 → guest 訪問 → SEA → SIGBUS BUS_OBJERR(arm64 SEA-to-user 正是此 si_code)。
- A/B 決定性實驗:crosvm `GH_NO_UNSHARE=1`(跳過所有 reclaim,單調 label 防 EBUSY,故意洩漏)vs 正常模式。模組已先修 vm_file UAF(get_file 引用,任務#3 的 rmmod 崩潰隱患)。

### 馬拉松結果(2026-07-11 01:51-03:00,手機重啟後)
- **Arm A(正常 unshare churn)20/20 輪全存活**:背靠背 MC 啟動循環,每輪 150s 密集 blob churn(平均 447 entries/parcel、最大 13488),host free 壓至 300MB-1GB,VM uptime 跑到 68 分(跨過死亡年代的 45 分門檻),guest gpa_watch 巡讀 0 死頁,無 hs_err、無 SIGABRT。
- **結論:手機重啟清除了發病前置狀態**——死亡需要「重啟前累積的某種 host/hyp/RM 狀態」+ churn,單靠 churn+壓力+uptime 重建不出來。A/B 的 B 臂(GH_NO_UNSHARE)因基線無法復現而未跑,工具保留在 binary 裡(launch 時 env 即生效)。
- **下次發病時的即時 A/B 程序**:確認 rc=134/135 → `GH_NO_UNSHARE=1` 重啟 VM → 重跑同負載;死→非 reclaim churn 因;活→reclaim churn 實錘。
- 附帶量測:blob 池棘輪 = 每次 MC 開關淨 +8 頁(16MB;folio 拆分洩漏+ring 高水位),20 輪後地板 756MB/額度 2GB;VM 重啟全歸還。

## 現象指紋
- guest 進程隨機 `SIGBUS`(rc=135;JVM hs_err 顯示 `SIGBUS (0x7)`;strace 顯示 `BUS_OBJERR`)
- 受害者全是**檔案 mmap 頁**的使用者:uptime/libproc、evolution-source-registry、gnome-shell、localsearch(同一秒集體死)、java(CDS/class 頁,15ms 陣亡)、sudo、pgrep
- **guest `sync + echo 3 > drop_caches` 後立即復活**(page cache 重建 → 換新 guest 頁/新 host pfn)——死的是特定 guest 頁,其 GPA→host pfn 的 stage-2 懸空了
- 同一檔案 root 能跑、droidvm 死(或反之):只取決於各自觸到哪些頁,與權限無關

## 速率與相關性
| 時段 | host free | 死亡速率 |
|---|---|---|
| 早上(mlock 修復前) | ~3GB | 大負載後偶發 |
| mlock(`--prepare-lend-mthp-mode chunked`)修復後 | ~3GB | 顯著降低但未歸零 |
| 深夜(全天遊戲+頁緩存累積) | **612MB** | **分鐘級**(13:43 死→13:47 drop_caches→13:48 又死,連 sudo 都中彈) |
| host drop_caches 後 | 2.8GB | 立即緩解 |

- **與 host 記憶體壓力強相關**(核心線索)
- 與 crash→重啟→池補貨風暴窗口相關(早期觀測)
- **與純 GPU 負載無關**:80 秒 vkcube 重載,`compact_migrate_scanned` 零增長、java 存活

## 已排除(別回頭路)
1. **磁碟/檔案損壞**:debsums 全系統掃 ×1 + openjdk 專項 ×1,全 OK
2. **guest OOM**:kernel oom-killer 零記錄、systemd-oomd 零記錄、事發時 free 2GB+
3. **crash 截斷 dpkg 檔案**:debsums OK(scp 部署檔案被 crash 吃掉是真的,但那是未 sync 的新寫入,與此無關)
4. **BAR/blob 相關**:GPA 用量、blob 生命週期正常;此問題發生在無 GPU 活動的窗口

## 機制假說(按嫌疑排序)
1. **host reclaim(kswapd/direct reclaim)動了 lent 頁**:host free 見底時最烈。mlock 應擋 reclaim——但 mlock 語義只覆蓋 mapped VA;guest-memfd/shmem 頁在 crosvm VA mlock 之外是否有其他可回收路徑(fallocate punch?shrinker?)需內核側確認
2. **模組補貨路徑遷移**:`acquire_sweep`/`alloc_contig_range` 組裝 order-9 時遷移擋路 movable 頁;若 lent 頁無 longterm pin,mlock 擋不住 migration
3. **khugepaged/kcompactd 遷移**:同上,mlock 不擋 migration

三者共同前提:**lent 頁對 host MM 而言仍是普通 movable/可回收頁**——這是要證偽的核心命題。

## 模組側三問(決定性)
1. 池頁是否從 movable allocator **徹底隔離**(compaction/alloc_contig 掃不到)?
2. LEND 提供路徑(6.6 demand-paging / chunked)**每一頁**是否真有 `FOLL_LONGTERM` pin?(勿假設;`gunyah_gup_share_parcel` 有 gup,但 chunked 模式的實際 provide 路徑要驗)
3. acquire/reclaim/exchange/limbo 各路徑是否**排除 served-pfn**(pb_track/served 表有現成資料)?

## 決定性實驗(留給模組側,有殺 VM 風險我沒跑)
- 健康 guest(drop_caches 後 java rc=0)→ host `echo 1 > /proc/sys/vm/compact_memory` 強制全域壓實 → 立即驗 guest java:死 = migration 動得了 lent 頁,實錘;活(反覆多次)= 遷移免疫,轉向 reclaim 路徑
- 對已知 lent pfn(share66 SHARE log 的 phys/mem_entries)在 host 查 `/proc/kpageflags`;或在模組加一個 debugfs:對指定 pfn 呼叫 `folio_maybe_dma_pinned()` 直接回答「有沒有 pin」

## 現行緩解(創可貼)
- `mc_common.sh` 啟動前自動 `sudo mc-fresh-pages`(guest drop_caches;sudoers 已配)
- host free 見底時手動 `sync; echo 3 > /proc/sys/vm/drop_caches`(Android host 側)
- 註:guest swapfile 這次 boot 沒掛(fstab 缺項),與本問題無關但順手可補

## 診斷工具箱
- 快篩:guest `java -version`(rc=135 = 中毒)
- 復活驗證:guest drop_caches → 復活 = 本問題
- host 壓力:`free -m`、`/proc/pressure/memory`
- 遷移計數:`/proc/vmstat` 的 `pgmigrate_success` / `compact_migrate_scanned` 事發窗口前後對比
