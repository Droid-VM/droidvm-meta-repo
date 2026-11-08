# 手機與 host

host 端（手機、Gunyah、crosvm）的未解項目完整細節，從 `PROGRESS.md`「未解／待查」移來（原文照錄）。

## 11-05 host 記憶體耗盡 guest 卡死

host 記憶體耗盡時 guest 卡死、恢復不了：5567 在截圖很多的測試裡 host 記憶體用光（anon 72 MB、GFP_NOWAIT 配置失敗、osvelte lowmem），adb 斷線，guest 所有 vCPU 停在 `gh_vcpu_ioctl`、timer 中斷 0、觸控叫不醒，只能重啟 VM；懷疑 crosvm／Gunyah 的中斷路徑在記憶體壓力下掉了 wakeup，未證實。有一次 18 分鐘後自己醒來，launchd reboot 時 APFS unmount panic（`vnode_rele_ext` usecount 變負），是另一個 kernel bug（懷疑 union／Data overlay）
