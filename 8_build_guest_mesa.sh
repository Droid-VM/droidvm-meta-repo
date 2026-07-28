#!/bin/bash
# Build the guest mesa for aarch64 guests and pack it per variant:
#   gfxstream -> mesa-guest-gfxstream-aarch64.tar.gz (prefix /usr/local)
#   kgsl      -> mesa-guest-kgsl-aarch64.tar.gz      (prefix /opt/mesa-kgsl)
# Unpack with `tar -xzf ... -C / && ldconfig` inside the guest, or let the
# droidvm-guest-additions installer do it. See mesa-variants.sh for why the two
# prefixes must differ.
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

for v in $(mesa_variants); do
    src=$(mesa_worktree "$v")
    prefix=$(mesa_variant_prefix "$v")
    tarball=$(mesa_variant_tarball "$v")
    echo "==> building guest mesa variant '$v' from $src (prefix $prefix)"
    (
        cd "$src"
        meson setup build-guest --prefix "$prefix" \
            "${MESA_COMMON_MESON[@]}" $(mesa_variant_meson "$v")
        ninja -C build-guest
        rm -rf install-guest
        DESTDIR="$PWD/install-guest" ninja -C build-guest install
        tar -czf "../$tarball" -C install-guest .
    )
    echo "wrote $PWD/$tarball"
done
