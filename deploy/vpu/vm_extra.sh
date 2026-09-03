#!/bin/bash
# VPU dev rig: edit a stored VM's `extra_options` -- the only seam for handing crosvm a flag the
# app does not know about yet (VPU_DESIGN.md §9). Until the app grows real VPU settings (WP A1),
# this is how --pre-alloc media pools and --virtio-media get onto the command line.
#
#   vm_extra.sh show  <name|id>
#   vm_extra.sh set   <name|id> <arg> [arg...]   replaces the whole array
#   vm_extra.sh clear <name|id>
#
# Example:
#   vm_extra.sh set Ubuntu-resolute \
#     --pre-alloc drm-host-mb=64,gpu-guest-mb=1024,gpu-guest-prealloc-mb=1024,\
#gpu-guest-step-mb=0,gpu-guest-max-grants=0,media-host-mb=256,media-guest-mb=128 \
#     --virtio-media kind=loopback
#
# TWO THINGS TO KNOW.
#
# 1. `--pre-alloc` IS SINGLE-VALUED. extra_options are appended AFTER the daemon's own arguments,
#    so a second --pre-alloc overrides the daemon's rather than merging with it. The daemon emits
#    one built from the VM's gpu_*/drm_* fields (on the lab VM today:
#    drm-host-mb=64,gpu-guest-mb=1024,gpu-guest-prealloc-mb=1024,gpu-guest-step-mb=0,
#    gpu-guest-max-grants=0 -- read it back with `vm.sh argv <name>`). If you add media keys you
#    MUST pass the full merged string, exactly as in the example above; passing only the media
#    keys silently drops the GPU pools and the guest loses its GPU.
#
# 2. `vm_modify` refuses a VM that is not STOPPED (VMInstanceStore.java:105-108), and it writes
#    only the daemon's in-memory store -- vms.json on disk is written by the app's editor alone
#    (app-daemon.md §5.4). So a change made here survives until the daemon restarts, and a daemon
#    restart stops every VM (Daemon.cleanup). Re-apply after any restart.
set -u
SP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SP/lib.sh"

USAGE_RC=2
usage() {  # print the file's own header comment, up to the first line of code
    awk 'NR>1 && !/^#/ {exit} NR>1 {sub(/^# ?/, ""); print}' "$0"
    exit "$USAGE_RC"
}

VERB=${1:-}; NAME=${2:-}
if [ -z "$VERB" ] || [ -z "$NAME" ]; then usage; fi
shift 2
adb_wait

INFO=$(vm_info "$NAME") || exit 1
ID=$(vm_field "$INFO" id)
STATE=$(vm_state "$INFO")

show() {
    local cfg
    cfg=$(dvm get "$ID") || exit 1
    printf '%s' "$cfg" | python3 -c '
import json,sys
opts = (json.load(sys.stdin).get("data") or {}).get("extra_options") or []
print("extra_options: %d" % len(opts))
for o in opts:
    print("  %s" % o)'
}

apply() {  # apply <new option>...
    [ "$STATE" = stopped ] || die "$NAME is $STATE; vm_modify only accepts a STOPPED VM (VMInstanceStore.java:105-108) -- run: $SP/vm.sh stop $NAME"
    local cfg tmp
    cfg=$(dvm get "$ID") || exit 1
    tmp=$(mktemp -t vm_extra.XXXXXX.json) || die "mktemp failed"
    trap 'rm -f "$tmp"' EXIT
    printf '%s' "$cfg" | python3 -c '
import json,sys
cfg = json.load(sys.stdin).get("data")
if not cfg:
    sys.exit("vm_get returned no config")
# python3 -c CODE a b c  =>  sys.argv == ["-c", "a", "b", "c"]
cfg["extra_options"] = sys.argv[1:]
sys.stdout.write(json.dumps(cfg))' "$@" > "$tmp" || exit 1
    dvm modify "$tmp" >/dev/null || exit 1
    show
}

case "$VERB" in
show)  show ;;
set)   [ "$#" -gt 0 ] || die "set: give me the arguments to store (use 'clear' to empty the array)"
       apply "$@" ;;
clear) apply ;;
*)     usage ;;
esac
