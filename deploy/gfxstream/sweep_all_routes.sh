#!/bin/bash
# The whole comparison, end to end: provision the guest for gfxstream, benchmark its four
# configurations, provision it for drm2kgsl, benchmark that one.
#
#   deploy/gfxstream/sweep_all_routes.sh
#
# A guest holds ONE route's mesa at a time -- the two packages install to the same prefix and
# Conflict -- so the mesa swap has to happen in the middle, and it has to happen while a VM is up
# because it goes over ssh. That is the only reason this is one script rather than two runs.
#
# Every VM here runs with the launchers' default log level (warn). Do not set CROSVM_LOG for a
# measurement run: rutabaga_gfx=debug writes a line per GEM_SUBMIT, and the same drm2kgsl
# configuration scores 2721 with it on against 5143 with it off.
set -u
cd "$(dirname "$0")"
REPO=$(cd ../.. && pwd)
PHONE=${PHONE:-10.53.12.1:5568}
GUEST=${GUEST:-root@172.22.68.12}
A="adb -s $PHONE shell"
SSH="ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no $GUEST"

vm_count() { $A "su -c 'ps -A -o ARGS | grep -c \"[c]rosvm --log-level\"'" 2>/dev/null | tr -d '\r'; }

vm_down() {
    [ "$(vm_count)" = 0 ] && return 0
    $SSH 'nohup systemctl poweroff >/dev/null 2>&1 &' >/dev/null 2>&1
    for _ in $(seq 1 30); do [ "$(vm_count)" = 0 ] && { echo "  vm down"; return 0; }; sleep 10; done
    echo "  !! VM still up -- NOT killing it (a SIGKILL'd crosvm leaks memparcels until reboot)"
    return 1
}

vm_up() {   # $1 dir, $2 launcher; waits for the DESKTOP, not just for ssh
    $A "su -c 'setsid sh /data/local/tmp/$1/$2 </dev/null >/dev/null 2>&1 &'" >/dev/null 2>&1
    for i in $(seq 1 45); do
        sleep 8
        $SSH 'echo up' 2>/dev/null | grep -q up && break
    done
    $SSH 'echo up' 2>/dev/null | grep -q up || { echo "  !! guest never came up"; return 1; }
    # vkmark needs the wayland socket, and Minecraft needs it too. Waiting only for ssh gets a
    # run where vkmark exits without printing a score.
    # Same gdm kick as bench_all.sh: the session does not reliably come up on its own.
    for _ in $(seq 1 12); do
        $SSH 'test -S /run/user/1001/wayland-0' 2>/dev/null && { echo "  desktop ready"; return 0; }
        sleep 10
    done
    $SSH 'systemctl restart gdm' >/dev/null 2>&1
    for _ in $(seq 1 18); do
        sleep 10
        $SSH 'test -S /run/user/1001/wayland-0' 2>/dev/null && { echo "  desktop ready (after gdm restart)"; return 0; }
    done
    echo "  !! no desktop session (wrong mesa for this route?)"
    return 1
}

bridge_up() {   # the app owns br-wifi; without it the VM boots with no network at all
    $A "su -c 'ip link show br-wifi'" >/dev/null 2>&1 && return 0
    echo "  br-wifi missing -- starting the app"
    $A 'am start -n cn.classfun.droidvm/.ui.SplashActivity' >/dev/null 2>&1
    for _ in $(seq 1 15); do sleep 4; $A "su -c 'ip link show br-wifi'" >/dev/null 2>&1 && return 0; done
    echo "  !! br-wifi never appeared"; return 1
}

provision() {   # $1 = gfxstream | drm2kgsl. Needs a VM up; swaps the guest's mesa and ICD.
    echo "== provisioning guest for $1 =="
    "$REPO/deploy/guest/provision.sh" "$GUEST" "$1" 2>&1 | grep -E "installed:|ok ICD|!!" | sed 's/^/  /'
}

echo "########## phase 1: gfxstream ##########"
bridge_up
vm_down
# Boot something to provision through. guestalloc is the config that works with either mesa
# present, because the provisioning itself does not render.
$A "su -c 'setsid sh /data/local/tmp/crosvm_gfx/run_ubuntu_gfx_guestalloc.sh </dev/null >/dev/null 2>&1 &'" >/dev/null 2>&1
for i in $(seq 1 45); do sleep 8; $SSH 'echo up' 2>/dev/null | grep -q up && break; done
provision gfxstream
vm_down

./bench_all.sh purepool fusion runtimeshare guestalloc

echo "########## phase 2: drm2kgsl ##########"
bridge_up
vm_down
$A "su -c 'setsid sh /data/local/tmp/crosvm_drm2kgsl/run_drm2kgsl_nctx.sh </dev/null >/dev/null 2>&1 &'" >/dev/null 2>&1
for i in $(seq 1 45); do sleep 8; $SSH 'echo up' 2>/dev/null | grep -q up && break; done
provision drm2kgsl
vm_down

./bench_all.sh drm2kgsl

echo
echo "label|vkmark|vk_gpu%|mc_fps|mc_gpu%|backend|clocks"
cat /tmp/mc_bench/results.psv 2>/dev/null
