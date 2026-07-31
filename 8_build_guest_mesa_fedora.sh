#!/bin/bash
# Build the aarch64 guest mesa AGAINST FEDORA and package it as an .rpm, for Fedora-family guests.
#
#   gfxstream -> mesa-guest-gfxstream-<ver>-1.aarch64.rpm
#   drm2kgsl  -> mesa-guest-drm2kgsl-<ver>-1.aarch64.rpm
#
#   bash 8_build_guest_mesa_fedora.sh                  # both variants
#   MESA_VARIANT=drm2kgsl bash 8_build_guest_mesa_fedora.sh
#   BASE=fedora:43 bash 8_build_guest_mesa_fedora.sh
#
# SLOW ON PURPOSE. This runs an aarch64 image under qemu-user binfmt, so the compiler is emulated
# and a full build takes hours where 8_build_guest_mesa_cross.sh takes minutes. That cost buys
# correctness: the packages ship .so files, and a mesa built against Ubuntu's glibc records the
# version symbols it saw there. On a Fedora with an older glibc the loader refuses them; on a newer
# one it happens to work, which is worse, because the arrangement looks sound until someone on a
# different release hits it. Fedora has no multiarch, so there is no aarch64 sysroot to cross
# against from x86_64 the way Debian offers one -- emulation is the only honest route.
#
# The build directory is separate from the cross build's (MESA_BUILDDIR), so the two targets can
# coexist in one worktree without reconfiguring meson back and forth.
#
# Needs: docker with binfmt/qemu-user for arm64 (`docker run --platform linux/arm64 alpine uname -m`
# should print aarch64).
set -e
cd "$(dirname "$0")"
source ./lib_branch.sh
source ./mesa-variants.sh
IMG=droidvm-mesa-fedora

command -v docker >/dev/null || { echo "error: docker required" >&2; exit 1; }
[ "$(docker run --rm --platform linux/arm64 alpine uname -m 2>/dev/null)" = aarch64 ] || {
    echo "error: no working arm64 emulation (install qemu-user-static + binfmt)" >&2; exit 1; }
clone_at mesa https://github.com/Droid-VM/mesa.git

echo "==> building fedora aarch64 env image ($IMG, base ${BASE:-fedora:42})"
# --network=host for the same reason the cross image needs it: BuildKit's own netns intermittently
# fails to resolve the mirrors on this host, and the symptom is a wall of dnf failures that reads
# like a mirror outage.
docker build --network=host --platform linux/arm64 -t "$IMG" \
    --build-arg BASE="${BASE:-fedora:42}" \
    -f mesa-cross/Dockerfile.mesa-fedora mesa-cross

for v in $(mesa_variants); do
    src=$(mesa_worktree "$v")
    echo "==> building mesa variant '$v' for fedora from $src (emulated, expect hours)"
    docker run --rm --platform linux/arm64 \
        -v "$PWD/$src:/work/mesa" \
        -v "$PWD/mesa-cross:/work/cross" \
        -v "$PWD:/work/out" \
        -e MESA_NATIVE=1 \
        -e MESA_PKGFMT=rpm \
        -e MESA_BUILDDIR=build-fedora \
        -e MESA_INSTDIR=install-fedora \
        "$IMG" bash /work/cross/build-in-container.sh "$v" "$(mesa_pkg_version "$src")"
done
