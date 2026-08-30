# DroidVM 3D 加速乾淨房驗收 — 第五輪(統一條件、使用者操作模擬)總結(2026-08-17 02:30)

## 0. 條件(三台完全相同,只有 mTHP 依裝置)
APK final8(base.apk 5e8ff235;crosvm a0fdff15、turnip ebafec08)/ deb:guest-additions r31+dirty20260816001330、mesa-guest-venus r217847+dirty20260816164345、mesa-guest-gfxstream r217844+dirty20260816164449、mesa-guest-drm2kgsl r227687 / base ubuntu-2026-kde.qcow2 md5 9fcb1c28 / acc-test:3584 MiB、4 vCPU 綁 host 2-5、GPU worker cpuset 7、SCHED_FIFO 97、1400x1050@120 dpi160、Native display + GPU-blit Turnip(GPU copy)、dynamic memory sharing 開、hugepages 開、VNC 關、mTHP 8gen3=single / 8e、8e5=chunked / MC -Xmx1536m。
操作:切路線、開機、開/離顯示器、電源、關機全部用 app UI(adb 觸控,`tk/app.py`);清增量碟用 adb;裝 deb / vkmark / MC / guest 端確認關機走 ssh。

## 1. 結果表(9/9 格 PASS;第四輪→第五輪)
| 裝置 | 路線 | provision | 未 provision 顯示 | reboot 後自動重連 | 桌面 | vkmark | MC 進世界 / fps | app 電源 → guest 關機 | BadPage / pool |
|---|---|---|---|---|---|---|---|---|---|
| 8gen3 OPD2404 | gfxstream | PASS | ⚠停格 | PASS +85s | PASS | GFXStream A750 **6398** | PASS 15/14/16 | PASS 11s(R4:**FAIL** OOM) | 0 / 2874→2874 |
| 8gen3 | venus | PASS | ⚠全黑 | PASS +87s | PASS | Venus A750 **220** | **PASS 53/61/60**(R4:**FAIL** 卡載入死結) | PASS 8s | 0 / 零損失 |
| 8gen3 | drm2kgsl | PASS | ⚠全黑 | PASS +85s | PASS | Turnip A750 **3774** | PASS 67/68/57 | PASS 8s | 0 / 零損失 |
| 8e TB322FC | gfxstream | PASS | ⚠停格 | PASS +84s | PASS | GFXStream A830 **2602** | PASS 49/41/46(R4 29) | PASS 9s | 0 / 3072→3072 |
| 8e | venus | PASS | ⚠全黑 | PASS +78s | PASS | Venus A830 **1095** | PASS 77/94/98→115 | PASS 8s | 0 / 零損失 |
| 8e | drm2kgsl | PASS | KDE 桌面 | PASS +78s | PASS | Turnip A830 **8625** | PASS 74/82/94→112 | PASS 8s | 0 / 零損失 |
| 8e5 PLK110 | gfxstream | PASS(apt 逾時重跑 1 次) | ⚠停格 | PASS +87s | PASS | GFXStream A840 **8866** | PASS 7~12 ⚠ | PASS 7s | 0 / 3072→3072 |
| 8e5 | venus | PASS | ⚠全黑 | PASS +88s | PASS | Venus A840 **73** ⚠ | PASS 58~60 | PASS 7s | 0 / 零損失 |
| 8e5 | drm2kgsl | PASS | ⚠全黑 | PASS +90s | PASS | Turnip A840 **949** | PASS 63~75 | PASS 7s | 0 / 零損失 |
三台全程未重開(boot_id 不變)、AHB 0、orphan_freed 0、pool 每次回滿;統一條件每格 vms.json + crosvm cmdline 核對一致。

## 2. 這兩輪找到並修掉的(全部未 commit)
| # | 問題(使用者會遇到) | 根因 | 修 | 驗證 |
|---|---|---|---|---|
| A | **app「電源」鍵一按 guest 整個卡死**(vCPU0 100%、RCU stall、soft lockup) | crosvm pl061(電源/睡眠鍵)用 edge irqfd(Gunyah 只支援 edge doorbell)但 guest FDT 宣告 IRQ_TYPE_LEVEL_HIGH → 中斷風暴;pl030 RTC 同型 | `crosvm/aarch64/src/fdt.rs` gpio/rtc 改 EDGE_RISING(final7) | 8e5 3/3 重現 → 修後 `/proc/interrupts` `4000.gpio 3 Edge`、logind `Power key pressed short`、R5 9/9 電源路徑 PASS |
| B | **venus MC 卡在載入不進世界**(R4 8gen3 再現;之前 cherry-pick 上游 6 commit 沒根治) | zink tc renderpass-info 死結(gdb:Render thread `tc_batch_increment_renderpass_info` 等 batch fence ↔ gdrv0 `threaded_context_get_renderpass_info` 等 ready),paravirt 送出延遲大→多 batch 在飛觸發 | mesa-venus / mesa-gfxstream `zink_screen.c`:deviceName "Virtio-GPU*" 停用 track_renderpasses(ZINK_DEBUG=rp 可強制開);新 deb | R5 venus 三台 MC 皆進世界(8gen3 53/61/60);gfxstream MC 反而略升(8e 29→49) |
| C | **未 provision 原版映像顯示器停格/黑,且一錯就死**(gfxstream) | crosvm CPU-copy flush 在 `framebuffer_region()` 鎖住 ANativeWindow 後 readback 出錯(`ErrRutabaga(-22)`)就 `?` 直接 return 沒 flip → window 永久鎖住(`Failed to lock window` 每幀) | `virtio_gpu.rs` pool/blob/transfer_read 三分支不論成敗都 flip 釋放(final8) | R5 三台 `Failed to lock surface scanout` 0(R4 gfxstream 252);但 -22 readback 本身仍在 → 停格未解(見 4-1) |
| D | **增量碟暴長 33GB**(R3/R4/R5 venus 輪,/data 剩 5G) | qcow2 有 backing 時 guest discard/fstrim → crosvm `zero_bytes()` 對每個 cluster「配置+寫零」;guest fstrim.timer 補跑一次就 32GB | `crosvm/disk/src/qcow` 實作 qcow2 v3 zero cluster(ZERO_FLAG、ClusterData::Zero、mark_cluster_zero)(final9) | 8e5:寫 150MB 隨機檔 → `fstrim` 32.4GiB → overlay 327MiB(修前 33GB)、reboot 後 md5 OK、`qemu-img check` No errors 0.79% allocated |
| E | **guest OOM 抖動→KDE 關機服務起不來**(R4 8gen3 gfxstream:3.2GB 無 swap 跑 MC 2000m) | 記憶體超賣(available 75MB、wa 56%、plasma-shutdown D 等讀盤) | 測試參數 MC heap 改 1536m(三台一致);產品面候選=guest additions 加 zram(未做) | R5 三台 MC 期間 guest avail 434~606MB、關機 7~11s |
| F | 工具:UI 驅動 `tk/app.py`/`ui.py`(uiautomator --windows dump + 觸控;含 SetupActivity、多語、橫直向)、`guest_shutdown.sh`、`progressmon.sh` | — | — | 三台三路線全 UI 流程跑通 |
最終產物 **final9**(base.apk 31991dca;crosvm bded6698 = A+C+D 三修)已裝三台;R5 表格是在 final8 上跑的(final9 只多 D 的磁碟層修正,未重跑 9 格)。

## 3. 統一條件的差異修正(第四輪前)
8e 顯示 1280x720→1400x1050、記憶體 4096→3584;8e5 4096→3584、vCPU 親和性 ""→0=2:1=3:2=4:3=5、dynamic memory sharing 關→開、gpu_arena/kgsl_pool 舊鍵無效忽略;三台皆用 UI 設定,vms.json + crosvm cmdline 已核對。

## 4. 仍開著的問題(有證據、需拍板)
1. **未 provision 原版映像的顯示**:gfxstream 停在開機文字(每幀 transfer_read -22:stock guest 的 KDE 用 GBM/3D 資源,gfxstream 讀不回)、venus/drm2kgsl 大多全黑(`FLUSH-ROUTE: transfer_read: readback is black`;8e drm2kgsl 卻正常)。ssh provision 後全部正常。要修得在 CPU-copy 路徑支援讀回 3D 資源(或改用 blit)。
2. **離開再重進顯示器要 10~60s 才有畫面**:新 surface 附著後 crosvm 沒重貼上一幀,要等 guest 下一次 flush(靜態畫面=等 KDE 時鐘每分鐘重繪);logcat `saveFrameForSurface failed … dimension mismatch from=(1280,800) to=(1400,1050)` → saved-frame 尺寸與目前 scanout 不符被丟掉。
3. **8e5 venus vkmark ~73 封頂**:面板 SF 120Hz 時 `-p fifo`=59 → guest vblank 實際 60Hz(crosvm flip fence = host present 完成);dynamic share / affinity 開關都不影響;16:37 那次 633(fifo 119)條件差異未找到。crosvm 端把 guest vblank 與實體 flip 解耦(依 refresh-rate)是根本解法。
4. **RT 97 + gfxstream MC 掉幀**(8gen3 15、8e5 7~12 fps;8e 49):gfxstream host render thread 全繼承 FIFO 97 且綁 cpu7 → cpu7 飽和;app 註解已列為取捨。要 RT 又不掉幀:render thread 不繼承 RT 或放寬 cpuset。
5. **MC 用 SIGTERM 結束時 JVM 退出路徑 SIGSEGV libopenal.so**(三台三路線同位址,非 GPU、非遊戲中)— 觀察。
6. guest 3.2GB 無 swap:MC 2000m 就 OOM;建議 guest additions 加 zram 或 UI 顯示記憶體建議。
7. 8gen3 kmod 只在 app UI 開啟時載入(daemon 起來不載)、`GH-DIAG: GH_VM_SET_BOOT_CONTEXT failed`(6.1 fallback)、provision 會把 guest kernel 28→29、apt 走 br-wifi 偶爾逾時(8e5 R5 重跑一次)— 沿用觀察。

## 5. 手機異動
三台 stayon 已關、screen_off_timeout 60000(原值未記到);三台已裝 final9;8gen3/8e5 KSU 模組 gh-hugepage-reserve 08-16 build;acc-test 統一條件如 §0(mTHP 依裝置);8e5 面板設定實驗全部還原。

## 6. 未 commit 的工作樹(自 9cc6ef4 之後)
crosvm:`aarch64/src/fdt.rs`(A)、`devices/src/virtio/gpu/virtio_gpu.rs`(C)、`disk/src/qcow/{mod.rs,qcow_raw_file.rs}`(D);mesa-venus / mesa-gfxstream:`src/gallium/drivers/zink/zink_screen.c`(B);crosvm_build/packages/modules/Virtualization/libs/android_display_backend/crosvm_android_display_client.cpp(之前就有的 1400 寬 stride 修正,未 commit);scratchpad/tk 工具(app.py/ui.py/guest_shutdown.sh/progressmon.sh/vmsjson.py 等)。

## 7. 附註:8gen3 04:19 重開(驗收結束後 2 小時,VM 未運行)
rebootmon 04:19:51 ADB-LOST → 04:20:41 回來 boot_id 4292ee5c→a7a77fb6。`ro.boot.bootreason=reboot,silence`,`persist.sys.boot.reason.history` 新增 `reboot,silence,1786911587`(=04:19:47);**無新的 minidump、SYSTEM_LAST_KMSG 仍是 15:41 那份** → 不是 kernel panic,是 ColorOS 的 silence(夜間閒置靜默)重啟,與 VM 無關(當時無 crosvm、app 閒置、螢幕已熄)。
