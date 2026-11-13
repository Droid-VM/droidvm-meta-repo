# Drivers: Line A (iPadOS 27, built into the kernel) vs Line B (macOS 27, kexts in a kernel collection)

Sources read 2026-11-13. A = UniXNU-droidvm-main @ main 8a645de (`package/`, `ipados27/`), fork
UniXNU-m1101 @ merge-up-1101 0f7b62a (submodule pins). B = Droid-VM/macOS-DroidVM @ macOS 58359aa.
Every row is READ (code or diff read, or a patch dry-run executed in the scratch dir) unless marked TITLE or NOT DETERMINED.
Line counts are `wc -l` (lines are up to ~130 columns wide).

## 0. Pins verified

| What B builds from | Pin in B's script | Where A's main is | Do B's patches apply to A main? |
|---|---|---|---|
| Audio: `DroidVMAudio.cpp`, `DroidVMVirtioSnd.c`, `DroidVMDmaRegion.h` | `AUDIO_REF=e29d087` (k27/build-native-audio.sh) | 0 commits, 0 lines changed since the pin | 4/4 apply cleanly |
| Video: `DroidVMVirtioMedia.c`, `DroidVMVTParavirt.cpp`, `DroidVMVTHost.cpp`, `DroidVMVTWire.h`, `DroidVMDmaRegion.h` | `VT_REF=706338e` (k27/build-native-video.sh) | 0 commits, 0 lines changed since the pin | 12/12 apply cleanly |
| virtio-gpu: `DroidVMVirtioGpu.h/.cpp`, `DroidVMVirtioGpu3D.cpp` | `VGPU_REF=59ec0a8` (k27/build-native-display.sh) | .h 1 commit (+9/-2), .cpp 1 commit (+187/-10, 3af9eca), 3D.cpp 3 commits (+248/-15: e29d087, 3af9eca, 7651f2b) | 0001, 0002 apply; 0003, 0004 conflict (A's own interrupt watch, 3af9eca) |
| `DroidVMGpu.cpp`, `DroidVMGpuWire.h` | `REF=bf7fc44` (scripts/build-droidvm-gpu.py) | A removed the KGSL proxy itself in 4284c6c; 5 more commits since | not applicable (A main already is the publish-only file, 320 lines vs B's 164) |
| NativeAdreno | 805c7e4 + 6 patches | A pins Adreno740 627836d = 805c7e4 + 30 commits, which contain all 6 | the 6 patches are cherry-picks of A's own commits (eaa2c28, 37cb421, a752475, 9fcf95f, 32e864a, 627836d) |
| ArmCpu | 1951cc8 (all 7 patches apply in sequence there; they fail on every later commit) | A pins 5265ef1 = 1951cc8 + 12 commits | 4 apply (arm64-assembly, idle-wfi, spi-controller, spi-attach-startup), 3 conflict (12377-boot-interrupt, park-wfi-latency, msi-affinity) |
| ArmDTPlatform | 0d54470 | A pins 417ff95 (one docs commit later) | 2/2 apply cleanly |
| DarwinBoot | 85332b3 (2026-10-21) + 2 patches | A pins eb4a095 = 85332b3 + 18 commits | both features already in A (see section 5e) |
| NativeVirtioBlock | 98909eb + overlay/kext/NativeVirtioBlock.patch | A pins VirtioMmioBlock 4e1013e (NOT available locally; nearest local 8ee3a5a, same 576-line file) + 6 patches | on A's patched file: hunks 1 and 4 apply, 2 and 3 conflict |
| DroidVMDataStore.c | copy of A's file at 670f95b | A main has 1 more commit (45052cd) | 34 differing lines |

`configs/sources.lock.json` is stale (xnu-10063 era); the real pins are in the k27 scripts above.

## 1. Per device function

| Function | Line A source (lines) | A build | A transport | Line B source (lines) | B build | B transport | Distance |
|---|---|---|---|---|---|---|---|
| Block (root/system) | drivers/VirtioMmioBlock `NativeVirtioBlock.cpp` (576) + `ipados27/patches/VirtioMmioBlock/0001..0006` (829 patch lines; result ~837 lines, 441 differ); IOStorageFamily's public `IOBlockStorageDevice` compiled from source; `DroidVMSourceStorage.cpp` (106), `DroidVMSourceRootPolicies.cpp` (87) | built in: `build-droidvm-source-storage.py` -> libDroidVMSourceStorage.a | virtio-mmio; SPI interrupt wait (`droidvm,intid`, patch 0006), verified reads | (a) mmio: same `NativeVirtioBlock.cpp` 98909eb + `overlay/kext/NativeVirtioBlock.patch` (61 lines); (b) `MACOS_DATA_PCI=1`: Apple's AppleVirtIO (`AppleVirtIOBlockStorageDevice`) | (a) kext, `build-native-kext.py` with `-U TARGET_OS_OSX -D TARGET_OS_OSX=1`; (b) Apple kext kept in the KC | (a) virtio-mmio, polling with 16..256 us back-off; (b) virtio-pci, MSI-X through `DroidVMGicMsi` | (a) same file, 61 vs 829 patch lines, read path diverged; (b) no shared code |
| Data store | `DroidVMDataStore.c` (360) + drivers/RamBlock `NativeRamBlock.cpp` (453) | built in (source storage archive) | virtio-mmio, polled (50 us spin, 50 us sleeps) | `overlay/kext/DroidVMDataStore.c` (350): copy of A's at 670f95b + 1 extern + 3 printf; NativeRamBlock patched by string edit in `build-native-ram-block.py`; `NativeUfsStoreStub.cpp` (11). With `MACOS_DATA_PCI=1`: none of them (raw GPT disk on PCIe) + `DroidVMAPFSVisibility.cpp` (55) | kext | virtio-mmio polled (200 us spin, 1 ms sleeps), or PCIe | same file, 34 lines apart; unused in B's PCIe mode |
| Network | `DroidVMVirtioNet.c` (374) + `DroidVMVirtioEthernet.cpp` (175) + `DroidVMVirtioNetIf.cpp` (137) + `DroidVMWifi.inc` (400) + IONetworkingFamily-188 (12 sources compiled in) | built in: `build-droidvm-devices.py` | virtio-mmio; RX worker sleeps on SPI (65a053a), 100 ms guard | (a) `overlay/kext/DroidVMEthernet.cpp` (448), "transport follows DroidVMVirtioNet.c"; (b) `MACOS_NET_PCI=1`: Apple's AppleVirtIONetwork | (a) kext against the KC's IONetworkingFamily; (b) Apple kext | (a) virtio-mmio, polling 1 ms / 10 ms; (b) virtio-pci MSI-X | separate implementation of 448 lines duplicating A's 549 (transport + controller); no Wi-Fi interface on B |
| Display / virtio-gpu 2D | GopFramebuffer `NativeLegacyDisplay.cpp` (874) + `NativeGOPPresenter.cpp` (362) + `LegacyDisplayProbe.cpp` (635) + `DroidVMVirtioGpuDisplay.cpp` (482) + `DroidVMVirtioGpu.cpp/.h` (545/44) | built in: `build-droidvm-legacy-display.py`; bound to the fileset's IOMobileFramebufferLegacy by fixture `legacy-display-24A446.json` (379 slots) | virtio-mmio; control queue: spin 300 us then sleep on SPI (3af9eca) | `overlay/kext/DroidVMDisplay/DroidVMDisplay.cpp` (1436) + generated `IOMobileFramebufferABI.h` (368) + A's `DroidVMVirtioGpu.cpp/.h` @59ec0a8 + `patches/droidvm-display/0001..0004` (457 patch lines) | kext `build-native-display.sh`; IOMobileFramebufferLegacy subclass, 473 slots checked by `kc-build.py` | virtio-mmio; level SPI (`gic-spi`) through IOInterruptEventSource; VBL is an IOTimerEventSource at the refresh rate; hardware cursor queue | transport: same file + 4 patches (A main 310 lines apart from B's result); framebuffer class: separate implementations (1436 vs ~2350 lines) of the same IOMobileFramebufferLegacy hooks |
| GPU 3D | `DroidVMGpu.cpp` (320) + `DroidVMVirtioGpu3D.cpp` (1214) + Adreno740 627836d + staged AGXAccelerator under IOGPUFamily | built in: `build-droidvm-gpu.py`, `link-droidvm-gpu-sources.py` | virtio-gpu DRM context (vgpu-3d=1) on the same mmio transport | `DroidVMGpu.cpp` bf7fc44 + 2 patches (164) + `DroidVMVirtioGpu3D.cpp` @59ec0a8 (+16 lines by display 0003) + NativeAdreno 805c7e4 + 6 cherry-picks + `overlay/kext/DroidVMGpuKext.cpp` (121: starter + `AGXAccelerator : IOAccelerator`) | kext `scripts/build-droidvm-gpu.py` | same | same files; `DroidVMGpu.cpp` 190 lines apart, 3D.cpp 265 lines apart (A's later work); accelerator shell differs by family (IOGPUFamily fixture vs IOGraphicsFamily IOAccelerator) |
| Input | `DroidVMVirtioInput.c` (963) + ShengHidInput `NativeHidInput.cpp` (320, 24f1f3f) + `HidInputProbe.cpp` (251) + `DroidVMTrackpadHid.inc` (356) + `DroidVMMotionHid.inc` (193) | built in: `build-droidvm-hid-input.py`; fixture `hid-device-24A446.json` (207 slots) | virtio-mmio (`--virtio-mmio-input`); worker sleeps on SPI (30886ad) | `overlay/kext/DroidVMInput/DroidVMInput.cpp` (973) + `overlay/droidvm/drivers/NativeVirtioInputPci/NativeVirtioPci.h` (280) | kext; IOHIDDevice subclass (334 slots) | virtio-pci: MSI-X per function on enumerated IOPCIDevice, else raw ECAM with a 4 ms poll | separate implementations; touch, keyboard, mouse, tablet on both; pen, trackpad (Magic Trackpad), motion only on A |
| Audio | `DroidVMAudio.cpp` (477) + `DroidVMVirtioSnd.c` (382) | built in (devices) | virtio-mmio; polling (`IOSleep(1)`, queues NO_INTERRUPT) | same two files @e29d087 + `patches/droidvm-audio/0001,0002,0003,0005` (412 patch lines) + `DroidVMAudioStarter.cpp` (31) | kext `build-native-audio.sh`, `-D DROIDVM_NATIVE_KEXT=1 -D DROIDVM_DEVICE_DYNAMIC=1` | virtio-mmio; level SPI (`gic-spi`), worker thread | same file + 4 patches (191 lines apart); IOAudio2Family on both |
| Video (VideoToolbox paravirt) | `DroidVMVTHost.cpp` (1848) + `DroidVMVTParavirt.cpp` (383) + `DroidVMVirtioMedia.c` (428) + `DroidVMVTWire.h` (299) | built in (devices) | virtio-mmio (virtio-media); polling 1 ms / 50 ms | same four files @706338e + `patches/droidvm-video/0001..0013` (12 patches, 2995 patch lines; result VTHost 3003 lines) + `DroidVMVideo.cpp` (38) | kext `build-native-video.sh` | virtio-mmio; level SPI | same file + 12 patches (1523 lines apart, 1399 of them in VTHost) |
| AES | drivers/SoftwareAES `NativeAES.cpp` (220) + `SoftwareAESKeys.inc` (50) + `DroidVMSoftwareAES.cpp` (81) + `SoftwareAES-24A446.S` (170, address bindings) | built in (devices); string edit at build | none | same `NativeAES.cpp` (a34964b per the stale lock file) with a string edit in `k27/build-native-aes.sh` + `overlay/kext/NativeAES/OriginalAESABI.h` (50) | kext; IOAESAccelerator 285 slots | none | same file; both add the AppleImage4 nonce key at the same two anchors (A: selector 0x8a4, SHA-256 of the chip id; B: selector 2212 = 0x8a4, fixed key) |
| Key store | `KeyStoreProbe.cpp` (146), `KeyStoreWrap.inc` (43), AppleKeyStoreState 42ff83e | built in | none | none found in overlay/kext | - | - | A only (B: NOT DETERMINED how macOS's key store is satisfied) |
| RTC / clock | `DroidVMClock.c` (39): PL030 at fixed 0x2000, sets the calendar before launchd | built in | MMIO read | `patches/drivers/ArmDTPlatform-pl030-rtc.patch` (42): `getGMTTimeOfDay` from the ADT's `arm,pl030` node | in ArmDTPlatform (kernel archive) | MMIO read | same device, different code |
| Interrupt controller | ArmCpu 5265ef1 (914 lines): GICv3, `armcpu_spi_attach`, 16 SPI slots, all SPIs to the boot CPU | kernel archive | - | ArmCpu 1951cc8 + 7 patches: 128 slots, `armcpu_spi_set_enabled`, `armcpu_spi_distribute`, attach lock; `overlay/kext/DroidVMGicMsi.cpp` (219) for MBI/MSI | kernel archive + kext | - | same file, forked 12 commits (A) vs 7 patches (B) |
| Platform expert | ArmDTPlatform 417ff95 | kernel archive | - | ArmDTPlatform 0d54470 + 2 patches; `ARMPlatformStandIn.cpp` (174) | kernel archive + kext | - | same file + 2 patches; stand-in is B only |
| USB | none | - | - | Apple's AppleUSBXHCIPCI etc. kept in the KC (`MACOS_USB_PCI=1`), `ArmDTPlatform-power-hierarchy.patch`, xnu `IOServicePM-virtual-thunk-callbacks.patch` | Apple kexts | PCIe xHCI, MSI-X | B only |
| Battery | `DroidVMBattery.cpp` (176), goldfish | built in | MMIO, polled | none | - | - | A only |
| Sensors / motion | `DroidVMSensorProcessor.cpp` (71), `DroidVMMotion.c` (56), `DroidVMMotionHid.inc` | built in | via virtio-input | none | - | - | A only |
| cpufreq | `DroidVMCpufreq.c` (199) | built in | MMIO | none | - | - | A only |
| Console / serial | `DroidVMVirtioConsole.c` (626) + kernel patch `droidvm-serial-uarts.patch` | built in | virtio-mmio, SPI wait with 250 ms guard | none (crosvm `--serial`, kernel's own console) | - | - | A only |

Functions on one line only: battery, sensors, cpufreq, virtio-console, key store, Wi-Fi interface, pen, trackpad (A); USB, MSI
controller, hardware cursor, APFS visibility, platform stand-in (B).

## 2. Every Line B driver patch (40)

Classes: K = needed only by kext packaging; M = macOS-specific; G = general, iPadOS should take; E = general, A already has it
(same commit or an equivalent). No patch is diagnostics only.

| Patch | Class | Note |
|---|---|---|
| audio 0001 native-kext-no-staged-module-load | K | three `#if !DROIDVM_NATIVE_KEXT` blocks; no effect when undefined |
| audio 0002 output-lead | G | 8 periods (40 ms) of silence queued ahead at output start; not in A |
| audio 0003 host-latency | G | HAL output latency += 1536 frames (Android fast mixer); not in A |
| audio 0005 completion-interrupts | G | A main polls (`IOSleep(1)`); reads `gic-spi`, A's ADT says `droidvm,intid`; also PREPARE/RELEASE at start/stop |
| video 0001 native-kext-no-staged-module-load | K | two `#if !DROIDVM_NATIVE_KEXT` blocks |
| video 0002 surface-root-by-class | G | `serviceMatching("IOSurfaceRoot")` instead of the iPadOS name; needs one iPadOS check |
| video 0003 userptr-buffers | G | V4L2 USERPTR instead of the 128 MiB media_host pool |
| video 0004 pageable-buffers | G | pageable allocation, wired by prepare() |
| video 0005 input-queue-1024 | G | 4096 queued inputs instead of 128 |
| video 0007 x420-surfaces | G | 10-bit streams |
| video 0008 frame-thinning | M | hands back every frame closer than 31 ms to the last shown as dropped, for every stream (still in the final source, `emitFrame`): written for the 240 fps lock-screen aerials; ungated it halves a 60 fps video |
| video 0009 demt-unawaited | G | no round trip per frame |
| video 0010 p010-capture-temporal-skip | G | P010 capture, undecoded upper temporal layers; needs crosvm's msm_vidc backend |
| video 0011 session-lifecycle | G | 673 added lines; found with a user-space harness |
| video 0012 dbuf-surface-from-another-process | G | Safari/WebKit surfaces |
| video 0013 media-completion-interrupts | G | A main polls; `gic-spi` |
| display 0001 slots-on-the-heap | K | 5 lines under the existing `DROIDVM_VIRTIO_GPU_DYNAMIC` |
| display 0002 cursor-queue | M | hardware cursor command; only B's display calls it; applies to A main |
| display 0003 completion-interrupts | E | A has its own (3af9eca); different design, conflicts |
| display 0004 async-cursor-moves | M | depends on 0002/0003 |
| gpu NativeAdreno 0001..0006 | E x6 | cherry-picks of A's commits |
| gpu UniXNU-droidvm 0001 | K | binding table on the heap, 64 IBs; the code it touches is deleted by 0002 |
| gpu UniXNU-droidvm 0002 | E | "as upstream's 4284c6c"; minus publishMetal (the kext's personality does it) |
| ArmCpu-arm64-assembly | G | see finding below; not in A |
| ArmCpu-12377-boot-interrupt | E | A: fe98808 (register late on Darwin 25), different code |
| ArmCpu-idle-wfi | E | self-IPI on by default; A passes `armcpu-self-ipi=1` |
| ArmCpu-park-wfi-latency | E | A: b3fd2a9/c6b72b6 (parkCore), 5265ef1 (25 us latency; B 20 us) |
| ArmCpu-spi-controller | G | 128 SPI slots, `armcpu_spi_set_enabled`; A has 16 slots; 5 driver files attach, one SPI per device instance (each disk, input device and console) |
| ArmCpu-msi-affinity | G | `armcpu_spi_distribute`, per-CPU counts; only needed with MSI |
| ArmCpu-spi-attach-startup | G | attach waits for the GIC and takes a lock; A's attach claims a slot from `gSpiUsed` without one, and its drivers attach from separate threads |
| ArmDTPlatform-pl030-rtc | G | cleaner than A's fixed-address `DroidVMClock.c` |
| ArmDTPlatform-power-hierarchy | G | only matters with a USB host controller |
| darwinboot-accept-arm64e | E | A: 3e3a8a9 / 3c75734 |
| darwinboot-reclaim-memory-and-512mb-kernel | M | reclaim is in A; what remains is `WINDOW_SIZE` 512 MB and a 512 MB kernel read limit (A: 256 MB, 128 MB) |
| overlay/kext/NativeVirtioBlock.patch | M | 30 s time-outs, publish after IOBSD and in MMIO order (APFS start deadlock, union order); the wait loop conflicts with A's |

Counts: K 4, M 5, G 19, E 12 (total 40).

## 3. Finding outside the comparison: ArmCpu inline assembly

`patches/drivers/ArmCpu-arm64-assembly.patch` replaces `;` between instructions with newlines in 17 inline-assembly statements.
Checked here with clang 18, `-target arm64-apple-ios17.0`: `"isb; mrs %0, cntvct_el0"` assembles to `isb` alone and
`"dsb ishst; msr icc_sgi1r_el1, %0; isb"` to `dsb ishst` alone (on Darwin arm64 `;` starts a comment). A's pin 5265ef1 still has all
17, among them `signalCPU`'s SGI (ArmCpu.cpp:712), `counter()` (161) and the EOI `isb`. With `armcpu-spi-ipi=1` (A's board) the SGI
path is not used. NOT VERIFIED: what Xcode's clang emits for A's actual ArmCpu.o, and whether B runs with `armcpu-spi-ipi` (its
kernel arguments come from a board.toml outside the repository).

## 4. Section 3 facts

a. Kext vs built-in at source level. A: each C++ driver's static initializer is taken out of `__mod_init_func`
(`llvm-objcopy --remove-section`, `stage_late` in build-droidvm-devices.py) and called later inside
`OSMetaClass::preModLoad(g_kernel_kmod_info.name)` / `postModLoad`; started from the board's late probe. B: `NativeKextGlue.cpp` (9
lines: empty `native_kext_start/stop`), a JSON descriptor per kext (bundle id, libraries, personalities, `vtable` check,
`stands_in_for`, `patch_personalities`), a starter IOService matched on IOResources/IOBSD that calls the same C entry
(`droidvm_snd_start`, `droidvm_media_start`, `sheng_gpu_power_probe`), and `kc_native.py` (252 lines) which resolves undefined
symbols by name against the kernel and the collection's kexts. One source builds both ways today: audio 0001 and video 0001 are five
`#if !DROIDVM_NATIVE_KEXT` blocks in total, and both lines already share `DROIDVM_DEVICE_DYNAMIC` / `DROIDVM_VIRTIO_GPU_DYNAMIC`.

b. macOS kext ABI. B's port notes (docs/xnu-12377-port.md): with `XNU_TARGET_OS_OSX` IOService has 275 vtable slots, the iOS target
171 (A's 24A446 fixture counts 168 for IOService). Slot counts of the bases: IOMobileFramebufferLegacy 473 (B) vs 379 (A fixture); IOHIDDevice 334 vs 207; IOAESAccelerator 285 vs
181; IOBlockStorageDevice needs `TARGET_OS_OSX=1` (35 slots differ otherwise). Drivers compiled from headers follow by a compile
flag. Not a flag: A binds by reviewed address fixtures (stripped iPadOS kernelcache), B by symbol name; the framebuffer's private
instance offsets (B hard-codes macOS 27's); the accelerator's family (IOGPUFamily vs IOGraphicsFamily); HID personalities. Audio and
VideoToolbox are independent of this: both drivers re-parent their metaclass at run time and implement the user client themselves,
and macOS 27 has IOAudio2Family too.

c. PCIe vs virtio-mmio. B on PCIe (opt-in `MACOS_PCIE/NET_PCI/DATA_PCI/USB_PCI=1`, all on in the last build command of
docs/k27-vmapple-pcie-msi-plan.md, 11-12): block, network (both Apple's AppleVirtIO), input (own driver, MSI-X), xHCI. B on virtio-mmio:
GPU, sound, media (level SPIs since 11-12; the plan keeps them on mmio), and the older block/net/data-store path. A: everything on
virtio-mmio. No shared transport layer on either line: A has 8 files each with their own virtio-mmio set-up and split-ring code
(Net, Snd, Media, Gpu, Input, Console, DataStore, NativeVirtioBlock); B adds a `virtio_pci::Transport` class (NativeVirtioPci.h)
used by DroidVMInput only. The interrupt ADT property differs: `droidvm,intid` (A, written by DarwinBoot a348165) vs `gic-spi`
(B, written by run-macos-vm.py, which patches a copy of A's make-droidvm-adt.py by string replacement).

d. Data store: see table. The single-container layout removed the SystemOS disk; with `MACOS_DATA_PCI=1` the store format is gone
too (converted to a GPT disk, `data-pcie.img`), leaving `DroidVMAPFSVisibility` as the only storage kext.

e. Boot: see pins. A's DarwinBoot accepts arm64e and MH_FILESET and has `darwinboot-memory-limit` (more complete: `ReclaimableEnd`);
A builds the ADT in DarwinBoot from the firmware FDT (`--dynamic`), B generates it on the build host.

## 5. Not determined

- VirtioMmioBlock 4e1013e is not in any local clone; A's block numbers use 8ee3a5a (A's patch 0005 does not apply there, so the
  pin differs somewhat).
- Whether B's deployed VM runs every PCIe switch at once: taken from B's docs, not from a VM.
- B's key store, battery and sleep handling on macOS: nothing in overlay/kext; not searched beyond the driver directories.
- Xcode clang's handling of the `;` statements (section 3).
