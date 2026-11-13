# Upstream UniXNU macOS profile (origin/main dff2765) vs macOS-DroidVM (B) vs Line A

Labels: READ = diff/code read; HDR = the patch's own prose header plus its hunk outline and `#if`/boot-arg guards read, code not
read line by line; TITLE = name only. "U" = upstream tree built here.

Trees (all on pristine xnu ac9718f, one commit per patch):
- `treeU` = origin/main arm64e arch series (69) + SoC series of UniXNU-sm8550-common HEAD 2dc650c (2) + macOS OS series (4 shared + 49).
  124 patches, 0 failures, 145 files, +8120/-202. The macOS layer alone (after the SoC tag): 93 files, +4799/-221.
- `treeA` = Line A (68 arch + 4 os + 25 device), `treeB` = macOS-DroidVM (48 + 2).
- Overlap files: `U-in-B.txt`, `B-in-U.txt`, `U-in-A.txt`, `A-in-U.txt` (tools/overlap.py), `UB-both.txt`, `U-order.txt`.

Correction to the brief: the profile directory holds 49 patch files, not 51; all 49 are in the series.

## 1. Composition (READ)

- `profiles/arch/arm64e/profile.toml:10` `patch_series = ["arch:patches/xnu/series", "os:patches/xnu/series"]`; a board replaces the
  list. Upstream boards use four layers, e.g. UniXNU-sheng `board.toml:22`
  `["arch:patches/xnu/series", "soc:patches/xnu-12377/series", "os:patches/xnu/series", "device:patches/xnu-12377/series"]`.
  Line A's board uses three (arch, os, device), no SoC series.
- macOS os series (`profiles/os/macos-27.3-26C5035r/patches/xnu/series`): first the same 4 generic patches as iPadOS 27
  (`arch:../../../patches/xnu-12377/zzz-boot-progress|darwin26-syscalls|darwin26-kpi|darwin26-shared-region.patch`), then 49 from
  `../xnu-12377/`. So: same arm64e arch series (69 patches) as iPadOS 27 + same 4 Darwin-26 patches + 49 macOS patches.
- The os series is not self-contained without a SoC layer: origin/main's `zzz-boot-progress.patch` has a hunk whose context
  (`#if defined(XNU_SHENG_PMGR) ... sheng_pmgr_run()` in bsd_init.c) comes from the SoC patch `sheng-platform-power.patch`.
  With arch + os only, `zzz-boot-progress` fails and 20 macOS patches fail after it. The fork's copy of the patch lacks that hunk.
- Target switch:
  - `profiles/os/macos-27.3-26C5035r/profile.toml:16` `"target" = "macosx"`
  - `scripts/unixnu/kernel.py:55-56` `env['UNIXNU_XNU_TARGET'] = profile.get('target', 'ios')`
  - `scripts/build-xnu-4k-baseline.sh:22-25` `ios) XNU_TARGET_DEFINE=-DXNU_TARGET_OS_IOS ;; macosx) XNU_TARGET_DEFINE=-DXNU_TARGET_OS_OSX ;;`
    and `:839` `DEPLOYMENT_TARGET_FLAGS="-miphoneos-version-min=$IOS_VERSION $XNU_TARGET_DEFINE"`.
    The fork (merge-up-1101) hardcodes `-DXNU_TARGET_OS_IOS` at `scripts/build-xnu-4k-baseline.sh:846` and `:888`.
  - Comment there: "Both build the same iOS-platform kernel with the same memory layout and link address".
  - Built-in drivers get the macOS family ABI by a forced include: `scripts/build-sheng-source-storage.py:192-200` writes
    `macos-target.h` (`#undef TARGET_OS_OSX / #define TARGET_OS_OSX 1`) "without them every later IOBlockStorageDevice vtable slot
    sits 3 slots early"; `scripts/build-adreno740-accelerator.py:42-43` picks the base class by build (`IOAccelerator` for 26C5035r,
    `IOAcceleratorES` otherwise); `scripts/build-sheng-source-drivers.py:136` places firmware in `__DATA,__firmware` on macosx.
- Packaging is the same as iPadOS 27: `[kernel.prelink] tool = "kits/XnuPrelink/emit_prelink.py"` (profile.toml:36) against the macOS
  kernelcache (mac17j, symbols kept, no `slide`, no `--fileset-reference`; 67 roots plus 2 exclusions, against 31 roots for iPadOS 27), drivers built into the kernel. No kext build, no KC linker, no KDK.
  `configs/macos.config` is byte-identical to `ipados.config` (2 lines).
- One device repository, two OSes: `scripts/unixnu/profiles.py:60-62` `[os_overrides."<profile>"]`, `cli.py:20` `--os`,
  `profiles.py:19` `resolve_os` (macos-27). docs/porting/macos.md: "One device repository serves the iPadOS and macOS profiles: the
  macOS values sit in [os_overrides."macos-27.3-26C5035r"] of board.toml, and an iPadOS build never reads them."
  The fork already has `os_overrides` and `--os` (profiles.py:52-54); it lacks `target` and the `macos-` family in `resolve_os`.

## 2. Drift

### Arch layer, origin/main vs merge-up-1101 (merge base 407db1a; fork 161 ahead, upstream 282 ahead)

- 58 of upstream's 69 arch patches are byte-identical in the fork.
- Only upstream (5): `native-pac-arm64-user-jop.patch` (= B 0042 idea; Line A has it as device `droidvm-native-pac-user-jop.patch`
  + `droidvm-native-pac-user-ib.patch`), `native-at-par-sync.patch` (= B 0045, same instruction; Line A lacks it),
  `native-union-statfs-fsid.patch` (has `#if !XNU_TARGET_OS_OSX` inside a common patch), `native-modload-lock-order.patch`,
  `native-union-readdir-eof.patch` (replaces `native-union-getdirentries-eof.patch`).
- Only fork (4): `native-union-getdirentries-eof.patch`, `zzyd-owner-hide-vmm.patch`, `zzye-owner-debug-task-ports.patch`,
  `zzyf-owner-debug-vnode-read.patch`.
- Changed (6): `native-4k-shared-region-slide.patch` (+39: page speculate + release of the source page before sliding = B 0013),
  `native-pac-keys.patch` (+18: `ml_default_jop_pid` returns 1 under HAS_NATIVE_PAC = B 0009), `offline-owner-systemos-mount.patch`
  (fork waits up to 10 s for the volume; upstream does not), `zzy-native-gpu-addon-mount.patch` (boot-arg `sheng-gpu-addon` ->
  `gpu-addon`, O_TRUNC size fix), `zzy-staged-system-apps.patch` (`sheng-staged-apps` -> `staged-apps`),
  `zzyc-owner-skip-launch-constraints.patch` (`sheng-no-lc` -> `no-lc`).
- Shared os patches: 3 of 4 identical; `zzz-boot-progress.patch` differs (the sheng PMGR hunk).
- Resulting trees at the end of the arch layer: 73 files (A) vs 74 (U); 64 identical, 7 differ (kern_exec.c 14 lines,
  vfs_lookup.c 10, vfs_syscalls.c 68, OSKext.cpp 29, machine_routines_asm.s 1, vm_shared_region_pager.c 29, mac_process.c 27),
  2 only A, 3 only U. Lines: 96% of U's arch lines are in A, 97% of A's in U.
- Test: the 49 macOS patches on the fork's arch+os layers: 41 apply, 8 fail (macos-droidvm-k27-parity, vfs-union-readdir-report,
  vfs-union-below-walk, kperf-timebase-scale-no-division, timebase-user-scaled-read, cshash-native4k-lazy, cssha-digest-time,
  memwired-cs-lazy-page-chunks) -- the union patches need upstream's newer arch union patches, the rest cascade. On the full Line A
  tree (with the device layer) 40 apply, 9 fail (cshash-native4k-stats too: device `droidvm-native4k-once.patch` is in the way).

### treeU vs treeB (macOS-DroidVM)

- Files: U 145, B 139; 85 in both (31 byte-identical, 54 differ), 60 only U, 54 only B.
- Lines (significant added lines found in the other tree, same file): U arch 821/2195 (37%), U shared os 83/356 (23%),
  U macOS layer 224/2266 (9%); B 1046/3472 (30%), of which 902 are B 0001+0002 (the common base).
- Guard style: B's added `#if` lines name `BCM2837` 28 times and `XNU_TARGET_OS_OSX` 3 times; U's macOS layer names
  `XNU_TARGET_OS_OSX` 41 times. Example: kqworkloop limits are `#ifdef BCM2837` in B 0011 and `#if XNU_TARGET_OS_OSX` in U;
  the 8 GiB shared region is an unconditional constant change in B 0002 and `#if ... XNU_TARGET_OS_OSX` in U.
- Storage layout: U has `MNT_UNION` 18, `firmlink` 29, `native_owner_data_prepare` 4, `XNU_OWNER_DATA_MOUNT` 3 added lines;
  B has 0, 1, 0, 0; A has 6, 0, 2, 2. U's macOS profile keeps Line A's owner layout (SystemOS union on "/", owner Data on another
  device), B has the single APFS container.

## 3. The 49 upstream macOS patches

B column: SAME = same code, IDEA = same idea other code, -- = nothing in B's current series. Guard: OSX = every functional hunk
under XNU_TARGET_OS_OSX (directly or inside the enclosing `#if ... XNU_TARGET_OS_OSX` region of kern_exec.c, checked in treeU);
ARG/DT = runtime switch, no change without it; ADD = only new symbols, counters, sysctls or prints; UNC = changes shared code for
every target.

| # | Upstream patch | Label | macOS-DroidVM | Line A | Guard |
|---|---|---|---|---|---|
| 1 | macos-machine-config | READ | IDEA 0007, 0036, 0046 (B edits MASTER files unconditionally) | -- | UNC (edits shared MASTER.arm64.bcm2837) |
| 2 | macos-target-kernel | READ | IDEA 0003 (3 lines same), 0006 | -- | OSX |
| 3 | macos-darwin26-kpi | READ | IDEA 0024 (k27_compat.c), 0025 | partly os `darwin26-kpi.patch` (the iPadOS `*_ext` forms) | ADD |
| 4 | macos-owner-data-firmlinks | HDR+guards | -- (no Data mount in B) | builds on arch `offline-owner-systemos-mount`, `zzyb-native-cryptex-os-view`, `zzy-native-gpu-addon-mount` (74 lines shared) | OSX (+CONFIG_FIRMLINKS) |
| 5 | macos-shared-region-size | READ | IDEA 0002 hunk (unconditional there) | -- | OSX |
| 6 | macos-verbose-text-console | READ | SAME 0002 (`virt-vc-text`, 9/10 lines) | -- | ARG vc-text |
| 7 | macos-user-address-space | READ | IDEA 0010 (39-bit, T0SZ shim) | -- | OSX |
| 8 | macos-union-one-volume | HDR+guards | -- (B dropped its union code 11-11) | -- | OSX |
| 9 | macos-kqworkloop-limits | READ | SAME 0011 (guard BCM2837 -> OSX) | -- | OSX |
| 10 | macos-exec-log | READ | SAME 0002 (15/15), 0016 extends | -- | ARG exec-log |
| 11 | macos-apfs-boot-shim | HDR | -- | -- | OSX + ARG |
| 12 | macos-read-only-system-volume | READ | -- | -- | OSX |
| 13 | macos-rw-held-report | READ | -- | -- | OSX (diagnostic) |
| 14 | macos-end-rename-swap | READ | SAME 0041 (22/22) | -- | UNC (MAC slot 55 called) |
| 15 | macos-service-port-derive-check | READ | -- | -- | UNC (MAC slot 44 void -> int) |
| 16 | macos-gpu-bundles | HDR | -- (B stages the plugin from userland scripts) | IDEA arch `zzy-native-gpu-addon-mount` | OSX |
| 17 | macos-owner-root-authenticated-open | READ | -- | -- | OSX |
| 18 | macos-hardware-volume | HDR | -- | -- | OSX |
| 19 | macos-droidvm-k27-parity | part READ | SAME 0017, 0022 (24/24), 0033 (13/20), 0039 (2/2), 0040 (35/39), 0044 (5/5); its union fixes cite B numbers of 11-08 that B has since dropped | device `droidvm-timebase-24mhz.patch` (35 lines same; arg `droidvm-timebase-hz` vs `timebase-hz`) | mixed: 19 OSX, 3 ARG, UNC: 16K mmap placement, realtime clamp, 4K CS NX rule, union lookup |
| 20 | macos-app-cryptex | HDR | -- | reuses arch `offline-owner-systemos-mount` code | OSX |
| 21 | macos-vm-volume | HDR | -- | -- | OSX |
| 22 | macos-addon-sbin | HDR | -- | -- | OSX |
| 23 | window-memory-excluded-ranges | HDR | -- | -- | DT (+ one unconditional page-array loop bound) |
| 24 | xnuconfig-macos-memorystatus-policy | READ | IDEA 0047 (jetsam floors, other remedy) | -- | OSX |
| 25 | xnuconfig-work-interval-counters | HDR | -- | -- | ADD |
| 26 | xnuconfig-timebase-trap-count | READ | -- | -- | ADD |
| 27 | vfs-union-readdir-report | HDR | -- | -- | UNC (removes an arch diagnostic) |
| 28 | vfs-union-below-walk | HDR | -- | -- | UNC (CONFIG_UNION_MOUNTS lookup) |
| 29 | vmwait-vnode-pager-peek-name | HDR | -- | -- | ADD |
| 30 | kperf-timebase-scale-no-division | HDR | -- (extends 0040) | extends `droidvm-timebase-24mhz` | UNC (acts only on a scaled timebase) |
| 31 | kperf-static-if-builtin-args | READ | -- | -- | UNC |
| 32 | cshash-native4k-stats | HDR | -- | -- | ADD |
| 33 | payload-boot-memory-report | HDR | -- | -- | ADD |
| 34 | payload-addon-release | HDR | -- | -- | ARG boot-payload-release |
| 35 | cshash-native4k-parallel | HDR | -- | related: device `droidvm-native4k-once.patch` | UNC (helper threads above 32 MiB) |
| 36 | gpubundle-system-extensions-view | HDR | -- | -- | OSX + ARG ("Has not run on hardware") |
| 37 | timebase-user-scaled-read | HDR | -- | -- | ARG timebase-user |
| 38 | cshash-native4k-lazy | HDR | -- | related: `droidvm-native4k-once.patch` | ARG cs-lazy |
| 39 | gpucache-system-shader-cache-view | HDR | -- | -- | OSX ("Has not run on hardware") |
| 40 | payload-radix-root-at-startup | READ | -- | -- | UNC ("Has not run on hardware") |
| 41 | cssha-digest-time | HDR | -- | -- | ADD |
| 42 | gpupool-device-pager-close | HDR | -- | -- | ADD |
| 43 | memwired-kc-segment-release | HDR | -- | -- | UNC (kc-segment-release default 1) |
| 44 | memwired-booter-size-accounting | READ | -- | -- | UNC |
| 45 | memwired-cs-lazy-page-chunks | HDR | -- | -- | ARG (cs-lazy path only) |
| 46 | platform-error-name-address | READ | -- | -- | ADD (panic text) |
| 47 | window-outside-memory-adoption | HDR | -- | -- | DT + ARG |
| 48 | contig-search-report | HDR | -- | -- | ADD ("Not run on hardware") |
| 49 | kmem-alloc-failure-report | HDR | -- | -- | ADD |

Counts vs macOS-DroidVM: SAME code 5 (#6, 9, 10, 14, and the bundle #19); IDEA 6 (#1, 2, 3, 5, 7, 24); nothing in B 38.
The 38: 14 for the two-volume owner layout (#4, 8, 11, 12, 16, 17, 18, 20, 21, 22, 27, 28, 36, 39), 1 Darwin 26 MAC hook (#15),
7 memory window / boot payload (#23, 33, 34, 40, 43, 44, 47), 5 code-signing cost (#32, 35, 38, 41, 45), 3 timebase follow-ups
(#26, 30, 37), 6 diagnostics (#13, 25, 29, 46, 48, 49), 2 other (#31, 42).
Line A equivalent by code: only the timebase part of #19; #3, 4, 16, 20, 30, 35, 38 build on or relate to Line A patches.

Guard counts: OSX 18, ARG/DT 8, ADD 11, UNC 12.

## 4. macOS-DroidVM patches and where upstream has them

| macOS-DroidVM patch | In upstream | Label |
|---|---|---|
| 0001 their 21 patches | arch layer (176/335 lines: bcm2837-machine-config etc.) | overlap |
| 0002 merge port diff | arch + shared os (726/1876 lines: offline-*, native-4k-*, mockfs, zzz-boot-progress) and macos-verbose-text-console, macos-exec-log, shared-region size | overlap |
| 0003 macOS target fixes | macos-target-kernel (part) | READ |
| 0007 ext_resolver config ... | macos-machine-config (config part only; KC segment addresses: nothing) | READ/TITLE |
| 0009 default jop pid 1 | arch `native-pac-keys.patch` (after the fork's merge base) | READ |
| 0010 user VA width | macos-user-address-space (other code) | READ |
| 0011 kqworkloop limits | macos-kqworkloop-limits | READ |
| 0013 shared region pager release | arch `native-4k-shared-region-slide.patch` (after the fork's merge base) | READ |
| 0016 exec-log=2 | macos-exec-log (exec-log=1 only) | READ |
| 0017, 0022, 0033, 0039, 0040, 0044 | macos-droidvm-k27-parity | part READ |
| 0021 AMP | SoC/device layer (sheng `zzyf-sheng-amp.patch`), not the profile | TITLE |
| 0024, 0025 KPIs, CallPlatformFunction | macos-darwin26-kpi (other code) | READ |
| 0031 lookup_preflight flags | shared os `darwin26-kpi.patch` (also Line A) | overlap |
| 0036 CONFIG_FIRMLINKS, 0046 macOS syscalls | macos-machine-config | READ |
| 0041 end rename swap | macos-end-rename-swap | READ |
| 0042 arm64 A keys off | arch `native-pac-arm64-user-jop.patch` | READ |
| 0045 PAR_EL1 ISB | arch `native-at-par-sync.patch` | READ |
| 0047 jetsam floors | xnuconfig-macos-memorystatus-policy (other remedy) | READ |
| 0004, 0005 | deletions only, nothing to render | overlap |

No rendering in upstream (23): diagnostics 0006 (part), 0014, 0019, 0026, 0027, 0028, 0032, 0034, 0037; upstream-clang workarounds
0015, 0048, IOServicePM-virtual-thunk-callbacks; owner chain / KC specifics 0008, 0029, 0030, 0035, IOService-owner-cache-media-
visibility; others 0012 (Line A has it in `ipados27-bringup.patch`), 0018, 0020 (idle WFI: SoC/device layer upstream), 0023, 0038
(removes workarounds upstream never had), 0043. Their content is TITLE-level here except the two IOService extras; the parent maps
them against Line A.

Counts: 25 rendered (same or idea), 2 empty, 23 not rendered = 50.

## 5. Drivers and packaging upstream

- No DroidVM macOS board upstream. devices.toml: `droidvm` (Droid-VM/UniXNU-droidvm, format 1, iPadOS 17, revision 77bb46b),
  two forks of it; macOS profile users: `piano-lenzhang` (macos-27.3, record_state "missing"), sheng through `os_overrides`
  (docs/porting/macos.md names the sheng board file), older 26.5 ports (`sheng-mataht`, `sheng-doubleloves`, `sheng-macos`).
- Drivers stay built into the kernel on macOS (docs/porting/macos.md step 6: per-build class fixtures
  `scripts/<family>-26C5035r.json` from `scripts/gen-board-abi.py`, SoftwareAES compiled against the 26C5035r layout, en0 as
  IOEthernetController of the original IONetworkingFamily, HID with `displayUUID`). docs/drivers/kexts.md: "The shipped DarwinBoot
  starts prelinked kernels. Its driver integration path is built-in XNU drivers"; kext bundles need a loader "revision 2" that
  DarwinBoot does not ship.
- Single APFS container: tried and reverted within a day. 51d1c56 (11-13) "feat(macos): build APFS containers with native tools"
  added `macos-native-apfs-container.patch` ("Native APFS container boot, adapted from Droid-VM/macOS-DroidVM 9db2f6f...", 177
  lines, `#if XNU_TARGET_OS_OSX` branches in bsd_init.c and `native_owner_cache_prepare`, trust by
  `csr_check(CSR_ALLOW_UNAUTHENTICATED_ROOT)` + `native_ram_block_root_device`), `[userdata] layout = "apfs-container"`,
  `XNU_SOURCE_STORAGE_CONTAINER`, `scripts/make-macos-disk.py`, `macos_container.py`, and removed the 14 union/Data patches.
  dff2765 (HEAD, same day) "fix(macos): restore the previous root storage layout" undid all of it; the commit has no body, so the
  reason is not recorded. 9db2f6f is 37 commits behind macOS-DroidVM's `macOS` head.
- kits/XnuPrelink is a submodule and not checked out here: how the emitter treats the macOS collection (and whether it covers what
  B 0029/0030/0035 do for AMFI) could not be read.
- Remote `droidvm/main` = fb2bb31 (2026-10-21), an ancestor of origin/main, 756 behind. `droidvm/macOS` = that plus 17 commits
  (NativeMetal pins, metal2vulkan-port patches 0012-0023, three `patches/xnu` files for the pre-layer tree); no `profiles/`,
  no xnu-12377 series; 17 ahead / 756 behind origin/main. `droidvm/wip/hackintosh` and `droidvm/wip/droidvm` = merge-up-1101.

## Not determined

- Whether iPadOS 27's kexts fill MAC slots 44 and 55 (so whether #14 and #15 change an iPadOS kernel's behaviour).
- Why upstream reverted the single-container layout.
- The SoC series used here is UniXNU-sm8550-common at its current HEAD, not the commit a board pins; DroidVM's `crosvm-gunyah` SoC
  layer has no XNU series, so a DroidVM macOS board would need the fork's hunk-less `zzz-boot-progress.patch` or a SoC series.
- Of the 49 patches, 19 are READ, 1 partly READ (#19), 29 HDR-level: descriptions and guards read, code not line by line.
