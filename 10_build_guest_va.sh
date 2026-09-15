#!/bin/bash
# Build the guest VA-API backend.
#
#   bash 10_build_guest_va.sh
#
# Checks out Droid-VM/libva-v4l2 at this repo's branch, cross-builds it (native x86 compiler
# emitting aarch64 -- no emulation), and leaves libva-v4l2_<ver>_arm64.deb in dist-guest/ along
# with everything else a guest needs. The package carries two files:
#
#   /usr/lib/aarch64-linux-gnu/dri/v4l2_drv_video.so   the libva backend
#   /etc/profile.d/droidvm-va.sh                       LIBVA_DRIVER_NAME=v4l2 (+ the gst knob)
#
# WHO THIS IS FOR. Steps 8 and 9 already give the guest a GPU and the V4L2 codec nodes, and that
# is enough for clients that speak V4L2 M2M themselves -- ffmpeg `h264_v4l2m2m`, GStreamer
# `v4l2videodec`. It is not enough for the clients that only speak VA-API: Chromium and Firefox,
# mpv `--hwdec=vaapi`, ffmpeg `-hwaccel vaapi`, GStreamer's `va*` elements. Those need a libva
# backend, and the guest has none -- step 8's mesa is built -Dgallium-drivers=zink,llvmpipe with
# no VA state tracker, and libva's default lookup (DRM driver name `virtio_gpu` ->
# virtio_gpu_drv_video.so) finds nothing. This package is that backend.
#
# WHY IT IS ITS OWN REPO AND NOT A MESA OPTION: design plans/VPU_DESIGN.md 7.6. Short version --
# Mesa's VA is a Gallium frontend that needs a pipe driver under it, /dev/videoN is not one, and
# enabling it would couple this work to the three 3d-accel mesa branches and a full cross build
# per line changed. The libva backend ABI is small and stable, and Droid-VM/libva-v4l2 is a fork
# of the upstream that is already heading this way, so the work can go back upstream.
#
# The build recipe lives in the component repo (libva-v4l2/packaging/ + build-packages.sh), as
# the guest additions' does and unlike mesa's, so a checkout of that repo builds on its own.
# Docker is required; the container is Ubuntu resolute with arm64 multiarch, same shape as
# mesa-cross.
set -e
cd "$(dirname "$0")"
source ./lib_branch.sh
source ./lib_dist.sh

# Same treatment as steps 8 and 9: the checkout is this layer's job, so the packaging script
# inside the repo stays runnable on its own against whatever tree you have.
# 1_build_crosvm_prepare.sh clones it too, so a full run already has it after the prepare step.
clone_at libva-v4l2 https://github.com/Droid-VM/libva-v4l2.git

echo "==> packaging the guest VA-API backend"
( cd libva-v4l2 && ./build-packages.sh deb )

deb=$(ls -t libva-v4l2/libva-v4l2_*_arm64.deb 2>/dev/null | head -1)
[ -n "$deb" ] || { echo "error: build-packages.sh produced no .deb" >&2; exit 1; }
dist_add "$deb"
dist_report
