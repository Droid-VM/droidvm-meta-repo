#!/bin/bash
# VPU dev rig: install a freshly built crosvm_out/ into the DroidVM app payload on the phone.
#
#   push_crosvm.sh [--dry-run] [--force] [--out <dir>]
#
# --dry-run  print every decision and md5 comparison, change nothing
# --force    install even while a crosvm is running (see the guard below)
# --out      source directory (default <repo>/crosvm_out)
#
# Two hazards this script exists to avoid.
#
# 1. adb push into a root-owned directory FAILS SILENTLY -- adb reports "1 file pushed" and the
#    file on the device is unchanged (deploy/SETUP.md). So everything is pushed into the
#    shell-writable staging dir /data/local/tmp/crosvm_vpu.new first, `su cp`d into place, and
#    md5-verified on BOTH sides of that copy.
#
# 2. A platform library in $APP/usr/lib is not dead weight, it is a shadow: the daemon runs
#    crosvm with LD_LIBRARY_PATH pointing there, and it is searched before /system/lib64, so our
#    copy answers for every consumer including the platform's own libraries. That has cost twice
#    already -- a stale libgui.so broke libmediandk.so's H.264 encoder, and our older libc++.so
#    hid std::__1::__hash_memory from libaudiobase.so and made crosvm unlinkable on Android 17
#    (6_build_apk_prepare.sh:29-48, which deletes eleven such libs from the APK payload). So a
#    .so is installed here ONLY IF the app's usr/lib already has one by that name: the APK is the
#    authority on which libraries may exist in that directory, and this script never adds one.
set -u
SP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SP/lib.sh"

USAGE_RC=2
usage() {  # print the file's own header comment, up to the first line of code
    awk 'NR>1 && !/^#/ {exit} NR>1 {sub(/^# ?/, ""); print}' "$0"
    exit "$USAGE_RC"
}

DRY=0; FORCE=0; OUT="$REPO/crosvm_out"
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1 ;;
        --force)   FORCE=1 ;;
        --out)     shift; OUT=${1:?--out needs a directory} ;;
        -h|--help) USAGE_RC=0; usage ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

STAGE=/data/local/tmp/crosvm_vpu.new
STAMP=$(date +%Y%m%d-%H%M)
[ -d "$OUT" ] || die "no such directory: $OUT"
[ -f "$OUT/crosvm" ] || die "$OUT has no crosvm binary -- run 2_build_crosvm.sh first"

adb_wait
say() { if [ "$DRY" = 1 ]; then echo "DRY: $*"; else echo "$*"; fi; }
run() { if [ "$DRY" = 1 ]; then echo "DRY: su -c $*"; else asu "$*"; fi; }

# Overwriting the binary of a running crosvm is both pointless (the running VM keeps the old
# mapping) and dangerous (an ETXTBSY mid-copy leaves a truncated crosvm behind). Only one crosvm
# may run at a time on this phone anyway.
RUNNING=$(asu "pidof crosvm")
if [ -n "$RUNNING" ] && [ "$FORCE" = 0 ]; then
    [ "$DRY" = 1 ] || die "crosvm is running (pid $RUNNING); stop the VM first (vm.sh stop <name>) or pass --force"
    say "crosvm is running (pid $RUNNING) -- a real run would refuse without --force"
fi

# The app's usr/lib decides which .so may be installed; see hazard 2 above.
HAVE=$(asu "ls -1 $APP/usr/lib")
[ -n "$HAVE" ] || die "cannot list $APP/usr/lib on $PHONE (is the app installed?)"

say "staging into $STAGE"
[ "$DRY" = 1 ] || ash "mkdir -p $STAGE"

rc=0
install_one() {  # install_one <local file> <dest path> [mode]
    local src=$1 dest=$2 mode=${3:-755} base want got
    base=$(basename "$src")
    want=$(md5sum "$src" | awk '{print $1}')
    got=$(asu "md5sum $dest 2>/dev/null" | awk '{print $1}')
    if [ "$got" = "$want" ]; then
        echo "  ok       $dest (unchanged, $want)"
        return 0
    fi
    say "  install  $dest  ($got -> $want)"
    if [ "$DRY" = 1 ]; then return 0; fi
    apush "$src" "$STAGE/$base" || { echo "  !! push $base failed"; rc=1; return 1; }
    got=$(asu "md5sum $STAGE/$base" | awk '{print $1}')
    [ "$got" = "$want" ] || { echo "  !! staged $STAGE/$base is $got, want $want"; rc=1; return 1; }
    asu "cp -f $STAGE/$base $dest && chmod $mode $dest && sync"
    got=$(asu "md5sum $dest" | awk '{print $1}')
    [ "$got" = "$want" ] || { echo "  !! installed $dest is $got, want $want"; rc=1; return 1; }
    echo "  verified $dest $got"
}

# The binary, with a dated backup of whatever is there now.
if [ -n "$(asu "[ -f $APP/usr/bin/crosvm ] && echo y")" ]; then
    say "backup   $APP/usr/bin/crosvm -> crosvm.bak.$STAMP"
    run "cp -f $APP/usr/bin/crosvm $APP/usr/bin/crosvm.bak.$STAMP"
fi
install_one "$OUT/crosvm" "$APP/usr/bin/crosvm" 755

# The libraries the app already carries -- and only those.
for so in "$OUT"/*.so; do
    [ -e "$so" ] || continue
    base=$(basename "$so")
    if ! printf '%s\n' "$HAVE" | grep -qx "$base"; then
        echo "  skip     $base (not in $APP/usr/lib -- the APK payload does not ship it)"
        continue
    fi
    install_one "$so" "$APP/usr/lib/$base" 644
done

if [ "$DRY" = 1 ]; then
    echo "dry run: nothing was changed"
else
    asu "rm -rf $STAGE"
    [ "$rc" = 0 ] && echo "pushed and verified" || echo "FAILED -- see the !! lines above"
fi
exit "$rc"
