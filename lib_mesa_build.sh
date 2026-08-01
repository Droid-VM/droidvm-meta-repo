#!/bin/bash
# The host-side flow for building ONE guest mesa variant: work out which branch, get a checkout,
# hand the PATH to the builder, collect the .deb.
#
# Everything git-shaped lives here, at the numbered-script layer. mesa-cross/ is handed a path and
# never learns where it came from -- so the build environment can be reasoned about without
# knowing anything about branches, worktrees or remotes, and the branch policy can change without
# touching the container.
#
# It is a shared function rather than a copy in each 8_build_guest_mesa_*.sh because the two
# variants must differ ONLY in the meson options that make them different routes. A duplicated
# flow is where "the drm2kgsl build quietly checks out a different branch" comes from.
#
#   source ./lib_mesa_build.sh
#   mesa_build_variant gfxstream

cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib_branch.sh
source ./mesa-variants.sh
source ./lib_dist.sh

MESA_URL=${MESA_URL:-https://github.com/Droid-VM/mesa.git}

mesa_build_variant() {
    local v=$1 src ver deb
    case $v in gfxstream|drm2kgsl) ;; *) echo "error: unknown variant '$v'" >&2; return 2 ;; esac
    command -v docker >/dev/null || { echo "error: docker required" >&2; return 1; }

    # One clone, two worktrees. The variants' branches share no history (26.0.3 for gfxstream,
    # 26.3.0-devel for drm2kgsl -- unrelated upstreams), so a single checkout would have to be
    # re-switched and fully rebuilt every time you alternate between them.
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
