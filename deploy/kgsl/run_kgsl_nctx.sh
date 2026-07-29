#!/system/bin/sh
# Manual crosvm launch for the ubuntu VM in KGSL NATIVE-CONTEXT mode: the guest runs real
# turnip over vdrm/virtio, and virglrenderer's DRM native context translates the msm protocol
# to KGSL ioctls on the host. No Vulkan command stream is remoted.
#
# Boots through EDK2 rather than the Linux boot protocol: the firmware is the payload, EDK2
# runs UEFI -> the guest's own GRUB from the qcow ESP -> the guest's own kernel and initramfs.
# That is the point -- with a direct kernel boot the initramfs comes from the phone's copy, so
# every guest-module change needs initrd surgery on the host. Booting the guest's own /boot
# makes `update-initramfs` inside the guest sufficient. It also exercises EDK2 + GPU together.
# --protected-vm-without-firmware is required: --protected-vm routes through pvmfw, which the
# Qualcomm RM's low-memory donation breaks (MEM_START 0x80000000 does not line up).
#
# Same disk / net / vnc as the gfxstream launchers; what differs:
#   --gpu backend=virglrenderer      rutabaga runs virglrenderer, not gfxstream
#   context-types=virgl2:drm         BOTH. With plain "drm" the virgl renderer is never
#                                    initialised (NO_VIRGL), and the first CREATE_2D comes back
#                                    ComponentError(22) -- a black screen with no other symptom.
#   --pre-alloc kgsl-mb=8,gfx-guest-mb=1024
#                                    Two pools, and both are pre-alloc -- the point of this
#                                    route is that nothing is SHARE'd at runtime.
#                                      gfx-guest-mb  guest-owned drm_buddy pool. Every BO comes
#                                        from here now. The gfx- prefix is a misnomer: the
#                                        region is a SHARE'd range plus the gpu_guest_reserved
#                                        DT node, with nothing gfxstream-specific about it.
#                                      kgsl-mb       host-owned pool, now only large enough for
#                                        the msm shmem rings (16 KiB per context -- 12 contexts
#                                        with a desktop and Minecraft, so 192 KiB against an
#                                        8 MiB pool whose first 2 MiB is the RM base guard).
#                                    Dropping kgsl-mb does NOT save memory worth having: the
#                                    rings fall back to a runtime GUNYAH-SHARE-BLOB each, which
#                                    is exactly the per-allocation RM round trip this route
#                                    exists to avoid. Measured: 4 shares without it, 0 with.
#   udmabuf=true                     builds the dma-buf for a guest-allocated blob AND is what
#                                    gates VIRTIO_GPU_F_CREATE_GUEST_HANDLE. Without it the
#                                    feature is never offered, the guest reports
#                                    has_create_guest_handle=0, and guest mesa silently keeps
#                                    the host-allocating path -- a working VM that is not
#                                    testing what it looks like it is testing.
#   no vram-limit / gunyah-pvm       both are gfxstream-only consumers.
set -u
DIR=/data/local/tmp/crosvm_kgsl
QCOW=/data/media/0/DroidVM/ubuntu-resolute-cloud-arm64-20260615_0742.qcow2
EDK2=/data/data/cn.classfun.droidvm/usr/share/droidvm/edk2-gunyah.fd
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
# passes while nothing is enslaved to the bridge and the guest has no path to the network.
ip link set "$TAP" master "$BR"
ip link set "$TAP" up

# The pool is mlock'd, and crosvm now refuses to SHARE a pool it could not pin -- an unpinned
# page can be migrated out from under a stage-2 mapping the RM will never update.
ulimit -l unlimited

# The kgsl backend windows every BO onto the pool with UDMABUF_CREATE, so this route does not
# work on a stock GKI udmabuf: it caps a dmabuf at 64 MiB (EINVAL past that) and builds the page
# array with kmalloc_array, which needs an order-6 contiguous allocation for a 128 MiB buffer.
# Minecraft asks for exactly that and dies -- the guest sees RESOURCE_CREATE_BLOB fail, turnip
# hands the app a bogus mapping, and the JVM SIGSEGVs inside VulkanTransientMemory.upload.
# The app's Kernel Module page normally loads this; a manual launch has to do it too.
if ! lsmod | grep -q udmabuf_gki; then
    KO=/data/data/cn.classfun.droidvm/usr/lib/modules/android15-6.6/udmabuf-gki-6.6.ko
    [ -f "$KO" ] && insmod "$KO" 2>/dev/null
    lsmod | grep -q udmabuf_gki && echo "loaded udmabuf hijack ($(cat /sys/module/udmabuf_gki_6.6/parameters/mode 2>/dev/null))" \
                                || echo "WARNING: udmabuf hijack not loaded -- blobs over 64 MiB will fail"
fi

echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true

export LD_LIBRARY_PATH="$DIR:/data/data/cn.classfun.droidvm/usr/lib"
# kgsl_diag_log writes every record at ANDROID_LOG_ERROR and defaults to on; leave it off unless
# something is being debugged, or it shows up in any number measured here.
export CROSVM_KGSL_DIAG=0

export RUST_LOG=info,devices::virtio::gpu=debug,hypervisor::gunyah=debug,vm_control=debug
exec "$DIR/crosvm" --log-level info,rutabaga_gfx=debug,devices::virtio::gpu=debug,hypervisor::gunyah=debug,vm_control=debug --extended-status run \
  --name "ubuntu 26 kgsl" \
  --mem 4096 --cpus 4 \
  --hypervisor gunyah \
  --protected-vm-without-firmware \
  --no-balloon --disable-sandbox --hugepages \
  --prepare-lend-mthp-mode chunked \
  --pre-alloc "kgsl-mb=8,gfx-guest-mb=1024" \
  --swiotlb 128 \
  --socket "$DIR/ubuntu.sock" \
  --smbios "processor-version=Qualcomm Snapdragon 8 Elite" \
  --block "$QCOW,lock=false" \
  --net "tap-name=$TAP,mac=$MAC" \
  --gpu "backend=virglrenderer,context-types=virgl2:drm,egl=true,gles=true,udmabuf=true,displays=[[mode=windowed[1280,720],refresh-rate=30,dpi=[160,160]]],pci-bar-size=4294967296" \
  --vnc-server "host=0.0.0.0,port=5900,input=tablet" \
  --serial "type=file,hardware=serial,num=1,earlycon,console,path=$DIR/serial.log,input=$DIR/con.in" \
  "$EDK2" > "$DIR/crosvm.log" 2>&1
