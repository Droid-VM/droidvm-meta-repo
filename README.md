# droidvm-3d-accel

Meta repo for DroidVM's 3D-acceleration stack (gfxstream route): build
pipeline, cross-repo docs and the guest kernel patches. Every component lives
in its own Droid-VM repo on the `3d-accel-gfxstream` branch; this folder is
the workspace that ties them together (sub-repo folders are gitignored).

## Pipeline

| step | script | what |
|---|---|---|
| 1 | `1_build_crosvm_prepare.sh` | repo-sync the crosvm soong tree (manifest branch pins all Droid-VM forks to `3d-accel-gfxstream`) |
| 2 | `2_build_crosvm.sh` | build crosvm (+ gfxstream/virglrenderer) for the device |
| 2-1 | `2-1_collect_crosvm.sh` | collect crosvm + linked .so into `crosvm_out/` (called by step 2) |
| 2-2 | `2-2_crosvm_out_to_adb.sh` | push `crosvm_out/` to the device for manual testing |
| 2-3 | `2-3_crosvm_run_ubuntu.sh` | run the manual test VM on the device |
| 3 | `3_build_edk2.sh` | build the EDK2 firmware (`edk2-gunyah && ./build.sh -DPCI_CAM_MODE=FALSE`) |
| 4 | `4_build_gunyah_host.sh` | build the host GuestAccept module `gunyah-host-share-gki-<ver>.ko` for each GKI KMI → `gunyah_host_mod/dist/` (docker/ddk-min) |
| 5 | `5_prepare_turnip.sh` | build the host turnip Vulkan driver (mesa-tu8 gen8/KGSL, via Adreno-Tools-Drivers) → `turnip/libvulkan_freedreno.so` |
| 6 | `6_build_apk_prepare.sh` | clone app + prebuilt-root, overlay crosvm/EDK2/gunyah/turnip artifacts into `manual-build/` |
| 7 | `7_build_apk.sh` | build the DroidVM APK with the local prebuilts baked in |
| 8 | `8_build_guest_mesa.sh` | build the guest mesa (gfxstream ICD + zink) tarball, aarch64-native |

Build artifacts (crosvm step 2, EDK2 step 3, gunyah module step 4, turnip step 5) each
land in their own component dir; step 6 (`6_build_apk_prepare.sh`) is the single place that
pulls them all (crosvm/EDK2/gunyah/turnip) into `manual-build/` before the APK is packed.

Turnip is the host GPU Vulkan driver (hwvulkan HAL): without it gfxstream falls back to the
closed Adreno blob (AHB-only, `supportsDmaBuf=0`) and host-visible coherent memory fails.
Step 5 builds it from source (mesa-tu8 gen8/KGSL) via StevenMXZ/Adreno-Tools-Drivers — a
self-contained build (own NDK + mesa fork). See `turnip/README.md`.

## Layout

- `plans/` — design docs and evidence packs
- `guest-patches/` — guest kernel delta as patches (in-tree reference; the
  supported install route is Droid-VM/droidvm-guest-additions) + ICD snapshots
- `crosvm`/`gfxstream`/`virglrenderer` — symlinks into `crosvm_build/` (the
  soong build sandbox needs the real directories in-tree)
