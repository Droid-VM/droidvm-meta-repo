#!/bin/bash
# Build the guest mesa for aarch64 guests and pack it per variant as a .deb:
#   gfxstream -> mesa-guest-gfxstream_<ver>_arm64.deb
#   drm2kgsl  -> mesa-guest-drm2kgsl_<ver>_arm64.deb
# Both install to /usr/local and Conflict with each other, so a guest holds one
# at a time. See mesa-variants.sh for why this is a package and not a tarball.
#
# The build is a NATIVE aarch64 build (mirrors the known-good configuration
# from build-guest/meson-info). Run it on aarch64: inside the guest VM, an
# aarch64 box, or via `docker run --platform linux/arm64` with qemu binfmt.
# On an x86_64 host use 8_build_guest_mesa_cross.sh instead.
#
#   MESA_VARIANT=gfxstream   build just one (default: whatever this branch implies)
set -e
cd "$(dirname "$0")"
source ./lib_branch.sh
source ./mesa-variants.sh

if [ "$(uname -m)" != "aarch64" ]; then
    echo "error: guest mesa must be built on aarch64 (run inside the guest VM" >&2
    echo "or an arm64 container: docker run --platform linux/arm64 ...)" >&2
    exit 1
fi

clone_at mesa https://github.com/Droid-VM/mesa.git

# The container script is the single implementation of "configure, build, package"; the native
# path differs only in having no cross file, so reuse it rather than keeping a second copy that
# drifts. /work/out is this repo, /work/mesa the variant worktree.
for v in $(mesa_variants); do
    src=$(mesa_worktree "$v")
    echo "==> building guest mesa variant '$v' from $src (native aarch64)"
    MESA_NATIVE=1 WORK_OUT="$PWD" WORK_MESA="$PWD/$src" \
        bash mesa-cross/build-in-container.sh "$v" "$(mesa_pkg_version "$src")"
done
