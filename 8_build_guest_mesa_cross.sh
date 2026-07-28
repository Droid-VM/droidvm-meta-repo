#!/bin/bash
# Cross-compile the aarch64 guest mesa from an x86_64 host -- native x86 compiler
# emitting aarch64, NO qemu emulation, so it is much faster than the aarch64-native
# 8_build_guest_mesa.sh (which needs an arm64 box or `docker run --platform linux/arm64`
# + qemu binfmt).
#
# Output, per variant (identical layout to the native build; see mesa-variants.sh):
#   gfxstream -> mesa-guest-gfxstream-aarch64.tar.gz (prefix /usr/local)
#   kgsl      -> mesa-guest-kgsl-aarch64.tar.gz      (prefix /opt/mesa-kgsl)
# Unpacked in the guest with `tar -xzf ... -C / && ldconfig` or by the
# droidvm-guest-additions installer (DROIDVM_MESA_URL).
#
# Needs: docker. Override the resolute base if the tag differs:
#   BASE=ubuntu:devel bash 8_build_guest_mesa_cross.sh
#   MESA_VARIANT=kgsl bash 8_build_guest_mesa_cross.sh
set -e
cd "$(dirname "$0")"
source ./lib_branch.sh
source ./mesa-variants.sh
IMG=droidvm-mesa-cross

command -v docker >/dev/null || { echo "error: docker required" >&2; exit 1; }
clone_at mesa https://github.com/Droid-VM/mesa.git

# Build the cross env image once (cached afterwards).
echo "==> building cross env image ($IMG, base ${BASE:-ubuntu:26.04})"
docker build -t "$IMG" --build-arg BASE="${BASE:-ubuntu:26.04}" \
    -f mesa-cross/Dockerfile.mesa-cross mesa-cross

for v in $(mesa_variants); do
    src=$(mesa_worktree "$v")
    echo "==> cross-building mesa variant '$v' from $src"
    # The worktree's .git is a file pointing at an absolute host path, so git is not
    # usable inside the container. mesa takes its version from the VERSION file, so
    # nothing in the build needs it.
    docker run --rm \
        -v "$PWD/$src:/work/mesa" \
        -v "$PWD/mesa-cross:/work/cross" \
        -v "$PWD:/work/out" \
        "$IMG" bash /work/cross/build-in-container.sh "$v"
    echo "==> wrote $PWD/$(mesa_variant_tarball "$v")"
done
