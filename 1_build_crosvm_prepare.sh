#!/bin/bash
# Pull the crosvm soong tree via the manifest, then check the Droid-VM forks out along
# this meta repo's branch chain (see lib_branch.sh). The manifest follows the same chain
# as every other component: which AOSP projects the tree needs is itself branch-specific
# work -- a branch that starts linking a new platform library has to add the projects that
# build it -- so pinning every branch to one manifest would make that change land on
# branches that cannot use it. A branch that has not published a manifest of its own gets
# the stable one, like any other component.
set -e
cd "$(dirname "$0")"
source ./lib_branch.sh

MANIFEST_URL=https://github.com/Droid-VM/crosvm-minimal-manifest.git
MANIFEST_BRANCH=$(pick "$MANIFEST_URL" $(branch_chain))
[ -n "$MANIFEST_BRANCH" ] || {
    echo "error: $MANIFEST_URL has none of: $(branch_chain)" >&2
    exit 1
}
clone_at crosvm-minimal-manifest "$MANIFEST_URL"
clone_at droidvm-guest-additions https://github.com/Droid-VM/droidvm-guest-additions.git
clone_at mesa https://github.com/Droid-VM/mesa.git
# The guest mesa build recipe (cross container, packaging, mesa-config.sh). Step 8 clones it
# too if it is missing, so it still works on its own; fetching it here means the prepare step
# delivers every component, which is what "prepare" promises.
clone_at mesa-cross https://github.com/Droid-VM/mesa-cross.git

mkdir -p crosvm_build
cd crosvm_build
repo init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" -m crosvm-minimal.xml --depth 1
repo sync -c
cd ..

# Convenience entries: one folder per Droid-VM org repo. The soong-tree repos
# must physically live inside crosvm_build (the build sandbox can't follow
# out-of-tree symlinks), so these just point in.
ln -sfn crosvm_build/external/crosvm                 crosvm
ln -sfn crosvm_build/hardware/google/gfxstream       gfxstream
ln -sfn crosvm_build/external/virglrenderer          virglrenderer
ln -sfn crosvm_build/packages/modules/Virtualization Virtualization

# Check each Droid-VM fork out along the branch chain. The manifest only pins a base; the
# dev work lives on this meta repo's branch, and a fork that does not carry it falls back
# to its stable branch (see lib_branch.sh). If a fork has neither, the manifest revision
# is kept rather than failing the sync.
for p in external/crosvm hardware/google/gfxstream external/virglrenderer packages/modules/Virtualization \
         external/libvncserver external/zstd external/virtio-media; do
    checkout_soong "crosvm_build/$p" "$(basename "$p")"
done
