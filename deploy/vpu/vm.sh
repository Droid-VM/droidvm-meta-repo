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
# Three verbs take no VM name and act on the daemon as a whole:
#
#   vm.sh stop-all             vm_stop_all -- stop every running VM cleanly, and wait
#   vm.sh daemon-check         is the running daemon the code the INSTALLED APK carries? (D12)
#   vm.sh daemon-restart       stop every VM, then restart the daemon with --force onto that APK
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

VERB=${1:-}; NAME=${2:-}
[ -n "$VERB" ] || usage
adb_wait

# The daemon-wide verbs resolve no VM, so they run before the vm_list lookup below -- which
# matters for daemon-check in particular: it must stay usable when the daemon is not running.
case "$VERB" in
stop-all)       vm_stop_all;   exit ;;
daemon-check)   daemon_check;  exit ;;
daemon-restart) daemon_restart && daemon_check; exit ;;
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
    dvm start "$ID" --clear-logs || exit 1
    # StartHandler returns as soon as the launch is accepted; poll for the state to settle.
    s=$STATE
    for _ in $(seq 1 30); do
        sleep 2
        s=$(vm_state "$(vm_info "$ID")")
        [ "$s" = running ] && { echo "running"; exit 0; }
        [ "$s" = stopped ] && { echo "went back to stopped -- see: $0 log $NAME"; exit 1; }
    done
    echo "still $s after 60s"; exit 1
    ;;
stop)
    # vm_stop is the daemon's own orderly path (StopHandler -> CrosvmBackendInstance). Never
    # kill -9 a crosvm: a killed one leaks RM memparcels until the phone is rebooted
    # (deploy/SETUP.md).
    [ "$STATE" = stopped ] && { echo "already stopped"; exit 0; }
    dvm stop "$ID" || exit 1
    for _ in $(seq 1 30); do
        sleep 2
        [ "$(vm_state "$(vm_info "$ID")")" = stopped ] && { echo stopped; exit 0; }
    done
    echo "still not stopped after 60s"; exit 1
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
