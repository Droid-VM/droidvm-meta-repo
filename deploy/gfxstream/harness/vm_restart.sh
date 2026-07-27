#!/bin/bash
# Restart the VM cleanly with the profiling launcher.
#
# poweroff from inside, never kill -9: a killed crosvm leaks its Gunyah memparcels, and the leak
# only clears on a phone reboot while masquerading as "too many concurrent memparcels".
set -u
A="adb -s ${PHONE:-172.22.74.2:5568} shell"
G="${GUEST:-root@172.22.68.12}"
LAUNCHER=${1:-/data/local/tmp/crosvm_gfx/run_prof.sh}

echo "==> shutting the guest down"
timeout 30 ssh -o ConnectTimeout=8 "$G" 'systemctl poweroff' >/dev/null 2>&1
for i in $(seq 1 24); do
    sleep 5
    # argv[0] is plain "crosvm", not the path it was launched from, and a "tail -f > con.in"
    # helper with crosvm_gfx in its command line lives on after the VM exits -- matching the path
    # therefore reports the VM as still running forever.
    $A 'su -c "pidof crosvm"' 2>/dev/null | tr -d '\r' | grep -q . || { echo "    crosvm gone after $((i*5))s"; break; }
    [ "$i" = 24 ] && { echo "    *** crosvm still running after 120s"; exit 1; }
done
sleep 3

# Wait for the reserve to take the last VM's pages back, then check there is enough for the next
# one -- both of which the old "crosvm is gone, go" was missing.
#
# Reclamation is asynchronous (the module refills on a timer), so the process disappearing says
# nothing about the pool. Starting into a partly-reclaimed reserve is how a VM ends up running on
# memory that was never really free, and that does not surface at boot: it surfaces later as a
# guest page fault the hypervisor answers with -ENOMEM, which kills the VM and leaks its pages,
# making the next attempt worse. Pages also stay out when a VM dies uncleanly -- active_vms=0 with
# served>0 is that leak, and only a phone reboot clears it.
pool_field() { $A "su -c 'sed -n \"s/^$1=//p\" /sys/module/gh_hugepage_reserve/parameters/refill_stat'" 2>/dev/null | tr -d '\r' | head -1; }

echo "==> waiting for the reserve to settle"
prev=""
for i in $(seq 1 24); do
    avail=$(pool_field pool_avail); served=$(pool_field served); vms=$(pool_field active_vms)
    echo "    pool_avail=${avail:-?} served=${served:-?} active_vms=${vms:-?}"
    if [ "${vms:-1}" = 0 ] && [ "${served:-1}" = 0 ] && [ -n "$avail" ] && [ "$avail" = "$prev" ]; then
        echo "    settled at $avail pages"
        break
    fi
    prev=$avail
    if [ "$i" = 24 ]; then
        echo "    *** reserve never settled after 120s"
        [ "${served:-0}" != 0 ] && echo "    *** served=$served with active_vms=$vms -- leaked pages, a phone reboot is the only fix"
    fi
    sleep 5
done

# What this VM asks for, in 2 MiB pages: guest RAM plus each pre-alloc pool.
# Follow the exec chain: the profiling launchers set env and exec the real one, so the pool sizes
# live a file or two down. Naming a fixed second file guessed wrong as soon as a new wrapper
# appeared, and a wrong guess here silently lets an oversized VM through.
chain=$($A "su -c 'f=$LAUNCHER; for i in 1 2 3; do cat \$f; n=\$(sed -n \"s/^exec sh \\\"\\\$DIR\\/\\(.*\\)\\\"\\$/\\1/p\" \$f | head -1); [ -z \"\$n\" ] && break; f=/data/local/tmp/crosvm_gfx/\$n; done'" 2>/dev/null | tr -d '\r')
need_mb=$(printf '%s\n' "$chain" | awk '
    match($0, /--mem[ ]+[0-9]+/)     { s=substr($0,RSTART,RLENGTH); gsub(/[^0-9]/,"",s); mem=s }
    match($0, /gfx-host-mb=[0-9]+/)  { s=substr($0,RSTART,RLENGTH); gsub(/[^0-9]/,"",s); hp=s }
    match($0, /gfx-guest-mb=[0-9]+/) { s=substr($0,RSTART,RLENGTH); gsub(/[^0-9]/,"",s); gp=s }
    END { print mem+hp+gp }')
avail=$(pool_field pool_avail)
if [ -n "$need_mb" ] && [ "$need_mb" -gt 0 ] && [ -n "$avail" ]; then
    need_pages=$(( (need_mb + 1) / 2 ))
    echo "==> this VM needs ~${need_mb}MB (${need_pages} pages); reserve has ${avail}"
    if [ "$avail" -lt "$need_pages" ]; then
        echo "    *** not enough: ${avail} < ${need_pages} pages -- refusing to launch."
        echo "    *** a VM that starts short does not fail at boot, it dies later and takes its pages with it."
        exit 1
    fi
fi

# The main process exiting is not the same as the VM being gone: crosvm itself logs "not all child
# processes have exited", and one of those still holds the tap, so an immediate relaunch dies with
# "failed to create tap interface: Device or resource busy" -- which looks exactly like the guest
# failing to boot. Retry the launch rather than scoring the arm as broken.
# The launcher attaches the tap to the bridge, but the bridge belongs to the DroidVM app and is
# rebuilt when it starts -- so straight after a phone reboot the attach can run before br-wifi
# exists and fail silently. The guest then boots perfectly and is simply unreachable, which reads
# from here as "the VM did not come up" and sent one investigation after the wrong thing entirely.
echo "==> waiting for the bridge"
for i in $(seq 1 24); do
    $A 'su -c "ip link show br-wifi"' >/dev/null 2>&1 && { echo "    br-wifi present after $((i*5))s"; break; }
    [ "$i" = 24 ] && { echo "    *** br-wifi never appeared (120s) -- the guest would boot with no network"; exit 1; }
    sleep 5
done

echo "==> launching $LAUNCHER"
up=0
for attempt in 1 2 3; do
    $A "su -c 'setsid sh $LAUNCHER >/dev/null 2>&1 &'" >/dev/null 2>&1
    sleep 15
    if ! $A 'su -c "pidof crosvm"' 2>/dev/null | tr -d '\r' | grep -q .; then
        echo "    crosvm exited immediately (attempt $attempt): $($A 'su -c "grep -m1 \"exiting with error\" /data/local/tmp/crosvm_gfx/crosvm.log"' 2>/dev/null | tr -d '\r' | sed 's/.*exiting with error/error/' | cut -c1-90)"
        sleep 10
        continue
    fi
    for i in $(seq 1 45); do
        timeout 12 ssh -o ConnectTimeout=6 "$G" 'true' >/dev/null 2>&1 && { echo "    guest up after $((15 + i*5))s"; up=1; break; }
        sleep 5
    done
    [ "$up" = 1 ] && break
    echo "    *** guest never came up (attempt $attempt)"
done
[ "$up" = 1 ] || {
    # Distinguish "no network" from "did not boot": the tap losing its master looks identical from
    # here, and the guest may be sitting happily at a login prompt.
    master=$($A 'su -c "ip link show vm526795fd-0 2>/dev/null"' 2>/dev/null | tr -d '\r' | grep -o "master [a-z0-9-]*")
    if [ -z "$master" ]; then
        echo "    *** the tap is not on the bridge (${master:-no master}) -- re-attaching and retrying ssh"
        $A 'su -c "ip link set vm526795fd-0 master br-wifi; ip link set vm526795fd-0 up"' >/dev/null 2>&1
        for i in $(seq 1 12); do
            sleep 5
            timeout 12 ssh -o ConnectTimeout=6 "$G" 'true' >/dev/null 2>&1 && { echo "    guest reachable after re-attach"; up=1; break; }
        done
    fi
}
[ "$up" = 1 ] || exit 1

echo "==> env of the new crosvm"
$A 'su -c "for p in $(pidof crosvm); do tr \"\\0\" \"\\n\" < /proc/\$p/environ | grep GFXSTREAM_; break; done"' 2>/dev/null | tr -d '\r'

echo "==> waiting for the desktop session"
for i in $(seq 1 36); do
    timeout 15 ssh -o ConnectTimeout=6 "$G" '[ -S /run/user/1001/wayland-0 ]' >/dev/null 2>&1 && { echo "    session up after $((i*5))s"; exit 0; }
    sleep 5
done
echo "    *** no desktop session after 180s"
exit 1
