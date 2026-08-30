#!/system/bin/sh
# Config 2 of 4: FUSION. Host-visible blobs up to pool-blob-max-kb come from the pool;
# anything larger goes straight to the runtime-SHARE path. vram-limit caps the
# runtime-shared side.
# Expect in the host log: BOTH GFXPOOL alloc lines and GUNYAH-SHARE-BLOB lines.
set -u
DIR=/data/local/tmp/crosvm_gfx
QCOW=/data/media/0/DroidVM/ubuntu-resolute-cloud-arm64-20260615_0742.qcow2
BOOT=/data/data/cn.classfun.droidvm/cache/boot/526795fd-0bbf-43d6-976e-287b43f75a80
KERNEL="$BOOT/kernel"
INITRD="$BOOT/initrd"
TAP=vm526795fd-0
MAC=02:ba:73:6e:7d:90
BR=br-wifi

rm -f "$DIR/ubuntu.sock"
rm -f "$DIR/con.in"
mkfifo "$DIR/con.in"
setsid sh -c "exec tail -f /dev/null > $DIR/con.in" </dev/null >/dev/null 2>&1 &

if ! ip link show "$TAP" >/dev/null 2>&1; then
    ip tuntap add dev "$TAP" mode tap
    echo "created tap $TAP"
fi
# Attach every time, not just when the tap is created. The app rebuilds br-wifi on each start,
# which orphans an existing tap: the device stays present and up, so an "is there a tap" check
# passes while nothing is enslaved to the bridge and the guest has no path to the network. That
# failure is silent and looks exactly like a guest networking bug from inside the VM.
ip link set "$TAP" master "$BR"
ip link set "$TAP" up

# The pool is mlock'd, and crosvm now refuses to SHARE a pool it could not pin.
ulimit -l unlimited

# Runtime SHARE needs /dev/gunyah_share. Without it every host-visible blob that is not
# pool-resident fails to map, and the guest reports "Failed to create virtgpu AddressSpaceStream"
# / "mmap64 failed with (Invalid argument)" -- which reads like a gfxstream bug rather than a
# missing host module. The app's Kernel Module page loads this; a manual launch has to too.
if [ ! -e /dev/gunyah_share ]; then
    for KO in /data/data/cn.classfun.droidvm/usr/lib/modules/*/gunyah-host-share-gki-*.ko; do
        [ -f "$KO" ] && insmod "$KO" 2>/dev/null && break
    done
    [ -e /dev/gunyah_share ] && echo "loaded gunyah host-share" \
                             || echo "WARNING: no /dev/gunyah_share -- runtime-SHARE blobs will fail to map"
fi

echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true

# Debug logging is for diagnosis, not for measurement. `rutabaga_gfx=debug` costs one log line
# per GEM_SUBMIT on the DRM route -- crosvm.log reached 1.15 GB in a benchmark run, and the same
# configuration scored 2721 with it on against 5143 with it off. It is off by default for that
# reason; set CROSVM_LOG to turn it back on when something needs diagnosing:
#   CROSVM_LOG=info,rutabaga_gfx=debug,devices::virtio::gpu=debug,hypervisor::gunyah=debug
LOG=${CROSVM_LOG:-warn}

export LD_LIBRARY_PATH="$DIR:/data/data/cn.classfun.droidvm/usr/lib"
export ANDROID_EMU_VK_LOADER_PATH=/data/data/cn.classfun.droidvm/usr/lib/libvulkan_freedreno.so
export GFXSTREAM_DEVICE_LOCAL_MEMORY_TYPE=1

export RUST_LOG=$LOG
exec "$DIR/crosvm" --log-level "$LOG" --extended-status run \
  --name "ubuntu 26 fusion" \
  --mem 4096 --cpus 4 \
  --hypervisor gunyah \
  --protected-vm-without-firmware \
  --no-balloon --disable-sandbox --hugepages \
  --prepare-lend-mthp-mode chunked \
  --pre-alloc "gfx-host-mb=1024" \
  --swiotlb 128 \
  --socket "$DIR/ubuntu.sock" \
  --smbios "processor-version=Qualcomm Snapdragon 8 Elite" \
  --block "$QCOW,lock=false" \
  --net "tap-name=$TAP,mac=$MAC" \
  --gpu "backend=gfxstream,context-types=gfxstream-vulkan,egl=true,gles=true,external-blob=true,vulkan=true,displays=[[mode=windowed[1280,720],refresh-rate=30,dpi=[160,160]]],pci-bar-size=4294967296,vram-limit=2048,pool-blob-max-kb=4096,gunyah-pvm=true" \
  --vnc-server "host=0.0.0.0,port=5900,input=tablet" \
  --initrd "$INITRD" \
  --params "root=/dev/vda2 rw console=ttyS0 loglevel=4" \
  --serial "type=file,hardware=serial,num=1,earlycon,console,path=$DIR/serial.log,input=$DIR/con.in" \
  "$KERNEL" > "$DIR/crosvm.log" 2>&1
