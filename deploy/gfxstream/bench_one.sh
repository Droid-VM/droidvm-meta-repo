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
PHONE=${PHONE:-10.53.12.1:5568}
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
# Bracket the first character of each pattern. Unbracketed, `pkill -f` also matches the remote
# `bash -c` that ssh runs it in -- the pattern is right there in that shell's own command line --
# so pkill signals its own parent, the shell dies, and the SECOND pkill never runs. Verified on
# this guest: `pgrep -af "net.minecraft.client.main.Main"` returns the pgrep shell itself.
# mc_bench.sh now quits Minecraft through the pause menu first; this is the backstop.
$SSH 'pkill -f "[n]et\.minecraft\.client\.main\.Main"; pkill -f "[j]ava_wrap\.sh"' >/dev/null 2>&1
sleep 10

# Let the GPU cool before vkmark, on the same terms mc_bench.sh uses before it pins.
#
# vkmark used to start ten seconds after Minecraft stopped, which was harmless while Minecraft was
# only loading the GPU to about 38% -- and stopped being harmless the moment the benchmark scene
# was fixed and that rose to 59-79%. The fusion run right after that change scored 1268 against
# 4387 for the same build measured cold, with thermal_pwrlevel=6 (throttled) recorded at the end
# of its Minecraft phase. A vkmark score taken on a hot GPU says nothing about the configuration.
#
# Waiting on thermal_pwrlevel alone is not enough: the pin holds min_freq at the target, which
# stops the thermal governor stepping down, so the level can stay high indefinitely. Drop the pin
# first, wait for the temperature, then put it back.
echo "  cooling before vkmark"
KGSL=/sys/class/kgsl/kgsl-3d0
GPU_HZ=$($A "su -c 'cat $KGSL/devfreq/min_freq'" 2>/dev/null | tr -dc 0-9)
$A "su -c 'echo 160000000 > $KGSL/devfreq/min_freq; echo 1100000000 > $KGSL/devfreq/max_freq'" >/dev/null 2>&1
for i in $(seq 1 40); do
    T=$($A "su -c 'cat /sys/class/thermal/thermal_zone0/temp'" 2>/dev/null | tr -dc 0-9)
    P=$($A "su -c 'cat $KGSL/thermal_pwrlevel'" 2>/dev/null | tr -dc 0-9)
    if [ "${P:-9}" = 0 ] && [ "${T:-99999}" -lt 45000 ]; then
        echo "    cool after $((i*10))s (temp=$((T/1000))C)"; break
    fi
    sleep 10
done
[ "${T:-0}" -ge 45000 ] && echo "    !! still ${T:-?} after 400s -- vkmark will be taken hot"
if [ -n "$GPU_HZ" ] && [ "$GPU_HZ" != 160000000 ]; then
    $A "su -c 'echo $GPU_HZ > $KGSL/devfreq/max_freq; echo $GPU_HZ > $KGSL/devfreq/min_freq'" >/dev/null 2>&1
fi

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
