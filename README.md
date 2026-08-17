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
| 8 | `8_build_guest_mesa_gfx.sh` | build the guest mesa for the gfxstream route (cross-compiled in a container, recipe from `mesa-cross/`) |
| 8 | `8_build_guest_mesa_drm2kgsl.sh` | the same for the drm2kgsl route |
| 8 | `8_build_guest_mesa_venus.sh` | the same for the venus route |
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

The guest ships one of THREE stacks, from three branches of Droid-VM/mesa
checked out as three worktrees of one clone. The build recipe is its own repo,
[Droid-VM/mesa-cross](https://github.com/Droid-VM/mesa-cross) (`wip/3d-accel`,
cloned into `mesa-cross/` by step 1 or by any step-8 script): the cross
container, the packaging, and `mesa-cross/mesa-variants.sh`, which holds the
whole per-variant configuration -- meson options, package names, ICD paths,
the version scheme -- so the local build and CI cannot drift apart:

| variant | branch | package | Vulkan ICD |
|---|---|---|---|
| gfxstream | `wip/3d-accel-gfxstream` (26.0.3) | `mesa-guest-gfxstream_<ver>_arm64.deb` | `gfxstream_vk_icd.aarch64.json` |
| drm2kgsl | `wip/3d-accel-drm2kgsl` (26.3.0-devel) | `mesa-guest-drm2kgsl_<ver>_arm64.deb` | `freedreno_icd.aarch64.json` |
| venus | `wip/3d-accel-venus` (26.0.3) | `mesa-guest-venus_<ver>_arm64.deb` | `virtio_icd.aarch64.json` |

The mesa branch is always THIS repo's branch plus the variant suffix
(`mesa_variant_branch`), so a new meta branch never silently keeps building
the old mesa.

All install to `/usr/local`, so a guest holds one at a time
(`sudo apt install ./mesa-guest-<variant>_<ver>_arm64.deb`). That is why these
are packages rather than the tarball they used to be: they `Conflict` with
each other through a shared `mesa-guest` virtual name and by naming each other,
so dpkg swaps rather than overwrites. All ship libgallium, the desktop
composites through gallium rather than through the Vulkan ICD, and an
unnoticed overwrite shows up as a fully black VNC scanout with no error
anywhere. Each route has its own build script; on the trunk all three are
built.

The split between the two repos is git vs. build: `lib_mesa_build.sh` here
resolves branches and keeps the worktrees, then hands a PATH to
`mesa-cross/build.sh`, which knows nothing about git. The same recipe runs in
mesa-cross's GitHub Actions workflow (**Actions → guest mesa → Run workflow**):
pick the branch family, it clones `Droid-VM/mesa` at `<family>-<variant>` for
each variant, builds the three `.deb`s in parallel and publishes them as a
release with `MD5SUMS` -- the same files a local `dist-guest/` would hold. Note
that CI builds what is PUSHED to Droid-VM/mesa; a local worktree with
uncommitted changes only reaches the local build.

## Layout

- `plans/` — design docs and evidence packs
- `deploy/` — phone-side launchers and benchmark harness (`gfxstream/`, `drm2kgsl/`);
  start at `deploy/SETUP.md`
- `guest-patches/` — guest kernel delta as patches (in-tree reference; the
  supported install route is Droid-VM/droidvm-guest-additions) + ICD snapshots
- `mesa-cross/` — clone of Droid-VM/mesa-cross (gitignored): the guest mesa
  cross-build recipe + `mesa-variants.sh`; `mesa-<variant>/` are the worktrees
  the step-8 scripts build from
- `crosvm`/`gfxstream`/`virglrenderer`/`Virtualization` — symlinks into
  `crosvm_build/` (the soong build sandbox needs the real directories in-tree)
