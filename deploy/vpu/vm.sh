#!/bin/bash
# VPU dev rig: drive one stored VM on the phone through the daemon's JSON IPC.
#
#   vm.sh status   <name|id>   state, pid, guest address
#   vm.sh start    <name|id>   vm_start (the shipped CLI cannot start a stored VM)
#   vm.sh stop     <name|id>   vm_stop -- a clean shutdown, never kill -9
#   vm.sh argv     <name|id>   the running crosvm's /proc/<pid>/cmdline, one argument per line
#   vm.sh log      <name|id>   the daemon's "Executing:" line + the VM's stdio history
#   vm.sh wait-ssh <name|id>   block until the guest answers ssh (default 240s)
#
#   vm.sh log-level <name|id> <filter|->   how loud the VMM is for this VM (defect D60)
#
# log-level stores the app's `log_level` key, which CrosvmBackendInstance emits as the TOP-LEVEL
# `--log-level <filter>` -- between the crosvm binary and `run`, which is the only place argh
# accepts it, and the reason extra_options cannot do this job. The filter is env_logger's: a level
# name (`off error warn info debug trace`) or a compound (`info,devices::virtio::media=debug`).
# `-` (or `info`) removes the key, which is crosvm's own default. The VM must be STOPPED, and
# every helper crosvm launches inherits the level -- so this is what makes a `debug!` in the
# camera, decoder or encoder backend reachable at all. Confirm after the next start with
# `vm.sh argv <name> | grep -A1 -- --log-level`; a value the app refuses is dropped with a
# warning in daemon.log and the VM starts at info.
#
# start, stop and stop-all end by asking hp.sh whether the hugepage module agrees: the memory a
# VM holds is the first thing to move and the last thing to come back, so it says "it is really
# up" / "it is really gone" long before ssh or vm_list do. The verdict is printed and never
# fatal; HP_CHECK=0 skips it. wait-ssh does treat one verdict as fatal -- see below.
#
# Four verbs take no VM name -- three act on the daemon as a whole, and `wake` on the phone:
#
#   vm.sh stop-all             vm_stop_all -- stop every running VM cleanly, and wait
#   vm.sh daemon-check         is the running daemon the code the INSTALLED APK carries? (D12)
#   vm.sh daemon-restart       stop every VM, then restart the daemon with --force onto that APK
#   vm.sh wake                 wake the phone's screen, dismiss the keyguard, print what it did
#
# `wake` is a camera precondition, not a convenience. The app's CAMERA appop is `foreground`, so a
# sleeping screen leaves it TOP_SLEEPING and cameraserver revokes access mid-capture: logcat
# `Camera access permission lost mid-operation (-13)`, the VM log `camera device error 4`, and
# ENODEV in the guest (B15-build §5.2, README trap 10). `start` runs it by itself when the VM's
# config carries a camera row; run it by hand right before any capture, because the screen sleeps
# again on its own `screen_off_timeout` -- which `wake` prints, and which a report should carry.
#
# PHONE=<host:port> overrides the device (default 172.22.74.2:5566).
# The daemon is started if it is not running; see lib.sh's daemon_start.
set -u
SP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SP/lib.sh"

USAGE_RC=2
usage() {  # print the file's own header comment, up to the first line of code
    awk 'NR>1 && !/^#/ {exit} NR>1 {sub(/^# ?/, ""); print}' "$0"
    exit "$USAGE_RC"
}

# The hugepage watchdog. It reports, it does not decide: every caller here ignores the exit code
# except wait-ssh, which fails fast on "not started" (4) rather than burning its whole budget on
# ssh retries against a VM that is not there. HP_CHECK=0 turns the checks off for a phone that
# has no gh_hugepage_reserve.
hp() {  # hp <hp.sh args...>
    [ "${HP_CHECK:-1}" = 0 ] && return 0
    "$SP/hp.sh" "$@"
}

# `expect on` wants a floor, and the VM's configured memory is one the rig knows: the module
# serves at least that much (the guest pools take more on top -- W/debugloop.md). 1 page = 2 MiB;
# 0 pages means the weaker "served > 0".
hp_expect_on() {  # hp_expect_on <seconds> -- uses $INFO
    local mem
    mem=$(vm_field "$INFO" memory_mb 0)
    case "$mem" in ''|*[!0-9]*) mem=0 ;; esac
    hp expect on --wait "$1" --min-pages "$(( mem / 2 ))"
}

VERB=${1:-}; NAME=${2:-}
[ -n "$VERB" ] || usage
adb_wait

# The daemon-wide verbs resolve no VM, so they run before the vm_list lookup below -- which
# matters for daemon-check in particular: it must stay usable when the daemon is not running.
case "$VERB" in
stop-all)       vm_stop_all; rc=$?; hp expect off --wait 30 || true; exit "$rc" ;;
daemon-check)   daemon_check;  exit ;;
daemon-restart) daemon_restart && daemon_check; exit ;;
wake)           phone_wake; exit ;;
esac

[ -n "$NAME" ] || usage
INFO=$(vm_info "$NAME") || exit 1
ID=$(vm_field "$INFO" id)
STATE=$(vm_state "$INFO")
PID=$(vm_field "$INFO" pid 0)

case "$VERB" in
status)
    echo "name:  $(vm_field "$INFO" name)"
    echo "id:    $ID"
    echo "state: $STATE"
    echo "pid:   $PID"
    echo "guest: $(guest_addr "$NAME")"
    echo "streams: $(vm_field "$INFO" streams '[]')"
    [ "$STATE" = running ] || exit 1
    ;;
start)
    if [ "$STATE" = running ]; then echo "already running (pid $PID)"; exit 0; fi
    # A camera row means the first thing the guest does with /dev/video0 goes through the app's
    # `foreground`-only CAMERA appop, so the screen has to be awake for it. Doing it here costs a
    # second and removes the commonest false `camera device error 4` (B15-build §5.2); it does not
    # remove the need to wake again right before a capture, since the screen sleeps on its own.
    wake_for_camera "$INFO"
    dvm start "$ID" --clear-logs || exit 1
    # StartHandler returns as soon as the launch is accepted; poll for the state to settle.
    s=$STATE
    for _ in $(seq 1 30); do
        sleep 2
        s=$(vm_state "$(vm_info "$ID")")
        [ "$s" = running ] && { echo "running"; hp_expect_on 20 || true; exit 0; }
        [ "$s" = stopped ] && { echo "went back to stopped -- see: $0 log $NAME"; exit 1; }
    done
    echo "still $s after 60s"; exit 1
    ;;
stop)
    # vm_stop is the daemon's own orderly path (StopHandler -> CrosvmBackendInstance). Never
    # kill -9 a crosvm: a killed one leaks RM memparcels until the phone is rebooted
    # (deploy/SETUP.md).
    [ "$STATE" = stopped ] && { echo "already stopped"; hp expect off --wait 30 || true; exit 0; }
    dvm stop "$ID" || exit 1
    for _ in $(seq 1 30); do
        sleep 2
        # The daemon calls it stopped as soon as the process is reaped; the pages come back a
        # moment later, and "not reclaimed" here is what makes the NEXT start fail with ENOMEM.
        [ "$(vm_state "$(vm_info "$ID")")" = stopped ] && { echo stopped; hp expect off --wait 30 || true; exit 0; }
    done
    echo "still not stopped after 60s"; hp expect off --wait 0 || true; exit 1
    ;;
log-level)
    VALUE=${3:-}
    [ -n "$VALUE" ] || usage
    # No validation here on purpose: VmmLogLevel.java is the one parser, and a second one in
    # python would be a second answer to drift away from it. What this owes the operator is the
    # way to see which answer the app gave -- hence the argv line below.
    vm_config_edit "$NAME" '
import json,sys
cfg = json.load(sys.stdin)
v = sys.argv[1]
if v in ("-", "default", "info"):
    cfg.pop("log_level", None)
else:
    cfg["log_level"] = v
json.dump(cfg, sys.stdout)' "$VALUE" || exit 1
    dvm get "$ID" | python3 -c '
import json,sys
v = (json.load(sys.stdin).get("data") or {}).get("log_level")
print("log_level: %s" % (v if v else "(unset -- crosvm defaults to info)"))'
    note "on the next start: $0 argv $NAME | grep -A1 -- --log-level"
    ;;
argv)
    [ "$STATE" = running ] || die "$NAME is $STATE, no crosvm to inspect"
    [ "${PID:-0}" -gt 0 ] 2>/dev/null || die "vm_list reported no pid for $NAME"
    asu "tr '\\0' '\\n' < /proc/$PID/cmdline"
    ;;
log)
    # CrosvmBackendInstance.java:183 logs the whole argv before exec; this is the fastest way to
    # confirm what a config change actually emitted.
    echo "=== daemon.log: Executing (last for this VM) ==="
    asu "grep 'Executing:' $DAEMON_LOG" | grep -- "--name $(vm_field "$INFO" name)" | tail -1
    echo
    echo "=== VM stdio history ==="
    dvm console-history "$ID" stdio
    ;;
wait-ssh)
    ADDR=$(guest_addr "$NAME")
    BUDGET=${BUDGET:-240}
    # A VM that never got off the ground answers ssh exactly never, so ask the hugepage module
    # first: 20s to see the pages move beats 240s of ssh retries and a log read afterwards.
    hp expect on --wait 20; hprc=$?
    [ "$hprc" = 4 ] && die "wait-ssh: no VM is holding hugepages -- it did not start; see: $0 log $NAME"
    echo "waiting for ssh on $ADDR (up to ${BUDGET}s)" >&2
    end=$(( $(date +%s) + BUDGET ))
    while [ "$(date +%s)" -lt "$end" ]; do
        guest_ssh_ready "$ADDR" && { echo "$ADDR"; exit 0; }
        sleep 5
    done
    die "ssh on $ADDR did not answer within ${BUDGET}s"
    ;;
*)
    usage
    ;;
esac
