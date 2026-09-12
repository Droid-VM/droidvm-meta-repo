#!/bin/bash
# VPU dev rig: edit a stored VM's `extra_options` -- the only seam for handing crosvm a flag the
# app does not know about yet (VPU_DESIGN.md §9). Until the app grows real VPU settings (WP A1),
# this is how --pre-alloc media pools and --virtio-media get onto the command line.
#
#   vm_extra.sh show     <name|id>
#   vm_extra.sh set      <name|id> <arg> [arg...]      replaces the whole array
#   vm_extra.sh takeover <name|id> [--show] [--base <string>] <k=v[,k=v...]>... [-- <opts...>]
#   vm_extra.sh restore  <name|id>                     undo a takeover
#   vm_extra.sh clear    <name|id>
#
# Example:
#   vm_extra.sh takeover Ubuntu-resolute media-host-mb=320,media-guest-mb=192 -- \
#     --virtio-media kind=loopback,card=lb0
#
# WHY THERE IS A `takeover` AND NOT A `merge` (defect D2, logs/vpu_wp/B1-acceptance.md §8).
#
# `--pre-alloc` is `Option<PreAllocConfig>` in argh (crosvm/src/crosvm/cmdline.rs:2073). A
# repeated flag is NOT an override and NOT a merge: argh fails the whole parse with
#
#   arg parsing failed: Error parsing option '--pre-alloc' with value '...': duplicate values
#   provided
#
# before crosvm runs anything, and the VM goes straight back to `stopped`. So `extra_options` may
# carry a --pre-alloc only when the daemon emits NONE, and the daemon emits one whenever any of
# the pool keys of a Gunyah VM is non-zero (CrosvmBackendInstance.java:421-470).
#
# `takeover` IS REPEATABLE (defect D7, logs/vpu_wp/B2-acceptance.md §12). Running it a second
# time re-uses the daemon's own string from state/<vm>.json instead of re-reading the daemon log
# -- because after a takeover-launched boot the last `Executing:` line in that log is the
# TAKEOVER'S OWN command line, media keys and all, and the old code fed it back to itself and
# then refused it. The saved config keys are never overwritten by a re-takeover, so one `restore`
# still undoes any number of them. `--base <string>` overrides the whole search, and `--show`
# prints what would be sent and sends nothing.
#
# `takeover` is therefore exactly the B1 workaround, mechanised: it reads the daemon's own
# --pre-alloc, saves the config keys that produce it into deploy/vpu/state/<vm>.json, sets those
# keys to 0 so the daemon emits no --pre-alloc at all, and stores the WHOLE string -- the
# daemon's GPU keys plus the media keys you asked for -- in extra_options. The command line is
# byte-identical to what the daemon would have emitted, and `vm.sh argv | grep -c -- --pre-alloc`
# is 1. `restore` puts the saved keys back and empties extra_options.
#
# THREE THINGS TO KNOW.
#
# 1. WHILE A TAKEOVER IS ACTIVE THE HUGE-PAGE PREFLIGHT UNDER-COUNTS. PoolPreflight sizes the
#    reserve from the config keys (GuestPoolSizing.bootGuestPreallocMb), which takeover just set
#    to 0, not from the string on the command line. The VM still asks the RM for the guest pool,
#    so the reserve must cover it and nobody checked that it does. On the lab VM that is 1024 MiB
#    of the 6 GiB reserve. Keep an eye on `gh_hugepage_reserve`'s pool_avail.
#
# 2. `takeover` IS BRING-UP ONLY -- for the window before the WP A1 APK is installed. With that
#    APK and the VM's VPU switch on, the daemon emits media-host-mb/media-guest-mb itself and
#    extra_options must carry NO --pre-alloc, only --virtio-media. takeover refuses in that world
#    (it sees the media keys in the daemon's string and stops).
#
# 3. `vm_modify` refuses a VM that is not STOPPED (VMInstanceStore.java:105-108), and it writes
#    only the daemon's in-memory store -- vms.json on disk is written by the app's editor alone
#    (app-daemon.md §5.4). So a change made here survives until the daemon restarts, and a daemon
#    restart stops every VM (Daemon.cleanup). Re-apply after any restart -- and note that a
#    daemon restart also makes `restore` unnecessary, since it drops the zeroed keys with
#    everything else.
set -u
SP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SP/lib.sh"

STATE_DIR="$SP/state"

# The keys the daemon reads to build its own --pre-alloc, checked against
# CrosvmBackendInstance.java at HEAD: gpu_host_pool_mb -> gfx-host-mb (gfxstream branch, :426),
# gpu_drm2kgsl_pool_mb -> drm-host-mb (drm2kgsl branch, :443), gpu_venus_pool_mb -> venus-host-mb
# (venus branch, :458), and gpu_guest_pool_mb -> the four gpu-guest-* keys appendGuestPoolOptions
# emits (:342-352, gated on GuestPoolSizing.bootGuestPoolMb, i.e. on gpu_guest_pool_mb itself);
# gpu_guest_prealloc_mb only sizes those, but is saved and zeroed too so a restore is exact.
# gpu_guest_step_mb / gpu_guest_max_grants are emitted only alongside a non-zero pool, so zeroing
# the pool is enough. The media keys (vpu_*) are deliberately NOT here: see note 2 above.
TAKEOVER_KEYS="gpu_host_pool_mb gpu_guest_pool_mb gpu_guest_prealloc_mb gpu_drm2kgsl_pool_mb gpu_venus_pool_mb"

# D3: the temp file apply() writes is cleaned up by a trap on a SCRIPT-level variable. It used to
# be a `local tmp` with the trap set inside the function, so the trap body ran after the function
# had returned and died with "tmp: unbound variable" under `set -u`, leaving the file behind.
TMPFILE=""
# A state file written by a takeover whose vm_modify then failed would refuse every later
# takeover while describing a config that was never changed, so it is rolled back on a failing
# exit and only kept when the whole verb succeeded.
STATE_PENDING=""
# takeover --show: run every guard and every computation, send nothing.
SHOW=0
cleanup() {
    local rc=$?
    [ -n "$TMPFILE" ] && rm -f "$TMPFILE"
    [ "$rc" != 0 ] && [ -n "$STATE_PENDING" ] && rm -f "$STATE_PENDING"
    return "$rc"
}
trap cleanup EXIT

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
VMNAME=$(vm_field "$INFO" name)
STATE=$(vm_state "$INFO")
PID=$(vm_field "$INFO" pid 0)
STATE_FILE="$STATE_DIR/$VMNAME.json"

require_stopped() {  # require_stopped <verb>
    [ "$STATE" = stopped ] || die "$1: $NAME is $STATE; vm_modify only accepts a STOPPED VM (VMInstanceStore.java:105-108) -- run: $SP/vm.sh stop $NAME"
}

show() {
    local cfg
    cfg=$(dvm get "$ID") || exit 1
    printf '%s' "$cfg" | python3 -c '
import json,sys
opts = (json.load(sys.stdin).get("data") or {}).get("extra_options") or []
print("extra_options: %d" % len(opts))
for o in opts:
    print("  %s" % o)'
    [ -f "$STATE_FILE" ] && { echo "takeover: ACTIVE, saved state in $STATE_FILE:"; sed 's/^/  /' "$STATE_FILE"; }
    return 0
}

# store <python program> <argv...> -- pipe the VM's config through the program and vm_modify the
# result. The program gets the config object (not the response envelope) as JSON on stdin and
# writes the new one to stdout; anything it prints on stderr is the operator's. Under SHOW=1
# (takeover --show) the program still runs -- so its guards still speak -- but the result is
# printed instead of sent, and nothing on the phone or in state/ is touched.
store() {
    local prog=$1; shift
    local cfg
    cfg=$(dvm get "$ID") || exit 1
    TMPFILE=$(mktemp -t vm_extra.XXXXXX.json) || die "mktemp failed"
    printf '%s' "$cfg" | python3 -c '
import json,sys
cfg = json.load(sys.stdin).get("data")
if not cfg:
    sys.exit("vm_get returned no config")
json.dump(cfg, sys.stdout)' | python3 -c "$prog" "$@" > "$TMPFILE" || exit 1
    if [ "$SHOW" = 1 ]; then
        note "takeover --show: NOTHING WAS SENT. The config that would be stored:"
        python3 -c '
import json, sys
cfg = json.load(sys.stdin)
keys = sys.argv[1].split()
print("extra_options: %d" % len(cfg.get("extra_options") or []))
for o in cfg.get("extra_options") or []:
    print("  %s" % o)
print("config keys that would be zeroed:")
for k in keys:
    print("  %s = %s" % (k, cfg.get(k)))' "$TAKEOVER_KEYS" < "$TMPFILE"
        return 0
    fi
    dvm modify "$TMPFILE" >/dev/null || exit 1
    show
}

SET_PROG='
import json,sys
cfg = json.load(sys.stdin)
# python3 -c CODE a b c  =>  sys.argv == ["-c", "a", "b", "c"]
cfg["extra_options"] = sys.argv[1:]
json.dump(cfg, sys.stdout)'

apply() {  # apply <new extra_options>...
    require_stopped "${VERB}"
    [ ! -f "$STATE_FILE" ] || note "warning: a takeover is active on $VMNAME ($STATE_FILE); '$VERB' does not undo it -- 'restore' does"
    store "$SET_PROG" "$@"
}

# Every media-* key, dropped. D7: what a live crosvm or the daemon log shows is the command line
# that was ACTUALLY exec'd, which after a takeover is the takeover's own merged string -- so the
# media keys in it are ours, not the daemon's, and feeding them back in would both double them
# and trip the WP A1 guard. Only a string the operator passed with --base, or the one saved in
# state/<vm>.json at the first takeover, is the daemon's untouched output.
strip_media_keys() {  # strip_media_keys <k=v,...>
    python3 -c '
import sys
items = [i for i in sys.argv[1].split(",") if i]
kept = [i for i in items if not i.split("=")[0].startswith("media-")]
dropped = [i for i in items if i.split("=")[0].startswith("media-")]
if dropped:
    sys.stderr.write("takeover: dropped %s from the observed command line "
                     "(a takeover put them there, the daemon did not)\n" % ", ".join(dropped))
print(",".join(kept))' "$1"
}

# The daemon's own --pre-alloc value: from the live crosvm while the VM runs, else from the last
# argv the daemon logged before exec (CrosvmBackendInstance.java:183). In both cases the FIRST
# --pre-alloc is the daemon's -- a second one cannot exist, argh refuses the parse (D2).
daemon_prealloc() {
    local src txt
    if [ "$STATE" = running ] && [ "${PID:-0}" -gt 0 ] 2>/dev/null; then
        src="/proc/$PID/cmdline"
        txt=$(asu "tr '\\0' ' ' < /proc/$PID/cmdline")
    else
        src="$DAEMON_LOG (last Executing: line)"
        txt=$(asu "grep 'Executing:' $DAEMON_LOG" | grep -- "--name $VMNAME " | tail -1)
    fi
    local val
    val=$(printf '%s\n' "$txt" | tr ' ' '\n' | grep -A1 -m1 -x -- '--pre-alloc' | tail -1)
    case "$val" in
        ""|--*) die "takeover: no --pre-alloc found in $src -- start the VM once, or use 'set' with the full string" ;;
    esac
    note "takeover: --pre-alloc observed in $src:"
    note "  $val"
    val=$(strip_media_keys "$val") || exit 1
    printf '%s' "$val"
}

# The base string for the merge, in the order the operator would want it: an explicit --base wins;
# then the daemon's own string as saved by the FIRST takeover (D7: this is what makes a second
# takeover work, and it is exact -- it was read before anything was zeroed); then a live read.
takeover_base() {  # takeover_base <explicit --base or empty>
    if [ -n "$1" ]; then
        note "takeover: base from --base:"
        note "  $1"
        printf '%s' "$1"
        return 0
    fi
    if [ -f "$STATE_FILE" ]; then
        local saved
        saved=$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1])).get("daemon_pre_alloc") or "")' "$STATE_FILE") || exit 1
        if [ -n "$saved" ]; then
            note "takeover: base from the active takeover ($STATE_FILE):"
            note "  $saved"
            printf '%s' "$saved"
            return 0
        fi
        note "takeover: $STATE_FILE has no daemon_pre_alloc -- falling back to the live command line"
    fi
    daemon_prealloc
}

TAKEOVER_PROG='
import json, os, sys, time
state_path, keys, base, merged, show = sys.argv[1:6]
extra = sys.argv[6:]
show = show == "1"
cfg = json.load(sys.stdin)

# The daemon already builds the media keys itself (WP A1 APK + VPU switch, or a camera row):
# extra_options must then carry no --pre-alloc at all, so there is nothing to take over. D7: ask
# the VM CONFIG, which is what the daemon actually reads, and not the observed command line, which
# after one takeover is our own string. vpu_enabled is the switch the WP A1 APK sets; the pool
# sizes beside it (vpu_host_pool_mb / vpu_guest_pool_mb) are what it then emits.
if cfg.get("vpu_enabled"):
    sys.exit("takeover: %s has vpu_enabled=true, so the daemon emits media-host-mb/media-guest-mb "
             "itself (host=%s guest=%s) -- this VM does not need a takeover; use: "
             "vm_extra.sh set %s --virtio-media <...>"
             % (cfg.get("name", ""), cfg.get("vpu_host_pool_mb"), cfg.get("vpu_guest_pool_mb"),
                cfg.get("name", "")))
# gfxstream emits gfx-host-mb whenever udmabuf is on, whatever gpu_host_pool_mb says
# (CrosvmBackendInstance.java:426-431), so zeroing the keys would NOT silence the daemon.
if "gfx-host-mb" in [item.split("=")[0] for item in base.split(",")] \
        and cfg.get("gpu_udmabuf", True):
    sys.exit("takeover: this VM is on the gfxstream route with gpu_udmabuf on, and the daemon "
             "emits gfx-host-mb even at size 0 (CrosvmBackendInstance.java:426-431) -- takeover "
             "cannot silence it. Turn udmabuf off in the app, or run this VM without media pools.")

now = time.strftime("%Y-%m-%dT%H:%M:%S")
# D7: a re-takeover must NOT re-save the config -- the keys are 0 and extra_options is ours by
# now, so saving them again would make "restore" put the takeover back. The first save is the only
# true one; later ones only append to the trail.
prior = None
if os.path.exists(state_path):
    with open(state_path) as f:
        prior = json.load(f)
if prior:
    saved = dict(prior)
    saved["reapplied_at"] = now
    saved["takeovers"] = int(prior.get("takeovers") or 1) + 1
else:
    saved = {"vm": cfg.get("name"), "id": cfg.get("id"), "saved_at": now,
             "daemon_pre_alloc": base, "extra_options": cfg.get("extra_options") or [],
             "keys": {k: cfg.get(k, None) for k in keys.split()}, "takeovers": 1}
for k in keys.split():
    cfg[k] = 0
cfg["extra_options"] = ["--pre-alloc", merged] + extra
if not show:
    os.makedirs(os.path.dirname(state_path), exist_ok=True)
    with open(state_path, "w") as f:
        json.dump(saved, f, indent=2)
        f.write("\n")
    sys.stderr.write("takeover: %s %s\n"
                     % ("re-applied, keeping the config saved in" if prior else "saved", state_path))
json.dump(cfg, sys.stdout)'

RESTORE_PROG='
import json, os, sys
state_path = sys.argv[1]
cfg = json.load(sys.stdin)
saved = json.load(open(state_path))
for k, v in (saved.get("keys") or {}).items():
    if v is None:
        cfg.pop(k, None)
    else:
        cfg[k] = v
cfg["extra_options"] = []
os.rename(state_path, state_path + ".restored")
sys.stderr.write("restore: put back %s; %s kept as %s.restored\n"
                 % (", ".join(sorted((saved.get("keys") or {}).keys())), state_path, state_path))
json.dump(cfg, sys.stdout)'

takeover() {  # takeover [--show] [--base <string>] <k=v[,k=v...]>... [-- <extra options...>]
    local keys="" explicit_base="" extra=()
    while [ "$#" -gt 0 ]; do
        case $1 in
            --) shift; extra=("$@"); break ;;
            --show) SHOW=1; shift ;;
            --base) explicit_base=${2:-}; [ -n "$explicit_base" ] || die "--base needs a --pre-alloc string"; shift 2 ;;
            --base=*) explicit_base=${1#--base=}; shift ;;
            -*) die "takeover: unknown flag '$1'" ;;
            *)  keys="${keys:+$keys,}$1"; shift ;;
        esac
    done
    [ -n "$keys" ] || die "takeover: give me the --pre-alloc keys to add, e.g. media-host-mb=320,media-guest-mb=192"
    # --show reads and prints only, so it does not care whether the VM is running.
    [ "$SHOW" = 1 ] || require_stopped takeover
    [ ! -f "$STATE_FILE" ] || note "takeover: a takeover is already active on $VMNAME -- re-applying on top of it (the config saved in $STATE_FILE is kept, so one 'restore' still undoes it)"
    local base merged
    base=$(takeover_base "$explicit_base") || exit 1
    merged=$(python3 -c '
import sys
from collections import OrderedDict
def parse(s):
    d = OrderedDict()
    for item in s.split(","):
        if not item:
            continue
        k, _, v = item.partition("=")
        d[k] = v
    return d
base, extra = parse(sys.argv[1]), parse(sys.argv[2])
base.update(extra)
print(",".join(k + "=" + v for k, v in base.items()))' "$base" "$keys") || exit 1
    if [ "$SHOW" = 1 ]; then note "takeover: would store --pre-alloc $merged"
    else note "takeover: storing --pre-alloc $merged"; fi
    # A state file that already existed is the operator's, not this run's: only roll back one this
    # run created (and --show creates nothing at all).
    [ "$SHOW" = 1 ] || [ -f "$STATE_FILE" ] || STATE_PENDING=$STATE_FILE
    store "$TAKEOVER_PROG" "$STATE_FILE" "$TAKEOVER_KEYS" "$base" "$merged" "$SHOW" ${extra[0]+"${extra[@]}"}
    if [ "$SHOW" = 1 ]; then
        note "takeover --show: done, nothing changed."
        return 0
    fi
    note ""
    note "!! TAKEOVER ACTIVE on $VMNAME -- $TAKEOVER_KEYS are 0 in the daemon's store."
    note "!! PoolPreflight now UNDER-COUNTS the huge-page reserve by the zeroed guest pool: it"
    note "!! sizes from those keys, not from the string above, while crosvm still asks the RM for"
    note "!! the pool. Watch gh_hugepage_reserve's pool_avail before you start the VM."
    note "!! This lives in the daemon's MEMORY only (vm_modify never writes files/vms.json), so a"
    note "!! daemon restart reverts it -- and stops every VM. Undo with: $0 restore $NAME"
    STATE_PENDING=""
}

restore() {
    require_stopped restore
    [ -f "$STATE_FILE" ] || die "restore: no takeover recorded for $VMNAME ($STATE_FILE does not exist)"
    store "$RESTORE_PROG" "$STATE_FILE"
    note "restore: extra_options cleared and the pool keys are back; PoolPreflight counts them again."
}

case "$VERB" in
show)     show ;;
set)      [ "$#" -gt 0 ] || die "set: give me the arguments to store (use 'clear' to empty the array)"
          apply "$@" ;;
takeover) takeover "$@" ;;
restore)  restore ;;
clear)    apply ;;
*)        usage ;;
esac
