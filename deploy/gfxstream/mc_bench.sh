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
# One representative CPU per cluster: scaling_max_freq is per-policy, so writing one core in each
# policy covers the rest of it.
#
# Enumerated from the device, never hardcoded. A hardcoded list is wrong the moment a phone groups
# its cores differently, and it fails silently -- the clusters it names get pinned, the one it
# misses runs free, and every number from that run is taken with one core at its own clock. On 5567
# the policies are {0,1} {2,3,4} {5,6} {7}, and the list this used to carry, "0 4 7", missed {5,6}
# entirely: cpu6 stayed unpinned at up to 2.57GHz while cpu7 sat at 1.36GHz. A cpuset experiment
# that widened from cpu7 to cpu6-7 was therefore not measuring a second equivalent core.
CPUS=$($A "su -c 'for p in /sys/devices/system/cpu/cpufreq/policy*; do cut -d\  -f1 \$p/related_cpus; done'" 2>/dev/null | tr -d '\r' | tr '\n' ' ')
[ -n "$CPUS" ] || { echo "cannot enumerate cpufreq policies" >&2; exit 1; }
echo "==> cpufreq policies represented by: $CPUS"
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
        # Order matters and it is not symmetric. Writing min first is rejected whenever the
        # target is above the current max, and the rejection is silent -- what it leaves behind is
        # min > max, a state the governor honours by doing something unstated, and which survives
        # into every later run on that core. Drop the floor, move the ceiling, then raise the
        # floor: valid at every step regardless of which direction the clock is moving.
        local lo
        lo=$(cpu_read "$c" cpuinfo_min_freq)
        [ -n "$lo" ] && cpu_write "$c" scaling_min_freq "$lo"
        cpu_write "$c" scaling_max_freq "$want"
        cpu_write "$c" scaling_min_freq "$want"
        local gotmin gotmax
        gotmin=$(cpu_read "$c" scaling_min_freq); gotmax=$(cpu_read "$c" scaling_max_freq)
        if [ "$gotmin" != "$want" ] || [ "$gotmax" != "$want" ]; then
            echo "    ERROR: cpu$c pin did not take (min=$gotmin max=$gotmax, wanted $want)" >&2
            exit 1
        fi
    done
}
cpu_unpin() {
    for c in $CPUS; do
        local hi lo
        hi=$(cpu_read "$c" cpuinfo_max_freq); lo=$(cpu_read "$c" cpuinfo_min_freq)
        # Floor down before ceiling up, for the same reason as cpu_pin.
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
# The hottest GPU thermal zone, found by type rather than by number. thermal_zone0 is not the GPU
# on every phone -- on 5567 it reads nothing at all, which made the temperature condition in
# cool_for_pin vacuously true and let a pin be taken while the part was still hot. A check that
# cannot fail is worse than no check, because it reports success. The GPU zones there are
# gpuss-0..7, at zone41..48.
GPU_TZ=""
cat_temp() {
    if [ -z "$GPU_TZ" ]; then
        GPU_TZ=$($A "su -c 'for z in /sys/class/thermal/thermal_zone*; do case \$(cat \$z/type 2>/dev/null) in *gpu*|*GPU*) echo \$z;; esac; done'" 2>/dev/null | tr -d '\r' | tr '\n' ' ')
        [ -z "$GPU_TZ" ] && GPU_TZ="none"
    fi
    [ "$GPU_TZ" = none ] && return 1
    $A "su -c 'cat $GPU_TZ/temp'" 2>/dev/null | tr -d '\r' | sort -n | tail -1
}
kgsl_write() { $A "su -c 'echo $2 > $KGSL/$1'" 2>/dev/null; }

# Re-check the pin after the work, not only before it. The thermal governor lowers the cap under a
# pin during a run, so a clock verified at the start says nothing about the rest -- and a run at an
# unknown clock is not comparable with any other, which is the whole point of pinning. Call it
# after every measurement, not just at the end, or a clock that fell says only that it fell some
# time in the last however-many runs.
#
# Compares against the snapped target GHZ, not the requested gpu_mhz: those differ whenever the
# request was not a real step, and comparing against the request reports a false INVALID every time.
GHZ=""; GLVL=""
clocks_ok() {
    [ -n "$GLVL" ] || return 0
    local mn mx cur
    mn=$(kgsl_read min_pwrlevel); mx=$(kgsl_read max_pwrlevel); cur=$(kgsl_read devfreq/cur_freq)
    # devfreq is deliberately not checked: the power HAL rewrites max_freq at app foreground on
    # this platform and that is expected, not a lost pin. What must hold is the pwrlevel interval,
    # and cur_freq, which is the clock actually run.
    if [ "$mn" != "$GLVL" ] || [ "$mx" != "$GLVL" ] || [ "$cur" != "$GHZ" ]; then
        echo "*** INVALID: the clock was taken from under the pin (min_pwrlevel=$mn max_pwrlevel=$mx cur=$cur, wanted level $GLVL at $GHZ) -- this run is not comparable with any other"
        return 1
    fi
    return 0
}

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
        if [ -z "$temp" ] || [ "$temp" = 0 ]; then
            echo "    WARNING: no GPU thermal zone readable; pinning without the temperature check"
            temp=0
            if [ "${thr:-9}" = 0 ] && [ "${max:-0}" -ge "$want_khz" ]; then
                echo "    cap clear after $((i*10))s (max_freq=$max, temp unknown)"
                return 0
            fi
        elif [ "${thr:-9}" = 0 ] && [ "${max:-0}" -ge "$want_khz" ] && [ "$temp" -lt 50000 ]; then
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
    # Snap to the nearest step the GPU actually offers, exactly as cpu_pin does for each cluster
    # and for the same reason: an off-step value leaves the governor to round it somewhere
    # unstated. It does not round to the nearest step -- writing 660MHz on a part whose steps are
    # 903/834/770/720/680/629/... is accepted into min_freq and then runs at 231MHz, the bottom of
    # the table, which is the opposite of what was asked for.
    #
    # The step tables differ per phone, so a fixed default cannot be assumed to exist: 660 is a
    # step on 5568 and not on 5567, where the nearest is 680. Snap and say so, rather than
    # refusing to run at all.
    #
    # The list is highest-first, and its index is the pwrlevel -- which is what the pin below is
    # actually written in terms of.
    desc=$(kgsl_read devfreq/available_frequencies | tr ' ' '\n' | grep -E '^[0-9]+$')
    [ -n "$desc" ] || { echo "cannot read GPU frequency steps" >&2; exit 1; }
    hz=$(echo "$desc" | awk -v t="$hz" '{d=$1>t?$1-t:t-$1; if(best==""||d<best){best=d;v=$1}} END{print v}')
    lvl=$(echo "$desc" | awk -v w="$hz" '$1==w {print NR-1; exit}')
    [ -n "$lvl" ] || { echo "cannot map $hz to a pwrlevel" >&2; exit 1; }
    if [ "$hz" != "$(( gpu_mhz * 1000000 ))" ]; then
        echo "==> ${gpu_mhz}MHz is not a step on this GPU; nearest is $((hz/1000000))MHz"
        gpu_mhz=$((hz/1000000))
    fi

    # Pinned through pwrlevel, not devfreq. On this driver devfreq/min_freq is a suggestion: it is
    # accepted, reads back, and does not stop cur_freq sitting below it. What does hold is KGSL's
    # own pwrlevel arbitration, and the two are separately owned -- Android's power HAL rewrites
    # devfreq/max_freq back to the top the moment the app comes to the foreground (staged probe:
    # it changes at foreground, not at VM start, and nothing in this repo writes GPU frequency),
    # and it does not touch pwrlevel at all.
    #
    # default_pwrlevel matters as much as the interval and is a different kind of thing: min/max
    # are what is allowed, default is where a reset lands. Setting only the interval leaves any
    # platform that resets free to leave it -- cur_freq was seen oscillating between exactly the
    # pinned step and the default one, never the steps between, which is a reset returning home
    # rather than a governor floating.
    #
    # devfreq is written too. It is not what holds here, but it is harmless and is the effective
    # control on parts where pwrlevel is not.
    echo "==> pinning GPU at ${gpu_mhz}MHz (pwrlevel $lvl)"
    cool_for_pin
    kgsl_write max_pwrlevel "$lvl"
    kgsl_write min_pwrlevel "$lvl"
    kgsl_write default_pwrlevel "$lvl"
    kgsl_write devfreq/max_freq "$hz"   # max first: min_freq above the current max is rejected
    kgsl_write devfreq/min_freq "$hz"

    # Read back all three. A write to any of these is accepted whether or not it can be honoured,
    # so the values themselves are the only evidence the pin took. force_clk_on was written during
    # investigation and silently did not stick -- had that not been read back, it would have gone
    # into this script as a necessary step when it does nothing.
    GLVL=$lvl; GHZ=$hz
    gmin=$(kgsl_read min_pwrlevel); gmax=$(kgsl_read max_pwrlevel); got=$(kgsl_read devfreq/cur_freq)
    if [ "$gmin" != "$lvl" ] || [ "$gmax" != "$lvl" ] || [ "$got" != "$hz" ]; then
        echo "    ERROR: min_pwrlevel=$gmin max_pwrlevel=$gmax cur_freq=$got, wanted level $lvl" >&2
        echo "           at $hz -- the pin did not take, and measurements from this run are not" >&2
        echo "           comparable with any other" >&2
        exit 1
    fi
    echo "    verified pwrlevel=$lvl cur_freq=$got"

    # A pin at or above the thermal ceiling verifies on a cold part and then loses the clock as
    # soon as the run heats it -- the same "check that cannot fail at the start" the temperature
    # condition above used to be. thermal_pwrlevel is an index into the same list, and a larger
    # index is a slower step, so the pin is safe only when its level is numerically greater.
    #
    # 660MHz snapped to 680 on 5567 is pwrlevel 4, and thermal_pwrlevel read 4 at 37C idle --
    # exactly on the ceiling, with nowhere to go once the load starts.
    thr=$(kgsl_read thermal_pwrlevel)
    if [ -n "$thr" ] && [ "$thr" -gt 0 ] 2>/dev/null && [ "$lvl" -le "$thr" ]; then
        echo "    WARNING: thermal_pwrlevel=$thr caps this GPU at pwrlevel $thr and the pin is at"
        echo "             $lvl -- at or above the ceiling. It verifies now and will be taken away"
        echo "             once the run heats the part. Slower steps that are actually below it:"
        echo "$desc" | awk -v t="$thr" 'NR-1 > t {printf "               %d MHz (pwrlevel %d)\n", $1/1000000, NR-1}' | head -4
    fi

    echo "    restore with: min_pwrlevel=$(( $(echo "$desc" | wc -l) - 1 )) max_pwrlevel=0 default_pwrlevel=$(( $(echo "$desc" | wc -l) - 1 ))"
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
        # Restore the world from a pristine copy so every configuration renders the IDENTICAL
        # scene. Minecraft persists the player position and camera angle into the save, so any
        # stray pointer event -- and there were four of them, left over from the pre-quickplay menu
        # walk -- permanently changes what later runs measure. Without this the sweep compares
        # camera angles: 120, 125, then 222 fps as the view drifted down onto bare sand.
        # Create the pristine copy with:  cp -a "New World" "New World.pristine"
        W=/home/droidvm/.minecraft/saves
        if [ -d "$W/New World.pristine" ]; then
            rm -rf "$W/New World"
            cp -a "$W/New World.pristine" "$W/New World"
            chown -R droidvm:droidvm "$W/New World"
        else
            echo "WARNING: no pristine world; the camera will drift between runs and the fps column will not compare"
        fi
        # A crash resets this to "default", which silently demotes the next run to zink.
        sed -i "s/^preferredGraphicsBackend:.*/preferredGraphicsBackend:\"vulkan\"/" /home/droidvm/.minecraft/options.txt
        mv -f /home/droidvm/mc_diag.log /home/droidvm/mc_diag.log.old 2>/dev/null
        # No droidvm session means no :0, and Minecraft dies on "Failed to open display".
        [ -S /run/user/1001/wayland-0 ] || { systemctl restart gdm; sleep 25; }
        # Pick the launcher that matches the route the VM is running. launch_mc_vk.sh is
        # gfxstream'"'"'s; the DRM route has its own, which exports VK_DRIVER_FILES pointing at the
        # freedreno ICD (and DBUS_SESSION_BUS_ADDRESS). Launching the gfxstream one under
        # drm2kgsl leaves Minecraft without an ICD it can use, and it reports "Failed to find
        # the GLFW platform surface extensions" -- which looks like a WSI bug in turnip, while
        # vulkaninfo and vkmark both work because they are run with the environment set by hand.
        #
        # Choose it by the mesa variant that is actually INSTALLED, not by whether a file exists.
        # Testing for the freedreno ICD was wrong: the two variants share 60 install paths but not
        # all of them, so installing mesa-guest-gfxstream overwrites the shared ones and leaves
        # drm2kgsl extras -- including freedreno_icd.aarch64.json -- orphaned on disk. The test
        # then picked the drm2kgsl launcher under gfxstream, Minecraft got VK_DRIVER_FILES pointing
        # at turnip, turnip looked for /dev/kgsl in a VM that has none, and it died with
        # "Failed to get number of physical devices" -- which reads as the route being broken.
        # The env file is shipped BY the package, so its header names the live variant.
        V=$(sed -n "s/^# Installed by mesa-guest-\([a-z0-9]*\).*/\1/p" \
            /usr/lib/environment.d/50-mesa-guest.conf 2>/dev/null)
        L=/home/droidvm/launch_mc_vk.sh
        [ "$V" = drm2kgsl ] && [ -f /home/droidvm/launch_mc_kgsl_nctx.sh ] \
            && L=/home/droidvm/launch_mc_kgsl_nctx.sh
        echo "mesa variant: ${V:-unknown}"
        echo "launcher: $L"
        sudo -u droidvm bash "$L"' >/dev/null 2>&1
    # The main menu takes a while; the first click only focuses the window.
    sleep 50

    # Assert the backend BEFORE driving the menus, and take one retry.
    #
    # Minecraft resets preferredGraphicsBackend to "default" whenever it detects that the last
    # startup ended unexpectedly, and it does so AFTER reading options.txt -- so writing "vulkan"
    # in above is not enough by itself. Every benchmark run ends by killing Minecraft, and the JVM
    # then segfaults inside the libopenal atexit path (hs_err names libopenal.so under vm_exit),
    # which is exactly the "ended unexpectedly" that arms the reset. So the second and every later
    # configuration in a sweep silently measured OpenGL-on-zink while reporting itself as Vulkan.
    #
    # One clean relaunch is enough -- verified: options.txt stays "vulkan" and the log reads
    # "Using graphics backend Vulkan".
    if [ "$(backend_line)" != Vulkan ]; then
        echo "==> backend came up as $(backend_line), not Vulkan -- relaunching once"
        ssh -o ConnectTimeout=10 "$GUEST" 'pkill -f "[n]et\.minecraft\.client\.main\.Main" 2>/dev/null
            pkill -f "[j]ava_wrap.sh" 2>/dev/null; sleep 5
            sed -i "s/^preferredGraphicsBackend:.*/preferredGraphicsBackend:\"vulkan\"/" \
                /home/droidvm/.minecraft/options.txt
            mv -f /home/droidvm/mc_diag.log /home/droidvm/mc_diag.log.old2 2>/dev/null
            V=$(sed -n "s/^# Installed by mesa-guest-\([a-z0-9]*\).*/\1/p" \
                /usr/lib/environment.d/50-mesa-guest.conf 2>/dev/null)
            L=/home/droidvm/launch_mc_vk.sh
            [ "$V" = drm2kgsl ] && [ -f /home/droidvm/launch_mc_kgsl_nctx.sh ] \
                && L=/home/droidvm/launch_mc_kgsl_nctx.sh
            sudo -u droidvm bash "$L"' >/dev/null 2>&1
        sleep 50
        echo "==> backend after retry: $(backend_line)"
    fi

    echo "==> loaded via --quickPlaySingleplayer (straight into the world, no menu to click)"
    sleep 45

    # ---- make sure the game, not the GNOME shell, owns the keyboard --------------------------
    #
    # GNOME sometimes sits in the Activities overview. Minecraft is a thumbnail there, it keeps
    # rendering -- so a capture looks perfectly plausible -- and every keystroke belongs to the
    # shell, so F6 never reaches the game. Observed directly while resetting the camera by hand.
    #
    # Escape leaves the overview and is keyboard-only. A click is the fallback and it is safe
    # HERE, and only here, because the overview has released the pointer: once the world has
    # focus the mouse is captured and any pointer event is a camera rotation (see below).
    focus_game() {
        local i st
        for i in 1 2 3; do
            vncdo -s "$VNC" capture "$OUT/.focus.png" >/dev/null 2>&1
            st=$(python3 "$(dirname "$0")/mc_read_fps.py" "$OUT/.focus.png" 2>&1)
            case "$st" in
                *state=overview*) ;;
                *) [ "$i" = 1 ] || echo "    focused after $i attempt(s)"; return 0 ;;
            esac
            echo "    GNOME is in the Activities overview -- leaving it (attempt $i)"
            vncdo -s "$VNC" key esc >/dev/null 2>&1; sleep 3
            vncdo -s "$VNC" capture "$OUT/.focus.png" >/dev/null 2>&1
            st=$(python3 "$(dirname "$0")/mc_read_fps.py" "$OUT/.focus.png" 2>&1)
            case "$st" in
                *state=overview*) vncdo -s "$VNC" move 640 400 click 1 >/dev/null 2>&1; sleep 3 ;;
            esac
        done
        echo "    !! still in the overview -- this run is not measurable"
        return 1
    }
    echo "==> checking the game has focus"
    focus_game

    # ---- put the scene in a known state ------------------------------------------------------
    #
    # Keyboard only, and re-applied every run. This is what makes the Minecraft column comparable
    # at all: /tp fixes position AND rotation at MEASUREMENT time, so it does not matter what
    # touched the camera earlier. Restoring a pristine world (still done above) only fixes the
    # STARTING state -- and Minecraft saves the camera angle, so one stray pointer event silently
    # changed the scene for the rest of that run and for every later run. That is exactly what
    # happened on 2026-07-30: the view walked down onto bare sand and "the configurations" read
    # 120, 125, then 222 fps while measuring nothing but camera angle.
    #
    # Time and weather are pinned for the same reason -- a sky that has moved on, or rain, changes
    # how much there is to draw. The world has allowCommands=1, so these all work.
    mc_cmd() {
        vncdo -s "$VNC" key t >/dev/null 2>&1; sleep 1
        vncdo -s "$VNC" type "$1" >/dev/null 2>&1; sleep 1
        vncdo -s "$VNC" key enter >/dev/null 2>&1; sleep 2
    }
    echo "==> normalising the scene (view, position, time, weather)"
    mc_cmd "/gamerule doDaylightCycle false"
    mc_cmd "/gamerule doWeatherCycle false"
    mc_cmd "/time set noon"
    mc_cmd "/weather clear"
    mc_cmd "/tp @s 75.66 80 97.34 0 0"
    sleep 5
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
# Do not test the pixels for "is the overlay on" -- use the fps reader itself as the oracle.
#
# The previous check cropped a fixed rectangle (0,296)-(430,334) looking for the debug-chart
# legend, and that rectangle was tuned for Minecraft windowed at 960x471. It is therefore a hidden
# dependency on window geometry: when the geometry moved, the crop landed on open sky, every
# capture read as "overlay off", and the loop pressed F6 an EVEN number of times -- turning a
# working overlay back off and saving that frame. Three configurations in one sweep reported
# "unread" while rendering perfectly, and the obvious remedy (force fullscreen, so the geometry is
# deterministic) made it worse for exactly the same reason.
#
# What the run actually needs is a readable number, and mc_read_fps.py already knows how to find
# the fps line and how to reject the Activities-overview case. So: press, read, stop when it reads.
shot="$OUT/mc_$(date +%H%M%S)${label:+_$label}.png"
echo "==> F6 overlay"
before=$(env_line)
fps_out=""
for attempt in 1 2 3 4 5 6; do
    vncdo -s "$VNC" capture "$shot" >/dev/null 2>&1
    fps_out=$(python3 "$(dirname "$0")/mc_read_fps.py" "$shot" 2>&1)
    case "$fps_out" in fps=*) break ;; esac
    # GNOME sometimes comes up sitting in the Activities overview, and then Minecraft is a
    # thumbnail and every keystroke belongs to the shell -- F6 never reaches the game, and more F6
    # presses only toggle shell things. Observed directly. Escape leaves the overview and is a
    # keyboard event, so unlike a click it cannot disturb the camera.
    case "$fps_out" in
        *state=overview*) vncdo -s "$VNC" key esc >/dev/null 2>&1; sleep 3 ;;
    esac
    # NEVER move the pointer once the world is loaded. Minecraft has the mouse captured in-game, so
    # a vncdo move is a CAMERA ROTATION, not a focus click, and Minecraft persists the resulting
    # angle into the save -- so one stray move corrupts every LATER run too. If F6 does not land,
    # spend another attempt on it rather than a pointer event: the camera is part of the
    # measurement, and the pristine-world restore above only helps if nothing moves it afterwards.
    vncdo -s "$VNC" key f6 >/dev/null 2>&1
    sleep 6
done
after=$(env_line)
echo "==> $shot"
echo "    guest submits: $rate     <- the number to compare between builds"
case "$fps_out" in
    fps=*) echo "    ${fps_out#fps=} fps" ;;
    *)     echo "    fps unreadable after 4 attempts: $fps_out" ;;
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

# ---- step 10: stop Minecraft cleanly, so vkmark does not share the GPU with it ----------------
#
# vkmark runs next (in bench_one.sh) with only a short gap, so whatever Minecraft is still doing
# lands in the vkmark score. Escape opens the pause menu -- which also RELEASES the pointer, so
# the menu click below cannot rotate the camera -- and "Save and Quit to Title" both writes the
# world and stops the world rendering. Coordinates are for the 1280x720 VNC framebuffer.
#
# The pkill that follows in bench_one.sh stays as the backstop: the JVM segfaults inside
# libopenal's atexit path on the way out (hs_err names libopenal.so under vm_exit), so a kill is
# how it ends either way -- but by then the save has already happened.
if [ "$launch" = 1 ]; then
    echo "==> quitting Minecraft (Escape -> Save and Quit to Title)"
    vncdo -s "$VNC" key esc >/dev/null 2>&1; sleep 3
    vncdo -s "$VNC" move 640 400 click 1 >/dev/null 2>&1
    for i in $(seq 1 15); do
        sleep 3
        ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no "$GUEST" \
            'pgrep -f "[n]et\.minecraft\.client\.main\.Main" >/dev/null' 2>/dev/null \
            || { echo "    Minecraft gone after $((i*3))s"; break; }
    done
fi
