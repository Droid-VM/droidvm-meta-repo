#!/bin/bash
# VPU dev rig: run one of the scratch cargo harnesses, or all of them.
#
#   harness.sh <gbt|kvt|kst|mpt|vmt|acb|acc|acd|all>
#
# Why these exist. Three crates that hold VPU code cannot be tested with cargo on the dev box:
# crosvm's `devices` (a pre-existing `rand` version mismatch, logs/vpu_wp/M2.md 5.3), crosvm's
# `src/crosvm` (same tree), and the virtio-media fork's `device/` (it wants nix 0.28, zerocopy
# 0.7 and a v4l2r that builds bindgen 0.69, none of which is in this box's offline cargo cache).
# Soong builds all three for aarch64 but runs no rust_test. So each harness is a small package
# whose sources are the REAL files -- `#[path]`-included, or `[lib] path`, or lifted out by name
# in a build.rs -- with only the dependency versions swapped for ones the cache has. Nothing here
# is a copy of code under test, and nothing here reaches the network: every run is `--offline`.
#
#   gbt  devices/src/virtio/media/guest_buf.rs   (base, resources, vm_memory)
#   kvt  MediaDeviceKind + MediaDeviceConfig     (the --virtio-media command-line surface)
#   kst  devices/src/virtio/media/kill.rs        (base, anyhow)
#   mpt  devices/src/virtio/media/pool.rs        (needs vmt for the allocator trait)
#   vmt  the fork's device/ crate                (over a v4l2r built from the vendored sources)
#   acb  the Android camera backend + probe      (a type-check: it runs no tests, it compiles)
#   acc  android_codec (lib + codec_probe)        (the crate's unit tests)
#   acd  the MediaCodec decoder backend          (a type-check, like acb)
#
# Each is staged into $TMPDIR/droidvm-harness/<name> and built there, so the repo stays clean and
# `target/` survives between runs. All of them are staged whichever one you ask for, because
# mpt's and acb's manifests point at vmt's packages next door.
set -u

SP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W="$(cd "$SP/../.." && pwd)"
SRC="$SP/harness"
ROOT="${TMPDIR:-/tmp}/droidvm-harness"
NAMES="gbt kvt kst mpt vmt acb acc acd"
JOBS="${JOBS:-32}"
TOOLCHAIN="${TOOLCHAIN:-1.88.0}"

usage() {
    echo "usage: $(basename "$0") <$(echo "$NAMES" | tr ' ' '|')|all>" >&2
    exit 2
}

# vmt is a workspace of two packages and only the fork's crate has tests worth running; v4l2r is
# there to compile against. acc's tests are android_codec's own, not the wrapper package's.
cargo_args() {
    case "$1" in
        vmt) echo "-p virtio-media" ;;
        acc) echo "-p android_codec" ;;
        *) echo "" ;;
    esac
}

# Copy the harness into the scratch dir, keeping target/ (and so the build cache) if it is there,
# and put this checkout's path where the manifests say @W@.
stage() {
    local name="$1" dest="$ROOT/$1"
    [ -d "$SRC/$name" ] || { echo "no such harness: $name" >&2; exit 2; }
    mkdir -p "$dest" || exit 1
    # Everything but target/, so a stale source file cannot survive a rename.
    find "$dest" -mindepth 1 -maxdepth 1 ! -name target -exec rm -rf {} + || exit 1
    cp -r "$SRC/$name/." "$dest/" || exit 1
    local f
    while IFS= read -r f; do
        sed -i "s#@W@#$W#g" "$f" || exit 1
    done < <(grep -rl '@W@' "$dest" --exclude-dir=target 2>/dev/null)
}

# "N passed, M failed" over every test binary and doctest run, from cargo's own summary lines.
counts() {
    awk '
        /^test result:/ {
            for (i = 1; i <= NF; i++) {
                if ($(i+1) ~ /^passed/) passed += $i
                if ($(i+1) ~ /^failed/) failed += $i
            }
            binaries++
        }
        END { printf "%d passed, %d failed, over %d test binar%s\n",
                     passed, failed, binaries, (binaries == 1 ? "y" : "ies") }
    ' "$1"
}

run_one() {
    local name="$1" log="$ROOT/$1.log" rc=0
    echo "=== $name: cargo +$TOOLCHAIN test --offline -j$JOBS $(cargo_args "$name")"
    # shellcheck disable=SC2046  # cargo_args is a word list on purpose
    ( cd "$ROOT/$name" && cargo "+$TOOLCHAIN" test --offline -j"$JOBS" $(cargo_args "$name") ) \
        > "$log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "--- $name FAILED (rc=$rc); last 30 lines of $log:"
        tail -30 "$log"
    fi
    echo "$name: $(counts "$log")  [$log]"
    return "$rc"
}

[ $# -eq 1 ] || usage
case " $NAMES " in
    *" $1 "*) want="$1" ;;
    *) [ "$1" = all ] || usage; want="$NAMES" ;;
esac

for name in $NAMES; do stage "$name"; done

failed=""
for name in $want; do
    run_one "$name" || failed="$failed $name"
done
if [ -n "$failed" ]; then
    echo "harness: FAILED:$failed"
    exit 1
fi
echo "harness: all requested harnesses passed"
