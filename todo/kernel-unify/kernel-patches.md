# Section 1 working notes: kernel patches, Line A (iPadOS 27) vs Line B (macOS 27)

Method (all READ unless marked): both series were applied to a pristine `xnu-12377.121.6` clone (ac9718f) in the scratch dir.
- `treeA` = fork `profiles/arch/arm64e/patches/xnu/series` (68) + `profiles/os/ipados-27.0.1-24A446/patches/xnu/series` (4) +
  device `ipados27/patches/xnu-12377/series` (25) = 97 patches, `git apply` in pipeline order, all apply. 136 files, +5872/-174.
- `treeB` = macOS-DroidVM `patches/xnu-12377/0001..0048` + `IOServicePM-virtual-thunk-callbacks.patch` +
  `IOService-owner-cache-media-visibility.patch` = 50 patches, `git am`, all apply. 139 files, +4584/-156.
- File sets: 78 files touched by both (31 byte-identical in the two final trees, 47 differ), 58 only A, 61 only B.
- `tools/overlap.py`: per patch, how many of its significant added lines appear among the lines the other tree's patches add to the
  same file (`B-in-A.txt`, `A-in-B.txt`). `tools/unmatched.py`: the lines of one patch absent from the other tree.
- Cross-apply test (each patch alone, `git apply --check` on the other line's final tree; textual only):
  B 0003..0048+2 on treeA: 22 apply, 26 conflict. A's 97 on treeB: 28 already there (reverse-apply), 29 apply, 40 conflict.

## Line B -> Line A (50 patches)

Categories: S = same code on A; I = same idea, different code (C = the two conflict in the same function/setting);
M = macOS-only for a stated reason; T = B's build host (Linux + upstream LLVM 21), not macOS as such; D = bring-up diagnostics;
G = general fix with no Line A counterpart.

| B patch | +/- | Cat | Line A counterpart | Relation / reason |
|---|---|---|---|---|
| 0001 their 21 patches | +486/-22 | S | fork arch series: bcm2837-machine-config, source-corecrypto14-bootstrap, native-dt-panic-region, armvirt-platform-personality, native-aes-personality, source-machine-layer, non-apple-cache-monitor, kernel-sdk-root | an older snapshot of the same UniXNU patches (none24smu/UniXNU `ios26`, per docs/xnu-12377-port.md): 175 of 335 significant added lines identical; the rest is the Pi 3 UART/GPIO block of BCM2837.h, a DWC3 console, the older corecrypto bootstrap |
| 0002 merge: our port diff | +3223/-105 | S + T + D + M | 689 of 1876 lines identical to A: offline-component-load-probes (111), native-4k-signature-hash-cache (104), zzz-boot-progress (79), mockfs-test-file (67), offline-owner-systemos-mount (52), offline-owner-root-binding-audit (47), offline-owner-boot-manifest (39), native-aes-personality (30), native-board-launch-policy, native-work-interval-*, source-pthread-bootstrap | the rest (read by file): Linux build host (Makefile, SETUP/*/Makefile, gunyah-linux.mk, makesyscalls.sh, MakeInc.cmd/top), diagnostics (syscall-err-log, nosys-log, mount-log, symlink-log, exec-log, vm-err-log, crash log in exception.c/kern_stackshot.c, the arm64e-compat instruction rewriter in sleh.c), stub TrustCache/CoreEntitlements headers (removed again by 0003), Sandbox workarounds (removed again by 0038), a window-buffer 16K slide in vm_shared_region_pager.c (A: native-4k-shared-region-slide, different design), the root-only owner check (single container) |
| 0003 macOS target fixes; KDK headers | +17/-1176 | M | (A keeps stubs: public-entitlements-v2-header; TrustCache from tag xnu-8796 via prepare-xnu-source.py) | `XNU_TARGET_OS_OSX` gaps of the open source: MAP_32BIT, pid_hibernate stub, swap constants, compressor_is_thrashing |
| 0004 drop duplicate ml_device_is_prod_fused | -7 | S | public-missing-definitions | housekeeping of 0002 |
| 0005 dedupe BCM2837 machine flags | -1 | S | bcm2837-machine-config | housekeeping |
| 0006 bring-up diagnostics, kalloc empty-view guard | +75/-6 | D (+T, M) | - | port_crumb breadcrumbs, kprintf; kalloc_type_view_init returns at kt_count 0 (no Apple type summary with upstream LLVM); VM_MAX_SWAP_FILE_NUM 5 (macOS target) |
| 0007 macOS target build | +49/-5 | M (+T) | partly: boot-arg use_contiguous_hint=0 + native-4k-block-split (the same __PRELINK_TEXT/hint problem), native-pac-keys (PAC defines) | config_ext_resolver/config_csr/config_audit (macOS userland), XNU_KC_SEGADDRS (the kernel linked into the holes of the macOS collection), KT_DATA_ONLY for kext views, CTRR fallback; LLVM 21 workarounds (DriverKit sed, authenticates-null-values) |
| 0008 owner chain | +43/-2 | I | offline-owner-* + the VerifiedRoot component | B stubs native_verified_block_root_authorized (every device) and the manifest digest (SHA-384 of the UUID); rootauth=0 |
| 0009 user JOP keys | +19/-4 | I | ipados27-bringup (cache pointers signed with the one native key set), native-pac-keys, droidvm-native-pac-user-jop | B: ml_default_jop_pid() = 1, no key programming in XNU (PAC_INIT_KEY_STATE stays empty; docs/xnu-12377-port.md: keys "not explicitly programmed"). A: HAS_NATIVE_PAC, keys derived once and loaded on every CPU |
| 0010 user VA width (T0SZ 17) | +63/-6 | I, C | ipados27-bringup (T0SZ_USER 17) | same need (userland strips PAC with a 47-bit mask). B: a one-entry L0 shim (hw_tte) over a 39-bit pmap, user VA stays 512 GiB. A: user pmaps get a real 4-level 47-bit geometry (pta_root_level) |
| 0011 no kqworkloop limits | +8 | M | - | launchd/opendirectoryd limits on macOS; `#ifdef BCM2837`, so it would change iPadOS too |
| 0012 native_pmap_user_mappings | +77 | S | ipados27-bringup | 38 of 41 lines identical |
| 0013 shared region pager: release the source page | +38/-12 | I | native-4k-shared-region-slide (each 4K part slid on its own); the fork's copy does NOT release the source page first -- upstream's newer copy of the same patch does (+39 lines, a self-deadlock under apfs_pagein_with_verification); droidvm-dyld-16k-peek-first is A's fix of the same class in vm_dyld_pager.c | B fixes its own window design; Line A lacks the fix in the shared region pager |
| 0014 diagnostics: stderr-log, sc-trace, sample-pid, crash-log | +360 | D | (A's own: sheng-exc-name in ipados27-bringup) | |
| 0015 IOWorkLoop: every event source active | +11/-1 | T | - | upstream LLVM gives one virtual thunk per member function; guarded by `__has_builtin(__builtin_load_member_function_pointer)` |
| 0016 diagnostics: reboot caller, exec-log=2 | +10 | D | - | |
| 0017 native 4K code signing: page past codeLimit | +17/-1 | G | none (cs_validate_hash of treeA has no such case) | a 4K page wholly past codeLimit in the last 16K block is answered CS_VALIDATE_NX |
| 0018 virt_set_external_method_hook | +88/-19 | M | - | macOS 27 userland's 1760-byte IOMobileFramebuffer swap record against the 26.5 family's 1416 (DroidVMDisplay sets the hook); also: mach_absolute_time starts at 0 (cpu.c), stderr-log rework, user backtrace helper |
| 0019 profiling: pc-sample | +369 | D | (A: droidvm-sched-trace, a different tool) | |
| 0020 idle: every idle path ends in WFI | +70/-7 | I | non-apple-idle-wfi (its header names this patch), non-apple-vcpu-park | same logic and boot-arg (idle-wfe); guard differs (ARM64_BOARD_CONFIG_BCM2837 vs !APPLE_ARM64_ARCH_FAMILY); B adds pc-sample counters |
| 0021 AMP on the virtual board | +17/-1 | I, C | droidvm-amp (+ package/DroidVMCpufreq.c) | B: sched_amp, CONFIG_SCHED_EDGE_OPT_OUT, MAX_CPU_CLUSTERS 2, cluster type from the device tree in ml_processor_register. A: __ARM_AMP__ with the Edge scheduler, preferred cluster per thread group set by DroidVMCpufreq |
| 0022 exec-env | +40 | D | - | A/B tool; used for GIGACAGE_ENABLED=no because of the 39-bit user VA (0023's comment) |
| 0023 k27 base snapshot | +28/-9 | D (+M) | - | exec-env groups; vfs_quota.c standard; frees the allow-all page in __mac_syscall |
| 0024 KPIs the macOS 27 kexts bind to (k27_compat.c) | +190 | I | darwin26-kpi | same Darwin 26 KPIs, separate code; B's names are the macOS 27 exports (`*_with_length`), A's are its own (`*_ext`): the iPadOS fileset pairs by address, the macOS collection binds by name |
| 0025 IOService::CallPlatformFunction | +15 | M | - (A: unmatched calls go to fileset-unmapped-call) | a symbol macOS 27's AppleARMPlatform references |
| 0026 panic-spin, 0027 stall-dump, 0028 stall-panic | +118 | D | - | |
| 0029 TrustCacheInterface_t gains queryWithLength | +12 | I, C | darwin26-kpi (libkern/amfi/amfi.c re-packs amfi_t at registration) | same AMFI interface version 5; B changes the header layout instead |
| 0030 owner boot manifest replaces the placeholder | +8/-1 | M | offline-owner-boot-manifest (the base) | the all-zero boot-manifest-hash run-macos-vm.py writes for macOS 27's Image4 |
| 0031 mpo_vnode_check_lookup_preflight flags | +3/-2 | S | darwin26-kpi | 2 of 3 lines identical |
| 0032 iokit-log | +25 | D | - | |
| 0033 k27-deny-exec | +41 | M | native-board-launch-policy (hook into package/DroidVMLaunchPolicy.c) is A's mechanism for the same job | default list is macOS's mobileactivationd; `#if defined(BCM2837)` |
| 0034 sample-name list, wait-resource log | +52/-18 | D | - | |
| 0035 k27_amfi_page_shift | +8 | M (collection) | ipados27/fileset-reviewed.json (the PAGE_SHIFT_CONST pairing, per droidvm-serial-uarts' header) | k27/kc-build27.py rebinds AMFI's GOT slot to it |
| 0036 CONFIG_FIRMLINKS on | +1/-1 | M | - | APFS firmlinks of the single container's volume group |
| 0037 k27-mkdir-log | +35 | D | - | |
| 0038 the 26.5 Sandbox workarounds go | +13/-62 | M (housekeeping) | - | removes what 0002 added |
| 0039 realtime computation held to the maximum | +9 | G | none | written before 0040; with the 24 MHz timebase the request fits (inference, not tested) |
| 0040 24 MHz timebase | +84/-5 | S | droidvm-timebase-24mhz | 39 of 39 lines; taken from our 5edbbfc |
| 0041 mpo_vnode_notify_end_rename_swap | +51/-2 | M | none | macOS 27.2's Sandbox; whether iPadOS 27.0.1's Sandbox pairs the hook was not determined |
| 0042 arm64 processes run with the A keys off | +37 | I | droidvm-native-pac-user-jop + droidvm-native-pac-user-ib | A turns IA/DA/DB and IB off (IB: C++ exceptions through arm64 frames died in libunwind); B IA/DA only |
| 0043 GPU carveout ends at 256 GiB | +9 | M | - | follows from the 512 GiB user VA of 0010; `#if defined(BCM2837)` |
| 0044 mmap on 16K boundaries | +13/-2 | G | none | motivated by Chromium/V8 on macOS, written for any 4K kernel (`!__ARM_16K_PG__`) |
| 0045 mmu_kvtop_wpreflight ISB | +1 | G | none | non-Apple cores return a stale PAR_EL1 |
| 0046 macOS's syscalls in the config | +3/-3 | M | - | sysv_sem/msg/shm, sendfile, searchfs, file leases |
| 0047 per-process jetsam floors | +46 | M | - (A: droidvm-pressure-pageable, droidvm-free-target-bytes are other memory fixes) | WallpaperAerialsExtension; `#if defined(BCM2837)` |
| 0048 signed macOS Block descriptors | +18 | M (+T) | - | macOS kexts pass signed descriptors; `XNU_TARGET_OS_OSX` |
| IOServicePM-virtual-thunk-callbacks | +7/-2 | T | - | as 0015 |
| IOService-owner-cache-media-visibility | +4/-1 | M | - | external (USB) disks with the fixed driver set; `XNU_OWNER_CACHE_STARTUP` |

Counts (50): S 7 (0001, 0002 in part, 0004, 0005, 0012, 0031, 0040) / I 9 (0008, 0009, 0010, 0013, 0020, 0021, 0024, 0029, 0042; three
of them conflicting: 0010, 0021, 0029) / M 16 (0003, 0007, 0011, 0018, 0025, 0030, 0033, 0035, 0036, 0038, 0041, 0043, 0046, 0047, 0048,
IOService-owner-cache-media-visibility) / T 2 (0015, IOServicePM) / D 12 (0006, 0014, 0016, 0019, 0022, 0023, 0026, 0027, 0028, 0032,
0034, 0037) / G 4 (0017, 0039, 0044, 0045).

Guards: only 3 of the 50 use `XNU_TARGET_OS_OSX` (0002, 0003, 0048). The macOS-only ones are mostly under `#ifdef BCM2837` -- the
machine config both lines build -- or unconditional, so they cannot enter a common layer as they are.

## Line A -> Line B (97 patches)

| Bucket | Count | Patches |
|---|---|---|
| Same code already in B (>= 75 % of added lines) | 38 | arch (35): bcm2837-machine-config, local-availability, cxx-flag-dependencies, external-archive-dependencies, public-entitlements-header, apple-only-cpu-tunables, non-apple-cache-monitor, native-4k-bootstrap-capacity, native-dt-panic-region, armvirt-platform-personality, native-aes-personality, null-root-media, zzx-pmap-sync-64bit-pa, native-quiet-managed-page-report, native-priv-work-interval, native-work-interval-soft-fail, kernel-sdk-root, source-machine-layer, source-pthread-bootstrap, native-arm-pan, mockfs-* (5), native-work-interval-trace, offline-component-load-probes, offline-legacy-start, offline-native-gpu-broker, offline-owner-boot-manifest, offline-owner-root-binding-audit, offline-owner-root-crypto-probe, offline-owner-z-air-init, native-4k-user-abi, native-4k-signature-hash-cache; os: zzz-boot-progress; device: native-board-launch-policy, droidvm-timebase-24mhz |
| B has its own rendering of the same thing | 22 | arch (16): native-pac-keys, public-entitlements-v2-header, trustcache-runtime-layout (B: KDK headers), no-apple-cpu-counters, apple-only-core-type, public-pmap-sart (B needs none; why was not determined), public-pmap-without-monitor, public-missing-definitions (B: link_compat.c), optional-kernel-support-archive, source-corecrypto14-bootstrap, zzw-native-adreno-sandbox-grant (older copy), native-4k-shared-region-slide, non-apple-iommu-bootstrap, offline-owner-systemos-mount (B: root-only check), arm64e-threaded-starts (B: linker flags in k27/build-kernel27.sh), native-4k-block-split (B: 0007); os (2): darwin26-kpi (B 0024/0029/0031), darwin26-shared-region (B enlarges the region to 8 GiB instead); device (4): ipados27-bringup (in part: T0SZ, cache pointer signing, pmap user mappings), non-apple-idle-wfi, droidvm-amp, droidvm-native-pac-user-jop |
| No counterpart; macOS would need it (general Gunyah / non-Apple core / 4K fix, or a hook our drivers call) | 17 | arch: native-work-interval-instance; os: darwin26-syscalls (need not determined: B adds no system call); device: non-apple-vcpu-park (WFE outside the idle loop: B changes only cpu.c/machine_routines.c), non-apple-vcpu-start-flush (and the cpu_start flushes inside ipados27-bringup), zzx-pmap-sync-flush, non-apple-sigp-recover, droidvm-native-pac-user-ib, droidvm-dyld-16k-peek-first (B does not touch vm_dyld_pager.c), droidvm-native4k-once, droidvm-pressure-pageable, droidvm-free-target-bytes, droidvm-serial-uarts, zzw-native-sandbox-grant-patterns, source-storage-start, droidvm-osmetaclass-adopt-superclass, droidvm-gpu-sandbox-first, droidvm-surface-gpu-wait. Also inside ipados27-bringup: HAS_16BIT_ASID (B's BCM2837.h has none: 8-bit ASIDs), hw.pagesize readable by everyone, built-in boot arguments |
| No counterpart; iPadOS layout or fileset only | 15 | native-union-getattrlistbulk, native-union-lower-directory, native-union-getdirentries-eof, offline-owner-cache-carrier, zzy-native-gpu-addon-mount, zzy-staged-system-apps, zzyb-native-cryptex-os-view, zzyd-owner-hide-vmm, zzwb-native-sandbox-grant-set-properties, zzyc-owner-skip-launch-constraints, native-text-fixup, droidvm-text-fixup-bitmap, droidvm-gpu-grant-apps, native-security-init, fileset-unmapped-call |
| Debug / diagnostics | 5 | zzye-owner-debug-task-ports, zzyf-owner-debug-vnode-read, native-lookup-trace, droidvm-sched-trace, droidvm-early-panic |

The "macOS would need it" column is a reading of the patch texts (what each fixes is a property of the host or of a 4K kernel, not of
iPadOS); none of it was run on macOS.
