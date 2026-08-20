# droidvm-3d-accel

Meta repo for DroidVM's 3D-acceleration stack: build pipeline, cross-repo docs
and the guest kernel patches. Every component lives in its own Droid-VM repo;
this folder is the workspace that ties them together (sub-repo folders are
gitignored).

## Branches

The development line is ONE trunk, `wip/3d-accel`, in every repo. Variant
branches exist only where the content genuinely differs:

| branch | where | what |
|---|---|---|
| `wip/3d-accel` | all 10 repos | everything host-side, both graphics backends, all three pools |
| `wip/3d-accel-gfxstream` | this repo + `mesa` | gfxstream launchers/plans; mesa 26.0.3 + the gfxstream guest ICD |
| `wip/3d-accel-drm2kgsl` | this repo + `mesa` | drm2kgsl launcher/plans; mesa 26.3.0-devel + turnip over vdrm |

`lib_branch.sh` resolves each component along a chain —
`wip/3d-accel-<variant>` → `wip/3d-accel` → (soong forks) the manifest
revision — so a variant branch inherits the trunk from every repo that does not
carry one. The old `wip/3d-accel-gfxstream` sits at the tail of that chain until
the trunk is published everywhere; selecting it prints a warning, because a
component left behind while the rest moved on is the crosvm/gfxstream ABI skew
whose failures are all silent.

## Pipeline

| step | script | what |
|---|---|---|
| 1 | `1_build_crosvm_prepare.sh` | repo-sync the crosvm soong tree, then check every Droid-VM fork out along the branch chain (incl. `mesa` and `mesa-cross`) |
| 2 | `2_build_crosvm.sh` | build crosvm (+ gfxstream/virglrenderer) for the device |
| 2-1 | `2-1_collect_crosvm.sh` | collect crosvm + linked .so into `crosvm_out/` (called by step 2) |
| 2-2 | `2-2_crosvm_out_to_adb.sh` | push `crosvm_out/` to the device for manual testing |
| 2-3 | `2-3_crosvm_run_ubuntu.sh` | run the manual test VM on the device |
| 3 | `3_build_edk2.sh` | build the EDK2 firmware (`edk2-gunyah && ./build.sh -DPCI_CAM_MODE=FALSE`) |
| 4 | `4_build_gunyah_host.sh` | build the host modules (host-share, kvcalloc, gh_unmovable, udmabuf) for each GKI KMI → `gunyah_host_mod/dist/` |
| 5 | `5_prepare_turnip.sh` | build the host turnip Vulkan driver (Droid-VM/turnip `gen8`, KGSL) → `turnip/libvulkan_freedreno.so` |
| 6 | `6_build_apk_prepare.sh` | clone app + prebuilt-root, overlay crosvm/EDK2/gunyah/turnip artifacts into `manual-build/` |
| 7 | `7_build_apk.sh` | build the DroidVM APK with the local prebuilts baked in |
| 8 | `8_build_guest_mesa.sh` | build the guest mesa — one package carrying all three routes (cross-compiled in a container, recipe from `mesa-cross/`) |
| 9 | `9_build_guest_addition.sh` | package the guest kernel modules as a DKMS .deb |

`gh_hugepage_reserve` is a separate out-of-tree module (`../gh-hugepage-reserve`)
and is NOT built by step 4.

Build artifacts (crosvm step 2, EDK2 step 3, gunyah modules step 4, turnip step 5)
each land in their own component dir; step 6 is the single place that pulls them
all into `manual-build/` before the APK is packed.

Turnip is the host GPU Vulkan driver (hwvulkan HAL): without it gfxstream falls
back to the closed Adreno blob (AHB-only, `supportsDmaBuf=0`) and host-visible
coherent memory fails. Step 5 builds it from our Droid-VM/turnip fork of
mesa-tu8 `gen8` via StevenMXZ/Adreno-Tools-Drivers — a self-contained build (own
NDK + mesa fork), so it does not touch the crosvm soong tree. The drm2kgsl route
does not need it: there the guest runs turnip itself and the host only
translates the DRM layer.

## Guest mesa

The guest ships ONE mesa package carrying all three routes, built from one
branch of Droid-VM/mesa. The build recipe is its own repo,
[Droid-VM/mesa-cross](https://github.com/Droid-VM/mesa-cross) (`wip/3d-accel`,
cloned into `mesa-cross/` by step 1 or by step 8): the cross container, the
packaging, and `mesa-cross/mesa-config.sh`, which holds the whole
configuration -- meson options, package name, ICD list, the version scheme --
so the local build and CI cannot drift apart:

| route | Vulkan driver | ICD |
|---|---|---|
| gfxstream | gfxstream guest ICD, paired with the host gfxstream decoder | `gfxstream_vk_icd.aarch64.json` |
| venus | venus (`vn`), speaking the venus wire to virglrenderer's vkr | `virtio_icd.aarch64.json` |
| drm2kgsl | turnip over vdrm (freedreno, kmds `msm,virtio`) | `freedreno_icd.aarch64.json` |

The mesa branch is always THIS repo's branch (`mesa_branch`), so a new meta
branch never silently keeps building the old mesa.

Until 2026-08-18 this was three packages from three mesa branches, because the
routes sat on unrelated upstream lines: gfxstream and venus on 26.0.3 (the
gfxstream guest ICD and the host decoder are one codebase and must match),
drm2kgsl on 26.3.0-devel (where the tu/virtio work lives). Rebasing every route
onto the same upstream commit showed the three trees touch disjoint files --
`src/gfxstream/**`, `src/virtio/vulkan/vn_*`, `src/freedreno/**` -- so they
became one branch and one build (`-Dvulkan-drivers=gfxstream,freedreno,virtio`).

**The route is now chosen at run time, not install time.** `VK_DRIVER_FILES`
names all three ICDs and the Vulkan loader keeps whichever one enumerates a
device: a guest sees exactly one virtio-gpu capset, so exactly one answers.
Nothing has to be swapped to change route. The package still supersedes the old
per-route `mesa-guest-{gfxstream,venus,drm2kgsl,kgsl}` packages, which installed
to the same `/usr/local` paths, so `apt install ./mesa-guest_<ver>_arm64.deb`
removes whichever of them a guest still carries. That matters because they all
shipped libgallium, the desktop composites through gallium rather than through
the Vulkan ICD, and a leftover copy shows up as a fully black VNC scanout with
no error anywhere.

The split between the two repos is git vs. build: `lib_mesa_build.sh` here
resolves the branch and keeps the checkout, then hands a PATH to
`mesa-cross/build.sh`, which knows nothing about git. The same recipe runs in
mesa-cross's GitHub Actions workflow (**Actions → guest mesa → Run workflow**):
pick the branch, it clones `Droid-VM/mesa`, builds the one `.deb` and publishes
it as a pre-release tagged with the branch name (`/` becomes `_`, which git
requires) plus `MD5SUMS` -- the same files a local `dist-guest/` would hold.
Note that CI builds what is PUSHED to Droid-VM/mesa; a local checkout with
uncommitted changes only reaches the local build.

## Layout

- `plans/` — design docs and evidence packs
- `deploy/` — phone-side launchers and benchmark harness (`gfxstream/`, `drm2kgsl/`);
  start at `deploy/SETUP.md`
- `guest-patches/` — guest kernel delta as patches (in-tree reference; the
  supported install route is Droid-VM/droidvm-guest-additions) + ICD snapshots
- `mesa-cross/` — clone of Droid-VM/mesa-cross (gitignored): the guest mesa
  cross-build recipe + `mesa-config.sh`; `mesa/` is the checkout step 8 builds
  from
- `crosvm`/`gfxstream`/`virglrenderer`/`Virtualization` — symlinks into
  `crosvm_build/` (the soong build sandbox needs the real directories in-tree)
