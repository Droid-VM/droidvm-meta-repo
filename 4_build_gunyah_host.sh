#!/bin/bash
# Build the host GuestAccept kernel module (gunyah-host-share-gki-<ver>.ko) for every
# supported GKI KMI -> gunyah_host_mod/dist/<kmi>/. 6_build_apk_prepare.sh overlays the
# result into DroidVM-Prebuilt-Root/manual-build (manual-build, NOT auto-build.toml), so
# the APK ships it to DATA/usr/lib/modules/<kmi>/ where the app's Kernel Module tab loads
# it (needed for crosvm --hypervisor gunyah[blob_mode=guest-accept]). Docker + the
# ddk-min images provide the per-KMI kernel headers.
set -e
cd "$(dirname "$0")"

[ -d gunyah_host_mod ] || git clone -b wip/3d-accel-gfxstream https://github.com/Droid-VM/gunyah_host_mod.git
cd gunyah_host_mod
./build.sh arm64
