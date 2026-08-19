#!/bin/bash
# Boot something in a pseudo-unprotected VM: the guest's RAM is shared to it at run time rather
# than lent before boot, so the host can still reach it and no bounce pool is needed.
#
# The point of the exercise is a stock distribution kernel. A protected VM needs the guest to
# carry CONFIG_RESTRICTED_DMA_POOL, because its memory is lent and every virtio buffer has to go
# through a pool the host can see; no distribution builds that, so no distribution kernel boots.
# Here there is nothing to bounce through.
#
#   PHONE=5567 KERNEL=Image INITRD=initrd.img pseudovm.sh direct     boot a kernel
#   PHONE=5567 pseudovm.sh edk2                                      boot the firmware
#   PHONE=5567 pseudovm.sh handoff                                   what the shim reported
#   PHONE=5567 pseudovm.sh console 60
#   PHONE=5567 pseudovm.sh stop
set -u
PHONE=${PHONE:-5567}
A="adb -s 172.22.74.2:$PHONE"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DBG=/data/local/tmp/pseudovm
APP=/data/data/cn.classfun.droidvm
SP="$(dirname "$0")"
LOG=${LOG:-/tmp/pseudovm_$PHONE.log}

MEMMB=${MEMMB:-2048}
CPUS=${CPUS:-2}
PROBE_EXEC=${PROBE_EXEC:-1}
KERNEL=${KERNEL:-}
INITRD=${INITRD:-}
DISK=${DISK:-}
PARAMS=${PARAMS:-console=ttyS0 earlycon panic=10}
case "$PHONE" in 5567) MTHP=single ;; *) MTHP=chunked ;; esac

param() { $A shell su -c "cat /sys/module/gh_hugepage_reserve/parameters/$1" 2>/dev/null | tr -dc 0-9; }

push_one() {
    local src=$1 dst=$2 b
    b=$(basename "$dst")
    $A push "$src" /data/local/tmp/"$b" >/dev/null 2>&1 || { echo "push $b failed"; exit 1; }
    $A shell su -c "mkdir -p $DBG; cp /data/local/tmp/$b $dst && chmod 755 $dst" >/dev/null 2>&1
    local l r
    l=$(md5sum "$src" | cut -c1-32)
    r=$($A shell su -c "md5sum $dst" 2>/dev/null | cut -c1-32 | tr -d '\r')
    [ "$l" = "$r" ] || { echo "MD5 MISMATCH $b"; exit 1; }
    echo "  ok $b"
}

case "${1:-direct}" in
push)
    keep=$($A shell su -c "ls $APP/usr/lib" 2>/dev/null | tr -d '\r')
    for f in "$ROOT"/crosvm_out/*; do
        b=$(basename "$f")
        case "$b" in
            *.so) printf '%s\n' "$keep" | grep -qx "$b" || continue ;;
        esac
        push_one "$f" "$DBG/$b"
    done
    [ -n "$KERNEL" ] && push_one "$KERNEL" "$DBG/Image"
    [ -n "$INITRD" ] && push_one "$INITRD" "$DBG/initrd.img"
    echo "pushed and verified"
    ;;
direct|edk2)
    what=${1:-direct}
    avail=$(param pool_avail)
    need=$(( (MEMMB + 224) / 2 ))
    echo "pool $avail pages, this VM needs $need"
    [ "${avail:-0}" -ge "$need" ] || { echo "not enough reserve pool"; exit 1; }

    if [ "$what" = edk2 ]; then
        IMAGE="\$APP/usr/share/droidvm/edk2-gunyah.fd"
        INITRD_ARG=""
    else
        IMAGE="\$DBG/Image"
        INITRD_ARG="--initrd \$DBG/initrd.img \\\\"
    fi
    [ -n "$DISK" ] && DISK_ARG="--block $DISK,lock=false \\\\" || DISK_ARG=""

    cat > "$SP/pseudorun.sh" <<EOF
#!/system/bin/sh
DBG=$DBG
APP=$APP
export LD_LIBRARY_PATH=\$DBG:\$APP/usr/lib
export LD_PRELOAD=\$APP/lib/libsimpledump.so:\$APP/lib/libcompat_a16.so
export TMPDIR=/data/local/tmp
export RUST_LOG=info
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
echo advise  > /sys/kernel/mm/transparent_hugepage/shmem_enabled
echo 3 > /proc/sys/vm/drop_caches
ulimit -n 65536
ulimit -l unlimited
# No --swiotlb: the guest's RAM is host-visible, so there is nothing to bounce through and no
# restricted-dma-pool node for a guest kernel to need a config option for.
exec \$DBG/crosvm --log-level info --extended-status run \\
  --name pseudovm \\
  --mem $MEMMB --cpus $CPUS --hypervisor gunyah \\
  --protected-vm-pseudo-unprotected --no-balloon --disable-sandbox --hugepages \\
  --prepare-lend-mthp-mode $MTHP \\
  --socket \$DBG/pseudovm.sock \\
  $DISK_ARG
  $INITRD_ARG
  --params "$PARAMS" \\
  --serial type=file,hardware=serial,num=1,earlycon,console,path=\$DBG/console.log \\
  $IMAGE
EOF
    $A push "$SP/pseudorun.sh" /data/local/tmp/pseudorun.sh >/dev/null 2>&1
    $A shell "su -c 'mkdir -p $DBG; cat /data/local/tmp/pseudorun.sh > $DBG/pseudorun.sh; rm -f $DBG/crosvm.log $DBG/console.log $DBG/pseudovm.sock'" >/dev/null 2>&1
    $A shell "su -mm -c 'setsid sh -c \"sh $DBG/pseudorun.sh > $DBG/crosvm.log 2>&1\" &'" >/dev/null 2>&1 &
    sleep 10
    P=$($A shell su -c "ps -Ao pid,args" 2>/dev/null | grep "[c]rosvm --log-level" | awk '{print $1}' | head -1 | tr -d '\r')
    echo "crosvm pid=${P:-NONE} ($what, mem ${MEMMB}M, probe_exec=$PROBE_EXEC)"
    $A shell su -c "tail -40 $DBG/crosvm.log" 2>/dev/null | tr -d '\r' | grep -E "GH-SHIM|GH-POOL|GH: layout|error|ERROR" | head -12
    ;;
handoff)
    # What the shim wrote back. Status 4 is "about to jump"; 0xe000 means it gave up, and the
    # message says why -- which is the whole reason the handoff page has a return path.
    $A shell su -c "grep -aE 'GH-SHIM' $DBG/crosvm.log | tail -8" 2>/dev/null | tr -d '\r'
    ;;
console)
    $A shell su -c "tail -${2:-40} $DBG/console.log" 2>/dev/null | tr -d '\r' | tr -d '\000'
    ;;
log)
    $A shell su -c "tail -${2:-40} $DBG/crosvm.log" 2>/dev/null | tr -d '\r'
    ;;
stop)
    $A shell su -c "$DBG/crosvm stop $DBG/pseudovm.sock" >/dev/null 2>&1
    for _ in $(seq 1 15); do
        $A shell su -c "ps -Ao args" 2>/dev/null | grep -q "[c]rosvm --log-level" || { echo stopped; break; }
        sleep 2
    done
    $A shell "su -c 'echo 1 > /sys/module/gh_hugepage_reserve/parameters/reconcile'" >/dev/null 2>&1
    sleep 2
    echo "pool now: $(param pool_avail)"
    ;;
esac
