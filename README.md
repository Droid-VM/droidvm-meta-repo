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
| 3 | `3_collect_crosvm.sh` | collect crosvm + linked .so into `crosvm_out/` (called by step 2) |
| 3-1 | `3-1_crosvm_out_to_adb.sh` | push `crosvm_out/` to the device for manual testing |
| 3-2 | `3-2_crosvm_run_ubuntu.sh` | run the manual test VM on the device |
| 4 | `4_build_apk_prepare.sh` | clone app + prebuilt-root, overlay crosvm/EDK2 artifacts into `manual-build/` |
| 5 | `5_build_apk.sh` | build the DroidVM APK with the local prebuilts baked in |
| 6 | `6_build_guest_mesa.sh` | build the guest mesa (gfxstream ICD + zink) tarball, aarch64-native |

EDK2 firmware is built separately: `cd edk2-gunyah && ./build.sh -DPCI_CAM_MODE=FALSE`
(step 4 picks up the resulting `edk2-gunyah.fd`).

## Layout

- `plans/` — design docs and evidence packs
- `guest-patches/` — guest kernel delta as patches (in-tree reference; the
  supported install route is Droid-VM/droidvm-guest-additions) + ICD snapshots
- `crosvm`/`gfxstream`/`virglrenderer` — symlinks into `crosvm_build/` (the
  soong build sandbox needs the real directories in-tree)
