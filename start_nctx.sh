#!/system/bin/sh
cd /data/local/tmp
set -eu
sync
# --- Memory prep ---
echo "=== Memory prep ==="
echo "Killing background apps..."
#am kill-all 2>/dev/null
echo "force_empty apps..."
# echo "drop_caches..."
echo 3 > /proc/sys/vm/drop_caches
echo "compact_memory..."
echo 1 > /proc/sys/vm/compact_memory
echo "=== Memory prep done ==="
cat /proc/meminfo | head -3

echo "drop_caches..."
echo 3 > /proc/sys/vm/drop_caches
echo "compact_memory..."
echo 1 > /proc/sys/vm/compact_memory
echo "drop_caches (post-compact)..."
echo 3 > /proc/sys/vm/drop_caches

ulimit -l unlimited
sleep 5

cd /data/local/tmp
rm -f crosvm.sock
pkill crosvm || true

VM_MEM_MB=800
HUGEPAGE_KB=2048
MIN_LEFT_MB=64
export CROSVM_ROOT=/data/local/tmp/crosvm_out
chmod 755 -R $CROSVM_ROOT

get_available_hugepages() {
    awk '$1=="Node" && $3=="zone" { total += $14 + $15 * 2 } END { print total + 0 }' /proc/buddyinfo
}

required_hugepages=$((VM_MEM_MB * 1024 / HUGEPAGE_KB))
min_left_hugepages=$((MIN_LEFT_MB * 1024 / HUGEPAGE_KB))
available_hugepages=$(get_available_hugepages)

[ -n "$available_hugepages" ] || {
    echo "Failed to parse hugepages" >&2
    exit 1
}

if [ "$available_hugepages" -lt "$required_hugepages" ]; then
    echo "Warning: hugepages may be insufficient for --mem ${VM_MEM_MB} (${available_hugepages}/${required_hugepages}, short $(((required_hugepages - available_hugepages) * HUGEPAGE_KB / 1024)) MiB)"
    # exit 1
else
    if [ $((available_hugepages - required_hugepages)) -lt "$min_left_hugepages" ]; then
        echo "Warning: hugepages left after --mem ${VM_MEM_MB} may be below ${MIN_LEFT_MB} MiB (left $(((available_hugepages - required_hugepages) * HUGEPAGE_KB / 1024)) MiB)"
    fi
fi

ifname=crosvm_tap
subnet=10.203.0.0/24
host_ip=10.203.0.1/24

# 创建 tap 接口（仅首次）
if [ ! -d /sys/class/net/$ifname ]; then
    ip tuntap add mode tap vnet_hdr $ifname
    ip addr add $host_ip dev $ifname
    ip link set $ifname up
fi

# iptables 规则：先删再加，保证幂等
iptables -D INPUT -j ACCEPT -i $ifname 2>/dev/null || true
iptables -D OUTPUT -j ACCEPT -o $ifname 2>/dev/null || true
iptables -I INPUT -j ACCEPT -i $ifname
iptables -I OUTPUT -j ACCEPT -o $ifname

iptables -t nat -D POSTROUTING -j MASQUERADE -s $subnet 2>/dev/null || true
iptables -t nat -I POSTROUTING -j MASQUERADE -s $subnet

iptables -j ACCEPT -D FORWARD -i $ifname 2>/dev/null || true
iptables -j ACCEPT -D FORWARD -o $ifname -m state --state ESTABLISHED,RELATED 2>/dev/null || true
iptables -j ACCEPT -I FORWARD -i $ifname
iptables -j ACCEPT -I FORWARD -o $ifname -m state --state ESTABLISHED,RELATED

sysctl -w net.ipv4.ip_forward=1

# ip rule：先删再加，保证幂等
ip rule del to $subnet lookup main priority 100 2>/dev/null || true
ip rule add to $subnet lookup main priority 100

get_wan_table() {
    route_line=$(ip route get 8.8.8.8 2>/dev/null | head -1 || true)
    table=$(echo "$route_line" | sed -n 's/.* table \([^ ]*\).*/\1/p')
    if [ -n "$table" ]; then
        echo "$table"
        return 0
    fi
    echo main
}


wan_table=$(get_wan_table)
ip rule del iif $ifname priority 9999 2>/dev/null || true
ip rule add iif $ifname lookup $wan_table priority 9999

WAN_PID=
DNSMASQ_PID=

# 脚本退出时同步终止 wan-monitor 和 dnsmasq
cleanup() {
    [ -n "${WAN_PID:-}" ] && kill "$WAN_PID" 2>/dev/null || true
    [ -n "${DNSMASQ_PID:-}" ] && kill "$DNSMASQ_PID" 2>/dev/null || true
}
trap cleanup EXIT TERM

(
    current_table=$wan_table
    while true; do
        sleep 5

        new_table=$(get_wan_table)
        [ -z "$new_table" ] && new_table=main
        if [ "$new_table" != "$current_table" ]; then
            ip rule del iif $ifname lookup $current_table priority 9999 2>/dev/null || true
            ip rule add iif $ifname lookup $new_table priority 9999
            current_table=$new_table
            echo "[wan-monitor] switched to table: $current_table"
        fi
    done
) &
WAN_PID=$!

# dnsmasq：每次启动前清掉旧进程
./dnsmasq --interface=$ifname --bind-interfaces \
      --listen-address=10.203.0.1 \
      --dhcp-range=10.203.0.2,10.203.0.10,255.255.255.0,12h \
      --dhcp-option=option:router,10.203.0.1 \
      --dhcp-option=option:dns-server,8.8.8.8,1.1.1.1 \
      --no-daemon --log-queries   --no-resolv &
DNSMASQ_PID=$!

ulimit -l unlimited

# crosvm run --hypervisor "gunyah[blob-mode=guest-accept]"   # 6.1
# crosvm run --hypervisor "gunyah[blob-mode=host-share]"  #6.6

BASELINE_KERNEL=/data/data/cn.classfun.droidvm/usr/share/droidvm/vmlinuz
BASELINE_INITRD=/data/data/cn.classfun.droidvm/usr/share/droidvm/initramfs.img

TARGET_KERNEL=/data/data/cn.classfun.droidvm/cache/boot/526795fd-0bbf-43d6-976e-287b43f75a80/kernel
TARGET_INITRD=/data/data/cn.classfun.droidvm/cache/boot/526795fd-0bbf-43d6-976e-287b43f75a80/initrd

KERNEL=$BASELINE_KERNEL
INITRD=$BASELINE_INITRD

KERNEL=$TARGET_KERNEL
INITRD=$TARGET_INITRD

LBX=/data/data/cn.classfun.droidvm/bin/lbx
DISK=/storage/emulated/0/DroidVM/ubuntu-resolute-cloud-arm64-20260615_0742.qcow2


# LD_PRELOAD=./libbinder_ndk.so:./libbinder.so \
LD_PRELOAD=$CROSVM_ROOT/libsimpledump.so GFXSTREAM_LOG_LEVEL=info $CROSVM_ROOT/crosvm --log-level debug run \
  --disable-sandbox \
  --hugepages \
  --no-balloon \
  --protected-vm-without-firmware \
  --hypervisor "gunyah[blob_mode=host-share]" \
  --android-display-service crosvm_display \
  --gpu='backend=virglrenderer,context-types=drm,egl=true,gles=true,external-blob=true,pci-bar-size=0x1000000,displays=[[mode=windowed[1920,1080],dpi=[320,320],refresh-rate=60]]' \
  --swiotlb 64 \
  --params 'root=/dev/vda2 init=/bin/bash' \
  --initrd $INITRD \
  --mem "$VM_MEM_MB" \
  --cpus 8 \
  -s /data/local/tmp/crosvm.sock \
  --net tap-name=$ifname \
  --serial type=stdout,hardware=virtio-console,console=true,stdin=true \
  -b $DISK,lock=false \
  $KERNEL 2>&1 | tee logs/"run-crosvm-$(date +%Y%m%d_%H%M%S).log"
