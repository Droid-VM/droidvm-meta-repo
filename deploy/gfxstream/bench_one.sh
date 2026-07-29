#!/bin/bash
# Benchmark ONE already-running configuration: vkmark score and Minecraft fps, each with the
# peak GPU utilisation observed while it ran.
#
#   deploy/gfxstream/bench_one.sh <label>
#
# The VM must already be up with its desktop session started. Clock pinning is done by
# mc_bench.sh, which this calls for the Minecraft half; vkmark runs afterwards, with the same pin
# still in place, so both numbers are taken at the same clocks. Pinning matters more than
# anything else here -- see the comment block at the top of mc_bench.sh.
#
# vkmark runs on WAYLAND, as the desktop user. The session is mutter+Xwayland, so there is no
# X11 display for root to open: `DISPLAY=:0 vkmark` as root gets "Authorization required, but no
# authorization protocol specified", builds a Vulkan instance anyway, and then exits without ever
# printing a score -- which reads like vkmark failing rather than like a login problem.
#
# Peak rather than mean GPU busy: the mean is dominated by whatever the guest was doing between
# scenes, and the question these runs answer is whether a configuration can keep the GPU fed at
# all. A configuration that stalls on memory shows up as a lower peak, not a lower average.
set -u
cd "$(dirname "$0")"
PHONE=${PHONE:-172.22.74.2:5568}
GUEST=${GUEST:-root@172.22.68.12}
OUT=${OUT:-/tmp/mc_bench}
A="adb -s $PHONE shell"
SSH="ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no $GUEST"
LABEL=${1:?usage: bench_one.sh <label>}
mkdir -p "$OUT"

# Sample GPU busy% on the phone, not over adb per sample: one adb round trip is ~100ms, so a
# per-sample shell would miss most of the window and undercount the peak badly.
gpu_sample_start() {
    $A "su -c 'rm -f /data/local/tmp/gpubusy.txt;
        setsid sh -c \"while true; do cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage; sleep 0.2; done > /data/local/tmp/gpubusy.txt\" </dev/null >/dev/null 2>&1 &'" >/dev/null 2>&1
}
gpu_sample_stop() {   # -> peak percentage
    $A "su -c 'pkill -f gpu_busy_percentage'" >/dev/null 2>&1
    $A "su -c 'cat /data/local/tmp/gpubusy.txt'" 2>/dev/null \
        | tr -d '\r %' | grep -E '^[0-9]+$' | sort -n | tail -1
}

# The desktop user and its runtime dir, read from the running session rather than assumed: the
# image has been rebuilt with different uids before.
desktop_env() {
    local uid
    uid=$($SSH 'loginctl list-sessions --no-legend 2>/dev/null | awk "{print \$2}" | grep -v "^0$" | head -1' 2>/dev/null | tr -d '\r')
    [ -n "$uid" ] || uid=1001
    echo "$uid"
}

echo "=== $LABEL ==="

# --- Minecraft. Foreground: mc_bench drives the menus over VNC on a timer, and running it
# --- backgrounded here was enough to make the F6 press land before the world had finished
# --- loading, which shows up only as "no overlay in the capture".
gpu_sample_start
./mc_bench.sh --label "$LABEL" > "$OUT/$LABEL.mc.log" 2>&1
MC_GPU=$(gpu_sample_stop)
# mc_bench.sh prints the reading as "    123 fps", not "fps=123" -- that is mc_read_fps.py's
# format, and it is not what reaches this log.
MC_FPS=$(grep -oE '^ +[0-9]+ fps$' "$OUT/$LABEL.mc.log" | tail -1 | grep -oE '[0-9]+')
MC_BACKEND=$(grep -oE 'backend: [A-Za-z]+' "$OUT/$LABEL.mc.log" | tail -1 | cut -d' ' -f2)
[ -n "$MC_FPS" ] || MC_FPS="unread"

# --- vkmark, with Minecraft closed so it is not sharing the GPU ---
$SSH 'pkill -f net.minecraft.client.main.Main; pkill -f java_wrap.sh' >/dev/null 2>&1
sleep 10
UID_D=$(desktop_env)
gpu_sample_start
$SSH "sudo -u \\#$UID_D env XDG_RUNTIME_DIR=/run/user/$UID_D WAYLAND_DISPLAY=wayland-0 \
      timeout 600 vkmark" > "$OUT/$LABEL.vkmark.log" 2>&1
VK_GPU=$(gpu_sample_stop)
VK=$(grep -oE 'vkmark Score: *[0-9]+' "$OUT/$LABEL.vkmark.log" | grep -oE '[0-9]+$' | tail -1)
[ -n "$VK" ] || VK="unread"

CLK=$(grep -oE 'clk=[0-9]+MHz[^ ]*' "$OUT/$LABEL.mc.log" | tail -1)
CPU=$(grep -oE 'cpu0=[0-9]+MHz' "$OUT/$LABEL.mc.log" | tail -1)
printf '%s\n' "$LABEL|${VK}|${VK_GPU:-?}|${MC_FPS}|${MC_GPU:-?}|${MC_BACKEND:-?}|${CLK:-?} ${CPU:-?}" \
    | tee -a "$OUT/results.psv"
