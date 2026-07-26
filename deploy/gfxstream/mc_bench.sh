#!/bin/bash
# Drive Minecraft to a fixed scene over VNC and capture the F3/F6 overlay, so a frame rate can be
# compared between builds instead of eyeballed.
#
# Why VNC: the guest's fps is only visible on screen. Driving the menus over VNC gets the same
# world, same camera, same overlay every run -- without that, one run is at the main menu and the
# next is in a forest, and the numbers are not comparable.
#
# It also records what the phone was doing at the time. Thermal throttling and the GPU governor
# move the result by more than most code changes do: an identical build measured 60 fps warm with
# another app in the foreground and 120 fps cool, so a number without its environment is noise.
#
#   ./mc_bench.sh                 launch MC, walk the menus, capture
#   ./mc_bench.sh --no-launch     MC is already in a world, just capture
#   ./mc_bench.sh --pin-clock     hold the GPU at its current max first (removes the DVFS variable)
set -u
PHONE=${PHONE:-172.22.74.2:5568}
GUEST=${GUEST:-root@172.22.68.12}
VNC=${VNC:-172.22.74.2::5900}
OUT=${OUT:-/tmp/mc_bench}
A="adb -s $PHONE shell"

mkdir -p "$OUT"
launch=1; pin=0
for a in "$@"; do
    case "$a" in
        --no-launch) launch=0 ;;
        --pin-clock) pin=1 ;;
        *) echo "unknown option: $a" >&2; exit 1 ;;
    esac
done

env_line() {
    # Single-quoted inside su -c: the command substitutions have to run as root, or they read
    # nothing and the line comes back blank.
    $A "su -c 'cat /sys/class/kgsl/kgsl-3d0/gpuclk /sys/class/kgsl/kgsl-3d0/thermal_pwrlevel /sys/class/kgsl/kgsl-3d0/devfreq/max_freq /sys/class/thermal/thermal_zone0/temp'" 2>/dev/null \
        | tr -d '\r' | paste -sd' ' \
        | awk '{printf "clk=%s thermal_pwrlevel=%s max_freq=%s temp=%.1fC", $1, $2, $3, $4/1000}'
    # Screen state matters as much as the clock: with the display dozing the governor has no
    # reason to raise the GPU, so an otherwise identical run lands at the bottom of the table.
    printf ' screen='
    $A 'dumpsys power | grep -m1 mWakefulness=' 2>/dev/null | tr -d '\r' | sed -E 's/.*mWakefulness=([A-Za-z]+).*/\1/'
    printf ' foreground='
    $A 'dumpsys activity activities | grep -m1 topResumedActivity' 2>/dev/null \
        | tr -d '\r' | grep -oE '[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+/' | head -1 | tr -d '/'
    echo
}

if [ "$pin" = 1 ]; then
    cap=$($A 'su -c "cat /sys/class/kgsl/kgsl-3d0/devfreq/max_freq"' 2>/dev/null | tr -d '\r')
    $A "su -c 'echo $cap > /sys/class/kgsl/kgsl-3d0/devfreq/min_freq'" 2>/dev/null
    echo "pinned GPU at $cap (restore with: min_freq=160000000)"
fi

if [ "$launch" = 1 ]; then
    echo "==> launching Minecraft"
    ssh -o ConnectTimeout=10 "$GUEST" 'pkill -f "[p]ortablemc" 2>/dev/null; pkill -x java 2>/dev/null; sleep 2
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

# F6 toggles, so a second run would switch the overlay back off. Capture, and if the overlay
# is not there (the top-left corner stays dark), press again.
overlay_on() { python3 -c "
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert('L').crop((0, 92, 200, 108))
sys.exit(0 if max(im.getdata()) > 150 else 1)" "$1" 2>/dev/null; }

shot="$OUT/mc_$(date +%H%M%S).png"
echo "==> F6 overlay"
vncdo -s "$VNC" key f6 >/dev/null 2>&1
sleep 6
vncdo -s "$VNC" capture "$shot" >/dev/null 2>&1
if ! overlay_on "$shot"; then
    vncdo -s "$VNC" key f6 >/dev/null 2>&1
    sleep 6
    vncdo -s "$VNC" capture "$shot" >/dev/null 2>&1
fi
echo "==> $shot"
echo "    fps is the top-left line of the overlay; read it off the capture"
printf '    env: '; env_line

# The host's own view, for attributing a change to the transport rather than the game.
$A 'su -c "logcat -d -b all | grep SUBMITPROF | tail -1"' 2>/dev/null | tr -d '\r' \
    | sed -E 's/.*(pre=[0-9.]+).*(dispatch=[0-9.]+).*(busy=[0-9.]+).*(idle-waiting-for-guest=[0-9.]+).*/    host: \1 \2 \3 \4/'
