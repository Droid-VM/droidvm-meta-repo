# Shared Minecraft driving/measuring helpers. Source this.
#
# Menu clicking is gone: java_wrap.sh passes --quickPlaySingleplayer, so the game loads straight
# into the world. Fixed VNC coordinates broke every time the layout moved (title bar present or
# not, windowed or fullscreen) and the run was then silently scored at the main menu -- 240
# submits/s and 7% GPU, reported as if it were a frame rate.
#
# Minecraft pauses itself when the window loses focus ("Saving and pausing game..."), and a paused
# game still renders, just a different scene. So focus is not optional either: click into the
# window after the world is up, and check the log for a pause that happened after that click.
A="adb -s ${PHONE:-10.53.12.1:5568} shell"
G="${GUEST:-root@172.22.68.12}"
VNC="${VNC:-10.53.12.1::5900}"
MCLOG=/home/droidvm/mc_diag.log

gs() { timeout 25 ssh -o ConnectTimeout=8 "$G" "$@" 2>/dev/null; }

# logcat survives a VM restart, so a "tail -N | grep" after switching arms can quietly report the
# previous arm's numbers -- the cache counters from arm 1 showed up verbatim under arm 2. Clear it
# whenever the thing being measured changes.
logcat_clear() { $A 'su -c "logcat -c -b all"' >/dev/null 2>&1; }

mc_launch() {   # $1 = extra env assignments for launch_mc_vk.sh (optional)
    local env_pre="${1:-}"
    timeout 90 ssh -o ConnectTimeout=10 "$G" "pkill -x java 2>/dev/null; sleep 3
        sed -i 's/^preferredGraphicsBackend:.*/preferredGraphicsBackend:\"vulkan\"/' /home/droidvm/.minecraft/options.txt
        mv -f $MCLOG $MCLOG.old 2>/dev/null
        sudo -u droidvm env $env_pre bash /home/droidvm/launch_mc_vk.sh" >/dev/null 2>&1
}

# Launch and reach the world, retrying the one failure that is self-inflicted and self-clearing.
#
# Killing Minecraft leaves the JVM crashing in libopenal, which Minecraft reads on the next launch
# as "unexpected shutdown during last game startup" and answers by rewriting
# preferredGraphicsBackend to "default" -- during startup, so setting it to "vulkan" beforehand
# does not survive. On this stack the default backend then hangs before it ever opens a window.
# Minecraft consumes the marker as it acts on it, so relaunching once is enough; what is not
# acceptable is scoring the run that came back on the wrong backend.
mc_start() {   # $1 = extra env for the launcher, $2 = world-wait seconds
    local env_pre="${1:-}" cap="${2:-300}" attempt backend
    for attempt in 1 2 3; do
        mc_launch "$env_pre"
        if mc_wait_world "$cap"; then
            backend=$(gs "grep -h 'Using graphics backend' $MCLOG | tail -1" | sed -E 's/.*backend ([A-Za-z]+).*/\1/')
            [ "$backend" = "Vulkan" ] && { echo "    backend: $backend"; return 0; }
            echo "    *** backend is $backend, not Vulkan -- retrying"
        elif gs "grep -q 'resetting preferred graphics API' $MCLOG"; then
            echo "    *** Minecraft reset the graphics API after the last kill -- retrying"
        else
            return 1
        fi
    done
    echo "    *** could not get a Vulkan run in 3 attempts"
    return 1
}

# Wait for the world to be live, then focus the window. Returns 1 on timeout or a dead JVM.
mc_wait_world() {   # $1 = timeout seconds (default 300)
    local cap=${1:-300} i seen_java=0
    for i in $(seq 1 $((cap / 5))); do
        sleep 5
        # portablemc resolves the version before it ever spawns the JVM, so "no java process" is
        # the normal state for the first several seconds. Only treat it as a death once java has
        # been seen alive at least once -- checking from the start scored a launch as crashed at 5s.
        if gs 'pgrep -x java >/dev/null'; then
            seen_java=1
        elif [ "$seen_java" = 1 ]; then
            echo "    *** java died after $((i*5))s"; return 1
        fi
        # Bail out the moment the backend is known to be wrong. It is printed long before the
        # world loads, and on the fallback backend the world may never load at all -- waiting for
        # it burns the full timeout to learn something the log already said.
        if gs "grep -q 'Using graphics backend OpenGL' $MCLOG"; then
            echo "    Minecraft came up on OpenGL after $((i*5))s"; return 1
        fi
        gs "grep -q \"ServerLevel\\[\" $MCLOG" && { echo "    world loaded after $((i*5))s"; break; }
        [ "$i" = $((cap / 5)) ] && { echo "    *** world never loaded (${cap}s)"; return 1; }
    done
    sleep 20   # chunk load / first frames
    mc_focus
    sleep 3
    mc_reset_view
    sleep 5
    # Did it pause after we clicked? Compare against the count at click time.
    local paused_at
    paused_at=$(gs "grep -c 'Saving and pausing game' $MCLOG")
    sleep 12
    local paused_now
    paused_now=$(gs "grep -c 'Saving and pausing game' $MCLOG")
    if [ "${paused_now:-0}" != "${paused_at:-0}" ]; then
        echo "    *** game paused again after the scene was set"
        return 1
    fi
    return 0
}

submit_rate() {   # $1 = window seconds (default 30)
    local w=${1:-30} n1 t1 n2 t2
    read -r n1 t1 <<< "$($A 'su -c "logcat -d -b all | grep SUBMITPROF | tail -1"' 2>/dev/null | tr -d '\r' \
        | awk '{split($2,t,":"); n=$0; sub(/.*n=/,"",n); sub(/ .*/,"",n); printf "%s %.3f\n", n, t[1]*3600+t[2]*60+t[3]}')"
    sleep "$w"
    read -r n2 t2 <<< "$($A 'su -c "logcat -d -b all | grep SUBMITPROF | tail -1"' 2>/dev/null | tr -d '\r' \
        | awk '{split($2,t,":"); n=$0; sub(/.*n=/,"",n); sub(/ .*/,"",n); printf "%s %.3f\n", n, t[1]*3600+t[2]*60+t[3]}')"
    awk -v a="${n1:-0}" -v b="${t1:-0}" -v c="${n2:-0}" -v d="${t2:-0}" \
        'BEGIN{e=d-b; if(e>0) printf "%.0f", (c-a)/e; else print "?"}'
}

# Take the window focus without generating any pointer or button event.
#
# The obvious "move the pointer into the window and click" is destructive here: after quickPlay the
# game already has the mouse grabbed, so the move IS a camera rotation -- a different one every run,
# depending on where the pointer happened to be -- and Minecraft writes the resulting angle back to
# the save. That is how the benchmark scene drifted until it was pointing at the sky, which is a
# much lighter frame; runs that looked like noise were partly this. A left click is not safe either:
# in survival it swings at whatever is in front of the player.
mc_focus() {
    gs 'XA=$(ls -t /run/user/1001/.mutter-Xwaylandauth.* 2>/dev/null | head -1)
        W=$(sudo -u droidvm env DISPLAY=:0 XAUTHORITY="$XA" xdotool search --name "Minecraft 26" 2>/dev/null | tail -1)
        [ -n "$W" ] && sudo -u droidvm env DISPLAY=:0 XAUTHORITY="$XA" xdotool windowactivate "$W"'
}

# Put the player back on the exact spot and heading the scene is defined by.
#
# Absolute coordinates, all lowercase, no ~ and no @: the VNC keyboard does not apply shift at all,
# so "@p" arrives as "2p" and "~" as a backtick. Pinning the position as well as the angle is the
# better trade anyway -- the scene is then identical run to run rather than merely level.
# Is a Minecraft menu covering the world?
#
# This has to be answered before any key is sent: "t" opens the chat only when the world has the
# keyboard. With the pause menu up it walks the menu instead, and two attempts in a row landed in
# the Friends List dialog. Minecraft pauses itself whenever the window loses focus, so the menu is
# the normal state after anything touches the pointer, not an unusual one.
#
# The tell is the button row: flat grey, r=g=b, at a fixed height, where the world would have
# terrain.
mc_in_menu() {
    timeout 40 vncdo -s "$VNC" capture /tmp/mc_menu_chk.png >/dev/null 2>&1 || return 1
    python3 - <<'PY'
import sys
from PIL import Image
im = Image.open('/tmp/mc_menu_chk.png').convert('RGB')
# Scan the whole middle band rather than one row: dialogs put their buttons wherever they like,
# and pinning a single height missed the Friends List panel twice.
for y in range(150, 520, 6):
    grey = 0
    for x in (520, 580, 640, 700, 760):
        r, g, b = im.getpixel((x, y))
        if abs(r-g) < 12 and abs(g-b) < 12 and 70 < r < 200:
            grey += 1
    if grey >= 5:
        sys.exit(0)
sys.exit(1)
PY
}

# Escape backs out one level, so this is a loop rather than a fixed number of presses: from the
# world Escape opens the menu, from the menu it closes it, from a dialog it returns to the menu.
mc_leave_menu() {
    local i
    for i in 1 2 3 4; do
        mc_in_menu || return 0
        timeout 40 vncdo -s "$VNC" key esc >/dev/null 2>&1
        sleep 2
    done
    mc_in_menu && { echo "    *** still in a menu after 4 escapes"; return 1; }
    return 0
}

MC_SCENE_CMD=${MC_SCENE_CMD:-/tp droidvm 75.66 80.0 97.34 0 0}
mc_reset_view() {
    mc_leave_menu || return 1
    timeout 40 vncdo -s "$VNC" key t >/dev/null 2>&1; sleep 1
    timeout 40 vncdo -s "$VNC" type "$MC_SCENE_CMD" >/dev/null 2>&1; sleep 1
    timeout 40 vncdo -s "$VNC" key enter >/dev/null 2>&1; sleep 2
    # The teleport is echoed into chat; if it is not there the keys did not land.
    gs "grep -q 'Teleported' $MCLOG" 2>/dev/null || true
}

# Minecraft's frame rate, read off the host profiler.
#
# "guest submits/s" is the wrong number: SUBMITPROF counts every context's submissions together,
# and how many a frame takes depends on the scene, so it swung 401-472 across runs that differed
# only in noise. Minecraft waits on its frame fence exactly once per frame, and the per-thread
# profile counts that wait for its thread alone -- 90, 92, 88 across the same three runs. Requires
# GFXSTREAM_DECODER_PROFILE=1, which both arms of an A/B have anyway.
#
# vkWaitForFences only, not vkWaitSemaphores: the two were both ~90/s until the turnip poll fix,
# after which semaphore polling got cheap enough that the guest does it 3-4x a frame. Mixing them
# into a median under-reported 103 fps as 97.
#
# The decoder thread is the one named after the guest thread that created the context: Minecraft's
# Java render thread is called "Render thread".
mc_fps() {
    $A 'su -c "logcat -d -b all | grep -E \"DECODERPROF.Render thread.*(vkWaitForFences|vkWaitSemaphores)\" | tail -4"' 2>/dev/null \
        | tr -d '\r' | grep -oE 'n=[0-9]+/s' | grep -oE '[0-9]+' | sort -n | awk '{v[NR]=$1} END{if(NR) print v[int((NR+1)/2)]; else print "?"}'
}

# Quote the pid argument: an empty unquoted one collapses, the duration slides into $1 and gets
# used as a pid -- "12" is a kernel thread, which exists, so the script happily measured it and
# reported nothing above the noise floor instead of failing.
host_threads() { $A "su -c 'sh /data/local/tmp/threadcpu.sh \"${CROSVM_PID:-}\" ${1:-10}'" 2>/dev/null | tr -d '\r' | head -12; }
gpu_busy()     { $A 'su -c "cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage"' 2>/dev/null | tr -d '\r %'; }
