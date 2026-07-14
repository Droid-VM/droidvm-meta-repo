#!/bin/bash
# Build the guest mesa (gfxstream Vulkan ICD + zink GL) for aarch64 guests and
# pack it as mesa-guest-aarch64.tar.gz (prefix /usr/local; unpack with
# `tar -xzf ... -C / && ldconfig` inside the guest, or let the
# droidvm-guest-additions installer do it).
#
# The build is a NATIVE aarch64 build (mirrors the known-good configuration
# from build-guest/meson-info). Run it on aarch64: inside the guest VM, an
# aarch64 box, or via `docker run --platform linux/arm64` with qemu binfmt.
set -e
cd "$(dirname "$0")"

if [ "$(uname -m)" != "aarch64" ]; then
    echo "error: guest mesa must be built on aarch64 (run inside the guest VM" >&2
    echo "or an arm64 container: docker run --platform linux/arm64 ...)" >&2
    exit 1
fi

[ -d mesa ] || git clone -b 3d-accel-gfxstream https://github.com/Droid-VM/mesa.git
cd mesa

meson setup build-guest \
    --buildtype release \
    --prefix /usr/local \
    --libdir lib/aarch64-linux-gnu \
    -Dplatforms=x11,wayland \
    -Dvulkan-drivers=gfxstream \
    -Dgallium-drivers=zink \
    -Dopengl=true -Dgbm=enabled -Dglx=dri -Degl=enabled \
    -Dshader-cache-default=true \
    -Dvulkan-manifest-per-architecture=true \
    -Dallow-fallback-for=perfetto

ninja -C build-guest
rm -rf install-guest
DESTDIR="$PWD/install-guest" ninja -C build-guest install
tar -czf ../mesa-guest-aarch64.tar.gz -C install-guest .
echo "wrote $(cd .. && pwd)/mesa-guest-aarch64.tar.gz"
