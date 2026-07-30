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

# The phone's display must stay awake for the whole sweep. mc_bench.sh explains why the clock
# matters; the screen is the same variable by another route -- with the display dozing the
# governor has no reason to raise the GPU, and a run taken that way lands at the bottom of the
# table for a reason that has nothing to do with the configuration under test. A 30-minute
# screen_off_timeout is shorter than this sweep, so it WILL fire if left alone.
$A 'input keyevent KEYCODE_WAKEUP; svc power stayon true' >/dev/null 2>&1
trap "$A 'svc power stayon false' >/dev/null 2>&1" EXIT

want=("$@")
for entry in "${CONFIGS[@]}"; do
    IFS=: read -r label dir launcher <<< "$entry"
    if [ ${#want[@]} -gt 0 ]; then
        printf '%s\n' "${want[@]}" | grep -qx "$label" || continue
    fi
    echo "########## $label ##########"
    vm_down || continue
    vm_up "$dir" "$launcher" || continue
    # Minecraft rewrites preferredGraphicsBackend to "default" (= zink/OpenGL) after a Vulkan
    # crash, and then every later run silently measures zink. The log line is the only place it
    # shows; the fps still reads fine. Force it back before each configuration.
    $SSH 'f=$(ls /home/*/.minecraft/options.txt 2>/dev/null | head -1);
          [ -n "$f" ] && { sed -i "/^preferredGraphicsBackend:/d" "$f";
                           echo "preferredGraphicsBackend:\"vulkan\"" >> "$f"; }' >/dev/null 2>&1
    ./bench_one.sh "$label"
    vm_down
done

echo
echo "label|vkmark|vk_gpu%|mc_fps|mc_gpu%|backend|clocks"
cat /tmp/mc_bench/results.psv 2>/dev/null
