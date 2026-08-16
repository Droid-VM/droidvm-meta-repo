# DroidVM 3D 加速乾淨房驗收 — 總結(2026-08-16)

## 1. 結果表(第三輪 = SCHED_FIFO 97 + 全程亮屏 + 最終產物 final5;括號 = 第二輪 RT 關)

| 裝置 | 路線 | provision | 桌面 | display 自動重連 | vkmark(driverName 正確)RT on(RT off) | MC 進世界 + F3 fps RT on(RT off) | 備註 |
|---|---|---|---|---|---|---|---|
| 8gen3 OPD2404 | gfxstream | PASS | PASS | PASS | **6621**(1275) | PASS **15**(28) ⚠ | AHB 0;render thread 全 FIFO 97 綁 cpu7 |
| 8gen3 | drm2kgsl | PASS | PASS | PASS | **4053**(495) | PASS **78**(58) | 新 hugepage 模組;Bad page 0,pool 零損失 |
| 8gen3 | venus | PASS | PASS | PASS | **230**(201) | PASS **49**(71→42) | 新 hugepage 模組 |
| 8e TB322FC | gfxstream | PASS | PASS | PASS | **3502**(2744) | PASS **32~35**(31~32) | render thread 未繼承 FIFO |
| 8e | drm2kgsl | PASS | PASS | PASS | **10853**(10687) | PASS **120**(120) | |
| 8e | venus | PASS | PASS | PASS | **1699**(1197) | PASS **120**(118~120) | |
| 8e5 PLK110 | gfxstream | PASS | PASS | PASS | **9159**(1958) | PASS **7~12**(43) ⚠ | render thread 全 FIFO 97 綁 cpu7 → cpu7 97% |
| 8e5 | drm2kgsl | PASS | PASS | PASS | **885**(764) | PASS **67~78**(75) | 面板 60Hz 影響 |
| 8e5 | venus | PASS | PASS | PASS | **63**(66)→ 面板 120Hz 時 **633** | PASS **52~59**(59) | 面板 60Hz 封頂(見 4-A) |

boot_id 全程不變(每格)、guest `command 0x203` 0、8gen3 AHB 0、三台 provision 0 warning、virtio_gpu 來自 updates/dkms、無 gpu_pool_base=0。

## 2. 這一輪修掉的東西(全部**未 commit**,只有你說 commit 我才 commit)
| # | 問題 | 根因 | 修法 / 產物 | 驗證 |
|---|---|---|---|---|
| 1 | 8gen3 任何 GPU 路線 host dmesg 每幀 `kgsl CP: AHB bus error 0x10008e07` | host turnip(APK 內 libvulkan_freedreno.so)缺 a750 BR-only RB_CCU 修正 | port 9452b5e9090 到 `turnip/adreno-tools-drivers/turnip_workdir/mesa`(tu_cmd_buffer.cc/freedreno_devices.py),`TURNIP_REBUILD=1 5_prepare_turnip.sh` → libvulkan_freedreno.so md5 ebafec08 → APK | 8gen3 三路線 AHB 全程 0(修前 700~4000/次) |
| 2 | venus MC 卡 loading / `begin_rendering` SIGSEGV | zink 26.0.3 tc renderpass-info 與 driver 迭代失同步(gdb 實錘互等死結) | `git cherry-pick -n` 上游 MR 42222+42388 六 commit 到 mesa-venus 與 mesa-gfxstream,重建 deb(venus r217841+dirty20260815233040、gfxstream r217838+dirty20260815233201) | 三台 venus/gfxstream MC 皆進世界、連拍畫面在動、無 hs_err |
| 3 | provision 出現 running-kernel initramfs warning | 同一 apt 交易中新核心尚未 setup 完就對它 update-initramfs | droidvm-guest-additions `packaging/hooks.sh` `ga_remake_initrd()` + `install.sh` 跳過沒有 vmlinuz/modules.dep 的核心;deb r31+dirty20260816001330 | 三台 ×3 路線 provision 0 warning |
| 4 | guest dmesg 成批 `virtio_gpu *ERROR* response 0x1200 (command 0x203)` | gem close 對未建 context 的 fpriv 也送 CTX_DETACH_RESOURCE | `virtio_gpu/virtgpu_gem.c` `virtio_gpu_gem_object_close()` 加 `if (!vfpriv->context_created) return;` | 三台 0x203 全程 0 |
| 5 | guest reboot → crosvm 重啟 → native display 不重連(黑/殘影/-22) | 舊 Surface 已失效;FOLLOWS_ATTACHMENT 下 visibility bounce 無效 | `DisplayProvider.java` death 時 removeView/addView 重建 SurfaceView 再 fetchBinder(`recreateSurface()`);APK final5 md5 4b33dc62(crosvm d8d6962c、turnip ebafec08) | 三台 ×3 路線 reboot 後 +57~78s 直接出 KDE,不需 display_fix |
| 6 | **8gen3 每次 VM teardown `Bad page state`(TAIL_MAPPING)→ 之後 `Unable to handle kernel paging request at dead0000000004c8` panic(lru_add_fn/folio_add_lru_vma/folio_mark_dirty)** | **不是程式碼問題,是部署問題**:8gen3/8e5 上的 gh-hugepage-reserve KSU 模組是 07-18 舊 build(≈abb6157),缺 4057fef「hold a reference while lent」/ efaf83c / 7f69b1c 等 08-07~08-08 修正 → 借出頁被 split、alloc_contig_range 硬湊視窗夾別人的頁、purge 漏放 reference;8e 是 08-08 版所以整天乾淨 | `bash gh-hugepage-reserve/build.sh` 重編(zip md5 3a59d814),`ksud module install` + reboot(8gen3、8e5) | 8gen3 新模組 4 個 VM 週期、8e5 1 個:Bad page 0、orphan_freed 0、pool 2874→2874 / 3072→3072 零損失、無 reset(舊模組活不過 3 週期;minidump 歷史 08-14~08-16 十次重開全是同一族) |
| 7 | 工具箱 | provision.sh md5 grep -E 被 `+` 打壞;watchdog su timeout/ps 抓 crosvm | 已修(scratchpad/tk) | — |

## 3. 已根因但需要你拍板的(不是 PASS/FAIL 問題)
**A. guest 桌面 vblank 被綁在手機面板實際刷新率(venus/drm2kgsl 效能上限)** — 8e5 同一 VM 同一 vkmark:面板 120Hz → **633**;面板 60Hz → **70~77**(= R1~R3 的 63~69 封頂)。機制是 crosvm `PendingFlipFence`(RESOURCE_FLUSH 等 Android display flip fence 才回 guest,「backpressures the guest compositor to the display」),`refresh-rate=120` 只進 EDID。ColorOS 對 DroidVM 常選 60Hz,而且 peak/min_refresh_rate、oplus 設定、`cmd display set-user-preferred-display-mode`、螢幕關開都拉不回 120 → app 端 preferredDisplayModeId 多半也沒用。**「螢幕不亮渲染會卡」也是同一機制**(面板不刷新只靠 25ms 逾時放行)。選項:crosvm 端把 guest vblank 與實體 flip 解耦(依 refresh-rate 計時)/ app 端要高刷(不保證)。8gen3 面板實測 120Hz(所以 8gen3 數字沒受這個影響)。
**B. RT 97 開啟時 gfxstream 的 MC 掉幀**(8gen3 28→15、8e5 43→7~12;8e 32→32 不受影響) — gfxstream 所有 host render thread 繼承 FIFO 97 且被 gpuworker cpuset 綁在 cpu7 → cpu7 97% busy、present 餓死;8e 上 render thread 沒繼承 FIFO(原因未查)。CrosvmBackendInstance.java 註解已寫這是已知取捨(所以 RT 預設關)。若要 RT 開又不掉幀:render thread 不繼承 RT(gfxstream 端起 thread 時降回 SCHED_OTHER)或放寬 cpuset。vkmark 反而大漲(gfxstream ×3~5、drm2kgsl ×1.2~8、venus ×1.1~1.4)。
**C. 8gen3 venus vkmark 230(面板 120Hz)且全場景 ~4.5ms/frame 齊平** — 不是 GPU-bound(host idle 455%),是每幀固定延遲地板;8e5 同路線 633、8e 1699。未查(嫌疑:6.1 host 上 vkr ring wait/notify 延遲)。
**D. 8gen3 host 一筆 `WARNING sched_walt android_rvh_try_to_wake_up rq->balance_callback`**(venus vkmark 中,49 條 FIFO 97 執行緒時,rcu_preempt 喚醒;非 panic,系統續跑)— 觀察,證據 8gen3/dmesg-r3b-after-venus.txt。
**E. 其他小項**:8gen3 kmod 只在 app UI 開啟時載入(daemon 起來時不載)、daemon 曾一次「已停止」;`GH-DIAG: GH_VM_SET_BOOT_CONTEXT failed`(6.1 fallback,ERROR 級但無害);provision 會把 guest kernel 28→29(meta 連動,預期)。

## 4. 手機重開紀錄(全部有據)
- 8gen3:15:40 kernel panic(舊模組 LIST_POISON,minidump 已存)、16:1x 我為裝新模組主動 reboot;之後 boot_id 4292ee5c 至今不變。歷史 minidump:08-14 17:52/22:56、08-15 01:13/01:59/11:43、08-16 03:24/05:03/07:07/09:03/15:41 → 有訊息的 5 次全是 `dead0000000004c8/04c0/00000200000000c8` 同一族;3 次無訊息(借頁中直接 reset,含 07:07 首 VM、09:03 我的 E3 實驗)。
- 8e5:僅我為裝新模組主動 reboot(boot_id 08bd9331)。8e:uptime 3.3 天,零重開。

## 5. 手機設定異動(需要你知道)
- 三台:測試期間 `svc power stayon true` + `screen_off_timeout=1800000`;現已還原為 stayon false、`screen_off_timeout=60000`(**原值我沒記到**,若原本不是 60 秒請告訴我或自行改回)。
- 8e5:面板實驗改過又還原 peak_refresh_rate=120.00001、min_refresh_rate 刪除、oplus_customize_screen_refresh_rate=7、user-preferred display mode 清除;誤觸開了一次相簿並關閉。
- 8gen3/8e5:KSU 模組 gh-hugepage-reserve 已換成 08-16 build(settings.prop 保留)。

## 6. 未 commit 的工作樹(供你決定 commit 範圍)
turnip fork 樹(a750 RB CCU)、mesa-venus / mesa-gfxstream(6 個 cherry-pick -n)、droidvm-guest-additions(hooks.sh/install.sh/virtgpu_gem.c)、DroidVM app(DisplayProvider.java)、產物:APK final5、三個 deb、gh-hugepage-reserve.zip(build 產物不進 git,但**手機端要跟著更新**)。
