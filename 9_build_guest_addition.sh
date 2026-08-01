#!/bin/bash
# Build the DroidVM guest additions .deb (one package, two kernel modules).
#
#   bash 9_build_guest_addition.sh
#
# Produces droidvm-guest-additions_<ver>_arm64.deb in dist-guest/. It carries:
#
#   virtio-gpu    the DroidVM virtio-gpu driver, which knows about the host-owned and
#                 guest-owned memory pools the DT describes. It replaces the in-tree driver of
#                 the same name by ranking ahead of it in depmod's search order.
#   gunyah_guest  the Gunyah resource-manager client and the virtio-gunyah-accept transport the
#                 host drives to accept memparcels on the guest's behalf.
#
# NOTHING IS COMPILED HERE. This is a DKMS source package: the .deb ships the C sources to
# /usr/src and dkms builds them ON THE GUEST against that guest's own kernel headers. So it is
# step 9 rather than a cross-build like step 8, and it works on any guest kernel the sources
# support without a matching toolchain here.
set -e
cd "$(dirname "$0")"
source ./lib_branch.sh
source ./lib_dist.sh

# Same treatment as the mesa steps: the checkout is this layer's job, so the packaging script
# inside the repo stays runnable on its own against whatever tree you have. Without this a fresh
# clone of the meta repo had no droidvm-guest-additions/ at all and the step just failed.
clone_at droidvm-guest-additions https://github.com/Droid-VM/droidvm-guest-additions.git

echo "==> packaging guest additions"
( cd droidvm-guest-additions && ./build-packages.sh deb )

deb=$(ls -t droidvm-guest-additions/droidvm-guest-additions_*_arm64.deb 2>/dev/null | head -1)
[ -n "$deb" ] || { echo "error: build-packages.sh produced no .deb" >&2; exit 1; }
dist_add "$deb"
dist_report
