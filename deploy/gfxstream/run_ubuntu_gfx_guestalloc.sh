#!/system/bin/sh
# Config 4 of 4: GUEST-ALLOC. The guest virtio-gpu driver owns a SHARE-blessed pool and
# sub-allocates BLOB_MEM_GUEST from it with drm_buddy, handing the host dma-bufs through
# udmabuf. crosvm ignores vram-limit here -- the guest pool is the cap.
# Expect: guest dmesg has_create_guest_handle=1 plus the drm_buddy pool line.
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

echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true

export LD_LIBRARY_PATH="$DIR:/data/data/cn.classfun.droidvm/usr/lib"
export ANDROID_EMU_VK_LOADER_PATH=/data/data/cn.classfun.droidvm/usr/lib/libvulkan_freedreno.so
export GFXSTREAM_DEVICE_LOCAL_MEMORY_TYPE=1

export RUST_LOG=info,devices::virtio::gpu=debug,hypervisor::gunyah=debug,vm_control=debug
exec "$DIR/crosvm" --log-level info,rutabaga_gfx=debug,devices::virtio::gpu=debug,hypervisor::gunyah=debug,vm_control=debug --extended-status run \
  --name "ubuntu 26 guestalloc" \
  --mem 4096 --cpus 4 \
  --hypervisor gunyah \
  --protected-vm-without-firmware \
  --no-balloon --disable-sandbox --hugepages \
  --prepare-lend-mthp-mode chunked \
  --pre-alloc "gfx-host-mb=256,gfx-guest-mb=1024" \
  --swiotlb 128 \
  --socket "$DIR/ubuntu.sock" \
  --smbios "processor-version=Qualcomm Snapdragon 8 Elite" \
  --block "$QCOW,lock=false" \
  --net "tap-name=$TAP,mac=$MAC" \
  --gpu "backend=gfxstream,context-types=gfxstream-vulkan,egl=true,gles=true,external-blob=true,vulkan=true,displays=[[mode=windowed[1280,720],refresh-rate=30,dpi=[160,160]]],pci-bar-size=4294967296,udmabuf=true,gunyah-pvm=true" \
  --vnc-server "host=0.0.0.0,port=5900,input=tablet" \
  --initrd "$INITRD" \
  --params "root=/dev/vda2 rw console=ttyS0 loglevel=4" \
  --serial "type=file,hardware=serial,num=1,earlycon,console,path=$DIR/serial.log,input=$DIR/con.in" \
  "$KERNEL" > "$DIR/crosvm.log" 2>&1
