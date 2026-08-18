#!/bin/bash
# E1/E2 rig for the pseudo-unprotected plan: boot a VM whose only unusual feature is a growable
# test pool, so the guest can ask for one big runtime memparcel and then try to EXECUTE out of it.
#
# Deliberately no GPU, no display, no VNC: every one of those brings its own pools and its own
# runtime shares, and the measurement here is about a single grant. Serial goes to a file and the
# guest is reached over ssh through the phone's br-wifi bridge.
#
#   PHONE=5568 poolvm.sh push          push crosvm_out to the phone (md5-verified)
#   PHONE=5568 poolvm.sh overlay       create a throwaway overlay over the base image
#   PHONE=5568 POOL_MB=512 EXEC=1 poolvm.sh start
#   PHONE=5568 poolvm.sh ip            print the guest address (from the phone's neighbour table)
#   PHONE=5568 poolvm.sh stop
#   PHONE=5568 poolvm.sh log
set -u
PHONE=${PHONE:-5568}
A="adb -s 172.22.74.2:$PHONE"
ROOT=/root/gitrs/DroidVM/DroidVM_3daccel_gfxstream
OUT=$ROOT/crosvm_out
DBG=/data/local/tmp/poolvm
APP=/data/data/cn.classfun.droidvm
SP="$(dirname "$0")"
LOG=$SP/poolvm_$PHONE.log

# One tap and one MAC per phone, fixed: the guest's SLAAC address is EUI-64 derived from the MAC,
# so a fixed MAC means the ssh target is known before the guest has booted.
case "$PHONE" in
    5566) MAC=02:44:44:00:00:66; BASE=${BASE:-} ;;
    5567) MAC=02:44:44:00:00:67; BASE=${BASE:-/data/media/0/DroidVM/ubuntu-2026-kde.qcow2} ;;
    *)    MAC=02:44:44:00:00:68; BASE=${BASE:-/data/media/0/DroidVM/ship.qcow2} ;;
esac
TAP=poolvm0
BRIDGE=br-wifi
DISK=$DBG/poolvm.qcow2
# EUI-64 of the MAC above, on the phone's own /64.
eui() { printf '2a0e:b107:1953:cc:%02x%02x:%02xff:fe%02x:%02x%02x\n' \
    $((0x${MAC%%:*} ^ 2)) 0x$(echo $MAC | cut -d: -f2) 0x$(echo $MAC | cut -d: -f3) \
    0x$(echo $MAC | cut -d: -f4) 0x$(echo $MAC | cut -d: -f5) 0x$(echo $MAC | cut -d: -f6); }
GUEST6=$(eui)

MEMMB=${MEMMB:-2048}
POOL_MB=${POOL_MB:-512}
POOL_PREALLOC_MB=${POOL_PREALLOC_MB:-0}
POOL_STEP_MB=${POOL_STEP_MB:-$POOL_MB}
EXEC=${EXEC:-1}
# Second pool and the hole between them: the sandwich that makes the hole a real hole in the
# middle of the declared stack rather than open address space above everything.
POOL2_MB=${POOL2_MB:-0}
POOL2_GAP_MB=${POOL2_GAP_MB:-0}
# GH_SHARE_PROBE=<gpa>[:<size_kib>] -- crosvm shares a scratch range there right after VM_START
# and prints the handle for the guest to accept.
PROBE=${PROBE:-}
HIDE=${HIDE:-}
# NODISK=1 boots firmware only. The question a DT change has to answer -- does the resource
# manager accept this tree -- is settled at GH_VM_START, before any block device is touched, so
# the check does not need a guest image on the phone at all.
NODISK=${NODISK:-0}
if [ "$NODISK" = 1 ]; then BLOCK_ARG=""; else BLOCK_ARG="--block $DISK,lock=false"; fi
# mTHP mode differs per SoC generation (8gen3's RM wants one parcel per region).
case "$PHONE" in 5567) MTHP=single ;; *) MTHP=chunked ;; esac

param() { $A shell su -c "cat /sys/module/gh_hugepage_reserve/parameters/$1" 2>/dev/null | tr -dc 0-9; }
served_live() {
    local v i
    for i in 1 2 3 4 5; do
        $A shell "su -c 'echo 1 > /sys/module/gh_hugepage_reserve/parameters/reconcile'" >/dev/null 2>&1
        sleep 2
        v=$($A shell su -c "cat /sys/module/gh_hugepage_reserve/parameters/served_summary" 2>/dev/null |
            tr -d '\r' | sed -n 's/^live=//p')
        [ "${v:-1}" = 0 ] && break
    done
    echo "${v:-?}"
}

case "${1:-start}" in
push)
    $A shell su -c "mkdir -p $DBG" >/dev/null 2>&1
    keep=$($A shell su -c "ls $APP/usr/lib" 2>/dev/null | tr -d '\r')
    for f in "$OUT"/*; do
        b=$(basename "$f")
        case "$b" in
            *.so) printf '%s\n' "$keep" | grep -qx "$b" || { echo "  skip $b (phone's own)"; continue; } ;;
        esac
        $A push "$f" /data/local/tmp/"$b" >/dev/null 2>&1 || { echo "push $b failed"; exit 1; }
        $A shell su -c "cp /data/local/tmp/$b $DBG/$b && chmod 755 $DBG/$b" >/dev/null 2>&1
        L=$(md5sum "$f" | cut -c1-32)
        R=$($A shell su -c "md5sum $DBG/$b" 2>/dev/null | cut -c1-32 | tr -d '\r')
        [ "$L" = "$R" ] || { echo "MD5 MISMATCH $b ($L vs $R)"; exit 1; }
        echo "  ok $b"
    done
    echo "pushed and verified"
    ;;
overlay)
    # The app ships qemu-img; use it rather than crosvm's create_qcow2, which opens the whole
    # backing chain and flock()s it -- and the phone's emulated storage answers ENOSYS to that.
    # `su -mm` because /data/media is only mounted in init's namespace. The parent is opened
    # read-only and never written: this is an empty delta on top of it.
    $A shell "su -mm -c 'mkdir -p $DBG; rm -f $DISK; \
        LD_LIBRARY_PATH=$APP/usr/lib $APP/usr/bin/qemu-img create -f qcow2 -F qcow2 -b $BASE $DISK'" 2>&1 |
        tr -d '\r' | tail -2
    $A shell su -c "ls -l $DISK" 2>&1 | tr -d '\r'
    ;;
start)
    live=$(served_live)
    [ "${live:-0}" = 0 ] || { echo "preflight: a VM still holds $live pages"; exit 1; }
    avail=$(param pool_avail); want=$(param pool_want)
    need=$(( (MEMMB + POOL_MB + POOL2_MB + 224) / 2 ))
    if [ "${avail:-0}" -lt "$need" ]; then
        echo "preflight: pool $avail < need $need pages -- acquiring"
        for _ in 1 2 3; do
            $A shell "su -c 'echo 1 > /sys/module/gh_hugepage_reserve/parameters/acquire'" >/dev/null 2>&1
            sleep 8; avail=$(param pool_avail)
            [ "${avail:-0}" -ge "$need" ] && break
        done
    fi
    echo "preflight: live=$live pool=$avail/$want pages (need $need)"
    [ "${avail:-0}" -ge "$need" ] || { echo "preflight: not enough pool"; exit 1; }

    cat > "$SP/poolrun.sh" <<EOF
#!/system/bin/sh
DBG=$DBG
APP=$APP
export LD_LIBRARY_PATH=\$DBG:\$APP/usr/lib
export LD_PRELOAD=\$APP/lib/libsimpledump.so:\$APP/lib/libcompat_a16.so
export TMPDIR=/data/local/tmp
export RUST_LOG=info
# The growable test pool: declared whole, nothing SHARE'd at boot, one grant covers it all.
export DROIDVM_TEST_POOL_MB=$POOL_MB
export DROIDVM_TEST_POOL_PREALLOC_MB=$POOL_PREALLOC_MB
export DROIDVM_TEST_POOL_STEP_MB=$POOL_STEP_MB
export DROIDVM_TEST_POOL_2_MB=$POOL2_MB
export DROIDVM_TEST_POOL_2_PREALLOC_MB=$POOL2_MB
export DROIDVM_TEST_POOL_2_STEP_MB=$POOL2_MB
export DROIDVM_TEST_POOL_2_GAP_MB=$POOL2_GAP_MB
export GH_SHARE_EXEC=$EXEC
export GH_SHARE_PROBE=$PROBE
# The probe's scratch pages are ordinary anonymous memory, so they can land in CMA where a
# FOLL_LONGTERM pin cannot follow; 'fix' migrates them out instead of refusing the share. The
# real window will be reserve-pool backed and will not need this.
export GUNYAH_PIN_POLICY=${PIN_POLICY:-fix}
# Empty when there is no disk; unquoted below so it disappears entirely rather than becoming an
# empty argument (and, as a variable, without leaving a blank continuation line that would end
# the command right there -- which is exactly what the first attempt did).
BLOCK_OPT="$BLOCK_ARG"
export DROIDVM_POOL_HIDE=$HIDE
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
echo madvise > /sys/kernel/mm/transparent_hugepage/defrag
echo advise  > /sys/kernel/mm/transparent_hugepage/shmem_enabled
echo 3 > /proc/sys/vm/drop_caches
echo 1 > /proc/sys/vm/compact_memory
ulimit -n 65536
ulimit -l unlimited
exec \$DBG/crosvm --log-level info --extended-status run \\
  --name poolvm \\
  --mem $MEMMB --cpus 2 --hypervisor gunyah \\
  --protected-vm-without-firmware --no-balloon --disable-sandbox --hugepages \\
  --prepare-lend-mthp-mode $MTHP --swiotlb 128 \\
  --socket \$DBG/poolvm.sock \\
  \$BLOCK_OPT \\
  --net tap-name=$TAP,mac=$MAC \\
  --serial type=file,hardware=serial,num=1,earlycon,console,path=\$DBG/console.log \\
  \$APP/usr/share/droidvm/edk2-gunyah.fd
EOF
    $A push "$SP/poolrun.sh" /data/local/tmp/poolrun.sh >/dev/null 2>&1
    $A shell "su -c 'cat /data/local/tmp/poolrun.sh > $DBG/poolrun.sh; rm -f $DBG/crosvm.log $DBG/console.log $DBG/poolvm.sock'" >/dev/null 2>&1
    $A shell "su -mm -c 'setsid sh -c \"sh $DBG/poolrun.sh > $DBG/crosvm.log 2>&1\" &'" >/dev/null 2>&1 &
    sleep 8
    P=$($A shell su -c "ps -Ao pid,args" 2>/dev/null | grep "[c]rosvm --log-level" | awk '{print $1}' | head -1 | tr -d '\r')
    echo "crosvm pid=${P:-NONE}  pool1=${POOL_MB}M(pre ${POOL_PREALLOC_MB}M step ${POOL_STEP_MB}M) gap=${POOL2_GAP_MB}M pool2=${POOL2_MB}M EXEC=$EXEC PROBE=${PROBE:-none} HIDE=${HIDE:-none}"
    [ -n "$P" ] || { $A shell su -c "tail -25 $DBG/crosvm.log" 2>/dev/null | tr -d '\r'; exit 1; }
    for _ in 1 2 3 4 5 6 7 8; do
        $A shell "su -c 'ip link set $TAP up; ip link set $TAP master $BRIDGE'" >/dev/null 2>&1
        state=$($A shell su -c "ip link show $TAP 2>/dev/null | head -1" 2>/dev/null | tr -d '\r')
        case "$state" in *master*$BRIDGE*) break ;; esac
        sleep 3
    done
    echo "tap: ${state:-missing}"
    pkill -f "[t]ail .*$DBG/crosvm.log" 2>/dev/null
    setsid bash -c "adb -s 172.22.74.2:$PHONE shell su -c 'tail -n +1 -F $DBG/crosvm.log'" > "$LOG" 2>&1 </dev/null &
    echo "guest will be at $GUEST6 ; log -> $LOG"
    ;;
ip)
    echo "$GUEST6"
    $A shell su -c "ip -6 neigh show dev $BRIDGE" 2>/dev/null | tr -d '\r' | grep -i "$(echo $MAC | tr 'A-Z' 'a-z')" | head -3
    ;;
console)
    $A shell su -c "tail -${2:-40} $DBG/console.log" 2>/dev/null | tr -d '\r'
    ;;
stop)
    # `crosvm stop` exits the VM immediately -- the guest never flushes, and everything written
    # during the session comes back as zero-length files next boot (measured, the hard way).
    # Shut the guest down from inside first; the socket is only the fallback.
    timeout 60 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=8 "root@$GUEST6" "sync; systemctl poweroff" >/dev/null 2>&1
    for _ in $(seq 1 20); do
        $A shell su -c "ps -Ao args" 2>/dev/null | grep -q "[c]rosvm --log-level" || break
        sleep 3
    done
    $A shell su -c "$DBG/crosvm stop $DBG/poolvm.sock" >/dev/null 2>&1
    for _ in $(seq 1 20); do
        $A shell su -c "ps -Ao args" 2>/dev/null | grep -q "[c]rosvm --log-level" || { echo stopped; break; }
        sleep 3
    done
    $A shell su -c "ps -Ao args" 2>/dev/null | grep -q "[c]rosvm --log-level" && {
        echo "still up; SIGTERM (never -9: leaks memparcels)"
        P=$($A shell su -c "ps -Ao pid,args" 2>/dev/null | grep "[c]rosvm --log-level" | awk '{print $1}' | head -1 | tr -d '\r')
        [ -n "$P" ] && $A shell su -c "kill -TERM $P"; sleep 8; }
    served_live > /dev/null
    echo "pool now: $(param pool_avail)/$(param pool_want) pages"
    ;;
log)
    tail -${2:-40} "$LOG"
    ;;
esac
