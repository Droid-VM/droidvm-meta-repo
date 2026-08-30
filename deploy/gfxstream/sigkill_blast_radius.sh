#!/bin/bash
# Does a VMM death take the host with it, and does the GPU decide that?
#
#   deploy/gfxstream/sigkill_blast_radius.sh [case...]      default: all three
#
# THIS DELIBERATELY SIGKILLS crosvm, which the rest of this tree is emphatic about never doing:
# a SIGKILL'd crosvm leaks its Gunyah memparcels and the RM does not reclaim them until the phone
# reboots. That cost is the point here -- the question is whether the host survives at all, and a
# leak is the mild outcome.
#
# The observation being chased: crosvm SIGABRTs (a FORTIFY: FD_SET abort, now fixed) and the phone
# reboots a few seconds later, with a clean "reboot" boot reason rather than a panic. Fixing the
# abort removes one trigger; it does not tell us why a dying VMM takes the device down, and any
# future crash would do the same. The prior worth testing: without a GPU device, SIGKILL did NOT
# take the host down.
#
# One result cannot separate "the GPU device is what makes teardown fatal" from "a heavier VM is
# what makes teardown fatal", so three cases:
#
#   nogpu   VM with --no-gpu, idle            <- the prior, re-established on today's build
#   gpuidle VM with the GPU, nothing drawing  <- GPU device present, few resources
#   gpumc   VM with the GPU, Minecraft in a world <- GPU device with ~1000 live dma-bufs
#   gpumc-abort  same, but SIGABRT instead of SIGKILL <- the death path the real crashes took
#
# nogpu surviving and gpumc not is the GPU. All three dying is Gunyah teardown generally. gpuidle
# surviving and gpumc not points at the amount of GPU state, not at the device existing.
set -u
cd "$(dirname "$0")"
PHONE=${PHONE:-10.53.12.1:5568}
GUEST=${GUEST:-root@172.22.68.12}
OUT=${OUT:-/tmp/mc_bench/blast}
A="adb -s $PHONE shell"
SSH="ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no $GUEST"
mkdir -p "$OUT"
. "$(dirname "$0")/harness/preflight.sh"

uptime_now() { $A "su -c 'cut -d. -f1 /proc/uptime'" 2>/dev/null | tr -dc 0-9; }
crosvm_pid() { $A "su -c 'pgrep -f \"[c]rosvm --log-level\"'" 2>/dev/null | tr -dc 0-9 | head -c 8; }

# Sleep, but give up the moment crosvm is gone.
#
# Every long wait in this script -- the boot wait, the Minecraft drive -- used to be a plain sleep,
# so if the VM died partway through, the script sat there for the rest of the timeout with nothing
# to wait for. Boot alone was 320s of that. Checking every 5s turns "the VM died during setup" into
# an immediate, labelled result instead of minutes of silence.
wait_alive() {   # $1 = seconds, $2 = what we are waiting for
    local n=$1 i
    for ((i = 0; i < n; i += 5)); do
        sleep 5
        [ -n "$(crosvm_pid)" ] || { echo "  !! crosvm vanished while waiting for $2 (after ${i}s)"; return 1; }
    done
    return 0
}

run_case() {   # $1 = case name
    local c=$1 pid up_before up_after alive
    echo "########## $c ##########"
    preflight || { echo "  refusing to start"; return 3; }
    bridge_up || return 3

    # logcat to THIS machine: if the phone goes down, a file on the phone loses its tail.
    ( adb -s "$PHONE" logcat -b all -v threadtime > "$OUT/$c.logcat.txt" 2>&1 ) & local LOG=$!
    # Watches from THIS machine, so the phone going away is noticed here rather than showing up as
    # a script that seems to have stalled.
    host_watchdog_start "$c" "$OUT"
    sleep 3

    case $c in
        nogpu)
            # Same launcher, GPU stripped. --no-gpu is not a flag; the GPU is configured by --gpu,
            # so the case is built by dropping it (and the VNC server, which needs the display).
            $A "su -c 'sed -e \"/--gpu /d\" -e \"/--vnc-server/d\" \\
                  /data/local/tmp/crosvm_drm2kgsl/run_drm2kgsl_nctx.sh \\
                  > /data/local/tmp/crosvm_drm2kgsl/run_nogpu.sh; chmod 755 /data/local/tmp/crosvm_drm2kgsl/run_nogpu.sh'" >/dev/null 2>&1
            $A "su -c 'setsid sh /data/local/tmp/crosvm_drm2kgsl/run_nogpu.sh </dev/null >/dev/null 2>&1 &'" >/dev/null 2>&1 ;;
        *)
            $A "su -c 'setsid sh /data/local/tmp/crosvm_drm2kgsl/run_drm2kgsl_nctx.sh </dev/null >/dev/null 2>&1 &'" >/dev/null 2>&1 ;;
    esac

    local up=no
    for i in $(seq 1 64); do
        sleep 5
        [ -n "$(crosvm_pid)" ] || { echo "  !! crosvm died during boot (after $((i*5))s)"; kill $LOG 2>/dev/null; host_watchdog_stop; return 1; }
        $SSH 'echo up' 2>/dev/null | grep -q up && { up=yes; echo "  guest up after $((i*5))s"; break; }
    done
    [ "$up" = yes ] || { echo "  !! guest never came up"; kill $LOG 2>/dev/null; host_watchdog_stop; return 1; }
    pid=$(crosvm_pid)
    [ -n "$pid" ] || { echo "  !! no crosvm; skipping"; kill $LOG 2>/dev/null; host_watchdog_stop; return 1; }

    case $c in gpumc*)
        $SSH 'f=$(ls /home/*/.minecraft/options.txt 2>/dev/null|head -1); [ -n "$f" ] && {
                sed -i "/^preferredGraphicsBackend:/d" "$f"; echo "preferredGraphicsBackend:\"vulkan\"" >> "$f"; }
              L=/home/droidvm/launch_mc_kgsl_nctx.sh; [ -f $L ] || L=/home/droidvm/launch_mc_vk.sh
              sudo -u droidvm bash $L' >/dev/null 2>&1
        wait_alive 50 "Minecraft to start" || { kill $LOG 2>/dev/null; host_watchdog_stop; return 1; }
        V="vncdo -s 10.53.12.1::5900"
        $V move 639 322 click 1 >/dev/null 2>&1; sleep 4
        $V move 639 325 click 1 >/dev/null 2>&1; sleep 5
        $V move 639 300 click 1 >/dev/null 2>&1; sleep 4
        $V move 639 640 click 1 >/dev/null 2>&1
        wait_alive 90 "the world to load" || {
            # Dying here, before we ever sent a signal, IS a result: the route killed itself.
            echo "  RESULT $c: crosvm died on its own during world load -- no signal needed"
            echo "$c|died-unprompted|$(uptime_now)|-|-" >> "$OUT/results.psv"
            kill $LOG 2>/dev/null; host_watchdog_stop; return 0; }
        ;;
    esac

    local fds
    fds=$($A "su -c 'ls /proc/$pid/fd 2>/dev/null | wc -l'" 2>/dev/null | tr -dc 0-9)
    up_before=$(uptime_now)

    # Snapshot what the pool and the process look like WHILE the VM is still up. After the kill
    # there may be no phone to ask. bench_all.sh's watchdog waits for live to reach 0 and then
    # collects; here the kill is deliberate, so the wait would be pointless -- collect first, then
    # kill, then collect again from whatever survives.
    {
        echo "=== before SIGKILL, $(date -u +%FT%TZ) ==="
        $A "su -c 'cat /sys/module/gh_hugepage_reserve/parameters/served_summary'" 2>/dev/null | tr -d '\r'
        echo "vm_owners: $($A "su -c 'cat /sys/module/gh_hugepage_reserve/parameters/vm_owners'" 2>/dev/null | tr -d '\r')"
        echo "pool_avail=$($A "su -c 'cat /sys/module/gh_hugepage_reserve/parameters/pool_avail'" 2>/dev/null | tr -d '\r')"
        echo "fds=${fds:-?} uptime=${up_before}s"
        echo "--- crosvm stdout/stderr so far ---"
        $A "su -c 'cat /data/local/tmp/crosvm_drm2kgsl/crosvm.log'" 2>/dev/null | tr -d '\r' | tail -60
    } > "$OUT/$c.before.txt" 2>&1

    # SIGKILL vs SIGABRT is the last variable left. SIGKILL is instant and external: the kernel
    # tears the process down with no userspace involvement. SIGABRT goes through bionic's crash
    # handler -- debuggerd is signalled, crash_dump64 attaches and walks the dying process, and only
    # then does it exit. The observed reboots were all SIGABRT, and all three SIGKILL cases here
    # survived, so the death PATH is the remaining candidate: what the process is still holding, and
    # for how long, while something else walks it.
    local sig=9 signame=SIGKILL
    case $c in *abort*) sig=6 signame=SIGABRT ;; esac
    echo "  crosvm pid=$pid fds=${fds:-?} uptime=${up_before}s -- sending $signame"
    $A "su -c 'kill -$sig $pid'" >/dev/null 2>&1

    # Immediately, before a reboot can take it: what the RM did with the memparcels the dead
    # process was holding. orphan_inuse is the number that says they are stranded.
    sleep 2
    {
        echo "=== 2s after SIGKILL ==="
        $A "su -c 'cat /sys/module/gh_hugepage_reserve/parameters/served_summary'" 2>/dev/null | tr -d '\r'
        echo "pool_avail=$($A "su -c 'cat /sys/module/gh_hugepage_reserve/parameters/pool_avail'" 2>/dev/null | tr -d '\r')"
        echo "--- dmesg tail ---"
        $A "su -c 'dmesg | tail -30'" 2>/dev/null | tr -d '\r'
    } > "$OUT/$c.after-kill.txt" 2>&1

    # Watch for two minutes: the reboot in the observed failures came seconds after the death.
    alive=yes
    for i in $(seq 1 24); do
        sleep 5
        up_after=$(uptime_now)
        if [ -z "$up_after" ] || [ "${up_after:-0}" -lt "${up_before:-0}" ]; then
            alive=no; break
        fi
    done
    kill $LOG 2>/dev/null
    host_watchdog_stop
    sleep 1

    if [ "$alive" = no ]; then
        echo "  RESULT $c: HOST WENT DOWN (uptime ${up_before}s -> ${up_after:-unreachable}s)"
        echo "    boot reason: $($A 'getprop sys.boot.reason' 2>/dev/null | tr -d '\r')"
    else
        echo "  RESULT $c: host survived (uptime ${up_before}s -> ${up_after}s)"
        echo "    leaked memparcels: $($A "su -c 'cat /sys/module/gh_hugepage_reserve/parameters/served_summary'" 2>/dev/null | tr -d '\r' | tr '\n' ' ')"
    fi
    if host_rebooted; then
        echo "    host watchdog:"; sed 's/^/      /' "$OUT/$c.hostwd.txt"
    fi
    grep -iE "FORTIFY|Fatal signal|RescueParty|watchdog|gunyah|reboot" "$OUT/$c.logcat.txt" 2>/dev/null | tail -6 | sed 's/^/    /'
    echo "$c|$alive|${up_before:-?}|${up_after:-?}|${fds:-?}" >> "$OUT/results.psv"
}

CASES=${*:-"nogpu gpuidle gpumc gpumc-abort"}
for c in $CASES; do run_case "$c"; done
echo
echo "case|host_survived|uptime_before|uptime_after|crosvm_fds"
cat "$OUT/results.psv" 2>/dev/null
