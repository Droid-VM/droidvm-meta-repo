#!/bin/bash
# Pull the crosvm soong tree via the stable manifest (its main branch), then check the
# Droid-VM forks out along this meta repo's branch chain (see lib_branch.sh). That way
# every dev branch reuses the same manifest instead of re-pinning it per branch, and a
# variant branch inherits the trunk from any component that does not carry one.
set -e
cd "$(dirname "$0")"
source ./lib_branch.sh

[ -d crosvm-minimal-manifest ] || git clone https://github.com/Droid-VM/crosvm-minimal-manifest.git
clone_at droidvm-guest-additions https://github.com/Droid-VM/droidvm-guest-additions.git
# mesa is the one component with genuinely different content per variant (two unrelated
# upstreams), so its variant branch is real rather than an alias of the trunk.
clone_at mesa https://github.com/Droid-VM/mesa.git
# The guest mesa build recipe (cross container, packaging, mesa-config.sh). Step 8 clones it
# too if it is missing, so it still works on its own; fetching it here means the prepare step
# delivers every component, which is what "prepare" promises.
clone_at mesa-cross https://github.com/Droid-VM/mesa-cross.git

mkdir -p crosvm_build
cd crosvm_build
repo init -u https://github.com/Droid-VM/crosvm-minimal-manifest.git -b main -m crosvm-minimal.xml --depth 1
repo sync -c
cd ..

# Convenience entries: one folder per Droid-VM org repo. The soong-tree repos
# must physically live inside crosvm_build (the build sandbox can't follow
# out-of-tree symlinks), so these just point in.
ln -sfn crosvm_build/external/crosvm                 crosvm
ln -sfn crosvm_build/hardware/google/gfxstream       gfxstream
ln -sfn crosvm_build/external/virglrenderer          virglrenderer
ln -sfn crosvm_build/packages/modules/Virtualization Virtualization

# Check each Droid-VM fork out along the branch chain. The manifest only pins a stable
# base; the dev work lives on the trunk, and a variant branch that a component does not
# carry falls back to it (see lib_branch.sh). If a component has none of them, the
# manifest revision is kept rather than failing the sync.
for p in external/crosvm hardware/google/gfxstream external/virglrenderer packages/modules/Virtualization; do
    checkout_soong "crosvm_build/$p" "$(basename "$p")"
done



