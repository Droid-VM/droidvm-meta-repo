#!/bin/bash
# The host-side flow for building ONE guest mesa variant: work out which branch, get a checkout,
# hand the PATH to the builder, collect the .deb.
#
# Everything git-shaped lives here, at the numbered-script layer. mesa-cross/ -- its own repo,
# Droid-VM/mesa-cross, cloned here along the branch chain like every other component -- is handed
# a path and never learns where it came from. So the build environment can be reasoned about
# without knowing anything about branches, worktrees or remotes, the branch policy can change
# without touching the container, and the very same recipe runs in mesa-cross's GitHub Actions
# workflow (its ci-build.sh is this file's counterpart there: it clones the one mesa branch it
# needs instead of walking the chain and sharing worktrees).
#
# It is a shared function rather than a copy in each 8_build_guest_mesa_*.sh because the variants
# must differ ONLY in the meson options that make them different routes. A duplicated flow is
# where "the drm2kgsl build quietly checks out a different branch" comes from.
#
#   source ./lib_mesa_build.sh
#   mesa_build_variant gfxstream

cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib_branch.sh
source ./lib_dist.sh

MESA_URL=${MESA_URL:-https://github.com/Droid-VM/mesa.git}
MESA_CROSS_URL=${MESA_CROSS_URL:-https://github.com/Droid-VM/mesa-cross.git}

# The recipe, and with it mesa-variants.sh (meson options, package names, ICD paths, version
# scheme -- the one place those are written down), come from mesa-cross. Cloned here so
# 8_build_guest_mesa_*.sh works from a fresh clone of the meta repo, exactly as
# 9_build_guest_addition.sh does for its component; 1_build_crosvm_prepare.sh clones it as well,
# so a full run already has it after the prepare step.
clone_at mesa-cross "$MESA_CROSS_URL"
source ./mesa-cross/mesa-variants.sh

# mesa_worktree <variant> -- print the path to a checkout of that variant's branch, creating a
# git worktree beside the main mesa/ checkout if needed. One clone, three trees: the branches
# share no history (26.0.3 for gfxstream/venus, 26.3.0-devel for drm2kgsl), so a single checkout
# would have to be re-switched (and fully rebuilt) between them.
mesa_worktree() {
    local v=$1 br dir
    br=$(mesa_variant_branch "$v") || return 1
    dir="mesa-$v"
    if [ ! -d "$dir" ]; then
        git -C mesa fetch -q origin "$br:refs/remotes/origin/$br" 2>/dev/null || true
        git -C mesa worktree add -f "../$dir" "$br" >&2
    fi
    echo "$dir"
}

mesa_build_variant() {
    local v=$1 src ver deb
    case $v in gfxstream|drm2kgsl|venus) ;; *) echo "error: unknown variant '$v'" >&2; return 2 ;; esac
    command -v docker >/dev/null || { echo "error: docker required" >&2; return 1; }

    clone_at mesa "$MESA_URL"
    src=$(mesa_worktree "$v") || return 1
    ver=$(mesa_pkg_version "$src") || return 1
    echo "==> $v: $src @ $(mesa_variant_branch "$v") -> $ver"

    mkdir -p "$DIST"
    bash mesa-cross/build.sh "$v" "$PWD/$src" "$ver" "$PWD/$DIST" || return 1

    deb=$(ls -t "$DIST"/$(mesa_variant_pkg "$v")_*_arm64.deb 2>/dev/null | head -1)
    [ -n "$deb" ] || { echo "error: the build produced no .deb" >&2; return 1; }
    dist_add "$deb"
    dist_report
}
