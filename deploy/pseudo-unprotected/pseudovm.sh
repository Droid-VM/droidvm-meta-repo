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

# MODE=old runs this exact rig -- same kernel, same devices, same flags -- as an ordinary
# protected VM. It is the control that separates "the new mode is wrong" from "this kernel or
# this command line never worked here".
MODE=${MODE:-new}
[ "$MODE" = old ] && PROT_ARG=--protected-vm-without-firmware || PROT_ARG=--protected-vm-pseudo-unprotected
MEMMB=${MEMMB:-2048}
CPUS=${CPUS:-2}
# Have the shim execute two instructions out of the window before handing over. On by default
# here because this rig exists to prove the mode works on a device, and that is the one question
# no probe inside Linux can answer.
PROBE_EXEC=${PROBE_EXEC:-1}
# How much of the VM is lent to boot in. Everything above it is the window.
BOOT_MB=${BOOT_MB:-4}
# SWIOTLB=<MB> adds a bounce pool the mode does not need, for comparing against the old one.
SWIOTLB=${SWIOTLB:-}
[ -n "$SWIOTLB" ] && SWIOTLB_ARG="--swiotlb $SWIOTLB" || SWIOTLB_ARG=""
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
    # Inner single quotes so the whole thing runs under su. Written the other way round, su gets
    # only the first command and the copy runs as `shell`, which cannot write into a directory
    # root just made -- and says nothing about it.
    $A shell "su -c 'mkdir -p $DBG; cp /data/local/tmp/$b $dst; chmod 755 $dst'" >/dev/null 2>&1
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

    # Optional arguments travel as shell variables rather than as lines of the command: an empty
    # continuation line ends the command right there, and the failure ("Executable is not
    # specified") points at the last argument rather than at the blank line that swallowed it.
    if [ "$what" = edk2 ]; then
        IMAGE="\$APP/usr/share/droidvm/edk2-gunyah.fd"
        INITRD_ARG=""
    else
        IMAGE="\$DBG/Image"
        INITRD_ARG="--initrd $DBG/initrd.img"
    fi
    [ -n "$DISK" ] && DISK_ARG="--block $DISK,lock=false" || DISK_ARG=""

    cat > "$SP/pseudorun.sh" <<EOF
#!/system/bin/sh
DBG=$DBG
APP=$APP
export LD_LIBRARY_PATH=\$DBG:\$APP/usr/lib
export LD_PRELOAD=\$APP/lib/libsimpledump.so:\$APP/lib/libcompat_a16.so
export TMPDIR=/data/local/tmp
export RUST_LOG=info
# Two host modules this mode cannot do without, normally loaded by the app's Kernel Module page.
# A reboot clears them and the failures that follow point anywhere but here, so load them.
#
#   host-share  the window is handed over with a runtime SHARE through /dev/gunyah_share; without
#               it the failure arrives as ENOENT from deep inside VM start.
#   kvcalloc    gh_vm_mem_alloc sizes its pinned-page array by 4 KiB pages and kmallocs it in one
#               piece: 4 MiB, order 10, for a 2 GiB parcel. It succeeds on a freshly booted phone
#               and fails on a used one -- the same VM, an hour apart. The module makes that
#               allocation a kvmalloc.
for KO in \$APP/usr/lib/modules/*/gunyah-kvcalloc-gki-*.ko; do
    [ -f "\$KO" ] && insmod "\$KO" 2>/dev/null && break
done
if [ ! -e /dev/gunyah_share ]; then
    for KO in \$APP/usr/lib/modules/*/gunyah-host-share-gki-*.ko; do
        [ -f "\$KO" ] && insmod "\$KO" 2>/dev/null && break
    done
    [ -e /dev/gunyah_share ] || echo "WARNING: no /dev/gunyah_share -- the window cannot be shared"
fi
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
echo advise  > /sys/kernel/mm/transparent_hugepage/shmem_enabled
echo 3 > /proc/sys/vm/drop_caches
ulimit -n 65536
ulimit -l unlimited
PROT_ARG="$PROT_ARG"
DISK_OPT="$DISK_ARG"
INITRD_OPT="$INITRD_ARG"
SWIOTLB_OPT="$SWIOTLB_ARG"
export DROIDVM_SHIM_PROBE_EXEC=$PROBE_EXEC
export DROIDVM_SHIM_BOOT_MB=$BOOT_MB
# No --swiotlb: the guest's RAM is host-visible, so there is nothing to bounce through and no
# restricted-dma-pool node for a guest kernel to need a config option for.
exec \$DBG/crosvm --log-level info --extended-status run \\
  --name pseudovm \\
  --mem $MEMMB --cpus $CPUS --hypervisor gunyah \\
  $PROT_ARG --no-balloon --disable-sandbox --hugepages \\
  --prepare-lend-mthp-mode $MTHP \\
  --socket \$DBG/pseudovm.sock \\
  --dump-device-tree-blob \$DBG/vm.dtb \\
  \$DISK_OPT \$INITRD_OPT \$SWIOTLB_OPT \\
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
