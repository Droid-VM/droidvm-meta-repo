#!/bin/bash
# The host-side flow for building the guest mesa: work out which branch, get a checkout, hand the
# PATH to the builder, collect the .deb.
#
# Everything git-shaped lives here, at the numbered-script layer. mesa-cross/ -- its own repo,
# Droid-VM/mesa-cross, cloned here along the branch chain like every other component -- is handed
# a path and never learns where it came from. So the build environment can be reasoned about
# without knowing anything about branches or remotes, the branch policy can change without
# touching the container, and the very same recipe runs in mesa-cross's GitHub Actions workflow
# (its ci-build.sh is this file's counterpart there: it clones the branch it needs instead of
# walking the chain).
#
#   source ./lib_mesa_build.sh
#   mesa_build

cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib_branch.sh
source ./lib_dist.sh

MESA_URL=${MESA_URL:-https://github.com/Droid-VM/mesa.git}
MESA_CROSS_URL=${MESA_CROSS_URL:-https://github.com/Droid-VM/mesa-cross.git}

# The recipe, and with it mesa-config.sh (meson options, package name, ICD list, version scheme --
# the one place those are written down), comes from mesa-cross. Cloned here so
# 8_build_guest_mesa.sh works from a fresh clone of the meta repo, exactly as
# 9_build_guest_addition.sh does for its component; 1_build_crosvm_prepare.sh clones it as well,
# so a full run already has it after the prepare step.
clone_at mesa-cross "$MESA_CROSS_URL"
source ./mesa-cross/mesa-config.sh

# One build now covers all three routes (-Dvulkan-drivers=gfxstream,freedreno,virtio), so this is
# one checkout of one branch. It used to be three worktrees of one clone, because the routes sat
# on unrelated upstream lines and a single checkout would have had to be re-switched -- and fully
# rebuilt -- between them. They share an upstream commit now, and the mesa-<variant>/ worktrees
# are gone; `git worktree list` in mesa/ will still show any left over from before, and
# `git worktree remove ../mesa-gfxstream` (etc.) is how to be rid of them.
mesa_build() {
    local src=mesa ver deb
    command -v docker >/dev/null || { echo "error: docker required" >&2; return 1; }

    clone_at "$src" "$MESA_URL"
    ver=$(mesa_pkg_version "$src") || return 1
    echo "==> mesa: $src @ $(git -C "$src" rev-parse --abbrev-ref HEAD) -> $ver"

    mkdir -p "$DIST"
    bash mesa-cross/build.sh "$PWD/$src" "$ver" "$PWD/$DIST" || return 1

    deb=$(ls -t "$DIST"/${MESA_PKG}_*_arm64.deb 2>/dev/null | head -1)
    [ -n "$deb" ] || { echo "error: the build produced no .deb" >&2; return 1; }
    dist_add "$deb"
    dist_report
}
