#!/bin/bash
# One output directory for everything a guest needs, with checksums.
#
# The build steps each drop their .deb here rather than leaving it wherever it happened to be
# written, so "run the numbered scripts, then copy dist-guest/ to the guest" is the whole
# deploy story and there is no step where you have to know which file came from which script.
#
# The checksums are not ceremony: scp into these guests has been seen to TRUNCATE without
# reporting an error, and a half-copied .deb fails in ways that look like a code bug. `md5sum -c
# MD5SUMS` on the far side is the cheapest way to rule that out first.
#
# Source after `cd` to the repo root.

DIST=${DIST:-dist-guest}

# dist_add <file>... -- copy into the dist dir and refresh MD5SUMS.
dist_add() {
    mkdir -p "$DIST"
    local f
    for f in "$@"; do
        [ -f "$f" ] || { echo "dist: no such file: $f" >&2; return 1; }
        # Replace any older build of the SAME package rather than accumulating versions: the
        # deploy step globs by package name, and two matches is how you install last week's
        # driver against this week's mesa without noticing.
        local base stem
        base=$(basename "$f")
        stem=${base%%_*}
        find "$DIST" -maxdepth 1 -name "${stem}_*.deb" ! -name "$base" -delete 2>/dev/null || true
        # A builder that already writes here (the mesa container is given this directory as its
        # output mount) hands us a file that IS the destination; copying it onto itself is an
        # error, not a no-op, and under `set -e` it would abort the build right after it succeeded.
        [ "$f" -ef "$DIST/$base" ] || cp -f "$f" "$DIST/"
    done
    ( cd "$DIST" && md5sum ./*.deb > MD5SUMS 2>/dev/null ) || true
}

# dist_report -- print what a guest would now get, and what is still missing.
dist_report() {
    echo
    echo "==> $DIST/"
    local f n=0
    for f in "$DIST"/*.deb; do
        [ -e "$f" ] || continue
        printf '    %-56s %s\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)"
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] || echo "    (empty)"

    local missing=()
    [ -e "$DIST"/droidvm-guest-additions_*.deb ] 2>/dev/null || missing+=("9_build_guest_addition.sh")
    [ -e "$DIST"/mesa-guest-gfxstream_*.deb ]   2>/dev/null || missing+=("8_build_guest_mesa_gfx.sh")
    [ -e "$DIST"/mesa-guest-drm2kgsl_*.deb ]    2>/dev/null || missing+=("8_build_guest_mesa_drm2kgsl.sh")
    [ -e "$DIST"/mesa-guest-venus_*.deb ]       2>/dev/null || missing+=("8_build_guest_mesa_venus.sh")
    if [ ${#missing[@]} -gt 0 ]; then
        echo "    still to run: ${missing[*]}"
    else
        echo
        echo "    complete. Copy to the guest and verify:"
        echo "      scp $DIST/* root@172.22.68.12:/root/"
        echo "      ssh root@172.22.68.12 'cd /root && md5sum -c MD5SUMS'"
    fi
}
