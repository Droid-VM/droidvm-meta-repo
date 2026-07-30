#!/bin/bash
# Boot each configuration in turn, benchmark it, shut it down.
#
#   deploy/gfxstream/bench_all.sh [label...]     default: the four gfxstream configs
#
# Each entry is "<label>:<dir>:<launcher>". The DRM route lives in its own directory with its own
# crosvm and libraries, and needs its own guest mesa, so it is not in the default set -- run it
# separately once the guest has been provisioned for it.
#
# NEVER kill -9 crosvm. A SIGKILL'd crosvm leaks its Gunyah memparcels, and the RM does not
# reclaim them until the phone reboots; the next run then fails to SHARE its pool and looks like
# a pool-sizing bug. Shutdown here is `systemctl poweroff` inside the guest, waited on.
set -u
cd "$(dirname "$0")"
PHONE=${PHONE:-172.22.74.2:5568}
GUEST=${GUEST:-root@172.22.68.12}
A="adb -s $PHONE shell"
SSH="ssh -o ConnectTimeout=6 -o StrictHostKeyChecking=no $GUEST"

CONFIGS=(
  "purepool:crosvm_gfx:run_ubuntu_gfx_purepool.sh"
  "fusion:crosvm_gfx:run_ubuntu_gfx_fusion.sh"
  "runtimeshare:crosvm_gfx:run_ubuntu_gfx.sh"
  "guestalloc:crosvm_gfx:run_ubuntu_gfx_guestalloc.sh"
  "drm2kgsl:crosvm_drm2kgsl:run_drm2kgsl_nctx.sh"
)

vm_count() { $A "su -c 'ps -A -o ARGS | grep -c \"[c]rosvm --log-level\"'" 2>/dev/null | tr -d '\r'; }

vm_down() {
    [ "$(vm_count)" = 0 ] && return 0
    $SSH 'nohup systemctl poweroff >/dev/null 2>&1 &' >/dev/null 2>&1
    for i in $(seq 1 30); do
        [ "$(vm_count)" = 0 ] && { echo "  vm down"; return 0; }
        sleep 10
    done
    echo "  !! VM still up after 300s -- NOT killing it (see the note at the top of this file)"
    return 1
}

vm_up() {   # $1 dir, $2 launcher
    $A "su -c 'setsid sh /data/local/tmp/$1/$2 </dev/null >/dev/null 2>&1 &'" >/dev/null 2>&1
    for i in $(seq 1 45); do
        sleep 8
        $SSH 'echo up' 2>/dev/null | grep -q up && { echo "  guest up after $((i*8))s"; return 0; }
    done
    echo "  !! guest never came up"
    return 1
}

# ssh answering is not the same as the desktop being up. vkmark needs the wayland socket and
# exits without printing a score if it is missing, which reads as vkmark failing.
#
# The session does not always come up on its own, and mc_bench.sh has always known this -- it
# restarts gdm when the socket is missing. Waiting without that kick is STRICTER THAN REALITY: it
# rejected all four gfxstream configurations in a sweep that would otherwise have run, and
# blamed the guest's mesa for it.
desktop_wait() {
    for _ in $(seq 1 12); do
        $SSH 'test -S /run/user/1001/wayland-0' 2>/dev/null && return 0
        sleep 10
    done
    echo "  no session after 120s -- restarting gdm"
    $SSH 'systemctl restart gdm' >/dev/null 2>&1
    for _ in $(seq 1 18); do
        sleep 10
        $SSH 'test -S /run/user/1001/wayland-0' 2>/dev/null && { echo "  desktop up after gdm restart"; return 0; }
    done
    echo "  !! no desktop session even after restarting gdm -- is the guest's mesa the one this route needs?"
    return 1
}

# The app owns br-wifi and the app keeps going away; when it does, the next VM boots with no
# network at all and every ssh in this script times out. Checked per configuration, not once.
bridge_up() {
    $A "su -c 'ip link show br-wifi'" >/dev/null 2>&1 && return 0
    echo "  br-wifi missing -- starting the app"
    $A 'am start -n cn.classfun.droidvm/.ui.SplashActivity' >/dev/null 2>&1
    for _ in $(seq 1 15); do sleep 4; $A "su -c 'ip link show br-wifi'" >/dev/null 2>&1 && return 0; done
    echo "  !! br-wifi never appeared"; return 1
}

# The phone's display must stay awake for the whole sweep. mc_bench.sh explains why the clock
# matters; the screen is the same variable by another route -- with the display dozing the
# governor has no reason to raise the GPU, and a run taken that way lands at the bottom of the
# table for a reason that has nothing to do with the configuration under test. A 30-minute
# screen_off_timeout is shorter than this sweep, so it WILL fire if left alone.
$A 'input keyevent KEYCODE_WAKEUP; svc power stayon true' >/dev/null 2>&1
trap "$A 'svc power stayon false' >/dev/null 2>&1" EXIT

# Everything below exists because a host-OOM that killed two runs left no evidence: the crosvm log
# was overwritten by the next configuration, dmesg was cleared by a host reboot three minutes
# later, and memory was only ever sampled after the fact. None of that is recoverable
# retrospectively, so it has to be collected as it happens.
DIAG=${DIAG:-/tmp/mc_bench/diag}
mkdir -p "$DIAG"

# What state the host was in BEFORE the run. The udmabuf hijack module is the one that matters:
# without it the built-in serves with a 64 MiB cap and a kmalloc_array that fails on order-6, and
# a run made in that state looks like every other run. Not checking this once already led to
# reporting "the module was loaded" from an observation taken before a DIFFERENT run.
host_state() {
    {
        echo "=== $1 @ $(date -u +%FT%TZ) ==="
        echo "-- udmabuf modules (refcount matters: 0 means nothing is using it) --"
        $A "su -c 'lsmod | grep -i udmabuf; for m in /sys/module/udmabuf*/parameters; do
              echo \"[\$m]\"; for p in \$m/*; do echo \"  \$(basename \$p)=\$(cat \$p 2>/dev/null)\"; done; done'" 2>/dev/null
        echo "-- gunyah reserve pool (units are 2MB pages) --"
        $A "su -c 'for p in pool_avail pool_want pool_size_max served_summary; do
              echo \"  \$p=\$(cat /sys/module/gh_hugepage_reserve/parameters/\$p 2>/dev/null)\"; done'" 2>/dev/null
        echo "-- /dev nodes --"
        $A "su -c 'ls -la /dev/gunyah_share /dev/udmabuf 2>&1'" 2>/dev/null
        echo "-- meminfo --"
        $A "su -c 'grep -E \"^MemTotal|^MemFree|^MemAvailable|^Cached:\" /proc/meminfo'" 2>/dev/null
    } | tr -d '\r'
}

# One line every 5s. Whether memory drains slowly or falls off a cliff separates a leak from a
# single oversized allocation, and only a time series shows which.
sample_start() {
    $A "su -c 'rm -f /data/local/tmp/memsample.txt;
        setsid sh /data/local/tmp/memsample.sh > /data/local/tmp/memsample.txt 2>/dev/null </dev/null &'" >/dev/null 2>&1
}
sample_stop() {   # $1 = label
    $A "su -c 'pkill -f memsample.sh'" >/dev/null 2>&1
    $A "su -c 'cat /data/local/tmp/memsample.txt'" 2>/dev/null | tr -d '\r' \
        > "$DIAG/$1.mem.tsv"
    awk 'NR==1{f=$2} {l=$2; p=$3} END{if(NR) printf "  memory: MemFree %.0f -> %.0fMB over %d samples, pool_avail ended %s\n", f/1024, l/1024, NR, p}' \
        "$DIAG/$1.mem.tsv"
}

# Kernel-side allocation failures appear ONLY in dmesg, and a host reboot erases them. Cleared
# before, captured after, kept per label.
# `dmesg -c` is not dependable here, so take a line count before and the tail after. That also
# leaves the ring buffer intact for anyone else looking at it.
DMESG_MARK=0
dmesg_clear() { DMESG_MARK=$($A "su -c 'dmesg | wc -l'" 2>/dev/null | tr -dc 0-9); : "${DMESG_MARK:=0}"; }
dmesg_save()  {
    $A "su -c 'dmesg'" 2>/dev/null | tr -d '\r' | tail -n "+$((DMESG_MARK + 1))" > "$DIAG/$1.dmesg.txt"
    local n
    n=$(grep -ciE "page allocation failure|Out of memory|oom-kill|order-[0-9]+.*fail|udmabuf" "$DIAG/$1.dmesg.txt" 2>/dev/null || echo 0)
    [ "$n" != 0 ] && echo "  dmesg: $n lines matching allocation-failure/udmabuf -- see $DIAG/$1.dmesg.txt"
}

# The launcher always writes $DIR/crosvm.log, so the next configuration overwrites it. Copy it off
# under the label while it is still the right one.
crosvm_log_save() {   # $1 = label, $2 = dir
    $A "su -c 'cat /data/local/tmp/$2/crosvm.log'" 2>/dev/null | tr -d '\r' > "$DIAG/$1.crosvm.log"
    local n
    n=$(grep -ciE "error|panic|fatal|Out of memory" "$DIAG/$1.crosvm.log" 2>/dev/null || echo 0)
    echo "  crosvm.log: $(wc -l < "$DIAG/$1.crosvm.log") lines, $n matching error/OOM -> $DIAG/$1.crosvm.log"
}

want=("$@")
for entry in "${CONFIGS[@]}"; do
    IFS=: read -r label dir launcher <<< "$entry"
    if [ ${#want[@]} -gt 0 ]; then
        printf '%s\n' "${want[@]}" | grep -qx "$label" || continue
    fi
    echo "########## $label ##########"
    bridge_up || continue
    vm_down || continue
    vm_up "$dir" "$launcher" || continue
    desktop_wait || { vm_down; continue; }
    # Minecraft rewrites preferredGraphicsBackend to "default" (= zink/OpenGL) after a Vulkan
    # crash, and then every later run silently measures zink. The log line is the only place it
    # shows; the fps still reads fine. Force it back before each configuration.
    $SSH 'f=$(ls /home/*/.minecraft/options.txt 2>/dev/null | head -1);
          [ -n "$f" ] && { sed -i "/^preferredGraphicsBackend:/d" "$f";
                           echo "preferredGraphicsBackend:\"vulkan\"" >> "$f"; }' >/dev/null 2>&1
    host_state "before $label" > "$DIAG/$label.host-before.txt"
    grep -E "udmabuf_gki|pool_avail=|MemFree" "$DIAG/$label.host-before.txt" | head -3 | sed 's/^/  /'
    dmesg_clear
    sample_start

    ./bench_one.sh "$label"

    sample_stop "$label"
    dmesg_save "$label"
    crosvm_log_save "$label" "$dir"
    host_state "after $label" > "$DIAG/$label.host-after.txt"
    vm_down
done

echo
echo "label|vkmark|vk_gpu%|mc_fps|mc_gpu%|backend|clocks"
cat /tmp/mc_bench/results.psv 2>/dev/null
