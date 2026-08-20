# pr/3d-accel 扁平化計畫 — 每個 repo 一張表（2026-08-18 修訂）

範圍：各 repo 的 `wip/3d-accel` + mesa 的 `wip/3d-accel-{gfxstream,venus,drm2kgsl}`。其餘分支（`wip-3d-accel`、`3d-accel`、
`wip/3d-accel-gfxstream` 等）是早期產物，不看。

**本次修訂的三個決定（與 08-17 版不同）**
1. **他人 commit 一律併入**功能 commit，作者掛 `Co-authored-by:`（表格第 5 欄）。
   - 唯一例外：mesa 上 6 個 Mike Blumenkrantz 的 **upstream cherry-pick**（zink/tc MR 42222/42388）。那不是 DroidVM 的貢獻，
     是上游 26.0.3 的 backport；併掉會毀掉 `(cherry picked from commit …)` 出處、也讓日後 rebase 到新 mesa 無法比對。建議原樣保留，
     若你要一起併我再改。
2. **virglrenderer 已 unshallow**（`git fetch --unshallow droidvm`，現在 3213 個 commit）。真正的上游基準是
   `8220efec`（AOSP `external/virglrenderer` snapshot, 2025-09-05）；原本被 graft 遮住的 13 個 commit（lateautumn233 ×1 + HuJK ×12，
   建立 drm/kgsl native context 後端）現在納入範圍 → 全範圍 41 commits、175 淨檔。
3. **DroidVM 已 rebase 到 `origin/master` (366d22c)**：58 個 commit 重放、零衝突，唯一跳過的是與 master `9d237f8` 重複的
   `f28c8ad`（差別只有 `•` vs `- ` 一個項目符號，保留 master 版）。備份在 `backup/pre-rebase-20260818` (15a7e7d)，
   未 commit 的 `context-types=drm/venus` 工作已 stash→pop 還原。新 HEAD `15a6a33`，57 commits，479 淨檔。
   下表用的是 **rebase 後的新 hash**。

**版本落差（08-18 查證）**：gfxstream / venus 兩支的 VERSION 是 **26.0.3**（上游 26.0 穩定分支，2026-03-18），
drm2kgsl 是 **26.3.0-devel**（mesa main）。26.0 穩定分支在 2026-01-14 從 main 分出，之後 main 跑完 26.1 → 26.2 → 26.3-devel，
所以 gfxstream/venus **落後 main 9189 個 commit**。要送 mesa 上游，這兩支的 X/V commit 得先 rebase 到 main；
drm2kgsl 本來就在 main 上，最接近能送。（此 clone 只有 Droid-VM fork，沒有 upstream remote、零個 tag，26.0.4/26.0.5 有沒有出未確認。）

bucket：**L** licensing → **M** GPU 無關雜項 → **G** 路線共用 GPU 基礎 → **D** drm2kgsl → **X** gfxstream → **V** venus。
逐檔 hunk 歸屬、淨零清單、coverage check 在 `plans/pr-flatten/<repo>.md`（那些是 08-17 產出的，他人 commit 部分照舊列為獨立 commit，
本檔的表才是最新決定）。

## 總表

| repo | base | head | 原始 commits | 淨檔 | 扁平後 |
|---|---|---|---|---|---|
| droidvm-3d-accel (meta) | 空樹 | 7ec8478 | 180 | 101 | 17 |
| mesa-cross | 空樹 | 7f16a6a | 17 | 15 | 6 |
| DroidVM | `origin/master` 366d22c ✅已 rebase | 15a6a33 | 57 | 479 | 28 |
| edk2-gunyah | `origin/master` b71b84a | ddd1b6e | 4 | 15 | 3 |
| gunyah_host_mod | 空樹 | 9c7557e | 29 | 29 | 10 |
| droidvm-guest-additions | 空樹 | 0fce564 | 33 | 43 | 20 |
| crosvm | `droidvm/droidvm` 3126586d1 | 8ba690b97 | 90 | 76 | 41 |
| Virtualization | `android16-qpr2-release-local` | b8e0971 | 6 | 4 | 3 |
| gfxstream | `aosp/android16-qpr2-release` | 6cfa0fbc2 | 95 | 61 | 22 |
| virglrenderer | `8220efec`（AOSP snapshot）✅已 unshallow | c7fd533 | 41 | 175 | 24（含 1 個純 vendoring） |
| mesa gfxstream | 26.0.3 `3f173c02d16` | 91374abe612 | 41 | 32 | 6 backport + 17 |
| mesa venus | 26.0.3 `3f173c02d16` | e95cae6583e | 44 | 35 | 6 backport + 6 |
| mesa drm2kgsl | mesa main `74d4e41b2bb` | ff069bb3c71 | 26 | 23 | 12 |
| crosvm-minimal-manifest | `origin/main` | f32c2d0 | 1 | 1 | 1 |

Co-authored-by 用到的 identity：
`Co-authored-by: lateautumn233 <lateautumn233@foxmail.com>`、`Co-authored-by: Kancy Joe <…>`（crosvm pflash）。
crosvm `d9000bb43` 作者是 `Your Name <you@example.com>`（時間/內容判斷是 lateautumn233），要確認後掛他。

---

## 1. droidvm-3d-accel（meta；空樹 → 7ec8478，180 → 17）

無他人 commit。

| # | bucket | commit subject | 併入 | Co-a | 備註 |
|---|---|---|---|---|---|
| 1 | L | licensing: GPL with additional permissions to take the work upstream | 37560d3, db999d3 | — | .sh/.md 都沒 SPDX header，要不要補 |
| 2 | M | pipeline: meta repo skeleton — numbered build scripts, branch-chain resolution, README | bf63337, 1014738, 399146d, ea1c4f4, 8103642, 7389713, e23936e, 9817d24, 997a494, cfc3504, bc1f0c2, a70011e, 60c83f5, a2c6e12 | — | 三次分支解析改寫只留 lib_branch.sh 的 chain |
| 3 | G | pipeline: build the gunyah host modules and stage them, their descr pages and match.json into the APK prebuilts | 8103642(4_), 08d0d47 | — | |
| 4 | G | turnip: build the host Vulkan driver from the Droid-VM/turnip fork (gen8, KGSL) and ship it in the APK | 8103642(5_), 7bc344c, eff42e6, 9f0de1c, 2865f35 | — | turnip/patches 加了又移進 fork → 淨零 |
| 5 | G | guest-patches: guest kernel virtio-gpu/gunyah patch series as in-tree reference | 57e76c5, 9817d24, cfc3c59 | lateautumn233（0001 patch 的 From:） | **考慮丟**：與 guest-additions 重複 |
| 6 | G | build: guest mesa build glue — worktrees, mesa-cross clone, dist packaging | b61b21b, ce0c3ee, bc1f0c2, 20c0c77, 58b7553, 8068223, 82a3c95, acbb43c, a70011e, 64d57d1, 6b425ef, cb30848, d2cb940, 1abda84, 7ec8478 | — | mesa-cross/* 已搬走 → 該部分淨零 |
| 7 | G | deploy: provision a guest for one route over ssh, re-establish the phone after a reboot, SETUP.md | b34f5d6, 7475e70, 6242ac1, d31d315, cfc3504, a322425, 20c0c77, bc1f0c2, 60c83f5, 9477084, 82a3c95, a70011e, a2c6e12 | — | SETUP.md/bringup.sh 有過期段落 |
| 8 | G | bench: vkmark + Minecraft harness for every route — fixed scene over VNC, clock pinning, fps reader, preflight, reboot watchdog | d1a195d, ae6f360, 9a33620, 925a238, e4e7ca9, edd7c95, 6b1cff4, 7ec8cd2, 104e6bd, bc4a5a4, b5bc340, ceec69f, 7558dea, 8b9a5a9, 0070694, 2c03cf0, e0a0421, 70c2786, 61873d0, 0d17956, 83941b3, 20032c4, 82a3c95, bcba917, 60c83f5 | — | 路線無關，建議移到 deploy/bench/ |
| 9 | G | deploy: reserve-pool and VMM-death diagnostics | 20032c4, 7f62051, 70c2786, 61873d0, 0d17956, 83941b3, bc9d54e, bcba917 | — | **考慮丟** |
| 10 | G | plans: memory-model and reserve-pool design docs | b34f5d6, 82a3c95, a70011e, bc9d54e, 1a34c93, 08e058d, 6d71c4f, 5ad2629, 1d12d24, 12f23c6, 69d0466, 1bf52a7, 38253e0 + POOL_DESIGN 系列 24 個 | — | POOL_DESIGN.md 工作樹已刪 |
| 11 | G | plans: pool-leak investigation survey, derivation notes and dated evidence packs | bf63337, 9f39841…5a510d2（44 個）, 9cc6ef4 | — | **考慮丟** |
| 12 | D | drm2kgsl: guest mesa variant (turnip over vdrm) and the native-context launcher | ce0c3ee, d31d315, 82c1d50, 58b7553, 509c243, 2bfa1a9, 0a19d89, cce7feb, a2c6e12, 60c83f5, 7bd867f, 7558dea, 82a3c95, bcba917, a70011e, 64d57d1, ceec69f | — | |
| 13 | D | drm2kgsl: early native-context plan, paged-arena design, legacy start_nctx.sh, turnip-virtio snapshot | bf63337, 399146d | — | **考慮整包丟**（被 #12 / mesa 分支取代） |
| 14 | X | gfxstream: guest mesa variant, one launcher per memory configuration, streaming-trace launcher, VK_KHR_display test | b34f5d6, 7475e70, 6242ac1, ae3d9b5, d31d315, fbde26d, 233e634, 4f94316, 104e6bd, 7558dea, ce0c3ee, a70011e, 64d57d1 | — | |
| 15 | X | gfxstream: guest ICD / zink source snapshots | cfc3c59, f3a2990, 3410861, fded20b, 4a18838, 8eacc22, 98fc47b, 19b6675, 2145e17 | — | **強烈建議丟**（26k 行整檔複製） |
| 16 | X | gfxstream: arena/folio-backing plan, ship plan, seqno dead ends, launch reference, debug loop | 4b0a5a3, ce734aa, 399146d, 551915e, eb8b452, d52e926, 6f862e8, de458eb, 2fd2369, 4c6d0be, c50d255, ecf79d1, 6d71c4f, 7596925 | — | 過期文件考慮丟 |
| 17 | V | venus: third guest mesa variant, provisioning, route survey and bring-up worklog | efc1fe3, a24c655, 9d7ba39, f290df3, 2867932, dbef5b2, 1c47873, fcc31be, 7b1293e, 9cc6ef4 | — | provision-any.sh 併回 provision.sh |

## 2. mesa-cross（空樹 → 7f16a6a，17 → 6）

無他人 commit。

| # | bucket | commit subject | 併入 | Co-a | 備註 |
|---|---|---|---|---|---|
| 1 | L | licensing: GPL with additional permissions to take the work upstream | 937da44(授權檔) | — | |
| 2 | G | build: cross-build the guest mesa for aarch64 in a container and package it as a .deb | a1ad501, e618973, 32dad17, 5903cc0, 4d47468, 8b3a020, a277948, 0ffbd91, bbb66e1, a9de7bc, 4ee98ed, 628d9c4, 620d1b3 | — | fedora/build-host.sh 加了又刪 → 淨零 |
| 3 | D | mesa-variants: the drm2kgsl variant (26.3.0-devel, freedreno ICD) | e618973/32dad17/8b8a2a5 的 drm2kgsl 條目 | — | |
| 4 | X | mesa-variants: the gfxstream variant (26.0.3, gfxstream_vk ICD) | 同上 gfxstream 條目 | — | |
| 5 | V | mesa-variants: the venus variant (26.0.3, virtio ICD) | 4495d6c | — | |
| 6 | M | ci: build the three guest debs on GitHub Actions | 937da44, 7f16a6a | — | |

## 3. DroidVM（`origin/master` 366d22c → 15a6a33，57 → 28；hash 已是 rebase 後）

| # | bucket | commit subject | 併入 | Co-a | 備註 |
|---|---|---|---|---|---|
| L1 | L | licensing: state the GPLv3 the app already used, allow upstream submission, attribute to Droid-VM | 363d765, aaf5f9c | — | 326 個 .java 只有 3 行 SPDX header；ADDITIONAL-PERMISSIONS §2 還是空的 |
| M1 | M | daemon: pass the real host CPU name to guests via crosvm --smbios | 137be4a | — | ↔ crosvm M6 + edk2 #2 |
| M2 | M | daemon: give loaded VM instances the real network store | e721c4f | — | |
| M3 | M | daemon: pass --swiotlb from swiotlb_mb to crosvm | d50faa6(部分) | — | |
| M4 | M | settings: kernel module manager — list shipped host modules by KMI + SoC match, load/unload, autoload, "why needed" pages, setup-wizard step | fd5fab4, 14cd15a, 2d1774e, 76c6277, 15a6a33, 2ba98fc(kmod), e2f78e9(module pages), caf74ae | — | 讀 gunyah_host_mod 的 match.json/descr |
| M5 | M | ui: spread tabs over the full width when they fit, scroll them when they do not | c101825, 45b0ac7 | — | |
| M6 | M | disk: one definition of the compression crosvm can boot, and stop re-compressing on import | 7582d0b | — | 移除 daemon IPC disk_compat |
| M7 | M | vm/disk: surface crosvm's no-snapshot rule before it bites | a675337 | — | |
| M8 | M | disk: overlays as a tree you can branch, switch and collapse | 2ba98fc(disk) | — | |
| M9 | M | display: unified input routing over crosvm --input evdev devices, shared gesture translator, coalesced motion, VNC direct binder sink | 54fab2b, d7d513c, aeef9e9, 4ffc4bc(input), 85fb5c9(vnc input=) | — | ↔ crosvm M3/M4 |
| M10 | M | display: viewport/chrome controllers, DisplaySource interface, shared daemon attach, follow guest resolution changes | 3eaee91, 4ffc4bc(config poll), **35a42f0** | lateautumn233 | 他的 test 強化併進來 |
| M11 | M | display: real key holds, a laptop-layout keyboard, and a one-row keyboard menu | e3109e5, e2f78e9(keyboard), 25884e6, 2ba98fc(FN row) | — | |
| M12 | M | native display: draw the guest's hardware cursor from crosvm's cursor position stream | e2f78e9(cursor) | — | ↔ crosvm M16 |
| M13 | M | native display: reconnect to a restarted crosvm with fresh surfaces | 9c2a734 | — | |
| M14 | M | native display: suppress OEM full-screen touch gestures while a VM display is foreground | d3e9f42 | — | **考慮丟**（root 改 oplus_customize_*） |
| M15 | M | ui/vm: one display-output picker (none/native/VNC), native display also on simplefb, virtio display default 120 Hz | 032e479(display), d974a38(simplefb), 5d59578 | — | |
| M16 | M | vm: vCPU affinity picker and CPU placement plan | **c4ea680**(cpu 部分) | lateautumn233 | 原 commit 混 M+G，GPU cpuset 那半拆到 G5 |
| M17 | M | archive: configurable zstd worker count | **1df811b** | lateautumn233 | |
| M18 | M | vm: per-VM environment variable configuration | **ba137d2** | lateautumn233 | |
| G0 | G | app: declare game mode so the platform raises CPU/GPU clocks while a VM display is foreground | 1c0d5d7 | — | 考慮丟 |
| G1 | G | ui/vm: Gunyah dynamic memory sharing switch (--runtime-share), published to the tabs that need it | fbf367d(gunyah), 032e479(move), 720ffaa | — | ↔ crosvm G5 |
| G2 | G | ui/vm: three-level GPU section — renderer / graphics API / host driver, with gpu_api migration; host Vulkan ICD selection; udmabuf size cap; pci-bar-size | b147368, 97684b7, d8bf7e8, cecabc0, 0aa8007, 5ef2d69, 4ffc4bc, 85fb5c9, d50faa6, 81b07fe, a16790f, aa7673d | — | `applyGfxstreamEnv()` 建議改名 applyHostVulkanEnv() |
| G3 | G | ui/vm: guest-allocated VRAM pool (gpu-guest-mb / udmabuf), with prealloc / growth step / grant limit | 484d2bb(guest), a508b6a, fbf367d(guest pool), cecabc0, **487b866** | lateautumn233 | ↔ crosvm G7/G9 |
| G4 | G | ui/vm: native-display GPU-blit provider with a real-time system-Vulkan capability probe | aa7673d, 568823a(blit) | — | ↔ Virtualization #3 |
| G5 | G | graphics: GPU worker CPU set and opt-in real-time scheduling (gpu_rt_prio) | 5bbdadf, **c4ea680**(gpu cgroup 部分) | lateautumn233 | ↔ crosvm G18 |
| D1 | D | ui/vm: DRM native context route (drm2kgsl) — Native Context API, DRM-to-KGSL host driver, context-types + udmabuf, drm-host-mb pool | 1ffe892, 54e55cb, 484d2bb(drm), f8ec94c, 6d2cb66, cecabc0, 0aa8007, d8bf7e8 | — | 工作樹還有未 commit 的 `context-types=drm`（去掉 virgl2）改動 |
| X1 | X | ui/vm: gfxstream route — gfxstream-vulkan context-types, gunyah-pvm, host-alloc vs guest-alloc, gfx-host-mb pool, dynamic vram | a16790f, d50faa6, fbf367d, 1f4da19, a508b6a, 484d2bb, f8ec94c, caf74ae, 0aa8007, 4ffc4bc, 720ffaa, d974a38 | — | |
| V1 | V | ui/vm: venus route — Vulkan under virglrenderer, venus context-types + udmabuf, host ICD row shared with gfxstream, venus-host-mb pool | 568823a(venus), ef92ee4, 5ef2d69(venus), cecabc0 | — | |

## 4. edk2-gunyah（`origin/master` → ddd1b6e，4 → 3）

| # | bucket | commit subject | 併入 | Co-a | 備註 |
|---|---|---|---|---|---|
| 1 | L | licensing: keep BSD-2-Clause-Patent, say why, and fill in the gaps | fe353d3 | — | 全 repo 唯一不轉 GPL 的 |
| 2 | M | firmware: Windows-on-ARM ACPI power patches (S5, reset register, per-CPU LPI) and runtime SMBIOS identity overrides from FDT /chosen | b24bffb, 12a3326 | — | ↔ crosvm M6 |
| 3 | G | GunyahPoolAcpiDxe: publish every DroidVM pool as an ACPI device so a Windows guest can find one | ddd1b6e | — | 自述「Not booted」 |

## 5. gunyah_host_mod（空樹 → 9c7557e，29 → 10）

| # | bucket | commit subject | 併入 | Co-a | 備註 |
|---|---|---|---|---|---|
| 1 | L | licensing: GPL-2.0-or-later with additional permissions to take the work upstream | f491c7a, 46664b4 | — | |
| 2 | M | build.sh: build every module per GKI KMI through the ddk-min container into dist/<kmi>/ | 79f1eff, dfde4b2, 181910d, d9b104c(target) | — | |
| 3 | M | gunyah_kvcalloc: reproduce the 6.1 gh_vm_mem_alloc kvcalloc fix as a kprobe module (>2GB guests) | 79f1eff, 181910d, e46764b(kvcalloc) | — | **M 不是 G**：任何 >2GB VM 都要，與 GPU 無關；訊息裡記著一個未解的 double-free |
| 4 | M | ship each module's "why is this needed" page and its device rules alongside the .ko | 357c863(descr/match/build.sh) | — | ↔ DroidVM M4 |
| 5 | G | gunyah_host_share: runtime SHARE_BLOB module for upstream gunyah (6.6/6.12) — liveness GC, bounded retry, kvcalloc page array, 6.12 label namespace + RESET_FAILED | 97cf7e0, 93d4184, ed85989, b14d65e, 6e8b7d3, 79f1eff, cf2d43a, 357c863(6.12), **0a9d951** | lateautumn233 | uapi header 出自他的 6.1 模組；mem_entries kvcalloc 也是他的 |
| 6 | G | gunyah_host_share: the 6.1 downstream gh_* SHARE_BLOB module, with kallsyms symbol resolution for OPLUS 6.1.118 | **d9b104c**, e46764b(6.1) | lateautumn233 | 模組本體逐字出自他的 2a8df05 |
| 7 | G | gh_unmovable: non-movable pinnable memory for small GPU blobs | d1aef9f | — | 目前唯一使用者是 gfxstream host，也可歸 X |
| 8 | G | udmabuf: /dev/udmabuf provide / override / paramonly module for GKI 6.1/6.6/6.12 — kvmalloc arrays, size and list limits, CFI-safe seals, folio-era override, LTO-rename escape hatch | 97db2f0, 5048681, 882e20c, d47171f, b61bb46, 63bbe97, ad6fbc5, eeb6052, 9c7557e | — | 6ad6378 淨零；三條路線 + scanout 都用 |
| 9 | G | udmabuf: on-device tests (create/list/CLOEXEC/pattern, entry-count ladder) | 5048681(test), 4e276e5 | — | |
| 10 | D | udmabuf: kgsl_frag_test — measure whether KGSL imports a fragmented dma-buf | 0d899ae | — | **考慮丟** |

丟：`GKI6.6/package/.../android15-6.6.ko`（被 track 的 prebuilt）、`docker_exec.sh`（被 build.sh 取代）。

## 6. droidvm-guest-additions（空樹 → 0fce564，33 → 20）

org 預設分支 529f081 與 `wip/3d-accel` 無共同祖先 → 建議 pr/3d-accel 直接以新歷史取代。

| # | bucket | commit subject | 併入 | Co-a | 備註 |
|---|---|---|---|---|---|
| 1 | L | licensing: GPL-2.0-or-later with additional permissions to take the work upstream | 577babf, 9dfedf2 | — | |
| 2 | base | virtio_gpu: import the 7.1-rc4 virtio-gpu driver as an out-of-tree module | 6a84605(upstream 部分) | — | 訊息寫明 upstream 5200f5f493f7；只含 Makefile / TRACE_INCLUDE_PATH / move_notify 三個 build 調整 |
| 3 | M | virtio_gpu: virtio_gpu.fbdev module parameter (default on) | 497b1d3, 3d3532a(drv.c) | — | |
| 4 | M | packaging: DKMS source package, top-level Makefile and install helper | 6a84605, b510200, 3f2a227, 5927cf0, 3060f8b | — | README 過期要重寫 |
| 5 | M | packaging: build .deb and .rpm from one payload, initramfs/dkms hooks, version by commit count | 8762c0a, fc5d9d0, 3060f8b, 5927cf0 | — | 補 .gitignore（6 個 .deb 被 commit 了） |
| 6 | G | gunyah_guest: Gunyah RM client module (raw-HVC mem_accept / mem_release) | **6a84605**(gunyah_guest/) | lateautumn233 | 與他的 f056a12bb2cd 逐字相同 |
| 7 | G | gunyah_guest: virtio-gunyah-accept transport for crosvm's VmAccept::Sync | 6e8f34d, e789f33, 0e8f8fe, a23294d | — | ↔ crosvm G6 |
| 8 | G | gunyah_guest: pool control queue and the exported gunyah_pool_grow/shrink/query API | 548eb4e, 24857a5 | — | ↔ crosvm G9 |
| 9 | G | dynpool_test: a driver that exercises a growable pool | 82f6af9, 24857a5, c67fa3b | — | 測試模組，可丟 |
| 10 | G | virtio_gpu: guard the host-visible BAR base GPA and 2 MB-align blob nodes under Gunyah | **6a84605**(guard), 0e8f8fe(align) | lateautumn233 | |
| 11 | G | virtio_gpu: map pool-resident host blobs (MAP_INFO_POOL) at gpu_pool_base + offset from a /reserved-memory node | 0e8f8fe, a23294d, 5927cf0, 24857a5 | — | ↔ crosvm G8 |
| 12 | G | virtio_gpu: guest-alloc pool — back BLOB_MEM_GUEST from a guest-owned drm_buddy pool, negotiate CREATE_GUEST_HANDLE, bound the scatter, report the budget | 0e8f8fe, 489a77c, f203a46, 4f6d47e, 4ca7bf7, f6ae582, 24857a5, fd9b8d0 | — | ↔ mesa 三支的 guest-alloc commit |
| 13 | G | tests: gpool_test probes the guest-alloc scatter bound from userspace | 00790a1, bac6534 | — | |
| 14 | G | virtio_gpu: blob-path diagnostics | **6a84605**(VGBLOB-DBG) | lateautumn233 | 前綴建議改名或丟 |
| 15 | G | virtio_gpu: grow and shrink the guest-alloc pool at runtime — range query, reclaim work, release blocks after RESOURCE_UNREF | **ce7e962** | lateautumn233 | 原 subject 大幅低估內容 |
| 16 | G | virtio_gpu: ABGR8888 primary format for the native scanout, keep the console's XRGB so fbdev/VT works | **075d260**, 3d3532a(display.c) | lateautumn233 | 他的 commit 把 XRGB 換掉→壞 fbdev，HuJK 的修正一起併 |
| 17 | X | virtio_gpu: look up the gfxstream host pool under `gfx_host` | 0e8f8fe→24857a5 | — | 3 行 |
| 18 | D | virtio_gpu: also find the host pool base under `drm2kgsl_host` | dc9471d, bac6534, 24857a5, 5927cf0 | — | 5 行 |
| 19 | V | virtio_gpu: probe the `venus_host` pool node | 2c75798(kms.c) | — | 7 行；不含那 6 個 .deb |
| 20 | G | virtio_gpu: do not send CTX_DETACH_RESOURCE from files that never created a context | 0fce564 | — | 可獨立上游的 bugfix |

丟：6 個 .deb、`virtio_gpu/uapi/linux/virtio_gpu.h`（被 kernel header 遮住，build 根本沒用到）。

## 7. crosvm（`droidvm/droidvm` 3126586d1 → 8ba690b97，90 → 41）

| # | bucket | commit subject | 併入 | Co-a | 備註 |
|---|---|---|---|---|---|
| L1 | L | licensing: GPL with additional permissions to take the work upstream | e4ce5e5fa, 5957b647c | — | zstd_ffi.rs 的 BSD header 要統一 |
| M1 | M | build: add the standalone crosvm_device_only soong target | e275a4fa8 | — | |
| M2 | M | input: absolute-mouse virtio-input device, a distinct Tablet event kind, VNC input=tablet | 3817da79d, 2052a4cc7, 67026a69b | — | ↔ DroidVM M9 |
| M3 | M | input: resolution-independent ABS range, REL_HWHEEL, one display-window input builder for gpu and simplefb | 7e570fe4a(input) | — | |
| M4 | M | aarch64: move the fixed GPIO/VMWDT SPIs to the top of the range so virtio-pci IRQs cannot collide | 7e570fe4a(irq) | — | 埋在 EDID commit 裡的 GPU 無關修正 |
| M5 | M | smbios: allow --smbios on all arches and forward identity through FDT /chosen | 9fa3ac20c | — | ↔ edk2 #2 |
| M6 | M | aarch64: add pflash support for UEFI variables | **f7838af1d** | Kancy Joe | 若 droidvm/pflash 先合入就自動消失 |
| M7 | M | disk: refuse to open a qcow2 with internal snapshots for writing | 28533c78b | — | ↔ DroidVM M7 |
| M8 | M | disk: back the zstd feature with a C libzstd FFI shim | 11e6ec4b0 | — | 需 manifest 的 external/zstd |
| M9 | M | linux: in-process fatal-signal handler that dumps pc/lr/mcontext, with a per-worker altstack | 5b7d0814b, 517aee6d6(部分) | — | |
| M10 | M | linux: turn a fatal signal into a VM death instead of a phone reboot | dcdb1b427, 864b16210 | — | |
| M11 | M | crosvm: accept any exit status from untracked children | ceef1bcfc | — | |
| M12 | M | gunyah: tolerate ENODEV from SET_BOOT_CONTEXT and tag every ioctl failure | 9c45f3ac2 | — | |
| M13 | M | gunyah: fence off the RM's non-executable low-IPA donation, gated on the RM generation | 29f4095c6(lowmem), 457ae10bd, 3e6840636, 0966fe730/19fc6900c(helper) | — | GPU 無關（guest SIGBUS） |
| M14 | M | gpu: EDID fixes, device reset restores scanout geometry and drops resources, padded-stride readback | 7e570fe4a(edid/reset), **d9000bb43** | lateautumn233（待確認 identity） | d9000bb43 作者是 "Your Name" |
| M15 | M | gpu_display: publish the guest hardware cursor to VNC as an RFB cursor, signed origin, hide on resource 0 | 6375d758e, f7160d039(cursor), c1e733604, d5dcfd317 | — | ↔ DroidVM M12 |
| M16 | M | simplefb: present through any display backend, not just VNC | 3d722a4aa | — | |
| G1 | G | gunyah: runtime host-visible blob SHARE/UNSHARE through the gunyah_share module, IPA size-max layout, non-exec SHARE, EEXIST reuse | **d01bdef7f**, **78ca3b50b** | lateautumn233 | 他兩個 commit 是同一功能的兩半；subject "tmp" 要重寫 |
| G2 | G | gunyah/aarch64: 4 GiB host-visible BAR window above RAM, matching IPA size-max headroom, 256 MiB default pci_bar_size | bf3ef7c1e, bdd1edccd, 29f4095c6(window_top), **bb171f312** | lateautumn233 | |
| G3 | G | crosvm: transparent runtime_share/unshare and VmAccept::Sync over a virtio-gunyah-accept device, with a VMM-owned folio policy (--runtime-share) | da1f18acc, 1c40f4fa5, d6edf08a8, 29f4095c6(runtime-share) | — | GH_NO_UNSHARE(dd24d1252) 建議丟 |
| G4 | G | gunyah/aarch64: boot-blessed GPU pool regions, --pre-alloc CLI, mTHP prepare + mlock + cache clean, one whole-region SHARE, reserved-memory pool nodes | fa1612b9f(倖存), 29f4095c6(pools), 5610bf04b, d55bb99db, 04781d0fd, 19fc6900c, 0966fe730, 972909cde | — | 順手刪 find_pci_bar / PrepareBlobArena / 無用 import |
| G5 | G | virtio-gpu: guest-alloc pool blobs — a udmabuf per blob, the pool-resident MAP_INFO_POOL wire, direct pool scanout reads | 29f4095c6(gpu), 1c40f4fa5(pool_offset) | — | ↔ guest-additions #12 |
| G6 | G | Growable pools: parameters, grant table, guest request queue, grow and shrink as one memparcel of 2 MiB folios, host-side grant refs | 63e4cef21, b955089ee, f0cfc5da3, 1df8c540e, 56cf6b51d, d55bb99db, 0966fe730, 188e44c78, **83ffa9d8f** | lateautumn233 | 他的「enhance gpu memory pool management」是同一功能的延伸；test pool 可另議 |
| G7 | G | virtio-gpu: bound the guest-controlled sizes, validate SET_SCANOUT_BLOB geometry, don't park descriptors on a failed fence, cap udmabuf entries, quiet the expected teardown detach | e909c1633, a2d914abb, 517aee6d6(scanout), f25bc40a5, ac6608177 | — | |
| G8 | G | rutabaga: forward virgl log levels to crosvm | **0091d85be** | lateautumn233 | ↔ virglrenderer M1 |
| G9 | G | gpu_display: cached DMA-BUF display import for the Android backend, display-only virgl export, per-buffer fourcc, no import for cursors | **eae3fba41**, b7f3b1c5f, **6a796a71a**, **00ec650d0**, **ddf70b61b** | lateautumn233 | eae3fba41 = 他的 f9e765c74 逐字、6a796a71a = 他的 3157433df 移植 |
| G10 | G | gpu: defer the RESOURCE_FLUSH fence until the display completion fence fires | **cff5722ee**, cb0072781 | lateautumn233 | 他加 completion fence fd、HuJK 用它 |
| G11 | G | gpu: GPU_DISPLAY_COPY_MODE=cpu to force the one-copy display path | eb7315cfa(part 2) | — | app 會設，保留 |
| G12 | G | gpu: scanout flush diagnostics | f7160d039, 50e7491d2, 3ba5c0746, 8c9b95172, 93216652b, c5642aba9, ac6608177 | — | **建議整包丟** |
| G13 | G | gpu: opt-in SCHED_FIFO for the virtio-gpu worker (CROSVM_GPU_RT_PRIO) | **2444da33c**, 8ba690b97 | lateautumn233 | ↔ DroidVM G5 |
| G14 | G | rutabaga: route ring-indexed fences to the per-context timeline | b7069c454 | — | venus + drm 都要 |
| D1 | D | gunyah/aarch64: drm2kgsl host pool (Drm2KgslPool, --pre-alloc drm-host-mb, drm2kgsl_host node, arena handover) | e8046e528, a974f43f6, 972909cde | — | |
| D2 | D | rutabaga: record virgl pool residency at create time through a read-only map_ptr accessor | 2718247ec, 7665bbb34, 6944ae98f | — | |
| D3 | D | rutabaga/gpu: hand virglrenderer a dup of the guest-allocated blob's dma-buf, and give HOST3D_GUEST blobs their iovecs | 52aa6ab10, 972909cde, a34b7fc86 | — | ↔ virglrenderer G4/D7 |
| D4 | D | gpu: swizzle the drm2kgsl pool scanout to BGRX, fourcc-aware | 669415587, eb7315cfa(part 1) | — | |
| D5 | D | gpu: import the guest-pool scanout udmabuf directly for a one-GPU-copy drm2kgsl display | 86343855d | — | |
| X1 | X | gfxstream: pre-alloc pool residency, host-visible blob-backing callbacks and VRAM quota, GFXSTREAM_* knobs only for the gfxstream renderer | 29f4095c6(gfxstream), 7e570fe4a(gunyah_pvm), 79c274eea, 41ad75cd4 | — | ↔ gfxstream X2 |
| X2 | X | rutabaga: reject negative descriptors from gfxstream blob/fence export | e78eb7e27 | — | |
| X3 | X | gpu: enable external_blob for udmabuf guest-alloc | 4b0d9c815 | — | |
| X4 | X | gpu: map a pool-resident scanout blob at its pool offset | 77b1bd1db | — | |
| V1 | V | gpu: venus_host pool and use_guest_vram for the venus route, with venus pool residency | d8bb530e9, 6b415492c, 6944ae98f, bb354e100 | — | ↔ virglrenderer V5 |

## 8. Virtualization（`android16-qpr2-release-local` → b8e0971，6 → 3）

| # | bucket | commit subject | 併入 | Co-a | 備註 |
|---|---|---|---|---|---|
| 1 | M | display: implement getDisplayConfig and follow guest resolution changes | 452eb33 | — | ↔ DroidVM M10 |
| 2 | G | display: import the guest scanout DMA-BUF and blit it with Vulkan, async, with a CPU fallback and surface-change handling | **f413ae8**, **4a4581e**, **466354b** | lateautumn233 | ↔ crosvm G9 |
| 3 | G | display: name the blit driver generically (CROSVM_DISPLAY_VULKAN_LIBRARY), drop the world-writable fallback, accept the scanout fourcc | b8e0971, 5a0d955 | — | 安全修正（world-writable dlopen = 本機提權） |

## 9. gfxstream（`aosp/android16-qpr2-release` → 6cfa0fbc2，95 → 22）

| # | bucket | commit subject | 併入 | Co-a | 備註 |
|---|---|---|---|---|---|
| L1 | L | licensing: GPL with additional permissions to take the work upstream | eb27b2755, 6cfa0fbc2 | — | GfxstreamDiag.h 現在帶 AOSP header，要換 |
| X1 | X | gfxstream: Android host bring-up — resolve the Vulkan loader through the hwvulkan HAL, fall back when AHB export is broken | **0c2064df5**(loader/CB 部分) | lateautumn233 | subject "tmp" 重寫 |
| X2 | X | gfxstream: turnip as the host driver — dma-buf export, DRM-modifier LINEAR images, blob readback | **166a754aa** | lateautumn233 | subject "wip" 重寫 |
| X3 | X | gfxstream: AHB-backed ColorBuffer adaptations for Adreno — dedicated export, BGRA8→RGBA8, stride fallback, lazy mLinear, on-demand AHB map | **85d737cba**, **87a26ce3e**, **d30f31837**, **62b2f9170**, **01d07a5a4**, **2c57c465f**, **f038bd111** | lateautumn233 | |
| X4 | X | vulkan: zero Vk13Features instead of dropping them, always map memoryTypeBits host-to-guest | **e1d0472b5**, **1c6e27ef3** | lateautumn233 | |
| X5 | X | gfxstream: one GFXSTREAM_DIAG switch, and gate the bring-up/zerocopy traces behind it | 52dd9e236, 1609ff7fa, 9f00493c8, 5b26b9306, c93a4b721 | lateautumn233（改的是他的 trace） | |
| X6 | X | gfxstream: host-visible memory backend for a protected Gunyah VM — pool pre-alloc, guest-alloc import, VMM blob-backing callbacks, memory budget | a7765887b, 4c8f0a838, 282414db5, 95290f7cf, 52aed6b81, 545d6c263, **364cb8d9e**(ExternalMemory/iovec) | lateautumn233 | ↔ crosvm X1 |
| X7 | X | gfxstream: back ASG ring blobs from the reserve pool — recycled, folio-backed, charged at their real size, zeroed, never reused while a reader holds them | fd788ec42, d9a24cabb, 1d7185732, 494d841a3, a7765887b(RingBlob), **0c2064df5**(recycle pool) | lateautumn233 | |
| X8 | X | gunyah/android: stop leaking blob descriptor handles | 5d72b52aa | — | |
| X9 | X | vulkan: harden the decoder against null dispatch entries — alias fill-in, 1.3 host instance, sync2 down-translation, non-fatal failed submit | 500a1ef81, d6a911232, 15463def7, b020a784d, a3fb53d7a | — | 可獨立上游 |
| X10 | X | vulkan: lifecycle races — a device belongs to its creating instance, flush/invalidate under the lock, cleanup after the instance is gone, destroyed pipeline cache | 500a1ef81, ef009ad0d, 83e84bcff | — | |
| X11 | X | vulkan: never hand the driver a raw push-descriptor-with-template op, and print unknown sTypes without dereferencing NULL | 3ae3ea7d2 | — | 安全修正 |
| X12 | X | gunyah: enable VulkanRobustness by default | 3f9f44b6e | — | |
| X13 | X | vulkan: expose device-local-only shadow memory types | d76fda021 | — | 沒 launcher 用就丟 |
| X14 | X | vulkan: take the device-op sweep off the guest-facing paths, and complete ops from fences the caller already knows are signalled | cf335e55d, b51ea5995, e94583f9c, e4c7ca4d3 | — | vkmark 4129→8713 |
| X15 | X | gfxstream: the ASG consumer spins longer before parking, attaches to the guest's ring instead of re-initialising it, and says honestly when it is parked | 01974406d, 85b47d9e9, 271456d3f, 3469a519c, f2427907f | — | 1µs sleep stage 已退回 |
| X16 | X | gfxstream: stream framing — accumulate the opening word, repair a stray word at any packet boundary, end a stream nobody can decode | a1aed6a89, 53d99b657, 7433c980d, 2925a25d5, 473ce9900, e11419ff0, 39ca2a227, bcd5b5e54, c93a4b721 | — | |
| X17 | X | gfxstream: give every render thread a sequence counter, a recycled context id a fresh one, and make the wait yield then park on a futex | dbf8b0f12, 4aaec8bb5, 748560551, 836ef19e8, 5053a37ff, 90c6cb1a2, e9a6bd75b, a1aed6a89 | — | 整串 repair saga 淨零 |
| X18 | X | gfxstream: guest-blob imports — bind a blob someone else created, retain the dups, let imported memory be guest-mappable, drop the entry when the resource dies | 3d650ed74, 53d99b657, eb4b020bb, 7876ed0d5 | — | 讓 kwin/plasmashell 活下來 |
| X19 | X | gfxstream: process teardown must not reach the next owner of a context id | ea6f2b4c0, 477e6f26a, e64b5fc5e | — | 淨行為只剩「不 flag、不 wait」，plumbing 可簡化 |
| X20 | X | gfxstream: opt-in profiling — per-opcode decoder profile, submit and sweep timers, reset-fence and semaphore-wait traces | 486358b78, b33c983f6, 00ad7a2d0, 5f7bc6a8e, 5f8cd4ef6, 9c9d406e2, dc2b11318, decaa5f3d, aa6980445, fef78c14c | — | **建議丟**（~700 行） |
| X21 | X | gfxstream: stream and startup diagnostics behind GFXSTREAM_DIAG | 5863a3920, fc9d94160, a9d47c77f, f64c6f87a, 5053a37ff, 7876ed0d5, 1d7185732, 39ca2a227, 5d461e20f | — | **建議丟或大砍** |

## 10. virglrenderer（`8220efec` AOSP snapshot → c7fd533，41 → 24）

已 unshallow，graft 前的 13 個 commit（P 開頭那幾列）現在納入。三個發現改寫了原本的計畫：

- **`d97194c6` 有 99.6% 是上游 `src/drm` native-context 框架的 vendoring**（16 264 行複製 vs 72 行 DroidVM 適配），
  必須拆成「vendor 上游框架」+「讓它在這個舊 core 上編起來」兩個 commit，KGSL 後端才審得動。
  **上游 ref 沒有記在樹裡**，要連網找回來釘在 commit message（特徵：有 asahi/panfrost/i915/amdgpu backend、`virgl_prefixed_logv`、`vdrm_ccmd_req` → upstream main, 2025 年中）。
- **KGSL 後端的作者是 HuJK 不是 lateautumn233**（他 graft 前只有 b9881a0c 一個 vrend commit）——原本報告的推測要更正。
- **P4 直接生成 `drm2kgsl` 命名**，原本的 D1 改名 commit（a7bcdd6+c901132）整個消失。

| # | bucket | commit subject | 併入 | Co-a | 備註 |
|---|---|---|---|---|---|
| P1 | G | virgl: disable dual-source blend on Adreno GLES | **b9881a0c** | lateautumn233 | 唯一碰 vrend/GL 的；三條路線的 UEFI/fbcon/VNC 都走 virgl2 |
| P2 | G | virgl: vendor the upstream DRM native-context framework (src/drm) at \<upstream ref\> | d97194c6(上游檔) | — | 47 新增 + 10 同步，≈16 264 行；**上游 ref 待查**。其中 amdgpu/asahi/i915/panfrost + 它們的 uapi header（≈11.6k 行）**根本沒編**，要不要留見下方 |
| P3 | G | drm: back-port the native-context framework onto the vendored virgl core | d97194c6(適配), 051b87d4, 095e085b | — | ≈72 行：log 相容層、hash_table API、`DRM_IOCTL_SET_CLIENT_NAME` guard、`fd<0` fallback、`ENABLE_DRM`。095e085b 補回 vendoring 漏掉的 `virgl_fence_table_init/cleanup`——扁平後這個漏根本不存在 |
| P8 | G | virgl: serve transfers on pipe-less blob resources with a CPU copy | c58b5266(core) | — | crosvm VNC/screenshot readback 的 `ComponentError(22)` 黑畫面；G3 之後會再改它 |
| P4 | D | drm2kgsl: msm-protocol native-context backend over KGSL | 147dea51, c1aa016c, e9c0801b, f0453560 | — | 真正的 DroidVM 發明；四個當天的 on-device 修正是互相取代不是疊加。**直接用 drm2kgsl 命名** → 原 D1 改名 commit 消失 |
| P5 | D | drm2kgsl: never explicitly unbind VBO ranges (msm BO-lifetime semantics) | 26348f9d(unbind) | — | 順手刪掉從此沒人用的 `kgsl_vbo_unbind()` |
| P6 | D | drm2kgsl: import every BO IO-coherent | 26348f9d(cache flag) | — | 從 26348f9d 拆出來：guest 沒辦法做 KGSL cache maintenance，非 snooping 讀到舊 DRAM → 桌面幾何炸掉。原 commit 訊息完全沒提這件事 |
| P7 | D | drm2kgsl: per-context VA slices — fix cross-client VBO iova collisions | f6a66611 | — | KGSL pagetable 是 per-process，每個 guest process 的 turnip 共用同一個 VBO |
| ~~P9~~ | D | ~~drm2kgsl: IB visibility/scan probes and the NCTX_NO_FENCE gate~~ | 26348f9d(probes), c58b5266(NCTX_NO_FENCE) | — | **建議丟**：NCTX_NO_FENCE 要防的 crash 其實是 P3(095e085b) 修掉的，開關活過了它的理由 |
| L1 | L | licensing: GPL with additional permissions to take the work upstream | 00c22b1, 26d604b | — | |
| M1 | M | virgl: check the log level before formatting, add virgl_set_log_level() and a SILENT level | **336c5ae** | lateautumn233 | ↔ crosvm G8 |
| G1 | G | virgl: let a context hand back a persistent host mapping (blob map_ptr) | **1e5568d**(core) | lateautumn233 | drm2kgsl arena + venus pool 都靠它 |
| G2 | G | virgl: display-only DMA-BUF export for SHM-backed resources | **fd611e6**, **24ce0a6** | lateautumn233 | ↔ crosvm G9 |
| G3 | G | virgl: map a blob transfer at its fd_offset, and expose virgl_renderer_resource_get_map_ptr() | eb20aa1 | — | 改的是 P8 的函式 |
| G4 | G | virgl: set_guest_blob_fd — hand a context the VMM's dma-buf over a guest-allocated blob's pages | e066ec7(core) | — | ↔ crosvm D3 |
| D2 | D | drm2kgsl: pre-shared blob arena — sub-allocate BOs and the shmem ring from a host-blessed region, import arena BOs across contexts with refcounted ranges | **1e5568d**(backend), **b91929a**, **9a15136** | lateautumn233 | |
| D3 | D | drm2kgsl: VA slices — geometry from the granted VBO (64 slices), leak fix on failed create, locked bitmask, overflow-safe bounds | **6ea764b**, **9c82cb0**, **dc0fca0**, **4b95636**(hardening) | lateautumn233 | 直接改寫 P7 |
| D4 | D | drm2kgsl: retire ring fences through WAITTIMESTAMP_CTXTID (poll first), keep sync-file fences on A830 | **44f90d1**, **36a2b12**, **ffb3aaa** | lateautumn233 | 若丟 P9，這裡有一句提到 NCTX_NO_FENCE 的註解要改 |
| D5 | D | drm2kgsl: arena and fence diagnostics, IB fault-scan probes | **939b20c**, **4b95636**(probes) | lateautumn233 | **建議丟**（與 P9 同一家族） |
| D6 | D | drm2kgsl: consume a crosvm pool slice as the blob arena | 64572ef | — | ↔ crosvm D1 |
| D7 | D | drm2kgsl: BOs are guest-allocated — GEM_NEW only records, get_blob imports the VMM's dma-buf | e066ec7(backend), 8740567, c7fd533 | — | wire flag day ↔ mesa drm2kgsl #10 |
| D8 | D | drm2kgsl: bias guest fence seqnos off KGSL timestamp 0 | 525ace0 | — | |
| V1 | V | venus: vendor upstream 1.3.0 vkr (virglrenderer dc35e4d) | 05f3358(vendored) | — | 最好逐 byte 等於上游（需連網驗） |
| V2 | V | venus: drive vkr in-process through a struct virgl_context adapter | 05f3358(adapter), ecc56c8(define) | — | V1 單獨不能編 → 也許與 V1 併 |
| V3 | V | venus: resolve Vulkan through ANDROID_EMU_VK_LOADER_PATH and the hwvulkan HMI bridge, cached for the process lifetime | 05f3358(vkr_library.c) | — | 讓 V1 保持 pristine；#if 0 死碼刪掉 |
| V4 | V | venus: harden vkr teardown for in-process use | ecc56c8 | — | 兩個真上游 bug，值得單獨送上游 |
| V5 | V | venus: serve blob_id==0 shmems from the venus_host pool | 73d830b, 1965c4b | — | VENUS-DIAG fprintf 要拿掉 ↔ crosvm V1 |

**這個 repo 特有的「永遠不要引入」清單**（歷史上加了、最後死掉，扁平後直接不要生出來）：
`427e1968` paged arena v2 整包（`nr_runs` 在 HEAD 從沒被賦值，`kgsl_vbo_bind_runs()`/`struct msm_gem_new_run` 全是死碼）、
`c58b5266` 的 THP-memfd BO allocator（`kgsl_alloc_thp_bo()` 沒人呼叫）、
`147dea51` 的 dma-heap allocator（沒人呼叫，但**至今每次 context create 都開 `/dev/dma_heap/system`，開不到就失敗**）、
`5d79e781` 的 ZONE_MOVABLE 註解（六小時後就被刪）。
代價：扁平後的樹會比 c7fd533 少掉這些死碼，而且 P4 到 D7 之間 `GEM_NEW` 不會配 backing——建議 P4 直接照最終架構寫
（GEM_NEW 只記錄、`get_blob()` 補完），反正歷史上 147dea51/c58b5266 也從來沒真的跑通過。

## 11. mesa

### 11-rebase. 實測：把 gfxstream 分支 rebase 到上游 main（2026-08-18）

備份 `backup/mesa-{gfxstream,venus,drm2kgsl}-20260818`；試作分支 `try/rebase-gfxstream`（worktree 在 scratchpad，未動既有三個 worktree）。

base 選 **`74d4e41b2bb`**（drm2kgsl 分支底下那個純上游 commit，2026-08-07）而不是 `origin/main`——後者 tip 是 lateautumn233 的
CI commit，Droid-VM/mesa 的 main 不是純上游鏡像。指令：`git rebase --onto 74d4e41b2bb 3f173c02d16`（只重放我們那 41 個，
不重放 26.0 穩定分支的上游 commit）。

**結果：可行，而且比留在 26.0.3 好。** 41 → 33 個 commit，delta 從 31 檔/1868 行縮到 26 檔/1733 行。

- **五次衝突**，全部在 `ResourceTracker.cpp` / `cpu_trace.h`，都不大：
  - 2 次是「上游後來自己做了同一件事」→ 我們的 commit 變空自動消失：
    `gfxstream guest: forward sampler/image-view pNext structs on Linux too`（上游已經 ungate 那兩個 pNext struct）、
    `gfxstream: expose VK_KHR_16bit_storage`（上游已列進 allowlist）。
  - 2 次是純文字位移（allowlist 位置、guard 縮排），照著上游新結構放回去即可。
    順帶發現我們的 `VK_KHR_imageless_framebuffer` 那行現在也是多餘的（上游 Vulkan 1.2 區已列）。
  - 1 次要**真的移植**：`util/perf: don't format a trace name…`。上游把 `_mesa_trace_scope_begin()` 改成
    `(bool cond, …)` 並回傳 struct，我們的補丁是寫在舊簽名上的。查證後上游**沒有**解決同一問題
    （沒編 backend 時 `MESA_TRACE_SCOPE` 仍傳 `cond=true`，vsnprintf 照跑；stub 只在編譯器缺 `cleanup` attribute 時），
    所以補丁仍然有效，已移植到新簽名（在 `if (unlikely(cond))` 外面包 `#if _MESA_TRACE_HAVE_BACKEND`）。
- **6 個 Blumenkrantz backport：不能靠 rebase 自動消。** 實測 3 個被 patch-id 判定重複而自動丟、1 個衝突（skip 掉）、
  另外 2 個（`TC_RESOLVE_STRICT` 0→1 與 1→0）互相抵銷所以留著當雜訊，而
  **`zink: use tc info to handle partial resolves` 乾淨套用成了「重複的第二份」**——上游後來改過那段、git 找到別的插入點，
  於是 `begin_rendering()` 裡那段 partial-resolve 邏輯出現兩次，沒有任何衝突警告。這是會靜默出錯的那種。
  正確做法是**明確 drop 掉那 6 個**（`rebase -i` 把 Mike Blumenkrantz 的 pick 改成 drop），不要指望 patch-id 偵測。
  照這樣重跑後：33 commits、zink_context.c 那段回到 1 份、`src/gallium` 一個檔都沒動——整個 backport 問題消失，
  因為上游 main 本來就有那 6 個修正。
- **還沒編過**。文字 rebase 成功 ≠ 能跑：`ResourceTracker.cpp` 有 626 行是我們的，上游這五個月動了不少，語意衝突要靠 build + 實機驗證。

### 11-merge. 實測：三支能不能合成一支 + 三個變體都編出來（2026-08-18）

接續 §11-rebase。`try/rebase-venus` 也接到同一個 base（44 → 36；唯一衝突是 `vn_renderer_virtgpu.c` 檔頭，
上游把 `SIMULATE_*` define 移走了，我們的 `CREATE_GUEST_HANDLE` 定義跟著它們放所以位置對不上）。
`wip/3d-accel-drm2kgsl` 本來就長在 `74d4e41b2bb` 上，不用動。

**編譯結果：三個變體全部編得過，零 FAILED**（`mesa-cross/build.sh` 是 git-agnostic 的，直接指向 scratch worktree，
沒動既有三個 worktree）。但編譯過程抓到三件純文字 rebase 看不出來的事：

1. **`-Werror=missing-declarations`**（上游 main 新增，26.0.3 沒有）撞到 `GFXSTREAM_MAP_LOW` 的三個函式。
   `gfxstreamLowVaEnabled`/`Reserve` 改 static；`gfxstreamLowVaRelease` 跨 TU，宣告移進兩邊都 include 的 `DrmVirtGpu.h`。
2. **上游把 codegen 產物從 build-time 產生改成簽入 repo**（`src/gfxstream/guest/vulkan_enc/autogenerated/`）。
   26.0.3 沒有這個目錄，meson 在 build 時跑 cereal script，所以我們改 `functable.py`/`transform.py`/`vulkantypes.py` 會自動生效；
   **在 main 上這三個補丁完全沒有效果**，除非重新產生產物並簽入。兩個後果：
   - 連結錯誤：`func_table.cpp` 自己定義了 `CmdPushDescriptorSetWithTemplate(KHR)`，跟我們手寫的 unroll 撞號。
   - **靜默失效**：沒有東西呼叫 `transformImpl_VkPhysicalDeviceMemoryProperties2_fromhost`，
     `VK_EXT_memory_budget` 回報 guest-alloc pool 變成死碼。這個不會有任何診斷訊息。
   已用 `generate-gfxstream-vulkan.sh` 的 guest 半重新產生。注意**不要**事後跑 clang-format：上游用的版本與 clang-format 16
   輸出不同，格式化反而讓 diff 從 431 行漲到 633 行。
3. **新缺口**：上游現在還產 `vkCmdPushDescriptorSetWithTemplate2` / `2KHR`（Vulkan 1.4 提升進 core），
   我們的 unroll 只處理非 2 的版本，這兩個新入口仍會把原始 pData 送給 host——正是當初要修的問題從新入口回來。移植到 main 必須補。

**三支可以合成一支。** 三支的檔案集合除了 4 個授權檔以外完全不相交（gfxstream 動 `src/gfxstream/**`、venus 動 2 個 `vn_*` 檔、
drm2kgsl 動 `src/freedreno/**` + `vdrm` + wsi + getstring），當初分家的唯一理由是上游 base 不同，rebase 之後那個理由沒了。
實測 `try/merge-all` = gfxstream 35 + venus 3 + drm2kgsl 23（跳過 3 個重複授權 commit）= **61 commits 零衝突**，
而且從這一棵樹編出三個 .deb 全部成功、版本號一致（`26.3.0-devel+droidvm.r227723.g94563500`）。
合併後可以拿掉 `mesa_variant_branch()` 與 `mesa_base_branch()` 的 strip-suffix 邏輯；
但 `build-in-container.sh` 的建置目錄是固定的 `build-cross`，三個變體共用一棵樹會互相 reconfigure，要改成 `build-cross-$V`。

**還沒驗證、而且比編譯更重要**：gfxstream guest ICD 從 26.0.3 換到 main 之後，encoder 產生的 wire 是否還與我們的 host
decoder（AOSP android16-qpr2 那份 fork）相容。編得過只證明語法沒問題；上面第 3 點那種新 opcode 正是會炸的來源。要實機驗。

試作分支：`try/rebase-gfxstream`(35)、`try/rebase-venus`(36)、`try/merge-all`(61)；worktree 在 scratchpad，
.deb 在 scratchpad 的 `dist-try/`、`dist-merged/`（沒有混進 dist-guest/）。備份 `backup/mesa-*-20260818`。

### 11a. `pr/3d-accel-gfxstream`（26.0.3 `3f173c02d16` → 512f8000316，40 → 6 backport + 17）

| # | bucket | commit subject | 併入 | Co-a | 備註 |
|---|---|---|---|---|---|
| B1-B6 | G | zink/tc renderpass-info backports（原樣保留 Mike Blumenkrantz 作者與 cherry-pick trailer） | 66736e76726, 7bd536a494e, 96e71d32601, 80eb5b4066c, 99c7f0e3c76, 512f8000316 | — | **上游 cherry-pick，例外不併**（見開頭決定 1） |
| 1 | L | licensing: GPL-2.0-or-later with additional permissions to take the work upstream | f08df78d0d0, 3f37b680916, **91374abe612** | — | 08-18 改成 GPL-2.0-or-later，授權檔 LICENSE.GPL-3.0 → LICENSE.GPL-2.0 |
| 2 | M | build: ignore build-cross/ and install-cross/ | 207f1816f0e(部分) | — | |
| 3 | G | util/perf: don't format a trace name when no tracing backend is compiled in | 89375e82401 | — | 可獨立上游 |
| 4 | G | zink/kopper: do not index the swapchain with a stale dt_idx | e14d2e5fc2c（目前只在 venus 分支） | — | 三條路線都跑 zink，建議三支都帶 |
| 5 | X | gfxstream: pass VK_EXT/KHR_robustness2 through and tolerate null buffer descriptors | **2168f8e1e34**(robustness2) | lateautumn233 | |
| 6 | X | gfxstream: back every exportable allocation with a blob, dedicated resource or not | **2168f8e1e34**(alloc) | lateautumn233 | |
| 7 | X | gfxstream: unroll push-descriptor templates guest-side and expose VK_KHR_push_descriptor | 9f65df6ece5 | — | 過期註解要清 |
| 8 | X | gfxstream: allow VK_EXT_multi_draw, VK_EXT_vertex_attribute_divisor and VK_KHR_16bit_storage through | 7a4ba5af11d, 9f65df6ece5(2 行) | — | |
| 9 | X | gfxstream: GFXSTREAM_MAP_LOW — place host-visible maps in the low 4 GB for 32-bit callers | 7596f6fa0f3, aec9c5ed48e, 52fd76a0b0c | — | 自述「DroidVM experiment」，上游 PR 要不要放 |
| 10 | X | gfxstream: gate the goldfish-only submit signalling on the platforms that actually signal | f4de8ff9847, 82b6fb7d25f | — | vkmark 3792→4468 |
| 11 | X | gfxstream: forward sampler and image-view pNext structs on Linux too | 0ef0122a5f9 | — | 可上游 |
| 12 | X | gfxstream: advertise VK_KHR_display so apps can present fullscreen | 7177dd271f7 | — | 可上游 |
| 13 | X | gfxstream: wake a parked host from every transport wait, and stop holding a vCPU for fifty million turns before sleeping | 6e2fea908a3, 7b9c82ea61f, cea499343cf, 5de944cbf18, 207f1816f0e(部分) | — | 順手刪 m_deepWaitPingCountdown 死碼 |
| 14 | X | gfxstream: do not build a stream before the host has sized it | d6d482a7320 | — | |
| 15 | X | gfxstream: report the guest-alloc pool through VK_EXT_memory_budget | add5bfd6821, 207f1816f0e | — | 依賴 guest-additions 的 GETPARAM 0x1000-0x1002 |
| 16 | X | gfxstream: exportable host-visible memory lives in guest pages on a protected VM | 940052fc559, ec2ae71e316, ba0037b9932 | — | ↔ crosvm G5 / gfxstream X6 |
| 17 | X | gfxstream: opt-in stream, image and extension tracing | 3238b4a62d7, 6c5ecd8beb5, 197a3d5f264, 1c1f1d86d12 | lateautumn233（ZC-EXTDBG） | **建議丟** |

淨零：fd36a661709+b0a3d691137、802f4d5831a+f80a84b5c10、c4f08227484+bee068b6c90+7dfd94ff794。

### 11b. `pr/3d-accel-venus`（26.0.3 → 0873b05d7bc，43 → 6 backport + 6）

**不要**用 gfxstream 分支當 base（會拖進 27 個 gfxstream-only 檔）。

| # | bucket | commit subject | 併入 | Co-a | 備註 |
|---|---|---|---|---|---|
| B1-B6 | G | 同 11a 的 6 個 zink/tc backport（venus 分支上的 hash：b1c43db9b02, d9a322761fc, b1bb673028d, 803be402b54, 0dc5db14ff5, 0873b05d7bc） | | — | venus 就是這個 deadlock 的根因現場 |
| 1 | L | licensing: GPL-2.0-or-later with additional permissions to take the work upstream | f08df78d0d0, 3f37b680916, **e95cae6583e** | — | 與 11a 逐 byte 相同 |
| 2 | M | build: ignore build-cross/ and install-cross/ | 207f1816f0e(部分) | — | 可選 |
| 3 | G | util/perf: don't format a trace name when no tracing backend is compiled in | 89375e82401 | — | 可選 |
| 4 | G | zink/kopper: do not index the swapchain with a stale dt_idx | e14d2e5fc2c | — | Minecraft SEGV |
| 5 | V | venus: give guest-vram allocations the guest-alloc wire shape (HOST3D_GUEST + CREATE_GUEST_HANDLE) | 61f7f4c7e53 | — | ↔ crosvm V1 |
| 6 | V | venus: do not take the ring mutex twice for the guest-vram upload roundtrip | 958d64bb23f | — | 修 kwin 首次大 shader upload 自鎖 |

### 11c. `pr/3d-accel-drm2kgsl`（mesa main `74d4e41b2bb` → 9be474f1658，25 → 12）

這支 25 個裡 20 個是 lateautumn233 的（等於他的 `dev` 分支），依新規則全部併入功能 commit 並掛 Co-authored-by。
6 個 Blumenkrantz backport 的原始 commit 已在這個 base 裡，**不要**帶進來。

| # | bucket | commit subject | 併入 | Co-a | 備註 |
|---|---|---|---|---|---|
| 1 | L | licensing: GPL-2.0-or-later with additional permissions to take the work upstream | 732d5cbbc42, 9be474f1658, **ff069bb3c71** | — | |
| 2 | M | mesa/main: return an empty string for core-profile GL_EXTENSIONS | **9c8575b06cd** | lateautumn233 | spec 說 NULL，上游大概會退；Qt strlen crash |
| 3 | M | ci: build the guest mesa GLVND arm64 deb on GitHub Actions | **f4859706843**, **6c1364fb4d2**, **7889494f1a2**, **8654cad05fc**, **ec44b80bca1** | lateautumn233 | **不上游** |
| 4 | G | wsi/wayland: make the MAILBOX image count configurable | **200a3027789** | lateautumn233 | 把預設 4→8 改到所有 ICD，上游會問 |
| 5 | G | wsi/drm: batch the explicit-sync release probe | **2a23cd55d21** | lateautumn233 | 預設關 |
| 6 | D | tu/a750: emit BR-only RB CCU registers outside CP_SET_THREAD_BOTH | **9452b5e9090** | lateautumn233 | 真硬體修正，值得單獨上游；host turnip 也要 |
| 7 | D | freedreno: recognize a750/a840 virtio guests | **9452b5e9090**(ids), **30158be8f1e** | lateautumn233 | 只有 device-id 表 |
| 8 | D | tu/virtio + freedreno/virtio: query the context VA slice on the real device context | **622c4323604**, **a9eb89e2bc3** | lateautumn233 | Vulkan + GL 兩邊 |
| 9 | D | tu/virtio: poll-first fence waits, empty submits resolved guest-side, lazy BO iova to the zombie VMA path | **039e8b29401**, **70ea33132c0**, **fe04b37f584**, **b272a38acdb**, **50f6f0acbe9** | lateautumn233 | vkmark 5427→9462 |
| 10 | D | tu/virtio + freedreno/virtio: allocate BO pages from the guest pool when the VMM offers one | 43f30bb6413, **9a7fdc670cc** | lateautumn233 | HuJK 起頭、他延伸到 GL ↔ virgl D7 |
| 11 | D | tu/virtio: size the heap from the guest pool, keep it coherent, initialise the pool-backed global BO and bound allocations | 4d50b92ec73, **6243ac58248**, **eef146a7553** | lateautumn233 | |
| 12 | D | tu: make a zeroed tu_bo mean "not in the dump BO list" | 23a873921b7 | — | 通用 turnip bug，可獨立上游 |

## 12. crosvm-minimal-manifest
一個：`manifest: add external/zstd (C libzstd for disk qcow2 zstd clusters)` — f32c2d0（配 crosvm M8）。

---

## 待你拍板

1. **mesa 的 6 個 Blumenkrantz upstream cherry-pick**要不要也併（我建議不要，理由見開頭）。
2. **診斷/實驗 commit**：meta #9/#11/#13/#15、crosvm G12（+GH_NO_UNSHARE、POOL_GROW_TEST）、gfxstream X20/X21、virgl P9+D5、mesa 11a#17、host_mod #10 —— 上游 PR 全丟？
2b. **virglrenderer P2 的 4 個沒編的 backend**（amdgpu/asahi/i915/panfrost + uapi header，≈11.6k 行）：留著讓 `src/drm` 與上游逐 byte 相同（日後上游 MR 是乾淨 diff），還是砍掉讓 P2 縮 70%？
2c. **virglrenderer 上游 ref 待查**（需連網）：P2 的 vendoring 到底 vendor 自上游哪個 commit，要釘進 commit message；V1 的 vkr 1.3.0 是否逐 byte 等於 dc35e4d 也要同樣驗證。
3. **crosvm d9000bb43** 的作者 `Your Name <you@example.com>` 是不是 lateautumn233（要掛 Co-authored-by 就得確認）。
4. **PR 目標分支名**：org 預設是 `wip-3d-accel`（連字號）。meta / gunyah_host_mod / guest-additions 整個 repo 都是 3d-accel 工作，
   建議 `pr/3d-accel` 直接以新歷史取代；`lib_branch.sh` 的 `TRUNK`/`LEGACY` 要跟著改成 pr/ 家族。
5. **Claude-Session trailer** 全部拿掉？HuJK 兩個 email（`gh@hujk.oeg` / `s920361@gmail.com`）統一哪一個？
6. **授權不一致**：crosvm `zstd_ffi.rs`(BSD-3)、gfxstream `GfxstreamDiag.h`(AOSP Apache)、virgl `vkr_virgl_adapter.{c,h}`(MIT) vs LICENSING.md 的規則；
   meta repo 的 .sh 全無 SPDX header；DroidVM ADDITIONAL-PERMISSIONS §2 空白。
