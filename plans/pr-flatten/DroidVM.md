# DroidVM app (Droid-VM/DroidVM) — base origin/master 3458070 (BigfootACA master; merge-base 33cf759) .. 15a7e7d (wip/3d-accel)  59 original commits (incl. 1 merge), 481 net files

Repo path: /root/Documents/DroidVM_meta/DroidVM

Style note: HuJK's subjects here are `area: what` in imperative/plain mood (`crosvm: ...`, `daemon: ...`, `ui/vm: ...`, `display: ...`, `native display: ...`, `settings: ...`, `disk: ...`, `licensing: ...`); lateautumn233 uses conventional `feat(scope): ...`. Proposed subjects below follow HuJK's style.

Base rebase FIRST (see "Open questions" §1): origin/master is 3 commits past the merge-base (9d237f8 hugepage v11, 78c2223 merge of PR #37, 3458070 libcompat). `wip/3d-accel` carries f28c8ad = a byte-for-byte duplicate of 9d237f8 except ONE string bullet ("- " on master vs "•" on wip in `hugepage_cma_warn_msg`). `pr/3d-accel` must be rebased onto origin/master and f28c8ad dropped. Two net-diff entries (`app/src/main/cpp/compat/a14.cpp`, `a15.cpp`) are only the REVERSE of master's 3458070 showing through (no wip commit touches them) and vanish on rebase.

Net-file arithmetic: 481 = 3 root licensing files + 326 `.java` files whose only net change is the 3-line SPDX header (324 untouched by any feature commit + `HugePageActivity.java`/`HugePageModel.java`, whose f28c8ad content cancels against master's 9d237f8) + 2 rebase artifacts (a14/a15.cpp) + 150 files touched by feature commits (many of which ALSO carry the SPDX header hunk, which belongs to L).

## Proposed flattened commits (in order)

Legend for hunk splits: "(hdr→L)" = the file's SPDX header hunk goes to L1; the rest to the row. Files marked SPLIT are itemised in "SPLIT NEEDED files".

| # | bucket | proposed subject | folds original commits | net files (paths) | notes |
|---|--------|------------------|------------------------|-------------------|-------|
| L1 | L | licensing: state the GPLv3 the app already used, allow upstream submission, attribute to the Droid-VM organization | 5a0a9ce, a0f4632 | `ADDITIONAL-PERMISSIONS`, `CONTRIBUTING.md`, `LICENSING.md` (all new); the 3-line SPDX header hunk of EVERY pre-existing `.java` under `app/src/main/java` in the net diff = the 326 header-only files (full list in Appendix A) + the header hunk of the 53 master-existing `.java` files that feature rows also modify (exact list: `BaseExtraKeysAdapter.java`, `BaseVncActivity.java`, `BootPlan.java`, `CpuUtils.java`, `CrosvmBackendInstance.java`, `DataAdapter.java`, `DiskActionDialog.java`, `DiskAdapter.java`, `DiskCompress.java`, `DiskConfig.java`, `DiskCreateActivity.java`, `DiskInfoInfoTab.java`, `DiskInfoSnapshotTab.java`, `DiskOperationActivity.java`, `DiskStore.java`, `DisplayExtraKeysPanel.java`, `DisplayProvider.java`, `DroidVMApp.java`, `EvdevEncoder.java`, `GpuApi.java`, `ImageCommandGenerate.java`, `ImageUtils.java`, `ImportImagesActivity.java`, `ImportLxcImagesActivity.java`, `ImportURLActivity.java`, `InputForwarder.java`, `KeyCodeMapper.java`, `KeyListener.java`, `MainDiskFragment.java`, `MainSettingsFragment.java`, `MaterialMenu.java`, `NativeDisplay.java`, `NativeExtraKeysPanel.java`, `ServerContext.java`, `SetupActivity.java`, `TabSwipeHelper.java`, `TarWriter.java`, `TextRowWidget.java`, `TouchScaleCalculator.java`, `VMActions.java`, `VMBackendInstance.java`, `VMDiskEditAdapter.java`, `VMDiskEditViewHolder.java`, `VMEditActivity.java`, `VMEditBaseTab.java`, `VMEditBasicTab.java`, `VMEditGraphicsTab.java`, `VMEditStorageTab.java`, `VMInstanceStore.java`, `VMNativeDisplayActivity.java`, `VMVncDisplayActivity.java`, `VncExtraKeysPanel.java`, `X11Keymap.java`) | 5a0a9ce touched 400 files; 17 of them were in-branch-created files (HostSocName, GamePerfHint, DisplayOutput, GpuMode, GpuProvider, AdaptiveTabLayout, KernelModuleDialog/Manager, DaemonDisplayAttach, DisplayChromeController, DisplayInputBackend, DisplaySource, DisplayViewportController, InputMode, PointerGestureTranslator, NativeSurfaceSource, VncBitmapSource) — in the flatten those carry the header from birth in their feature row, not in L1. `LICENSE.txt` deliberately untouched. ADDITIONAL-PERMISSIONS §2 "Upstream Projects" list and LICENSING.md "Material inherited from upstream" section are EMPTY placeholders — must be filled before submission. `app/src/test/**` and `.cpp/.c` under `app/src/main/cpp` got no header (see Open questions §5). |
| M1 | M | daemon: pass the real host CPU name to guests via crosvm --smbios | 4402a0c | `app/src/main/java/cn/classfun/droidvm/daemon/vm/backend/HostSocName.java` (new); `CrosvmBackendInstance.java` (SPLIT: the `--smbios processor-version=` hunk in buildCommand) | Needs the DroidVM crosvm fork's `--smbios processor-version` → FDT /chosen → edk2 SMBIOS Type 4 path. Not GPU. |
| M2 | M | daemon: give loaded VM instances the real network store | 40f3594 | `daemon/server/ServerContext.java`, `daemon/vm/VMInstanceStore.java` | Pure bug fix (VM with NICs failed to start: "has networks but no network store"). |
| M3 | M | daemon: pass --swiotlb from swiotlb_mb to crosvm | 13ba212 (swiotlb hunk only) | `CrosvmBackendInstance.java` (SPLIT: `var swiotlbMb = item.optLong("swiotlb_mb", 0); ... args.add("--swiotlb")` hunk) | `swiotlb_mb` key + UI already exist on master (QEMU backend used it); crosvm just never got the flag. |
| M4 | M | settings: kernel module manager — list shipped host modules by KMI + SoC match, load/unload, load with the daemon, "why needed" pages, setup-wizard step | 691cd35, a60487c, cde941b, 2cb1627, 15a7e7d, 1228b39 (kmod hunks), e50758c (module-page hunks), afa8776 (`kernel_module_subtitle` string fix) | `DroidVMApp.java` (applyAutostart hunk; hdr→L), `ui/main/settings/KernelModuleDescriptions.java`, `KernelModuleDialog.java`, `KernelModuleListController.java`, `KernelModuleManager.java`, `KernelModuleMatch.java`, `KernelModuleWhyDialog.java` (all new), `lib/data/SocIdentity.java` (new), `ui/setup/step/KernelModuleStepFragment.java` (new), `ui/setup/SetupActivity.java` (kmod step + hidden-step skipping; hdr→L), `ui/widgets/row/ShrinkToFitRow.java` (new), `MainSettingsFragment.java` (SPLIT: item_kernel_modules row + showKernelModules), `res/layout/fragment_main_settings.xml` (SPLIT: `item_kernel_modules` row), `res/layout/dialog_kernel_modules.xml`, `dialog_module_descr.xml`, `fragment_setup_step_kmod.xml`, `item_kernel_module.xml` (new), `assets/match.json`, `assets/descr/gh_hugepage_reserve.html`, `assets/descr/style.css` (new), strings (SPLIT: `kernel_module_*` (17 keys), `setup_kmod_desc`) in `values/`, `values-zh-rCN/`, `values-zh-rTW/strings.xml` | Reads `usr/lib/modules/<kmi>/*.ko`, `usr/lib/modules/match.json`, `usr/lib/modules/descr/*.html` from the prebuilt tree (gunyah_host_mod repo) — cross-repo contract. The modules it manages (gunyah_host_share, udmabuf, gh_unmovable, kvcalloc) serve the GPU routes, but the manager itself is route-agnostic. |
| M5 | M | ui: adaptive tab layout — spread tabs when they fit, scroll when they do not; tab strip owns its own drags | 8362652, 93660e1 | `lib/ui/AdaptiveTabLayout.java` (new), `lib/ui/TabSwipeHelper.java` (hdr→L), `res/layout/activity_disk_info.xml`, `activity_network_info.xml`, `activity_vm_edit.xml` | |
| M6 | M | disk: one definition of the compression crosvm can boot, and stop re-compressing on import | db2ede5 | `daemon/ipc/vm/DiskCompatHandler.java` (DELETED), `daemon/vm/BootPlan.java` (hasCompressedClusters removed; hdr→L), `lib/utils/ImageUtils.java` (SPLIT: `detectCompression`), `ui/disk/create/DiskCompress.java` (CROSVM_SUPPORTED etc.), `ui/disk/operation/OptimizeCompression.java` (new), `ui/disk/action/DiskActionDialog.java` (SPLIT: compression hunks), `ui/disk/download/ImportURLActivity.java`, `ui/disk/images/ImportImagesActivity.java`, `ui/disk/lxc/ImportLxcImagesActivity.java` (SPLIT: skip-rewrite hunks), `ui/disk/operation/DiskOperationActivity.java` (SPLIT: optimize-target hunks), `MainSettingsFragment.java` (SPLIT: KEY_VM_OPTIMIZE_COMPRESSION / dialog; removes keep-compress switch), `ui/vm/VMActions.java` (SPLIT: pre-start compression guard via qemu-img), `res/layout/dialog_optimize_compress.xml` (new), `res/layout/fragment_main_settings.xml` (SPLIT: keep-compress switch → `item_vm_optimize_compression`), strings (SPLIT: `settings_optimize_compression_title/_ask`, `disk_compress_none`, `disk_optimize_compress_remember`; removes `settings_vm_keep_compress_on_optimize_title/_summary`) | Removes a daemon IPC handler (`disk_compat`) — note for API consumers. |
| M7 | M | vm/disk: surface crosvm's no-snapshot rule before it bites | baf0ed7 | `lib/utils/ImageUtils.java` (SPLIT: `hasInternalSnapshots`), `ui/disk/info/snapshot/DiskInfoSnapshotTab.java` (SPLIT: crosvm-writable warning), `ui/vm/VMActions.java` (SPLIT: snapshot pre-start guard + flatten offer), strings (SPLIT: `vm_snapshot_disk_title/_message/_flatten`, `disk_snapshot_crosvm_warning_title/_message/_create`) | |
| M8 | M | disk: overlays as a tree you can branch, switch and collapse | 1228b39 (disk hunks — the bulk of it) | `lib/store/disk/DiskConfig.java`, `DiskStore.java` (parent link), `lib/utils/ImageUtils.java` (SPLIT: `hasBackingFile`), `ui/disk/action/BackingChainLinker.java` (new), `DiskOverlayCreateDialog.java` (new), `DiskActionDialog.java` (SPLIT: overlay/merge/flatten/lock hunks), `ui/disk/create/DiskCreateActivity.java`, `Import{URL,Images,LxcImages}Activity.java` (SPLIT: backing-chain registration hunks), `ui/disk/info/info/DiskInfoInfoTab.java`, `DiskInfoSnapshotTab.java` (SPLIT: base-locked refusal), `ui/disk/operation/DiskOperationActivity.java` (SPLIT: overlay create/merge/flatten ops), `ImageCommandGenerate.java`, `ui/disk/tree/DiskTree.java`, `DiskTreeCollapse.java`, `DiskTreeDialog.java`, `DiskTreeView.java` (new), `ui/main/base/list/DataAdapter.java`, `ui/main/disk/DiskAdapter.java`, `MainDiskFragment.java`, `ui/vm/VMActions.java` (SPLIT: locked-base pre-start guard, registry self-repair), `ui/vm/VmRunningQuery.java` (new), `ui/vm/edit/storage/VMEditStorageTab.java`, `storage/disk/VMDiskEditAdapter.java`, `VMDiskEditViewHolder.java`, `res/layout/dialog_overlay_create.xml`, `item_disk_tree_row.xml` (new), `item_vm_disk_edit.xml`, `partial_disk_info_content.xml`, `res/menu/menu_disk_actions_overlay.xml`, `menu_disk_tree_node.xml` (new), strings (SPLIT: `disk_tree_*`, `disk_locked_*`, `edit_vm_disk_locked_readonly`, `vm_locked_disk_*`, `disk_overlay_*`, `disk_chain_*`, `disk_merge*`, `disk_flatten*`, `disk_manage_branches*`, `disk_branches_button`, `disk_delete_tree_title/_message`, `disk_delete_subtree_message`, `disk_family_vm_running`) | 1228b39 is a mixed commit: its kmod hunks go to M4 and its `DisplayPhysicalKeyboardView` hunk (PgUp/PgDn → PrtSc/Pause) to M11. |
| M9 | M | display: unified input routing over crosvm --input evdev devices (touch / tablet / mouse) for VNC and native, shared gesture translator, coalesced motion, VNC direct binder sink | d92be08, 7909f11, da6715b, 0d5832e (input hunks), 4467065 (VNC `input=` hunk; nets to fixed `tablet` — see nets-to-zero) | `lib/store/vm/NativeDisplay.java` (MOUSE/TABLET channels), `CrosvmBackendInstance.java` (SPLIT: `isInputBridgeNeeded()`, `buildInputDevicesCommand()` (multi-touch/keyboard/mouse/absolute-mouse), `buildNativeDisplayCommand` reduced to `--android-display-service`, `,input=tablet` in `buildVncCommand`, start() pre-bind gate), `ui/vm/display/base/InputMode.java`, `DisplayInputBackend.java`, `PointerGestureTranslator.java` (new), `nativedisplay/input/EvdevEncoder.java`, `InputForwarder.java`, `KeyCodeMapper.java`, `TouchScaleCalculator.java`, `lib/ui/MaterialMenu.java` (header view), `res/layout/view_input_mode_toggle.xml`, `res/drawable/ic_tablet_stylus.xml`, `ic_touchscreen.xml` (new), `res/menu/menu_native_display_menu.xml` (SPLIT: `menu_rotate` added), `menu_vnc_display_menu.xml` (SPLIT: `menu_input_mode` removed), `VMNativeDisplayActivity.java`, `VMVncDisplayActivity.java`, `BaseVncActivity.java` (SPLIT: input routing / gesture / binder-sink hunks), strings (SPLIT: `vnc_menu_input_mode_tablet`) | Requires the DroidVM crosvm fork's `--input mouse[path=]` / `absolute-mouse[path=]` and `--vnc-server input=` support and its NORMALIZED_ABS_MAX contract. Not GPU. |
| M10 | M | display: viewport/chrome controllers, DisplaySource interface, shared daemon attach, follow guest resolution changes | 68a6067, 0d5832e (display hunks: config poll + NaN guard) | `ui/vm/display/base/DaemonDisplayAttach.java`, `DisplayChromeController.java`, `DisplaySource.java`, `DisplayViewportController.java` (new), `nativedisplay/display/NativeSurfaceSource.java`, `vnc/display/VncBitmapSource.java` (new), `nativedisplay/display/DisplayProvider.java` (SPLIT: `CONFIG_POLL_MS`/`startConfigPoll`/`applyConfigIfChanged`), `VMNativeDisplayActivity.java`, `VMVncDisplayActivity.java` (SPLIT: controller/insets/DisplaySource hunks), `res/layout/activity_vm_native_display.xml` (SPLIT: drop `fitsSystemWindows`), `app/src/test/.../DisplayViewportControllerTest.java` (new), `DisplayChromeControllerTest.java` (new — the 68a6067 base; ddd1d07 (other author) extends it later) | |
| M11 | M | display: keyboard modes — real key holds, laptop-layout keyboard, one-row keyboard menu, extra-keys regroup | eb999b2, e50758c (keyboard hunks), 1ab0125, 1228b39 (`DisplayPhysicalKeyboardView` FN-row hunk) | `ui/vm/display/base/BaseExtraKeysAdapter.java`, `DisplayExtraKeysPanel.java`, `KeyListener.java`, `X11Keymap.java` (hdr→L), `DisplayKeyboardMenuRow.java`, `DisplayPhysicalKeyboardView.java`, `HoldKeyGroup.java`, `KeyboardMode.java`, `ViewHeightAnimator.java` (new), `DisplayChromeController.java` (SPLIT: keyboard-mode / extra-zone state hunks — 68a6067 base is M10), `nativedisplay/input/NativeExtraKeysPanel.java`, `vnc/input/VncExtraKeysPanel.java`, `VMNativeDisplayActivity.java`, `VMVncDisplayActivity.java`, `BaseVncActivity.java` (SPLIT: keyboard hunks), `res/drawable/extra_key_bg.xml`, `ic_key_backspace.xml`, `ic_key_enter.xml`, `ic_key_shift.xml`, `ic_key_space.xml`, `ic_key_tab.xml`, `ic_key_windows.xml`, `ic_keyboard_close.xml`, `ic_keyboard_phy.xml` (new), `res/layout/activity_vm_native_display.xml` + `activity_vm_vnc_display.xml` (SPLIT: `phy_keyboard` view), `view_keyboard_mode_toggle.xml` (new), `widget_display_extra_keys.xml`, `res/menu/menu_native_display_menu.xml` + `menu_vnc_display_menu.xml` (SPLIT: remove `menu_keyboard`/`menu_extra_keys`), `res/values/colors.xml`, `ids.xml` (new), `themes.xml`, strings (SPLIT: `key_desc_*`, `key_ime`, `key_fnx`, `key_prtsc`, `key_pause`, `keyboard_mode_none/system/laptop`; removes `key_win`, `key_cap`, `key_shift`, `key_enter`) | Heavily interleaved with M9/M10 in the two activities; see Open questions §7 for the "one display-console commit" alternative. |
| M12 | M | native display: draw the guest's hardware cursor from crosvm's cursor position stream | e50758c (cursor hunks) | `nativedisplay/display/CursorPositionStream.java` (new), `DisplayProvider.java` (SPLIT: cursor surface/stream hunks, `CURSOR_PLANE_PX`), `DisplaySource.java` + `NativeSurfaceSource.java` (SPLIT: `setCursorView`/`setCursorListener`), `DisplayViewportController.java` (SPLIT: `panToShowContentPoint`), `VMNativeDisplayActivity.java` (SPLIT: cursor view wiring), `res/layout/activity_vm_native_display.xml` (SPLIT: `cursor_view` SurfaceView) | Depends on the crosvm fork publishing cursor positions + a cursor Surface via the Android display service. Not route-specific (simplefb too), so M rather than G; owner may prefer G. |
| M13 | M | native display: reconnect to a restarted crosvm with fresh surfaces | 1257dfa | `DisplayProvider.java` (SPLIT: binder-death re-fetch + `recreateSurface`) | |
| M14 | M | native display: suppress OEM full-screen touch gestures while a VM display is foreground | e1e7d91 | `lib/perf/SystemGestureGuard.java` (new), `VMNativeDisplayActivity.java` (SPLIT: enter/exitDisplay calls) | Writes ColorOS/OxygenOS `settings put system oplus_customize_*` via root — see "Consider dropping". |
| M15 | M | ui/vm: one display-output picker (none / native / VNC), display rows apply to every backend, native display also on simplefb, virtio display default 120 Hz | 8da1b6b (display hunks), 872408b (simplefb hunk; its blob_mode removal nets to zero), dd249db | `lib/store/vm/DisplayOutput.java` (new), `VMEditGraphicsTab.java` (SPLIT: display section — `chooseDisplayOutput`, `readDisplayOutput`, `isNativeDisplayAllowed`, `updateDisplayOutputVisibility`, VNC visibility off the picker, refresh default 120), `res/layout/partial_vm_edit_graphics.xml` (SPLIT: display section restructure — width/height/refresh first, `choose_display_output`, VNC block moved under display, `create_vm_category_vnc` container removed), `CrosvmBackendInstance.java` (SPLIT: `isNativeDisplayEnabled()` SIMPLEFB case; `display_refresh_rate` default 120), strings (SPLIT: `create_vm_display_output/_none/_native/_vnc`; removes `create_vm_category_vnc`, `create_vm_vnc_enabled`, `create_vm_native_display_enabled`, `create_vm_error_native_display_vnc_cannot_enabled`) | dd249db is labelled feat(gpu) but is just a default; fold here or make it its own one-liner. |
| G0 | G (or M) | app: declare game mode so the platform raises CPU/GPU clocks while a VM display is foreground | f9c0f32 | `app/src/main/AndroidManifest.xml` (`appCategory="game"`), `lib/perf/GamePerfHint.java` (new), `VMNativeDisplayActivity.java`, `BaseVncActivity.java` (SPLIT: enter/exitGameplay in onResume/onPause) | GPU-motivated (Adreno governor parks at min clock) but route-agnostic; equally defensible as M. See "Consider dropping". |
| G1 | G | ui/vm + crosvm: Gunyah dynamic memory sharing switch (--runtime-share, hugepage threshold) on the basic tab, published to other tabs that need it | 851651f (gunyah hunks), 8da1b6b (move to basic tab), d229f6a (shared-data channel + `showHint`) | `ui/vm/edit/basic/VMEditBasicTab.java` (SPLIT: `sw_gunyah_dynamic_share`/threshold + `updateGunyahVisibility` publish), `res/layout/partial_vm_edit_basic.xml` (SPLIT: gunyah section), `ui/vm/edit/VMEditActivity.java` (`SHARED_GUNYAH_DYNAMIC_SHARE`), `ui/vm/edit/base/VMEditBaseTab.java` (`showHint`), `CrosvmBackendInstance.java` (SPLIT: `--runtime-share hugepage-threshold-kb=` hunk in the GUNYAH case), strings (SPLIT: `create_vm_gunyah_dynamic_share`, `create_vm_gunyah_hugepage_threshold`, `create_vm_error_needs_gunyah_dynamic_share`) | Memory plumbing used by gfxstream dynamic-vram and by every guest-alloc route past its pool. Needs the crosvm fork's `--runtime-share`. |
| G2 | G | ui/vm + crosvm: three-level GPU section — renderer / graphics API (gpu_mode) / host driver (gpu_provider) with gpu_api migration; host Vulkan ICD selection (bundled turnip / system HAL / PanVK) via ANDROID_EMU_VK_LOADER_PATH; udmabuf size cap; pci-bar-size | 04f4fb6, eaf9a49, 4a6993f, b88ffe7 (row-naming hunks), b05a328 (row-ordering hunk), 8a247c7 (VK_* row generalisation), 0d5832e (gpu_api VULKAN_SYSTEM/TURNIP/PANVK + host-driver env hunks), 4467065 (turnip env), 13ba212 (udmabuf size_limit hunk), 07d843e, 86cd769 (pci-bar-size hunk), 1950f61 (2D `setItems` crash fix hunk) | `lib/store/vm/GpuMode.java` (new; SPLIT: OPENGL/VULKAN here, NATIVE→D1), `lib/store/vm/GpuProvider.java` (new; SPLIT: EGL/GLES/VK_SYSTEM/VK_TURNIP/VK_PANVK + fromLegacyApi here, DRM2KGSL→D1, retired-VENUS note→V1), `lib/store/vm/GpuApi.java` (SPLIT: VULKAN_SYSTEM/TURNIP/PANVK entries; DRM2KGSL→D1), `VMEditGraphicsTab.java` (SPLIT: `chooseGpuMode`/`chooseGpuProvider`, `updateGpuModeOptions`/`updateGpuProviderOptions` skeleton, `toLegacyApi`, `isVulkanProvider`, PanVK toast, legacy restore, 2D row hiding), `res/layout/partial_vm_edit_graphics.xml` (SPLIT: `choose_gpu_api` → `choose_gpu_mode` + `choose_gpu_provider`), `CrosvmBackendInstance.java` (SPLIT: `effectiveGpuMode()`, ANGLE→`gles=true`, `applyGfxstreamEnv()` host-ICD + udmabuf `size_limit_mb` glob (`gpu_udmabuf_limit_mb`), `gpu_pci_bar_size` default), strings (SPLIT: `create_vm_gpu_mode`, `create_vm_gpu_mode_opengl/_vulkan`, `create_vm_gpu_provider`, `create_vm_gpu_api_vulkan_system/_turnip/_panvk`, `create_vm_gpu_api_not_implemented`) | Framework shared by D/X/V. Note `applyGfxstreamEnv()` is gated `gfxstream || venus`; a route-neutral G2 could gate on `effectiveGpuMode()==VULKAN` (equivalent) — owner's call (Open questions §4). |
| G3 | G | ui/vm + crosvm: guest-allocated VRAM pool (gpu-guest-mb / udmabuf=true) shared by every route, VRAM section | 88d9ff1 (gpu-guest-mb hunks), 8bd2bf6, 851651f (guest pool hunk), b88ffe7 ("VRAM size" label, section expanded) | `VMEditGraphicsTab.java` (SPLIT: `vram_settings` container wiring, `til_gpu_guest_pool_mb`, `usesGuestPool()`/`updateVramAllocVisibility()` skeleton, `guestAlloc` visibility), `res/layout/partial_vm_edit_graphics.xml` (SPLIT: `vram_settings` CollapsibleContainer + `til_gpu_guest_pool_mb`), `CrosvmBackendInstance.java` (SPLIT: inline `gpu-guest-mb=%d` in each route's `--pre-alloc`; the `appendGuestPoolOptions()` refactor is lateautumn233's 5ec15a0), strings (SPLIT: `create_vm_category_vram`, `create_vm_gpu_guest_pool_mb`) | The guest pool is the same region/flag for gfxstream(udmabuf), drm2kgsl and venus. |
| G4 | G | ui/vm + crosvm: native-display GPU-blit provider (turnip / system / PanVK / off) with a real-time system-Vulkan capability probe | 1950f61, 09ce4f9 (blit/probe hunks) | `lib/store/vm/GpuBlitProvider.java` (new), `lib/natives/VulkanBlitProbe.java` (new), `app/src/main/cpp/vkprobe/vkprobe.cpp` (new), `app/src/main/cpp/CMakeLists.txt` (vkprobe target), `CrosvmBackendInstance.java` (SPLIT: `applyDisplayBlitEnv()`, `resolveSystemVulkanHal()`), `VMEditGraphicsTab.java` (SPLIT: `chooseDisplayBlitProvider`, `warnIfSystemBlitIncapable`, `accelScanout` visibility), `res/layout/partial_vm_edit_graphics.xml` (SPLIT: `choose_display_blit_provider`), strings (SPLIT: `create_vm_display_blit_provider`, `create_vm_display_blit_off`, `display_blit_system_missing_ext`) | Scanout/native-display path (G per preamble). Needs the crosvm fork's `CROSVM_DISPLAY_VULKAN_LIBRARY` / `GPU_DISPLAY_COPY_MODE` env. |
| OA-1 | G/M | (lateautumn233) feat(cpu): add vCPU affinity picker dialog and layout (+ GPU worker cpuset) | 0fcd8e4 — KEEP AUTHORSHIP | see "Other-author commits" | Sits here (after G4, before G5) — G5's switch lives inside this commit's layout container. Its context in `VMEditGraphicsTab.validate` touches X1 lines; see placement note. |
| G5 | G | graphics: "GPU worker real-time scheduling" switch (gpu_rt_prio), off by default | 3e0d6b3 | `CrosvmBackendInstance.java` (SPLIT: `applyGpuRtPrioEnv()`), `VMEditGraphicsTab.java` (SPLIT: `swGpuRtPrio` load/save), `res/layout/partial_vm_edit_graphics.xml` (SPLIT: `sw_gpu_rt_prio` inside the `create_vm_category_gpu_cgroup` container from 0fcd8e4), strings (SPLIT: `create_vm_gpu_rt_prio`) | Needs crosvm fork `CROSVM_GPU_RT_PRIO`. |
| D1 | D | ui/vm + crosvm: DRM native context route (drm2kgsl) — Native Context graphics API, DRM-to-KGSL host driver, context-types=virgl2:drm + udmabuf, drm-host-mb command-buffer pool (8 MB) | 3a05eee, 5f3d508, 88d9ff1 (drm hunks), 8ce9dae, 4b1c481, b88ffe7 (drm/Native strings), b05a328 ("Native Context first" ordering), 4a6993f (Native Context label) | `lib/store/vm/GpuApi.java` (SPLIT: `DRM2KGSL(8, "drm2kgsl")`), `GpuMode.java` (SPLIT: `NATIVE` + `fromLegacyApi(DRM2KGSL)`), `GpuProvider.java` (SPLIT: `DRM2KGSL(7)` + legacy map), `CrosvmBackendInstance.java` (SPLIT: `drm2kgslGpu` `--pre-alloc drm-host-mb=`, `effectiveGpuMode()==NATIVE` `--gpu` branch), `VMEditGraphicsTab.java` (SPLIT: NATIVE in virgl mode list, DRM2KGSL provider branch, `etGpuDrm2KgslPoolMb` default 8, drm2kgsl in `usesGuestPool`/`updateVramAllocVisibility`), `res/layout/partial_vm_edit_graphics.xml` (SPLIT: `til_gpu_drm2kgsl_pool_mb`), strings (SPLIT: `create_vm_gpu_mode_native`, `create_vm_gpu_provider_drm2kgsl`, `create_vm_gpu_api_drm2kgsl`, `create_vm_gpu_drm2kgsl_pool_mb`) | "Native Context"/"DRM to KGSL" intentionally untranslated (b88ffe7). |
| X1 | X | ui/vm + crosvm: gfxstream route — context-types=gfxstream-vulkan, vulkan+gles, gunyah-pvm, device-local memory type; host-alloc vs guest-alloc (udmabuf switch), gfx-host-mb command-buffer pool (64 MB), dynamic vram (vram-limit, pool-blob-max-kb) requiring dynamic sharing | 86cd769, 13ba212 (gfxstream env hunks), 851651f (vram hunks), 335c4e9, 8bd2bf6 (gfxstream-only gating), 88d9ff1 (gfx hunks), 8ce9dae, afa8776, b05a328 (rename gpu_arena_mb→gpu_vram_quota_mb, udmabuf default on), 0d5832e (gunyah-pvm / vram-limit hunks), d229f6a (dynamic-vram validation), 872408b (blob_mode removal — nets to zero against 13ba212) | `CrosvmBackendInstance.java` (SPLIT: `gfxstreamGpu` `--pre-alloc gfx-host-mb=`, dynamic-vram warning, `--gpu gfxstream` branch: `context-types=gfxstream-vulkan`, `vulkan=true,gles=true`, `vram-limit`, `pool-blob-max-kb`, `gunyah-pvm=true`, `udmabuf=true`; `GFXSTREAM_DEVICE_LOCAL_MEMORY_TYPE=1`; `isGunyahHypervisor()`), `VMEditGraphicsTab.java` (SPLIT: `swGpuUdmabuf`, `etGpuHostPoolMb` (64), `swGpuDynamicVram`, `etGpuVramQuotaMb`, `etGpuPoolBlobMaxKb`, `hostAlloc` visibility, `isDynamicMemorySharingAvailable`, `dynamicVramNeedsSharingMessage`, `loadingConfig` guard, validation), `res/layout/partial_vm_edit_graphics.xml` (SPLIT: `sw_gpu_udmabuf`, `til_gpu_host_pool_mb`, `sw_gpu_dynamic_vram`, `dynamic_vram_options`, `til_gpu_vram_quota_mb`, `til_gpu_pool_blob_max_kb`), strings (SPLIT: `create_vm_gpu_udmabuf`, `create_vm_gpu_host_pool_mb`, `create_vm_gpu_dynamic_vram`, `create_vm_gpu_vram_quota_mb`, `create_vm_gpu_pool_blob_max_kb`) | |
| OA-2 | G | (lateautumn233) feat(graphics): add guest memory allocation options | 5ec15a0 — KEEP AUTHORSHIP | see "Other-author commits" | Refactors `appendGuestPoolOptions()` over the gfxstream + drm2kgsl branches → sits after X1 (or after V1 with V's call adjusted). |
| V1 | V | ui/vm + crosvm: venus route — Vulkan graphics API under virglrenderer, context-types=virgl2:venus + udmabuf, host ICD row shared with gfxstream, venus-host-mb command-buffer pool (256 MB) | 09ce4f9 (venus hunks), e8e32f5, 8a247c7 (venus hunks; retires the short-lived VENUS provider), b88ffe7 (venus "not compiled in" toast — nets to zero) | `CrosvmBackendInstance.java` (SPLIT: `venusGpu` `--pre-alloc venus-host-mb=` (+ `appendGuestPoolOptions` call), `effectiveGpuMode()==VULKAN` `--gpu` branch `context-types=virgl2:venus`, `applyGfxstreamEnv()` venus gate + comment), `GpuProvider.java` + `GpuMode.java` (SPLIT: venus javadoc / retired-VENUS(8) comment / `fromLegacyApi(VULKAN)→VK_TURNIP` if owner treats that as venus-specific), `VMEditGraphicsTab.java` (SPLIT: VULKAN in the virgl mode list, `modeOk`/`vkMode` restore rule for virgl+VULKAN, `etGpuVenusPoolMb` (256), venus in `usesGuestPool`/`updateVramAllocVisibility`), `res/layout/partial_vm_edit_graphics.xml` (SPLIT: `til_gpu_venus_pool_mb`), strings (SPLIT: `create_vm_gpu_venus_pool_mb`; the three host pools were relabelled "Command buffer pool size (MB)" in e8e32f5 — apply the relabel of `create_vm_gpu_host_pool_mb`/`create_vm_gpu_drm2kgsl_pool_mb` in X1/D1 directly) | |

Other-author commits are interleaved as marked (OA-1, OA-2) plus the four listed below that have no ordering constraint beyond "after the HuJK commit they build on".

## Other-author commits (keep authorship)

All five are lateautumn233 <lateautumn233@foxmail.com>, merged from `origin/feature/dynamic-memory` (branched from HuJK's 1ab0125) by the merge commit 7ee6e51 (a CLEAN merge — `git show 7ee6e51` is empty, no conflict resolution to preserve; the merge commit itself disappears in the flatten). Cherry-pick each with `-x`/original author, in this order:

| commit | subject | files | where it sits / notes |
|--------|---------|-------|------------------------|
| a0f1435 | feat(archive): add zstd worker count configuration | `lib/archive/TarWriter.java` (hdr→L) | M bucket, anywhere (independent). |
| 6926338 | feat(vm): add environment variable configuration support | `daemon/vm/VMBackendInstance.java` (`applyConfiguredEnvironment`), `ui/vm/edit/basic/VMEditBasicTab.java` (SPLIT: env-var field/validation), `res/layout/partial_vm_edit_basic.xml` (SPLIT: `til_environment_variables`), strings `create_vm_environment_variables_hint`, `create_vm_error_invalid_environment_variable` (en/zh-CN/zh-TW) | M bucket. Authored on top of the gunyah section in the basic tab; place after G1 for a clean pick, or before with trivial layout-adjacency conflicts. |
| ddd1d07 | test(display): enhance DisplayChromeController tests | `app/src/test/.../DisplayChromeControllerTest.java` | After M11 (tests keyboard mode / extra zone toggling from eb999b2/e50758c). No SPDX header on this file (none of `app/src/test` has one). |
| 0fcd8e4 (OA-1) | feat(cpu): add vCPU affinity picker dialog and layout | `CrosvmBackendInstance.java` (SPLIT: `gpuCgroupPath`, `prepareGpuCgroup()`, `buildCpuPlacementCommand()` → `--cpu-affinity/--cpu-capacity/--cpu-cluster/--gpu-cgroup-path`), `lib/store/vm/CpuPlacementPlan.java` (new), `lib/utils/CpuUtils.java`, `MainSettingsFragment.java` (SPLIT: qemu-img affinity dialog → `CpuCorePickerDialog`), `ui/vm/edit/basic/VMCpuAffinityDialog.java` (new), `VMEditBasicTab.java` (SPLIT: affinity/topology), `VMEditGraphicsTab.java` (SPLIT: GPU worker cpuset rows), `ui/widgets/row/TextRowWidget.java`, `ui/widgets/tools/CpuCorePickerDialog.java` (new), `res/layout/dialog_vm_cpu_affinity.xml` (new), `partial_vm_edit_basic.xml` (SPLIT: affinity icon button), `partial_vm_edit_graphics.xml` (SPLIT: `create_vm_category_gpu_cgroup` container), `widget_text_row.xml`, `app/src/test/.../CpuPlacementPlanTest.java` (new), strings `create_vm_category_gpu_cgroup`, `create_vm_cpu_*` (18 keys), `create_vm_gpu_cgroup*` (5), `create_vm_error_cpu_*` (4), `create_vm_error_gpu_cgroup_*` (2) | Mixed M (vCPU affinity + guest topology) and G (GPU worker cpuset). Keep as one commit. It was authored on top of everything, so its `VMEditGraphicsTab.validate` insertion sits right after X1's dynamic-vram check and its `initValue` insertion after G3's `updateVramAllocVisibility()` — a clean pick wants it after X1; placing it in G (before D1) needs small context fix-ups. G5 (rt-prio switch) MUST follow it either way (or the switch is re-homed). |
| 5ec15a0 (OA-2) | feat(graphics): add guest memory allocation options | `CrosvmBackendInstance.java` (SPLIT: `appendGuestPoolOptions()` and its two call sites), `VMEditGraphicsTab.java` (SPLIT: prealloc/step/max_grants fields, `validateGuestPoolOptions`, `usesGuestPool`), `partial_vm_edit_graphics.xml` (SPLIT: `til_gpu_guest_prealloc_mb/_step_mb/_max_grants`), strings `create_vm_gpu_guest_prealloc_mb/_step_mb/_max_grants`, `create_vm_error_gpu_guest_*` (3) (en/zh-CN/zh-TW) | Emits `gpu-guest-prealloc-mb/step-mb/max-grants` (crosvm fork growable guest pool). References the gfxstream(udmabuf) and drm2kgsl branches → after X1 (before V1; V1's `appendGuestPoolOptions` call then lands on top), or after V1 with V1 emitting inline `gpu-guest-mb` and this commit's context adjusted. |

No HuJK follow-up commit exists that only fixes another author's commit. (3e0d6b3 ADDS to 0fcd8e4's layout container but is its own feature.)

## Nets to zero / disappears in flatten

- f28c8ad "hugepage: adapt to v11 module" — duplicate of origin/master's 9d237f8 (identical except `hugepage_cma_warn_msg` uses "•" bullets vs master's "- "). Drop on rebase; the only residue is that one-line string change (owner: keep master's text or carry the bullet as a trivial string fix — recommend drop).
- 7ee6e51 merge commit — clean merge, no resolution content; disappears.
- 13ba212 `--hypervisor gunyah[blob_mode=guest-accept]` ↔ 872408b removed it (crosvm dropped the field).
- 13ba212 `GFXSTREAM_GUNYAH_PIN_RINGBLOB=1` / `GFXSTREAM_ARENA_MB` env ↔ 0d5832e replaced them by the `--gpu` keys `gunyah-pvm=true` / `vram-limit=` (the env lines are gone; the replacement lives in X1).
- 4467065 configurable `vnc_input_mode` (`--vnc-server input=<mode>`) ↔ d92be08 pinned it to `input=tablet` and removed the key.
- d92be08 `res/drawable/ic_stylus.xml` ↔ 0d5832e deleted it (replaced by ic_tablet_stylus/ic_touchscreen).
- 3a05eee `GpuApi.KGSL` + `--pre-alloc kgsl-mb=` + `external-blob=true` ↔ eaf9a49 (external-blob), 88d9ff1 (kgsl-mb→drm-host-mb/gpu-guest-mb), 4b1c481 (KGSL→DRM2KGSL rename incl. `gpu_kgsl_pool_mb`→`gpu_drm2kgsl_pool_mb`, `drm-kgsl`→`drm2kgsl` wire value).
- 851651f `gpu_arena_mb` ↔ b05a328 renamed to `gpu_vram_quota_mb`; 851651f `gfx-guest-mb` ↔ 88d9ff1 `gpu-guest-mb`; 851651f gunyah rows in the graphics tab ↔ 8da1b6b moved to the basic tab.
- 8ce9dae "256 stays for gfxstream's host pool" ↔ afa8776 (64 MB); 8ce9dae's DRM 8 MB survives (D1).
- 04f4fb6/b88ffe7 "venus is not compiled in" toast+revert and comments ↔ 09ce4f9 wired venus; 09ce4f9 `GpuProvider.VENUS(8)` + `create_vm_gpu_provider_venus` strings ↔ 8a247c7 retired them (only a comment remains).
- 0d5832e's `updateGpuApiOptions()`/`isGfxstreamApi()` single-row model ↔ 04f4fb6 replaced with mode/provider rows.
- eb999b2's Extra-keys toggle in the keyboard menu row ↔ 1ab0125 removed it (row back to seven keys); e50758c's three-boolean keyboard state ↔ replaced by `KeyboardMode`.
- 691cd35's programmatic KernelModuleDialog rows ↔ cde941b XML cards ↔ 1228b39/15a7e7d rewrote again (only the final DialogFragment + `KernelModuleListController` survive); 691cd35 `KernelModuleManager.list()` ↔ `list(ctx)`.
- 68a6067's `DisplayChromeControllerTest` initial 5 tests are superseded/extended by ddd1d07 (other author) — file survives, keep the ddd1d07 delta as its own commit.
- `app/src/main/cpp/compat/a14.cpp` / `a15.cpp` net entries — artefact of master's 3458070 not being in wip; vanish on rebase.

## Consider dropping from the PR

- `lib/perf/SystemGestureGuard.java` + its two calls (e1e7d91, M14): flips ColorOS/OxygenOS `oplus_customize_*` system settings through the root shell while the native display is up. OEM-specific and side-effectful (a process death leaves the user's gesture setting off); upstream may not want it. Owner decides.
- `AndroidManifest.xml` `android:appCategory="game"` + `GamePerfHint` (f9c0f32, G0): categorises the whole app as a game to feed OEM game power profiles. Works and needs no root, but is a global app-store/behaviour declaration. Owner decides.
- f28c8ad (duplicate) — drop.
- The "•" bullet residue in `hugepage_cma_warn_msg` — drop (keep master's).
- Nothing else looks like a dead probe / evidence dump / debug scaffolding: no TODO/FIXME/debug markers were added; `vkprobe` is a real capability probe used by G4.

## SPLIT NEEDED files

(hunk-level, rough; every file below also carries the SPDX header hunk → L1 if it existed on master)

- `daemon/vm/backend/CrosvmBackendInstance.java` (25 original commits): M1 `--smbios`; M3 `--swiotlb`; M9 `isInputBridgeNeeded()`, `buildInputDevicesCommand()`, `buildNativeDisplayCommand()` trimmed, `,input=tablet`, start() pre-bind gate; M15 `isNativeDisplayEnabled()` SIMPLEFB case + `display_refresh_rate` default 120; G1 `--runtime-share`; G2 `effectiveGpuMode()`, ANGLE→gles, `applyGfxstreamEnv()` skeleton with host-ICD env + udmabuf size_limit glob, `gpu_pci_bar_size` reads; G3 inline `gpu-guest-mb` per route; G4 `applyDisplayBlitEnv()`/`resolveSystemVulkanHal()`; OA-1 `prepareGpuCgroup()`/`buildCpuPlacementCommand()`/`gpuCgroupPath`; G5 `applyGpuRtPrioEnv()`; D1 `drm2kgslGpu` pre-alloc + NATIVE `--gpu` branch; X1 `gfxstreamGpu` pre-alloc + gfxstream `--gpu` branch + `GFXSTREAM_DEVICE_LOCAL_MEMORY_TYPE` + `isGunyahHypervisor()`; OA-2 `appendGuestPoolOptions()`; V1 `venusGpu` pre-alloc + VULKAN `--gpu` branch + venus gate in `applyGfxstreamEnv()`.
- `ui/vm/edit/graphics/VMEditGraphicsTab.java` (24 commits): M15 display-output/blit-independent display hunks; G2 mode/provider rows + migration; G3 VRAM section skeleton + guest pool; G4 blit provider + probe; OA-1 GPU cgroup; G5 rt-prio; D1 NATIVE/DRM2KGSL/drm2kgsl pool; X1 udmabuf/host pool/dynamic vram/quota/blob-threshold + sharing validation; OA-2 prealloc/step/max_grants; V1 VULKAN-under-virgl + venus pool.
- `res/layout/partial_vm_edit_graphics.xml` (14 commits): same split as the tab — M15 display section; G2 `choose_gpu_mode`/`choose_gpu_provider`; G3 `vram_settings` + `til_gpu_guest_pool_mb`; G4 `choose_display_blit_provider`; OA-1 gpu_cgroup container; G5 `sw_gpu_rt_prio`; D1 `til_gpu_drm2kgsl_pool_mb`; X1 `sw_gpu_udmabuf`, `til_gpu_host_pool_mb`, `sw_gpu_dynamic_vram`, `dynamic_vram_options`, `til_gpu_vram_quota_mb`, `til_gpu_pool_blob_max_kb`; OA-2 three guest fields; V1 `til_gpu_venus_pool_mb`.
- `ui/vm/edit/basic/VMEditBasicTab.java` + `res/layout/partial_vm_edit_basic.xml`: G1 gunyah share/threshold; 6926338 env vars; OA-1 affinity/topology + icon button.
- `lib/store/vm/GpuApi.java`: G2 (VULKAN_SYSTEM/TURNIP/PANVK); D1 (DRM2KGSL). `GpuMode.java`: G2 (OPENGL/VULKAN, legacy map); D1 (NATIVE); V1 (venus javadoc). `GpuProvider.java`: G2 (EGL/GLES/VK_*, legacy map); D1 (DRM2KGSL); V1 (retired-VENUS comment, javadoc).
- `res/values/strings.xml`, `values-zh-rCN/strings.xml`, `values-zh-rTW/strings.xml` (33 commits each): key→row map: `kernel_module_*`,`setup_kmod_desc`→M4; `settings_optimize_compression_*`,`disk_compress_none`,`disk_optimize_compress_remember`,(-)`settings_vm_keep_compress_on_optimize_*`→M6; `vm_snapshot_disk_*`,`disk_snapshot_crosvm_warning_*`→M7; `disk_tree_*`,`disk_locked_*`,`edit_vm_disk_locked_readonly`,`vm_locked_disk_*`,`disk_overlay_*`,`disk_chain_*`,`disk_merge*`,`disk_flatten*`,`disk_manage_branches*`,`disk_branches_button`,`disk_delete_*`,`disk_family_vm_running`→M8; `vnc_menu_input_mode_tablet`→M9; `key_desc_*`,`key_ime`,`key_fnx`,`key_prtsc`,`key_pause`,`keyboard_mode_*`,(-)`key_win/key_cap/key_shift/key_enter`→M11; `create_vm_display_output*`,(-)`create_vm_category_vnc`,(-)`create_vm_vnc_enabled`,(-)`create_vm_native_display_enabled`,(-)`create_vm_error_native_display_vnc_cannot_enabled`→M15; `create_vm_gunyah_*`,`create_vm_error_needs_gunyah_dynamic_share`→G1; `create_vm_gpu_mode`,`create_vm_gpu_mode_opengl/_vulkan`,`create_vm_gpu_provider`,`create_vm_gpu_api_vulkan_system/_turnip/_panvk`,`create_vm_gpu_api_not_implemented`→G2; `create_vm_category_vram`,`create_vm_gpu_guest_pool_mb`→G3; `create_vm_display_blit_*`,`display_blit_system_missing_ext`→G4; `create_vm_gpu_rt_prio`→G5; `create_vm_gpu_mode_native`,`create_vm_gpu_provider_drm2kgsl`,`create_vm_gpu_api_drm2kgsl`,`create_vm_gpu_drm2kgsl_pool_mb`→D1; `create_vm_gpu_udmabuf`,`create_vm_gpu_host_pool_mb`,`create_vm_gpu_dynamic_vram`,`create_vm_gpu_vram_quota_mb`,`create_vm_gpu_pool_blob_max_kb`→X1; `create_vm_gpu_venus_pool_mb`→V1; `create_vm_environment_variables_hint`,`create_vm_error_invalid_environment_variable`→6926338; `create_vm_category_gpu_cgroup`,`create_vm_cpu_*`,`create_vm_gpu_cgroup*`,`create_vm_error_cpu_*`,`create_vm_error_gpu_cgroup_*`→OA-1; `create_vm_gpu_guest_prealloc_mb/_step_mb/_max_grants`,`create_vm_error_gpu_guest_*`→OA-2; `hugepage_cma_warn_msg` "•" → drop.
- `ui/main/settings/MainSettingsFragment.java` + `res/layout/fragment_main_settings.xml`: M4 kernel-modules row; M6 optimize-compression setting; OA-1 CpuCorePickerDialog refactor (java only).
- `lib/utils/ImageUtils.java`: M6 `detectCompression`; M7 `hasInternalSnapshots`; M8 `hasBackingFile`.
- `ui/vm/VMActions.java`: M6 compression guard; M7 snapshot guard; M8 locked-base guard + registry repair.
- `ui/disk/action/DiskActionDialog.java`, `ui/disk/operation/DiskOperationActivity.java`, `Import{URL,Images,LxcImages}Activity.java`, `DiskInfoSnapshotTab.java`: M6 compression hunks vs M8 overlay hunks (M7 for the snapshot tab warning).
- `ui/vm/display/nativedisplay/display/DisplayProvider.java`: M10 config poll; M12 cursor stream/surface; M13 death re-fetch + `recreateSurface`.
- `ui/vm/display/base/DisplaySource.java`, `NativeSurfaceSource.java`, `DisplayViewportController.java`: M10 base; M12 cursor hooks / `panToShowContentPoint`.
- `ui/vm/display/base/DisplayChromeController.java`: M10 base (fullscreen/extra-keys); M11 keyboard-mode state.
- `VMNativeDisplayActivity.java` (8 commits), `VMVncDisplayActivity.java` (7), `BaseVncActivity.java` (4): M9 input routing/gestures/binder sink; M10 controllers/insets/DisplaySource/attach; M11 keyboard; M12 cursor (native only); M14 gesture guard (native only); G0 game-state calls.
- `res/layout/activity_vm_native_display.xml`: M10 (fitsSystemWindows), M11 (`phy_keyboard`), M12 (`cursor_view`). `activity_vm_vnc_display.xml`: M11 only.
- `res/menu/menu_native_display_menu.xml`, `menu_vnc_display_menu.xml`: M9 (`menu_rotate` added / `menu_input_mode` removed); M11 (`menu_keyboard`, `menu_extra_keys` removed).
- `app/src/main/cpp/CMakeLists.txt`: G4 only (vkprobe target) — no split, listed for completeness.
- `ui/setup/SetupActivity.java`, `DroidVMApp.java`: M4 only + header.

## Open questions / decisions for the owner

1. Rebase `pr/3d-accel` onto `origin/master` (3458070) and DROP f28c8ad (duplicate of 9d237f8). Decide whether the "•" bullet in `hugepage_cma_warn_msg` is wanted (recommend: no).
2. ADDITIONAL-PERMISSIONS §2 lists NO upstream projects and LICENSING.md's "Material inherited from upstream" section is empty — fill in (this repo's upstream = Droid-VM/DroidVM itself, so the DroidVM-app copy may just need the section to say so) before the PR.
3. Placement of lateautumn233's 0fcd8e4 and 5ec15a0 vs the L/M/G/D/X/V order: both were authored on top of the finished GPU section, so a conflict-free pick wants them after X1; the "pure" order (G before D/X) needs small context fix-ups in `VMEditGraphicsTab`/`CrosvmBackendInstance`. Also G5 (rt-prio switch) lives inside 0fcd8e4's layout container.
4. G2's `applyGfxstreamEnv()` (name and `gfxstream || venus` gate) is route-mentioning; for a route-neutral G2 rename to e.g. `applyHostVulkanEnv()` and gate on `effectiveGpuMode()==VULKAN` (equivalent today), or accept X/V wording in G2.
5. SPDX headers: 5a0a9ce covered only `app/src/main/java`; `app/src/test/**` (7 files: 4 pre-existing + `DisplayChromeControllerTest`, `DisplayViewportControllerTest`, `CpuPlacementPlanTest`) and the pre-existing `.c/.cpp` under `app/src/main/cpp` have none (`vkprobe.cpp` does). Add in L1 / at file creation?
6. `applyGfxstreamEnv()` raises `udmabuf*/parameters/size_limit_mb` only for gfxstream and venus; the drm2kgsl route also uses `udmabuf=true` guest-alloc blobs but never gets the cap raised — intended (small BOs) or an oversight?
7. Display console flatten granularity: M9/M10/M11/M12 are cleanly separable in the `base/` helper classes but heavily interleaved in `VMNativeDisplayActivity`/`VMVncDisplayActivity`. If hunk-splitting those two proves too costly, collapse M9–M12 into one "display: console rework — input routing, viewport/chrome controllers, keyboard modes, guest cursor" commit (and keep M13/M14 separate).
8. Whether G0 (game mode) and M14 (OEM gesture guard) go in at all (see "Consider dropping").
9. Cross-repo dependencies to state in the PR: crosvm fork flags/env used by the app (`--runtime-share`, `--pre-alloc gfx-host-mb/drm-host-mb/venus-host-mb/gpu-guest-mb[...]`, `--gpu gunyah-pvm/udmabuf/vram-limit/pool-blob-max-kb/pci-bar-size/context-types=...`, `--input mouse/absolute-mouse`, `--vnc-server input=`, `--smbios`, `--gpu-cgroup-path`, `--cpu-capacity/--cpu-cluster/--cpu-affinity`, `CROSVM_GPU_RT_PRIO`, `CROSVM_DISPLAY_VULKAN_LIBRARY`, `GPU_DISPLAY_COPY_MODE`, `ANDROID_EMU_VK_LOADER_PATH`, `GFXSTREAM_DEVICE_LOCAL_MEMORY_TYPE`, cursor position stream); prebuilt tree layout for the kernel module manager (`usr/lib/modules/<kmi>/`, `match.json`, `descr/`); bundled `usr/lib/libvulkan_freedreno.so`.
10. Legacy `gpu_api` is still written on save (exactly recoverable from mode+provider) so an older build/daemon reads the VM — keep, and say so in the G2 message.
11. `create_vm_gpu_api_drm2kgsl` and `create_vm_gpu_provider_drm2kgsl` are identical text ("DRM to KGSL"); the former is only the legacy enum label. Keep both or collapse.

## Coverage check

- all original commits assigned: yes — 59/59. Map: f28c8ad→drop; 86cd769→X1,G2; 13ba212→M3,X1,G2(+nz); 4467065→G2,M9(+nz); d92be08→M9; 691cd35→M4; 4402a0c→M1; 7909f11→M9; 68a6067→M10; 0d5832e→M9,M10,G2,X1; da6715b→M9; a60487c→M4; cde941b→M4; 851651f→G1,G3,X1; f9c0f32→G0; 07d843e→G2; 40f3594→M2; 872408b→M15(+nz); 8da1b6b→M15,G1; 8362652→M5; 93660e1→M5; d229f6a→G1,X1; 335c4e9→X1; 8bd2bf6→G3,X1; 3a05eee→D1; 04f4fb6→G2; eaf9a49→G2; 5f3d508→D1; 2cb1627→M4; 88d9ff1→G3,D1,X1; b88ffe7→G2,G3,D1,V1(nz); 4a6993f→G2,D1; 8ce9dae→D1,X1(nz); afa8776→X1,M4; b05a328→X1,G2,D1; 4b1c481→D1; 5a0a9ce→L1; eb999b2→M11; db2ede5→M6; baf0ed7→M7; 1228b39→M8,M4,M11; e50758c→M11,M12,M4; 1ab0125→M11; 5ec15a0→OA-2; 6926338→OA; a0f4632→L1; a0f1435→OA; ddd1d07→OA; 0fcd8e4→OA-1; 7ee6e51→disappears; 1950f61→G4,G2; dd249db→M15; 09ce4f9→G4,V1,G2; e8e32f5→V1; 8a247c7→V1,G2; 1257dfa→M13; 3e0d6b3→G5; e1e7d91→M14; 15a7e7d→M4.
- all net files assigned: yes — 481/481: 3 root licensing files + 326 header-only `.java` (Appendix A) → L1; `a14.cpp`/`a15.cpp` → rebase artefact (not in PR); the remaining 150 feature files → rows above (each named in a row or in the SPLIT list; the 3 `strings.xml` files split by key).

## Appendix A — the 326 `.java` files whose only net change is the SPDX header (all → L1)

```
app/src/main/java/cn/classfun/droidvm/daemon/Daemon.java
app/src/main/java/cn/classfun/droidvm/daemon/console/ConsoleStream.java
app/src/main/java/cn/classfun/droidvm/daemon/console/FDPipeConsoleStream.java
app/src/main/java/cn/classfun/droidvm/daemon/console/FDSocketConsoleStream.java
app/src/main/java/cn/classfun/droidvm/daemon/console/InputConsoleStream.java
app/src/main/java/cn/classfun/droidvm/daemon/console/LocalSocketConsoleStream.java
app/src/main/java/cn/classfun/droidvm/daemon/console/SimpleConsoleStream.java
app/src/main/java/cn/classfun/droidvm/daemon/display/DaemonSystemContext.java
app/src/main/java/cn/classfun/droidvm/daemon/display/NativeDisplayBinder.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/basic/AuthHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/basic/PingHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/basic/SetAppConfig.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/basic/VersionHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/network/AddAddressHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/network/AddInterfaceHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/network/CreateHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/network/DeleteHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/network/ExistsHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/network/InfoHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/network/ListHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/network/ListInterfacesHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/network/ListUplinksHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/network/ModifyHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/network/PdReleaseHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/network/PdRenewHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/network/RemoveAddressHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/network/RemoveInterfaceHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/network/StartHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/network/StatusHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/network/StopHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/network/ToolLogHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/vm/BootScanHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/vm/ConsoleClearHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/vm/ConsoleHistoryHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/vm/ConsoleInfoHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/vm/ConsoleListHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/vm/ConsoleWriteHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/vm/ControlHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/vm/CreateHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/vm/DeleteHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/vm/DisplayAttachHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/vm/ExistsHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/vm/ExportHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/vm/GetHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/vm/ImportHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/vm/InputHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/vm/ListHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/vm/ModifyHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/vm/RebootHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/vm/ResumeHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/vm/StartHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/vm/StatusHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/vm/StopAllHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/vm/StopHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/vm/SuspendHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/ipc/vm/VncInfoHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/network/NetworkInstance.java
app/src/main/java/cn/classfun/droidvm/daemon/network/NetworkInstanceStore.java
app/src/main/java/cn/classfun/droidvm/daemon/network/NetworkWatchdog.java
app/src/main/java/cn/classfun/droidvm/daemon/network/backend/BackendBase.java
app/src/main/java/cn/classfun/droidvm/daemon/network/backend/BridgeBackend.java
app/src/main/java/cn/classfun/droidvm/daemon/network/backend/BridgeDhcp.java
app/src/main/java/cn/classfun/droidvm/daemon/network/backend/DefaultRouterWatcher.java
app/src/main/java/cn/classfun/droidvm/daemon/network/backend/FirewallHelper.java
app/src/main/java/cn/classfun/droidvm/daemon/network/backend/LinuxBridgeBackend.java
app/src/main/java/cn/classfun/droidvm/daemon/network/backend/LinuxNetwork.java
app/src/main/java/cn/classfun/droidvm/daemon/network/backend/ManagedProcess.java
app/src/main/java/cn/classfun/droidvm/daemon/network/backend/Netbox.java
app/src/main/java/cn/classfun/droidvm/daemon/network/backend/Pbridge.java
app/src/main/java/cn/classfun/droidvm/daemon/network/backend/UplinkResolver.java
app/src/main/java/cn/classfun/droidvm/daemon/network/backend/gvisor/GvisorBridgeBackend.java
app/src/main/java/cn/classfun/droidvm/daemon/network/backend/gvisor/GvswitchClient.java
app/src/main/java/cn/classfun/droidvm/daemon/network/backend/gvisor/GvswitchConfigBuilder.java
app/src/main/java/cn/classfun/droidvm/daemon/network/backend/iptables/ChainInfo.java
app/src/main/java/cn/classfun/droidvm/daemon/network/backend/iptables/IptablesBackend.java
app/src/main/java/cn/classfun/droidvm/daemon/network/backend/iptables/IptablesNetworkInstance.java
app/src/main/java/cn/classfun/droidvm/daemon/network/backend/pd/Duid.java
app/src/main/java/cn/classfun/droidvm/daemon/server/ClientHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/server/ClientRequest.java
app/src/main/java/cn/classfun/droidvm/daemon/server/ClientResponse.java
app/src/main/java/cn/classfun/droidvm/daemon/server/RequestException.java
app/src/main/java/cn/classfun/droidvm/daemon/server/RequestHandler.java
app/src/main/java/cn/classfun/droidvm/daemon/server/RequestHandlerStore.java
app/src/main/java/cn/classfun/droidvm/daemon/server/Server.java
app/src/main/java/cn/classfun/droidvm/daemon/vm/SerialPipe.java
app/src/main/java/cn/classfun/droidvm/daemon/vm/VMInstance.java
app/src/main/java/cn/classfun/droidvm/daemon/vm/VMStartResult.java
app/src/main/java/cn/classfun/droidvm/daemon/vm/backend/BackendBase.java
app/src/main/java/cn/classfun/droidvm/daemon/vm/backend/CrosvmBackend.java
app/src/main/java/cn/classfun/droidvm/daemon/vm/backend/NativeDisplayInputBridge.java
app/src/main/java/cn/classfun/droidvm/daemon/vm/backend/QemuBackend.java
app/src/main/java/cn/classfun/droidvm/daemon/vm/backend/QemuBackendInstance.java
app/src/main/java/cn/classfun/droidvm/daemon/vm/pkg/VMExportTask.java
app/src/main/java/cn/classfun/droidvm/daemon/vm/pkg/VMExportUtils.java
app/src/main/java/cn/classfun/droidvm/daemon/vm/pkg/VMImportTask.java
app/src/main/java/cn/classfun/droidvm/daemon/vm/pkg/VMImportUtils.java
app/src/main/java/cn/classfun/droidvm/lib/Constants.java
app/src/main/java/cn/classfun/droidvm/lib/api/ApiInfo.java
app/src/main/java/cn/classfun/droidvm/lib/api/ApiManager.java
app/src/main/java/cn/classfun/droidvm/lib/api/ApiServiceInfo.java
app/src/main/java/cn/classfun/droidvm/lib/api/Privacy.java
app/src/main/java/cn/classfun/droidvm/lib/archive/Compression.java
app/src/main/java/cn/classfun/droidvm/lib/archive/LimitedInputStream.java
app/src/main/java/cn/classfun/droidvm/lib/archive/OutputStreamLimiter.java
app/src/main/java/cn/classfun/droidvm/lib/archive/RandomAccessFileOutputStream.java
app/src/main/java/cn/classfun/droidvm/lib/archive/TarReader.java
app/src/main/java/cn/classfun/droidvm/lib/crypt/HashFile.java
app/src/main/java/cn/classfun/droidvm/lib/crypt/HashItem.java
app/src/main/java/cn/classfun/droidvm/lib/daemon/DaemonClient.java
app/src/main/java/cn/classfun/droidvm/lib/daemon/DaemonConnection.java
app/src/main/java/cn/classfun/droidvm/lib/daemon/DaemonHelper.java
app/src/main/java/cn/classfun/droidvm/lib/daemon/ForegroundCallback.java
app/src/main/java/cn/classfun/droidvm/lib/daemon/PendingRequest.java
app/src/main/java/cn/classfun/droidvm/lib/daemon/Protocol.java
app/src/main/java/cn/classfun/droidvm/lib/daemon/RequestContext.java
app/src/main/java/cn/classfun/droidvm/lib/daemon/VMEventHandler.java
app/src/main/java/cn/classfun/droidvm/lib/data/CrosvmExit.java
app/src/main/java/cn/classfun/droidvm/lib/data/Images.java
app/src/main/java/cn/classfun/droidvm/lib/data/Language.java
app/src/main/java/cn/classfun/droidvm/lib/data/License.java
app/src/main/java/cn/classfun/droidvm/lib/data/QcomChipName.java
app/src/main/java/cn/classfun/droidvm/lib/data/QcomGunyahSupports.java
app/src/main/java/cn/classfun/droidvm/lib/data/Repos.java
app/src/main/java/cn/classfun/droidvm/lib/diag/LogHelper.java
app/src/main/java/cn/classfun/droidvm/lib/diag/LogHelperHandler.java
app/src/main/java/cn/classfun/droidvm/lib/diag/handler/BadSM8650HostKernelHandler.java
app/src/main/java/cn/classfun/droidvm/lib/diag/handler/HugePageFaultHandler.java
app/src/main/java/cn/classfun/droidvm/lib/diag/handler/OsKernelWithoutRestrictPoolHandler.java
app/src/main/java/cn/classfun/droidvm/lib/diag/handler/UnsupportedGunyahVersionHandler.java
app/src/main/java/cn/classfun/droidvm/lib/diag/handler/UnsupportedSandboxHandler.java
app/src/main/java/cn/classfun/droidvm/lib/download/DiskDownloadManager.java
app/src/main/java/cn/classfun/droidvm/lib/download/DiskDownloadService.java
app/src/main/java/cn/classfun/droidvm/lib/natives/NativeProcess.java
app/src/main/java/cn/classfun/droidvm/lib/natives/UnixHelper.java
app/src/main/java/cn/classfun/droidvm/lib/network/FDSocket.java
app/src/main/java/cn/classfun/droidvm/lib/network/IPAddress.java
app/src/main/java/cn/classfun/droidvm/lib/network/IPNetwork.java
app/src/main/java/cn/classfun/droidvm/lib/network/IPv4Address.java
app/src/main/java/cn/classfun/droidvm/lib/network/IPv4Network.java
app/src/main/java/cn/classfun/droidvm/lib/network/IPv6Address.java
app/src/main/java/cn/classfun/droidvm/lib/network/IPv6Network.java
app/src/main/java/cn/classfun/droidvm/lib/pkg/BootFile.java
app/src/main/java/cn/classfun/droidvm/lib/pkg/DiskEntry.java
app/src/main/java/cn/classfun/droidvm/lib/pkg/DiskRef.java
app/src/main/java/cn/classfun/droidvm/lib/pkg/PackageConstants.java
app/src/main/java/cn/classfun/droidvm/lib/pkg/PackageHeader.java
app/src/main/java/cn/classfun/droidvm/lib/pkg/PackageInput.java
app/src/main/java/cn/classfun/droidvm/lib/pkg/PackageManifest.java
app/src/main/java/cn/classfun/droidvm/lib/pkg/Phase.java
app/src/main/java/cn/classfun/droidvm/lib/run/RunContext.java
app/src/main/java/cn/classfun/droidvm/lib/run/RunResult.java
app/src/main/java/cn/classfun/droidvm/lib/run/root/RootRunContext.java
app/src/main/java/cn/classfun/droidvm/lib/run/root/RootRunResult.java
app/src/main/java/cn/classfun/droidvm/lib/run/system/SystemRunContext.java
app/src/main/java/cn/classfun/droidvm/lib/run/system/SystemRunResult.java
app/src/main/java/cn/classfun/droidvm/lib/size/SizeNumber.java
app/src/main/java/cn/classfun/droidvm/lib/size/SizeUnit.java
app/src/main/java/cn/classfun/droidvm/lib/size/SizeUtils.java
app/src/main/java/cn/classfun/droidvm/lib/store/base/DataConfig.java
app/src/main/java/cn/classfun/droidvm/lib/store/base/DataItem.java
app/src/main/java/cn/classfun/droidvm/lib/store/base/DataStore.java
app/src/main/java/cn/classfun/droidvm/lib/store/base/JSONSerialize.java
app/src/main/java/cn/classfun/droidvm/lib/store/base/RingBuffer.java
app/src/main/java/cn/classfun/droidvm/lib/store/disk/DiskBus.java
app/src/main/java/cn/classfun/droidvm/lib/store/enums/ColorEnum.java
app/src/main/java/cn/classfun/droidvm/lib/store/enums/EnumPicker.java
app/src/main/java/cn/classfun/droidvm/lib/store/enums/Enums.java
app/src/main/java/cn/classfun/droidvm/lib/store/enums/StringEnum.java
app/src/main/java/cn/classfun/droidvm/lib/store/network/BridgeType.java
app/src/main/java/cn/classfun/droidvm/lib/store/network/Ipv6Source.java
app/src/main/java/cn/classfun/droidvm/lib/store/network/NetworkConfig.java
app/src/main/java/cn/classfun/droidvm/lib/store/network/NetworkConfigValidator.java
app/src/main/java/cn/classfun/droidvm/lib/store/network/NetworkState.java
app/src/main/java/cn/classfun/droidvm/lib/store/network/NetworkStore.java
app/src/main/java/cn/classfun/droidvm/lib/store/network/UplinkMode.java
app/src/main/java/cn/classfun/droidvm/lib/store/network/VlanConfig.java
app/src/main/java/cn/classfun/droidvm/lib/store/vm/BootConfig.java
app/src/main/java/cn/classfun/droidvm/lib/store/vm/DisplayBackend.java
app/src/main/java/cn/classfun/droidvm/lib/store/vm/GpuBackend.java
app/src/main/java/cn/classfun/droidvm/lib/store/vm/LendMthpMode.java
app/src/main/java/cn/classfun/droidvm/lib/store/vm/PortProtocol.java
app/src/main/java/cn/classfun/droidvm/lib/store/vm/ProtectedVM.java
app/src/main/java/cn/classfun/droidvm/lib/store/vm/SharedDirCache.java
app/src/main/java/cn/classfun/droidvm/lib/store/vm/SharedDirType.java
app/src/main/java/cn/classfun/droidvm/lib/store/vm/VMBackend.java
app/src/main/java/cn/classfun/droidvm/lib/store/vm/VMConfig.java
app/src/main/java/cn/classfun/droidvm/lib/store/vm/VMHypervisor.java
app/src/main/java/cn/classfun/droidvm/lib/store/vm/VMNicConfig.java
app/src/main/java/cn/classfun/droidvm/lib/store/vm/VMState.java
app/src/main/java/cn/classfun/droidvm/lib/store/vm/VMStore.java
app/src/main/java/cn/classfun/droidvm/lib/ui/BackAskHelper.java
app/src/main/java/cn/classfun/droidvm/lib/ui/CopyableField.java
app/src/main/java/cn/classfun/droidvm/lib/ui/DragTouchListener.java
app/src/main/java/cn/classfun/droidvm/lib/ui/IconItemAdapter.java
app/src/main/java/cn/classfun/droidvm/lib/ui/ImeInsetsApplier.java
app/src/main/java/cn/classfun/droidvm/lib/ui/ImeInsetsExempt.java
app/src/main/java/cn/classfun/droidvm/lib/ui/MenuDialogBuilder.java
app/src/main/java/cn/classfun/droidvm/lib/ui/NotificationPermission.java
app/src/main/java/cn/classfun/droidvm/lib/ui/SimpleAdapterDataObserver.java
app/src/main/java/cn/classfun/droidvm/lib/ui/SimpleTextWatcher.java
app/src/main/java/cn/classfun/droidvm/lib/ui/SwipeableTabActivity.java
app/src/main/java/cn/classfun/droidvm/lib/ui/UIContext.java
app/src/main/java/cn/classfun/droidvm/lib/ui/termux/SimpleTerminalSessionClient.java
app/src/main/java/cn/classfun/droidvm/lib/ui/termux/SimpleTerminalViewClient.java
app/src/main/java/cn/classfun/droidvm/lib/ui/termux/TerminalFonts.java
app/src/main/java/cn/classfun/droidvm/lib/utils/AssetUtils.java
app/src/main/java/cn/classfun/droidvm/lib/utils/BinaryUtils.java
app/src/main/java/cn/classfun/droidvm/lib/utils/FileUtils.java
app/src/main/java/cn/classfun/droidvm/lib/utils/JsonUtils.java
app/src/main/java/cn/classfun/droidvm/lib/utils/NetUtils.java
app/src/main/java/cn/classfun/droidvm/lib/utils/ProcessUtils.java
app/src/main/java/cn/classfun/droidvm/lib/utils/RunUtils.java
app/src/main/java/cn/classfun/droidvm/lib/utils/ShareUtils.java
app/src/main/java/cn/classfun/droidvm/lib/utils/StringUtils.java
app/src/main/java/cn/classfun/droidvm/lib/utils/ThreadUtils.java
app/src/main/java/cn/classfun/droidvm/lib/utils/Try.java
app/src/main/java/cn/classfun/droidvm/ui/SplashActivity.java
app/src/main/java/cn/classfun/droidvm/ui/agent/AgentOperationActivity.java
app/src/main/java/cn/classfun/droidvm/ui/agent/base/AgentVM.java
app/src/main/java/cn/classfun/droidvm/ui/agent/base/BaseAction.java
app/src/main/java/cn/classfun/droidvm/ui/agent/password/ChangePasswordActivity.java
app/src/main/java/cn/classfun/droidvm/ui/agent/password/PasswordAction.java
app/src/main/java/cn/classfun/droidvm/ui/disk/action/DiskCloneDialog.java
app/src/main/java/cn/classfun/droidvm/ui/disk/action/DiskResizeDialog.java
app/src/main/java/cn/classfun/droidvm/ui/disk/action/DiskSetFormatDialog.java
app/src/main/java/cn/classfun/droidvm/ui/disk/create/DiskFormat.java
app/src/main/java/cn/classfun/droidvm/ui/disk/images/FlatImage.java
app/src/main/java/cn/classfun/droidvm/ui/disk/images/ImageAdapter.java
app/src/main/java/cn/classfun/droidvm/ui/disk/images/ImagePickerDialog.java
app/src/main/java/cn/classfun/droidvm/ui/disk/images/ImageViewHolder.java
app/src/main/java/cn/classfun/droidvm/ui/disk/info/DiskInfoActivity.java
app/src/main/java/cn/classfun/droidvm/ui/disk/info/base/DiskInfoBaseTab.java
app/src/main/java/cn/classfun/droidvm/ui/disk/info/base/DiskInfoTab.java
app/src/main/java/cn/classfun/droidvm/ui/disk/info/snapshot/DiskSnapshotEntryAdapter.java
app/src/main/java/cn/classfun/droidvm/ui/disk/info/snapshot/DiskSnapshotEntryViewHolder.java
app/src/main/java/cn/classfun/droidvm/ui/disk/info/tree/DiskInfoTreeTab.java
app/src/main/java/cn/classfun/droidvm/ui/disk/info/tree/DiskTreeEntryAdapter.java
app/src/main/java/cn/classfun/droidvm/ui/disk/info/tree/DiskTreeEntryViewHolder.java
app/src/main/java/cn/classfun/droidvm/ui/disk/lxc/LxcImage.java
app/src/main/java/cn/classfun/droidvm/ui/disk/lxc/LxcImageParser.java
app/src/main/java/cn/classfun/droidvm/ui/hugepage/AcquireContainerView.java
app/src/main/java/cn/classfun/droidvm/ui/hugepage/HugePageActivity.java
app/src/main/java/cn/classfun/droidvm/ui/hugepage/HugePageColor.java
app/src/main/java/cn/classfun/droidvm/ui/hugepage/HugePageModel.java
app/src/main/java/cn/classfun/droidvm/ui/hugepage/HugePageProcess.java
app/src/main/java/cn/classfun/droidvm/ui/hugepage/HugePageProcessActivity.java
app/src/main/java/cn/classfun/droidvm/ui/hugepage/HugePageProcessAdapter.java
app/src/main/java/cn/classfun/droidvm/ui/hugepage/SegmentedBar.java
app/src/main/java/cn/classfun/droidvm/ui/logs/LogAdapter.java
app/src/main/java/cn/classfun/droidvm/ui/logs/LogViewHolder.java
app/src/main/java/cn/classfun/droidvm/ui/logs/LogsActivity.java
app/src/main/java/cn/classfun/droidvm/ui/main/MainActivity.java
app/src/main/java/cn/classfun/droidvm/ui/main/base/BaseViewHolder.java
app/src/main/java/cn/classfun/droidvm/ui/main/base/MainBaseFragment.java
app/src/main/java/cn/classfun/droidvm/ui/main/base/MainFragmentEnum.java
app/src/main/java/cn/classfun/droidvm/ui/main/base/list/MainListFragment.java
app/src/main/java/cn/classfun/droidvm/ui/main/base/stateful/MainStatefulFragment.java
app/src/main/java/cn/classfun/droidvm/ui/main/base/stateful/StatefulAdapter.java
app/src/main/java/cn/classfun/droidvm/ui/main/disk/ImageInfo.java
app/src/main/java/cn/classfun/droidvm/ui/main/home/MainHomeFragment.java
app/src/main/java/cn/classfun/droidvm/ui/main/network/MainNetworkFragment.java
app/src/main/java/cn/classfun/droidvm/ui/main/network/NetworkAdapter.java
app/src/main/java/cn/classfun/droidvm/ui/main/settings/ApiManagerDialog.java
app/src/main/java/cn/classfun/droidvm/ui/main/settings/ApiServiceAdapter.java
app/src/main/java/cn/classfun/droidvm/ui/main/settings/ApiServiceViewHolder.java
app/src/main/java/cn/classfun/droidvm/ui/main/settings/LicenseListAdapter.java
app/src/main/java/cn/classfun/droidvm/ui/main/settings/SoftwareLicenseDialog.java
app/src/main/java/cn/classfun/droidvm/ui/main/vm/MainVMFragment.java
app/src/main/java/cn/classfun/droidvm/ui/main/vm/VMAdapter.java
app/src/main/java/cn/classfun/droidvm/ui/network/NetworkActions.java
app/src/main/java/cn/classfun/droidvm/ui/network/edit/NetworkEditActivity.java
app/src/main/java/cn/classfun/droidvm/ui/network/edit/VlanCardBinder.java
app/src/main/java/cn/classfun/droidvm/ui/network/info/NetworkInfoActivity.java
app/src/main/java/cn/classfun/droidvm/ui/network/info/NetworkToolLogActivity.java
app/src/main/java/cn/classfun/droidvm/ui/setup/base/BaseCheckStepFragment.java
app/src/main/java/cn/classfun/droidvm/ui/setup/base/BaseStepFragment.java
app/src/main/java/cn/classfun/droidvm/ui/setup/step/DoneStepFragment.java
app/src/main/java/cn/classfun/droidvm/ui/setup/step/ExtractStepFragment.java
app/src/main/java/cn/classfun/droidvm/ui/setup/step/PrivacyStepFragment.java
app/src/main/java/cn/classfun/droidvm/ui/setup/step/RootStepFragment.java
app/src/main/java/cn/classfun/droidvm/ui/setup/step/SocStepFragment.java
app/src/main/java/cn/classfun/droidvm/ui/setup/step/StartStepFragment.java
app/src/main/java/cn/classfun/droidvm/ui/setup/step/StorageStepFragment.java
app/src/main/java/cn/classfun/droidvm/ui/setup/step/VirtualizationStepFragment.java
app/src/main/java/cn/classfun/droidvm/ui/update/UpdateDialog.java
app/src/main/java/cn/classfun/droidvm/ui/update/UpdateInfo.java
app/src/main/java/cn/classfun/droidvm/ui/update/VersionCheck.java
app/src/main/java/cn/classfun/droidvm/ui/vm/NicLeaseAllocator.java
app/src/main/java/cn/classfun/droidvm/ui/vm/boot/BootEntries.java
app/src/main/java/cn/classfun/droidvm/ui/vm/boot/BootMenuDialog.java
app/src/main/java/cn/classfun/droidvm/ui/vm/console/VMConsoleActivity.java
app/src/main/java/cn/classfun/droidvm/ui/vm/console/VMConsoleRouter.java
app/src/main/java/cn/classfun/droidvm/ui/vm/display/base/DisplayPresentation.java
app/src/main/java/cn/classfun/droidvm/ui/vm/display/base/DisplayTouchPadPanel.java
app/src/main/java/cn/classfun/droidvm/ui/vm/display/base/UsbHidInput.java
app/src/main/java/cn/classfun/droidvm/ui/vm/display/nativedisplay/input/DirectInputSink.java
app/src/main/java/cn/classfun/droidvm/ui/vm/display/nativedisplay/input/NativeKeyboardEditText.java
app/src/main/java/cn/classfun/droidvm/ui/vm/display/vnc/base/VncClient.java
app/src/main/java/cn/classfun/droidvm/ui/vm/display/vnc/base/VncDisplayView.java
app/src/main/java/cn/classfun/droidvm/ui/vm/display/vnc/display/VMVncPresentationActivity.java
app/src/main/java/cn/classfun/droidvm/ui/vm/display/vnc/input/VncTouchPadPanel.java
app/src/main/java/cn/classfun/droidvm/ui/vm/edit/base/VMEditTab.java
app/src/main/java/cn/classfun/droidvm/ui/vm/edit/boot/VMEditBootTab.java
app/src/main/java/cn/classfun/droidvm/ui/vm/edit/network/VMEditNetworkTab.java
app/src/main/java/cn/classfun/droidvm/ui/vm/edit/network/VMNetEditAdapter.java
app/src/main/java/cn/classfun/droidvm/ui/vm/edit/network/VMNetEditViewHolder.java
app/src/main/java/cn/classfun/droidvm/ui/vm/edit/storage/dir/VMSharedDirEditAdapter.java
app/src/main/java/cn/classfun/droidvm/ui/vm/edit/storage/dir/VMSharedDirEditViewHolder.java
app/src/main/java/cn/classfun/droidvm/ui/vm/info/ConsoleButton.java
app/src/main/java/cn/classfun/droidvm/ui/vm/info/VMInfoActivity.java
app/src/main/java/cn/classfun/droidvm/ui/vm/pkg/exports/VMPkgExportActivity.java
app/src/main/java/cn/classfun/droidvm/ui/vm/pkg/exports/VMPkgExportDiskAdapter.java
app/src/main/java/cn/classfun/droidvm/ui/vm/pkg/imports/NetworkImportMode.java
app/src/main/java/cn/classfun/droidvm/ui/vm/pkg/imports/VMPkgImportActivity.java
app/src/main/java/cn/classfun/droidvm/ui/vm/pkg/imports/VMPkgImportDiskAdapter.java
app/src/main/java/cn/classfun/droidvm/ui/vm/pkg/imports/VMPkgImportNetworkAdapter.java
app/src/main/java/cn/classfun/droidvm/ui/widgets/container/CardItemAdapter.java
app/src/main/java/cn/classfun/droidvm/ui/widgets/container/CardItemListView.java
app/src/main/java/cn/classfun/droidvm/ui/widgets/container/CollapsibleContainer.java
app/src/main/java/cn/classfun/droidvm/ui/widgets/row/ChooseRowWidget.java
app/src/main/java/cn/classfun/droidvm/ui/widgets/row/DropdownRowWidget.java
app/src/main/java/cn/classfun/droidvm/ui/widgets/row/SwitchRowWidget.java
app/src/main/java/cn/classfun/droidvm/ui/widgets/row/TextInputRowWidget.java
app/src/main/java/cn/classfun/droidvm/ui/widgets/tools/DownloadWidget.java
app/src/main/java/cn/classfun/droidvm/ui/widgets/tools/KernelAnalysisWidget.java
app/src/main/java/cn/classfun/droidvm/ui/widgets/tools/PickerButtonWidget.java
```
