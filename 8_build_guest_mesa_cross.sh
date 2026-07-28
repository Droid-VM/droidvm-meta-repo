#!/bin/bash
# Cross-compile the aarch64 guest mesa (gfxstream Vulkan ICD + zink GL) from an
# x86_64 host -- native x86 compiler emitting aarch64, NO qemu emulation, so it
# is much faster than the aarch64-native 8_build_guest_mesa.sh (which needs an
# arm64 box or `docker run --platform linux/arm64` + qemu binfmt).
#
# Output: mesa-guest-aarch64.tar.gz (prefix /usr/local) -- identical layout to
# the native build, unpacked in the guest with `tar -xzf ... -C / && ldconfig`
# or by the droidvm-guest-additions installer (DROIDVM_MESA_URL).
#
# Needs: docker. Override the resolute base if the tag differs:
#   BASE=ubuntu:devel bash 8_build_guest_mesa_cross.sh
set -e
cd "$(dirname "$0")"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
IMG=droidvm-mesa-cross

command -v docker >/dev/null || { echo "error: docker required" >&2; exit 1; }
[ -d mesa ] || git clone -b "$BRANCH" https://github.com/Droid-VM/mesa.git

# Build the cross env image once (cached afterwards).
echo "==> building cross env image ($IMG, base ${BASE:-ubuntu:26.04})"
docker build -t "$IMG" --build-arg BASE="${BASE:-ubuntu:26.04}" \
    -f mesa-cross/Dockerfile.mesa-cross mesa-cross

# Cross-build mesa in it (source + cross file + repo root bind-mounted).
echo "==> cross-building mesa"
docker run --rm \
    -v "$PWD/mesa:/work/mesa" \
    -v "$PWD/mesa-cross:/work/cross" \
    -v "$PWD:/work/out" \
    "$IMG" bash /work/cross/build-in-container.sh

echo "==> wrote $PWD/mesa-guest-aarch64.tar.gz"
