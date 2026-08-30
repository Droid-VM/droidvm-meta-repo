#!/bin/bash
# Reproduce, then verify the fix for, crosvm aborting on FD_SET past FD_SETSIZE.
#
#   deploy/gfxstream/fdsetsize_repro.sh
#
# The bug needs a VNC client to connect AFTER crosvm's descriptor numbers have passed 1023 -- the
# abort is on the fd NUMBER accept() returns, not on how many are open. A benchmark run connects
# VNC early, while numbers are still low, which is why an earlier "verification" passed against a
# build that had only half the fix: the crash site (rfbNewTCPOrUDPClient, on the listener thread
# right after accept) had not been touched at all.
#
# So this drives the order explicitly:
#   1. boot the VM with VNC listening and NOTHING connected
#   2. run a buffer-object-heavy workload in the guest until crosvm's highest fd passes 1023
#   3. only then connect a VNC client
#   4. see whether crosvm is still alive
#
# On an unfixed build step 4 finds it gone, with FORTIFY: FD_SET in logcat and, shortly after, the
# phone rebooting. On a fixed build the client connects and the VM keeps running.
set -u
cd "$(dirname "$0")"
PHONE=${PHONE:-10.53.12.1:5568}
GUEST=${GUEST:-root@172.22.68.12}
VNC_HOST=${VNC_HOST:-10.53.12.1}
VNC_PORT=${VNC_PORT:-5900}
OUT=${OUT:-/tmp/mc_bench/fdrepro}
A="adb -s $PHONE shell"
SSH="ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no $GUEST"
mkdir -p "$OUT"
. "$(dirname "$0")/harness/preflight.sh"

crosvm_pid() { $A "su -c 'pgrep -f \"[c]rosvm --log-level\"'" 2>/dev/null | tr -dc 0-9 | head -c 8; }
highest_fd() { $A "su -c 'ls /proc/$1/fd 2>/dev/null | sort -n | tail -1'" 2>/dev/null | tr -dc 0-9; }
fd_count()   { $A "su -c 'ls /proc/$1/fd 2>/dev/null | wc -l'" 2>/dev/null | tr -dc 0-9; }

echo "=== capture ==="
( adb -s "$PHONE" logcat -b all -v threadtime > "$OUT/logcat.txt" 2>&1 ) & LOGPID=$!
trap 'kill $LOGPID 2>/dev/null' EXIT
sleep 3

echo "=== 0. preflight ==="
# This script had none, which would have let it start a VM against a short reserve pool and then
# read the resulting ENOMEM as evidence about the thing under test. Same checks as the benchmark
# driver, from the same file: no stale processes, no second crosvm, no memparcels still served,
# pool topped up (triggering acquire if short), udmabuf module loaded, uptime recorded.
preflight || { echo "  refusing to start"; exit 3; }

echo "=== 1. boot, no VNC client ==="
bridge_up || exit 3
$A "su -c 'setsid sh /data/local/tmp/crosvm_drm2kgsl/run_drm2kgsl_nctx.sh </dev/null >/dev/null 2>&1 &'" >/dev/null 2>&1
for i in $(seq 1 40); do sleep 8; $SSH 'echo up' 2>/dev/null | grep -q up && { echo "  guest up (${i}x8s)"; break; }; done
PID=$(crosvm_pid); [ -n "$PID" ] || { echo "  !! no crosvm"; exit 1; }
echo "  crosvm pid=$PID  fds=$(fd_count "$PID")  highest=$(highest_fd "$PID")"

echo "=== 2. push descriptor numbers past 1023 ==="
# Minecraft is the workload that gets there: three long-lived fds per guest BO on this route.
$SSH 'f=$(ls /home/*/.minecraft/options.txt 2>/dev/null|head -1); [ -n "$f" ] && {
        sed -i "/^preferredGraphicsBackend:/d" "$f"; echo "preferredGraphicsBackend:\"vulkan\"" >> "$f"; }
      L=/home/droidvm/launch_mc_kgsl_nctx.sh; [ -f $L ] || L=/home/droidvm/launch_mc_vk.sh
      sudo -u droidvm bash $L' >/dev/null 2>&1
# Minecraft has to be driven into a world: at the main menu it plateaus around 750 fds and stays
# there. Driving it needs VNC, and that is fine -- the bug is not about a client being connected,
# it is about what fd number a NEW accept() returns. A client that connected while numbers were low
# is harmless; the one that connects afterwards aborts. vncdo connects and disconnects per command,
# which is exactly how the original crash happened: a late vncdo call drew a high fd.
sleep 50
V="vncdo -s $VNC_HOST::$VNC_PORT"
$V move 639 322 click 1 >/dev/null 2>&1; sleep 4
$V move 639 325 click 1 >/dev/null 2>&1; sleep 5
$V move 639 300 click 1 >/dev/null 2>&1; sleep 4
$V move 639 640 click 1 >/dev/null 2>&1
echo "  driven into a world; watching fd numbers climb"
for i in $(seq 1 60); do
    sleep 10
    PID=$(crosvm_pid)
    [ -n "$PID" ] || { echo "  !! crosvm died before a client ever connected -- that is a different bug"; break; }
    H=$(highest_fd "$PID"); C=$(fd_count "$PID")
    printf "  t=%3ds fds=%-5s highest=%-5s\n" $((i*10)) "${C:-?}" "${H:-?}"
    [ "${H:-0}" -gt 1023 ] && { echo "  past FD_SETSIZE: highest fd = $H"; break; }
done
H=$(highest_fd "$PID")
if [ "${H:-0}" -le 1023 ]; then
    echo "  !! never got past 1023 (highest=$H) -- the workload did not allocate enough; INCONCLUSIVE"
    exit 2
fi

echo "=== 3. connect a VNC client now ==="
BEFORE=$(crosvm_pid)
timeout 25 vncdo -s "$VNC_HOST::$VNC_PORT" capture "$OUT/after.png" >/dev/null 2>&1
RC=$?
sleep 8

echo "=== 4. verdict ==="
uptime_check || { echo "  the host rebooted during this run -- verdict is not trustworthy"; exit 4; }
AFTER=$(crosvm_pid)
ABORTS=$(grep -c "FORTIFY: FD_SET" "$OUT/logcat.txt" 2>/dev/null || true)
echo "  crosvm before=$BEFORE after=${AFTER:-gone}"
echo "  FORTIFY: FD_SET in logcat: $ABORTS"
echo "  vncdo capture: rc=$RC $([ -s "$OUT/after.png" ] && echo "(got a frame)" || echo "(no frame)")"
if [ -z "$AFTER" ] || [ "$ABORTS" != 0 ]; then
    echo "  FAIL -- the abort is still reachable"
    grep -B2 -A6 "FORTIFY: FD_SET" "$OUT/logcat.txt" 2>/dev/null | tail -12
    exit 1
fi
echo "  PASS -- a client connected at fd > 1023 and crosvm survived"
