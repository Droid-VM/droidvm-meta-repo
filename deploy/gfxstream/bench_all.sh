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

# Preflight, the bridge check and the uptime comparison live in one place; see the note there
# for why they are not duplicated per driver.
. "$(dirname "$0")/harness/preflight.sh"

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
# Stream the evidence OFF the phone as it happens.
#
# Anything written to a file on the phone loses its tail when the host reboots -- the page cache
# never gets flushed. Four host reboots today produced: a crosvm.log frozen at a previous run, a
# sampler file that did not exist because /data/local/tmp had been cleared by an earlier reboot,
# and a dmesg wiped by the reboot itself. Nothing survived, three times over.
#
# So both capture streams run as long-lived adb commands writing to THIS machine. The reboot kills
# the adb connection, which ends the stream -- but everything up to that instant is already local.
CAP_PIDS=""

capture_start() {   # $1 = label, $2 = deploy dir (for crosvm.log)
    # logcat is the only place an Android-side death shows up: a crosvm SIGABRT, a RescueParty
    # decision, a vendor watchdog. -b all because the crash lands in the crash buffer, not main.
    ( adb -s "$PHONE" logcat -b all -v threadtime > "$DIAG/$1.logcat.txt" 2>&1 ) &
    CAP_PIDS="$!"

    # One adb shell that loops on the phone, printing to our stdout. The interval is real (a
    # per-sample adb invocation costs ~100ms and would miss most of the window) and the output is
    # already here when the phone goes down.
    # Columns: epoch MemFree_kB pool_avail_pages udmabuf_refcount crosvm_count
    ( $A "su -c 'while true; do
            echo \"\$(date +%s) \$(grep -m1 MemFree /proc/meminfo | tr -dc 0-9) \$(cat /sys/module/gh_hugepage_reserve/parameters/pool_avail 2>/dev/null) \$(cat /sys/module/udmabuf_gki_*/refcnt 2>/dev/null | head -1 || echo -)- \$(ps -A -o ARGS | grep -c \"[c]rosvm --log-level\")\";
            sleep 5;
          done'" > "$DIAG/$1.mem.tsv" 2>/dev/null ) &
    CAP_PIDS="$CAP_PIDS $!"
    # Watchdog. served_summary's `live` counts memparcels the reserve pool is currently serving:
    # measured at live=2496 with a VM up (vm_owners naming it: pid=... comm="ubuntu 26 drm2k"), 0
    # with none. So a transition back to 0 is the VM going away, and it is a cheaper signal than
    # scraping the process list. Detecting that
    # within a couple of seconds is what makes crosvm's own stdout/stderr recoverable: the launcher
    # redirects it to a file ON THE PHONE, and if a host reboot follows the death -- which is what
    # happens here -- the tail of that file never reaches disk. Copy it while the phone is still up.
    (
        armed=0
        while :; do
            live=$($A "su -c 'cat /sys/module/gh_hugepage_reserve/parameters/served_summary'" 2>/dev/null \
                   | tr -d '\r' | sed -n 's/^live=//p')
            case "$armed:$live" in
                0:0|0:) : ;;                       # not up yet
                0:*)    armed=1 ;;                 # VM took memparcels: arm
                1:0)                               # they went away: it died
                    {
                        echo "=== watchdog: served live -> 0 at $(date -u +%FT%TZ) ==="
                        echo "--- crosvm stdout/stderr, pulled before a reboot can lose the tail ---"
                        $A "su -c 'cat /data/local/tmp/$2/crosvm.log'" 2>/dev/null | tr -d '\r' | tail -200
                        echo "--- last dmesg ---"
                        $A "su -c 'dmesg | tail -40'" 2>/dev/null | tr -d '\r'
                        echo "--- crosvm still running? ---"
                        $A "su -c 'ps -A -o PID,ARGS | grep \"[c]rosvm\"'" 2>/dev/null | tr -d '\r'
                    } > "$DIAG/$1.death.txt" 2>&1
                    break ;;
            esac
            sleep 5
        done
    ) &
    CAP_PIDS="$CAP_PIDS $!"

    sleep 6
    # Verify the collectors are producing. A silent collector is worse than none: it looks like
    # evidence. (The watchdog has nothing to show until something dies, so it is not checked here.)
    [ -s "$DIAG/$1.logcat.txt" ] || echo "  !! logcat capture is empty"
    [ -s "$DIAG/$1.mem.tsv" ]    || echo "  !! memory sampling is empty"
}

capture_stop() {   # $1 = label
    for pid in $CAP_PIDS; do kill "$pid" 2>/dev/null; done
    CAP_PIDS=""
    sleep 1
    local n
    n=$(grep -c . "$DIAG/$1.mem.tsv" 2>/dev/null || true)
    awk 'NR==1{f=$2;a=$3} {l=$2;p=$3} END{if(NR) printf "  memory: MemFree %.0f->%.0fMB, pool_avail %s->%s pages, %d samples\n", f/1024, l/1024, a, p, NR}' \
        "$DIAG/$1.mem.tsv" 2>/dev/null
    if [ -s "$DIAG/$1.death.txt" ]; then
        echo "  !! the VM died during this run -- crosvm's own output was captured:"
        grep -iE "error|panic|fatal|FORTIFY|Out of memory|abort" "$DIAG/$1.death.txt" | tail -5 | sed 's/^/     /'
        echo "     full: $DIAG/$1.death.txt"
    fi
    n=$(grep -ciE "SIGABRT|signal 6|Fatal signal|RescueParty|lowmemorykiller|Out of memory|crosvm.*(abort|died)|watchdog" \
        "$DIAG/$1.logcat.txt" 2>/dev/null || echo 0)
    echo "  logcat: $(grep -c . "$DIAG/$1.logcat.txt" 2>/dev/null || true) lines, $n matching crash/OOM signatures"
    [ "$n" != 0 ] && grep -iE "SIGABRT|signal 6|Fatal signal|RescueParty|lowmemorykiller|Out of memory|watchdog" \
        "$DIAG/$1.logcat.txt" | tail -6 | sed 's/^/     /'
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
    n=$(grep -ciE "page allocation failure|Out of memory|oom-kill|order-[0-9]+.*fail|udmabuf" "$DIAG/$1.dmesg.txt" 2>/dev/null || true)
    [ "$n" != 0 ] && echo "  dmesg: $n lines matching allocation-failure/udmabuf -- see $DIAG/$1.dmesg.txt"
}

# The launcher always writes $DIR/crosvm.log, so the next configuration overwrites it. Copy it off
# under the label while it is still the right one.
crosvm_log_save() {   # $1 = label, $2 = dir
    $A "su -c 'cat /data/local/tmp/$2/crosvm.log'" 2>/dev/null | tr -d '\r' > "$DIAG/$1.crosvm.log"
    local n
    n=$(grep -ciE "error|panic|fatal|Out of memory" "$DIAG/$1.crosvm.log" 2>/dev/null || true)
    echo "  crosvm.log: $(wc -l < "$DIAG/$1.crosvm.log") lines, $n matching error/OOM -> $DIAG/$1.crosvm.log"
}
want=("$@")
for entry in "${CONFIGS[@]}"; do
    IFS=: read -r label dir launcher <<< "$entry"
    if [ ${#want[@]} -gt 0 ]; then
        printf '%s\n' "${want[@]}" | grep -qx "$label" || continue
    fi
    echo "########## $label ##########"
    preflight || { echo "  SKIPPING $label"; continue; }
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
    host_watchdog_start "$label" "$DIAG"
    capture_start "$label" "$dir"

    ./bench_one.sh "$label"

    capture_stop "$label"
    host_watchdog_stop
    host_rebooted && { echo "  !! the phone rebooted during this run:"; sed 's/^/     /' "$DIAG/$label.hostwd.txt"; }
    dmesg_save "$label"
    crosvm_log_save "$label" "$dir"
    host_state "after $label" > "$DIAG/$label.host-after.txt"
    uptime_check || echo "$label|HOST-REBOOTED|-|-|-|-|-" >> /tmp/mc_bench/results.psv
    vm_down
done

echo
echo "label|vkmark|vk_gpu%|mc_fps|mc_gpu%|backend|clocks"
cat /tmp/mc_bench/results.psv 2>/dev/null
