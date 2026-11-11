# 手機與 host

host 端（手機、Gunyah、crosvm）的未解項目完整細節，從 `PROGRESS.md`「未解／待查」移來（原文照錄）。

## 11-11 5567 的大頁池補不滿

同一天稍早序列埠那條工作就碰過（PROGRESS「序列埠收尾」：池子從 2560 縮到約 2370，VM 暫以 4608 MB＝2304 頁開機）。
5567 停掉 UniXNU 27（為了換新 crosvm＋app）之後，池子只有 2370／2560 頁：停之前就是閒置 66 頁＋VM 用的 2304 頁，沒有掉頁
（abandoned、orphan 都是 0）。acquire 3、2 都回 `acquire_stop_reason=cma sources exhausted`；drop_caches＋compact_memory
之後也一樣（MemAvailable 約 1.6 GB）。vm.sh 依規則不開機（池子不滿開出來的 VM 會被少給頁面）。手機開機 6.4 天。
使用者 11-11：已知現象，每次關 VM 碎片化都會加劇一些，列為未來待解決事項；這次的處理是重開手機（之後使用者 insmod
KernelSU 目錄裡的 gh_hugepage_reserve.ko）。教訓：停掉一台 VM 之前先看 `pool_avail + served` 有沒有到 `pool_want`，沒到就是停了可能開不回來。

## 11-05 host 記憶體耗盡 guest 卡死

host 記憶體耗盡時 guest 卡死、恢復不了：5567 在截圖很多的測試裡 host 記憶體用光（anon 72 MB、GFP_NOWAIT 配置失敗、osvelte lowmem），adb 斷線，guest 所有 vCPU 停在 `gh_vcpu_ioctl`、timer 中斷 0、觸控叫不醒，只能重啟 VM；懷疑 crosvm／Gunyah 的中斷路徑在記憶體壓力下掉了 wakeup，未證實。有一次 18 分鐘後自己醒來，launchd reboot 時 APFS unmount panic（`vnode_rele_ext` usecount 變負），是另一個 kernel bug（懷疑 union／Data overlay）
