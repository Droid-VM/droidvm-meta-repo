#!/bin/bash
# Drive Minecraft to a fixed scene over VNC and capture the F3/F6 overlay, so a frame rate can be
# compared between builds instead of eyeballed.
#
# Why VNC: the guest's fps is only visible on screen. Driving the menus over VNC gets the same
# world, same camera, same overlay every run -- without that, one run is at the main menu and the
# next is in a forest, and the numbers are not comparable.
#
# HOLD BOTH CLOCKS. This is not optional hygiene, it decides whether a run means anything.
#
# The GPU, because the adreno governor only raises it for what Android considers a foreground game
# and a VM is not one -- so it sits at its 160 MHz floor while Minecraft renders inside it. Three
# measurements of the same code came back 127, 58 and 56 fps purely from where the clock was.
#
# The CPU, because that is what actually sets the submit rate, and on this SoC the two clocks trade
# against each other through a shared power/thermal budget: the same build measured 637 submits/s
# with the GPU at 660 MHz and 564 with it at 734, twice each, reproducible to within 0.05%. A
# faster GPU left less headroom for the cores doing the encode and decode. Pinning only the GPU
# therefore does not hold the experiment still -- it just moves the uncontrolled variable.
#
# --gpu-mhz / --cpu-mhz pin them. The defaults are what this phone can hold through a run without
# cooking: 660 MHz GPU (734 was taken at temperature and then quietly lowered underneath the pin)
# and 1400 MHz CPU, which also matches the clocks the drm2kgsl native-context reference numbers were
# taken at. A run whose clock does not match what was asked for is reported INVALID rather than
# given a number.
#
#   ./mc_bench.sh                      launch MC, walk the menus, capture
#   ./mc_bench.sh --no-launch          MC is already in a world, just capture
#   ./mc_bench.sh --gpu-mhz 660        pin the GPU (0 = leave the governor alone)
#   ./mc_bench.sh --cpu-mhz 1400       pin every CPU cluster (0 = leave the governor alone)
#   ./mc_bench.sh --label ladder-v2    tag the capture filename
set -u
PHONE=${PHONE:-172.22.74.2:5568}
GUEST=${GUEST:-root@172.22.68.12}
VNC=${VNC:-172.22.74.2::5900}
OUT=${OUT:-/tmp/mc_bench}
A="adb -s $PHONE shell"
KGSL=/sys/class/kgsl/kgsl-3d0

mkdir -p "$OUT"
launch=1; gpu_mhz=660; cpu_mhz=1400; label=""
while [ $# -gt 0 ]; do
    case "$1" in
        --no-launch) launch=0 ;;
        --gpu-mhz) shift; gpu_mhz=$1 ;;
        --cpu-mhz) shift; cpu_mhz=$1 ;;
        --label) shift; label=$1 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done
# One representative CPU per cluster; scaling_max_freq is per-policy, so writing one core in each
# cluster covers all of them.
CPUS="0 4 7"
cpu_read() { $A "su -c 'cat /sys/devices/system/cpu/cpu$1/cpufreq/$2'" 2>/dev/null | tr -d '\r'; }
cpu_write() { $A "su -c 'echo $3 > /sys/devices/system/cpu/cpu$1/cpufreq/$2'" 2>/dev/null; }
cpu_pin() {
    local hz=$(( $1 * 1000 ))
    for c in $CPUS; do
        # Snap to the nearest frequency the cluster actually offers. The steps differ per cluster --
        # a 1400 MHz request lands on 1363200 for the little/mid cores and 1401600 for the prime
        # one -- and writing an off-step value leaves the governor to round it somewhere unstated.
        # Nearest, not highest-at-or-below: the prime cluster's next step down is 1209600, so
        # rounding down would silently run it 14% slower than asked.
        local steps want
        steps=$(cpu_read "$c" scaling_available_frequencies | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n)
        want=$(echo "$steps" | awk -v t="$hz" '{d=$1>t?$1-t:t-$1; if(best==""||d<best){best=d;v=$1}} END{print v}')
        [ -z "$want" ] && want=$hz
        cpu_write "$c" scaling_min_freq "$want"
        cpu_write "$c" scaling_max_freq "$want"
    done
}
cpu_unpin() {
    for c in $CPUS; do
        local hi lo
        hi=$(cpu_read "$c" cpuinfo_max_freq); lo=$(cpu_read "$c" cpuinfo_min_freq)
        [ -n "$lo" ] && cpu_write "$c" scaling_min_freq "$lo"
        [ -n "$hi" ] && cpu_write "$c" scaling_max_freq "$hi"
    done
}
cpu_line() {
    local out=""
    for c in $CPUS; do out="$out cpu$c=$(( $(cpu_read "$c" scaling_cur_freq) / 1000 ))MHz"; done
    echo "$out"
}

kgsl_read() { $A "su -c 'cat $KGSL/$1'" 2>/dev/null | tr -d '\r'; }
cat_temp() { $A "su -c 'cat /sys/class/thermal/thermal_zone0/temp'" 2>/dev/null | tr -d '\r'; }
kgsl_write() { $A "su -c 'echo $2 > $KGSL/$1'" 2>/dev/null; }

# Wait out the thermal cap before pinning: with thermal_pwrlevel non-zero the pin lands on a
# ceiling the hardware has already lowered, and the run measures the heat of the previous run.
# Unpin first -- a pin left over from the previous run keeps min_freq at the target, the thermal
# governor cannot step down, and thermal_pwrlevel then stays high forever whatever the temperature
# is. (That reads as "still throttled" and burns the whole timeout.)
cool_for_pin() {
    local want_khz=$(( gpu_mhz * 1000000 ))
    kgsl_write devfreq/min_freq 160000000
    kgsl_write devfreq/max_freq 1100000000
    # Wait for the temperature too, not just for the cap to lift. A pin taken at 70C holds for
    # about a minute and then the hardware lowers max_freq underneath it -- which is exactly how a
    # run labelled 734MHz ended up measured at 660.
    for i in $(seq 1 60); do
        local thr max temp
        thr=$(kgsl_read thermal_pwrlevel); max=$(kgsl_read devfreq/max_freq)
        temp=$(cat_temp)
        if [ "${thr:-9}" = 0 ] && [ "${max:-0}" -ge "$want_khz" ] && [ "${temp:-99999}" -lt 50000 ]; then
            echo "    cool after $((i*10))s (max_freq=$max temp=$((temp/1000))C)"
            return 0
        fi
        sleep 10
    done
    echo "    WARNING: still hot after 600s (thermal_pwrlevel=${thr:-?} max_freq=${max:-?} temp=${temp:-?}); ${gpu_mhz}MHz will not hold"
    return 1
}

if [ "$gpu_mhz" != 0 ]; then
    hz=$(( gpu_mhz * 1000000 ))
    $A "su -c 'grep -qw $hz $KGSL/devfreq/available_frequencies'" 2>/dev/null \
        || { echo "$gpu_mhz MHz is not an available frequency" >&2; exit 1; }
    echo "==> pinning GPU at ${gpu_mhz}MHz"
    cool_for_pin
    # max first: min_freq above the current max is rejected.
    kgsl_write devfreq/max_freq "$hz"
    kgsl_write devfreq/min_freq "$hz"
    got=$(kgsl_read devfreq/cur_freq)
    [ "$got" = "$hz" ] || echo "    WARNING: cur_freq=$got, wanted $hz"
    echo "    restore with: min_freq=160000000 max_freq=1100000000"
fi

if [ "$cpu_mhz" != 0 ]; then
    echo "==> pinning CPUs at ${cpu_mhz}MHz"
    cpu_pin "$cpu_mhz"
    echo "   $(cpu_line)"
    echo "    restore by writing cpuinfo_min_freq/cpuinfo_max_freq back into scaling_*"
fi

env_line() {
    # Single-quoted inside su -c: the command substitutions have to run as root, or they read
    # nothing and the line comes back blank.
    $A "su -c 'cat $KGSL/gpuclk $KGSL/thermal_pwrlevel $KGSL/devfreq/max_freq /sys/class/thermal/thermal_zone0/temp'" 2>/dev/null \
        | tr -d '\r' | paste -sd' ' \
        | awk '{printf "clk=%.0fMHz thermal_pwrlevel=%s max=%.0fMHz temp=%.1fC", $1/1000000, $2, $3/1000000, $4/1000}'
    # Screen state matters as much as the clock: with the display dozing the governor has no
    # reason to raise the GPU, so an otherwise identical run lands at the bottom of the table.
    printf ' screen='
    $A 'dumpsys power | grep -m1 mWakefulness=' 2>/dev/null | tr -d '\r' | sed -E 's/.*mWakefulness=([A-Za-z]+).*/\1/'
    printf ' foreground='
    $A 'dumpsys activity activities | grep -m1 topResumedActivity' 2>/dev/null \
        | tr -d '\r' | grep -oE '[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+/' | head -1 | tr -d '/' | tr -d '\n'
    cpu_line
}

# Which graphics backend Minecraft actually chose. It silently falls back to OpenGL-on-zink when
# the Vulkan backend fails to start, and rewrites options.txt to "default" after a crash -- an
# fps from the zink path is not comparable with one from the Vulkan path, and the overlay is the
# only place the difference shows.
backend_line() {
    ssh -o ConnectTimeout=10 "$GUEST" 'grep -h "Using graphics backend" /home/droidvm/mc_diag.log 2>/dev/null | tail -1' 2>/dev/null \
        | sed -E 's/.*Using graphics backend ([A-Za-z]+).*/\1/'
}

if [ "$launch" = 1 ]; then
    echo "==> launching Minecraft"
    ssh -o ConnectTimeout=10 "$GUEST" 'pkill -f "[p]ortablemc" 2>/dev/null; pkill -x java 2>/dev/null; sleep 2
        # A crash resets this to "default", which silently demotes the next run to zink.
        sed -i "s/^preferredGraphicsBackend:.*/preferredGraphicsBackend:\"vulkan\"/" /home/droidvm/.minecraft/options.txt
        mv -f /home/droidvm/mc_diag.log /home/droidvm/mc_diag.log.old 2>/dev/null
        # No droidvm session means no :0, and Minecraft dies on "Failed to open display".
        [ -S /run/user/1001/wayland-0 ] || { systemctl restart gdm; sleep 25; }
        sudo -u droidvm bash /home/droidvm/launch_mc_vk.sh' >/dev/null 2>&1
    # The main menu takes a while; the first click only focuses the window.
    sleep 50
    vncdo -s "$VNC" move 639 322 click 1 >/dev/null 2>&1; sleep 4
    echo "==> Singleplayer"
    vncdo -s "$VNC" move 639 325 click 1 >/dev/null 2>&1; sleep 5
    echo "==> select world"
    vncdo -s "$VNC" move 640 183 click 1 >/dev/null 2>&1; sleep 2
    echo "==> Play Selected World"
    vncdo -s "$VNC" move 533 663 click 1 >/dev/null 2>&1
    sleep 45
fi

# The primary number: guest vkQueueSubmit calls per second, from the host's own SUBMITPROF line
# (emitted every 1000 submits, so the counter and a timestamp are both already there). Minecraft
# issues a fixed number of submits per frame in a fixed scene, so this tracks fps -- and unlike the
# overlay it needs no keyboard input, no window focus, and no screen scraping. Keep the overlay as
# the human-readable cross-check.
submit_snap() {
    $A 'su -c "logcat -d -b all | grep SUBMITPROF | tail -1"' 2>/dev/null | tr -d '\r' \
        | awk '{split($2,t,":"); n=$0; sub(/.*n=/,"",n); sub(/ .*/,"",n);
                printf "%s %.3f\n", n, t[1]*3600+t[2]*60+t[3]}'
}

# Let the frame rate settle before measuring: the seconds right after entering a world are still
# loading chunks.
echo "==> settling 40s"
sleep 40

echo "==> measuring submit rate over 40s"
read -r sn1 st1 <<< "$(submit_snap)"
sleep 40
read -r sn2 st2 <<< "$(submit_snap)"
rate=$(awk -v n1="${sn1:-0}" -v t1="${st1:-0}" -v n2="${sn2:-0}" -v t2="${st2:-0}" \
    'BEGIN{d=t2-t1; if(d<=0){print "n/a"; exit} printf "%.1f/s over %.0fs", (n2-n1)/d, d}')

# F6 toggles, so pressing it blind flips the overlay off half the time. Detect it by the
# debug-chart legend -- a fixed block of text on a dark backing plate, so the crop holds both very
# dark and very bright pixels no matter what the world looks like behind it. (Sampling the fps
# line instead, as an earlier version did, read a bright sky as "already on".) Keep whichever
# capture has the overlay rather than assuming the first press turned it on.
overlay_on() { python3 -c "
import sys
from PIL import Image
d = list(Image.open(sys.argv[1]).convert('L').crop((0, 296, 430, 334)).getdata())
sys.exit(0 if sum(p < 60 for p in d) > 150 and sum(p > 180 for p in d) > 150 else 1)" "$1" 2>/dev/null; }

shot="$OUT/mc_$(date +%H%M%S)${label:+_$label}.png"
echo "==> F6 overlay"
before=$(env_line)
for attempt in 1 2 3; do
    vncdo -s "$VNC" capture "$shot" >/dev/null 2>&1
    overlay_on "$shot" && break
    vncdo -s "$VNC" key f6 >/dev/null 2>&1
    sleep 6
done
overlay_on "$shot" || echo "    WARNING: no overlay in the capture; fps is not readable"
after=$(env_line)
echo "==> $shot"
echo "    guest submits: $rate     <- the number to compare between builds"
# Read the number rather than leaving it to the eye. mc_read_fps.py also fails the run when the
# shell is in the Activities overview -- the game keeps rendering as a thumbnail there, so the
# capture looks fine and the fps is whatever was last drawn at full size.
fps_out=$(python3 "$(dirname "$0")/mc_read_fps.py" "$shot" 2>&1)
case "$fps_out" in
    fps=*) echo "    ${fps_out#fps=} fps" ;;
    *)     echo "    fps unreadable: $fps_out" ;;
esac
echo "    backend: $(backend_line)   (Vulkan expected; OpenGL means it fell back to zink)"
echo "    env: $after"
# Check both samples against the frequency that was ASKED FOR, not against each other: thermal
# throttling can lower the clock before the first sample, and then both agree on the wrong value
# and the run looks stable. (thermal_pwrlevel rising under a pin is expected -- the governor wants
# to step down and min_freq forbids it -- so that is not a drift signal.)
if [ "$gpu_mhz" != 0 ]; then
    for phase in "before:$before" "after:$after"; do
        got=$(echo "${phase#*:}" | grep -oE 'clk=[0-9]+MHz' | tr -dc 0-9)
        [ "$got" = "$gpu_mhz" ] \
            || echo "    *** INVALID (${phase%%:*}): clock was ${got}MHz, asked for ${gpu_mhz}MHz -- discard this run"
    done
fi

# The host's own view, for attributing a change to the transport rather than the game.
$A 'su -c "logcat -d -b all | grep SUBMITPROF | tail -1"' 2>/dev/null | tr -d '\r' \
    | sed -E 's/.*(pre=[0-9.]+).*(dispatch=[0-9.]+).*(busy=[0-9.]+).*(idle-waiting-for-guest=[0-9.]+).*/    host: \1 \2 \3 \4/'
