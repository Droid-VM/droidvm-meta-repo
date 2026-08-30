#!/bin/bash
# Pull the crosvm soong tree via the manifest, then check the Droid-VM forks out along
# this meta repo's branch chain (see lib_branch.sh). The manifest follows the same chain
# as every other component: which AOSP projects the tree needs is itself branch-specific
# work -- a branch that starts linking a new platform library has to add the projects that
# build it -- so pinning every branch to one manifest would make that change land on
# branches that cannot use it. main stays in the chain as the last resort, so a branch that
# has not published a manifest of its own still gets the stable one.
set -e
cd "$(dirname "$0")"
source ./lib_branch.sh

MANIFEST_URL=https://github.com/Droid-VM/crosvm-minimal-manifest.git
MANIFEST_BRANCH=$(pick "$MANIFEST_URL" $(branch_chain) main)
[ -n "$MANIFEST_BRANCH" ] || {
    echo "error: $MANIFEST_URL has none of: $(branch_chain) main" >&2
    exit 1
}
clone_at crosvm-minimal-manifest "$MANIFEST_URL" main
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

# A project whose manifest NAME changes keeps pointing at its old object store, and repo
# refuses to fetch rather than rebind it:
#
#   error: hooks is different in .repo/projects/external/zstd.git
#                            vs .repo/project-objects/zstd.git
#
# That is what happened when external/zstd moved from platform/external/zstd (AOSP) to zstd
# (the Droid-VM fork). A fresh workspace never sees it -- there is no old binding to collide
# with -- so this only bites a checkout that predates the rename. Say so with the command,
# rather than letting repo's message stand on its own: it warns about losing "the work tree's
# git metadata", which sounds worse than it is when the project carries nothing local.
for stale in .repo/project-objects/platform/external/zstd.git; do
    [ -e "crosvm_build/$stale" ] || continue
    echo ">>> external/zstd was renamed in the manifest; its old object store is still here." >&2
    echo "    Nothing of ours lives in that project, so rebinding it is safe:" >&2
    echo "        (cd crosvm_build && repo sync --force-sync external/zstd)" >&2
    echo "    Check first if you are unsure: git -C crosvm_build/external/zstd status" >&2
done

# Check each Droid-VM fork out along the branch chain. The manifest only pins a stable
# base; the dev work lives on the trunk, and a variant branch that a component does not
# carry falls back to it (see lib_branch.sh). If a component has none of them, the
# manifest revision is kept rather than failing the sync.
for p in external/crosvm hardware/google/gfxstream external/virglrenderer packages/modules/Virtualization \
         external/libvncserver external/zstd; do
    checkout_soong "crosvm_build/$p" "$(basename "$p")"
done
