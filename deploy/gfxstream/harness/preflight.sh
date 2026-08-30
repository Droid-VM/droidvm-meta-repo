#!/bin/bash
# Shared preflight for anything that starts a VM on this phone.
#
# One definition, sourced by every driver. The alternative was tried: bench_all.sh and
# sweep_all_routes.sh each had their own copy of the desktop wait, they drifted, and the stricter
# one silently rejected four configurations. And fdsetsize_repro.sh was written with NO preflight
# at all, which would have let it start a VM against a short reserve pool and then blame the
# resulting ENOMEM on whatever it was actually testing.
#
# Expects the caller to have set: PHONE, A ("adb -s $PHONE shell"), SSH.
# Sets UPTIME_BEFORE, for uptime_check to compare against afterwards.

# Refuse to start a run the host is not in a fit state for. Every check here corresponds to a
# measurement this project has already thrown away.
#
# Stale local processes: killing bench_all.sh leaves bench_one.sh and mc_bench.sh reparented to
# init, still pinning clocks and clicking through VNC. Three of them were found running hours
# after the run that spawned them, and the phone rebooted while they fought over it -- which read
# as "the drm2kgsl route can kill the host" until the process list was checked.
#
# A second crosvm: two VMs competing for the reserve pool produce ENOMEM that looks exactly like
# the pool being too small.
#
# live/orphan_inuse: memparcels still held. orphan_inuse in particular is memory the RM will not
# reclaim until the phone reboots, which is what a SIGKILL'd crosvm leaves behind.
preflight() {
    local bad=0 n

    # Match on argv[1], not on the whole command line. Any shell whose -c text merely MENTIONS
    # mc_bench.sh -- including the one running this check -- matches a substring search, which is
    # both how earlier pkills killed the wrong thing and how this check first reported a stale
    # process that was itself. A real invocation has argv[1] = the script; a wrapper has "-c".
    local stale
    stale=$(for d in /proc/[0-9]*; do
                [ -r "$d/cmdline" ] || continue
                a1=$(tr '\0' '\n' < "$d/cmdline" 2>/dev/null | sed -n 2p)
                # Only the children. This script cannot check for itself: invoked via its
                # shebang, argv[1] IS its own path, so including bench_all.sh here made preflight
                # reject the run it was called from. bench_one.sh and mc_bench.sh are the ones
                # that get reparented to init and keep driving the phone, which is the real
                # problem; a duplicate entry point would be caught by the crosvm check below.
                case "$a1" in
                    *mc_bench.sh|*bench_one.sh)
                        [ "${d#/proc/}" != "$$" ] && echo "${d#/proc/} $a1" ;;
                esac
            done)
    if [ -n "$stale" ]; then
        n=$(printf '%s\n' "$stale" | grep -c .)
        echo "  !! $n stale bench process(es) on this machine -- kill them first:"
        printf '%s\n' "$stale" | sed 's/^/     /'
        bad=1
    fi

    n=$($A "su -c 'ps -A -o ARGS | grep -cE \"[c]rosvm\"'" 2>/dev/null | tr -dc 0-9)
    if [ "${n:-0}" -gt 0 ]; then
        echo "  !! $n crosvm already running on the phone -- shut it down (poweroff, never kill -9)"
        bad=1
    fi

    # Reconcile before reading, or the orphan tally is whatever the LAST reconcile computed, which
    # may be minutes stale and outlive the condition it describes. That is not hypothetical: a
    # single page lost hours earlier had already been purged from the served table (tracked=0), but
    # the stale orphan_inuse=1 sat there and made preflight refuse every subsequent run. The write
    # is also the module's reacquire scavenger, so this makes the check "is anything ACTUALLY still
    # stranded" rather than "did anything ever get stranded".
    local live orphan
    $A "su -c 'echo 1 > /sys/module/gh_hugepage_reserve/parameters/reconcile'" >/dev/null 2>&1
    sleep 1
    live=$($A "su -c 'cat /sys/module/gh_hugepage_reserve/parameters/served_summary'" 2>/dev/null \
           | tr -d '\r' | sed -n 's/^live=//p')
    orphan=$($A "su -c 'cat /sys/module/gh_hugepage_reserve/parameters/served_summary'" 2>/dev/null \
             | tr -d '\r' | sed -n 's/^orphan_inuse=//p')
    # live and orphan_inuse are NOT the same kind of problem, and treating them alike made this
    # check refuse runs it had no business refusing.
    #
    #   live           pages a CURRENTLY TRACKED VM owner still holds. A second VM is up, or one
    #                  did not shut down. Starting now means two VMs fighting over the pool, and
    #                  the resulting ENOMEM reads as the pool being too small. Refuse.
    #
    #   orphan_inuse   pages whose owner is gone and whose 2MB block somebody else has since
    #                  taken. These are PERMANENT losses of pool capacity -- measured at 1-2 per
    #                  shutdown -- not memory anyone is still holding, and no VM shutdown will
    #                  ever bring them back. Refusing on them meant the check blocked the first
    #                  run after any normal shutdown; it silently skipped a whole configuration
    #                  out of a sweep that way. The pool refills the capacity via acquire below,
    #                  which is the actual remedy. So: report it, do not refuse.
    if [ "${live:-0}" != 0 ]; then
        echo "  !! reserve pool still serving: live=${live}"
        echo "     another VM still holds memparcels; shut it down (poweroff, never kill -9)"
        bad=1
    fi
    if [ "${orphan:-0}" != 0 ]; then
        echo "  note: ${orphan} pool page(s) permanently lost to other allocations ($(( ${orphan:-0} * 2 ))MB)"
        echo "        capacity, not a live holder -- acquire refills it; see plans/POOL_RECLAIM_PLAN.md"
    fi

    # Short pool: ask the module to refill rather than failing the run. acquire is write-only and
    # any write triggers a refill attempt; it is bounded by acquire_mem_floor_mb, so it will not
    # take the host below its own floor.
    local avail wantp
    avail=$($A "su -c 'cat /sys/module/gh_hugepage_reserve/parameters/pool_avail'" 2>/dev/null | tr -dc 0-9)
    wantp=$($A "su -c 'cat /sys/module/gh_hugepage_reserve/parameters/pool_want'" 2>/dev/null | tr -dc 0-9)
    if [ "${avail:-0}" -lt "${wantp:-0}" ]; then
        echo "  pool short: avail=$avail want=$wantp pages (2MB each) -- triggering acquire"
        for _ in 1 2 3; do
            $A "su -c 'echo 1 > /sys/module/gh_hugepage_reserve/parameters/acquire'" >/dev/null 2>&1
            sleep 10
            avail=$($A "su -c 'cat /sys/module/gh_hugepage_reserve/parameters/pool_avail'" 2>/dev/null | tr -dc 0-9)
            [ "${avail:-0}" -ge "${wantp:-0}" ] && break
        done
        if [ "${avail:-0}" -lt "${wantp:-0}" ]; then
            echo "  !! pool still short after acquire: avail=$avail want=$wantp"
            echo "     free host memory (background apps) -- the module will not go below acquire_mem_floor_mb"
            bad=1
        else
            echo "  pool refilled: avail=$avail pages ($((avail * 2 / 1024)) GB)"
        fi
    fi

    # A host reboot unloads the udmabuf module, and the built-in that takes over caps a
    # dma-buf at 64 MiB and builds its page array with kmalloc_array -- which is a recorded cause of
    # Minecraft dying on this route. Load it here so the state is the same every run rather than
    # depending on whether the phone has rebooted since someone last loaded it.
    if ! $A "su -c 'ls /sys/module | grep -q udmabuf_gki'" 2>/dev/null; then
        echo "  udmabuf module not loaded (a host reboot removes it) -- loading"
        $A "su -c 'for k in /data/data/cn.classfun.droidvm/usr/lib/modules/*/udmabuf-gki-*.ko; do
              [ -f \"\$k\" ] && insmod \"\$k\" 2>/dev/null && break; done'" >/dev/null 2>&1
        if $A "su -c 'ls /sys/module | grep -q udmabuf_gki'" 2>/dev/null; then
            echo "  loaded, mode=$($A "su -c 'cat /sys/module/udmabuf_gki_*/parameters/mode'" 2>/dev/null | tr -d '\r')"
        else
            echo "  !! could not load the udmabuf module -- the built-in will serve with a 64 MiB cap"
            bad=1
        fi
    fi

    UPTIME_BEFORE=$($A "su -c 'cut -d. -f1 /proc/uptime'" 2>/dev/null | tr -dc 0-9)
    echo "  preflight: pool=$((${avail:-0} * 2 / 1024))GB live=${live:-?} uptime=${UPTIME_BEFORE:-?}s"
    return $bad
}

# A host reboot mid-run invalidates the measurement and is worth saying out loud, because from the
# harness's point of view it is indistinguishable from the VM dying.
uptime_check() {
    local now
    now=$($A "su -c 'cut -d. -f1 /proc/uptime'" 2>/dev/null | tr -dc 0-9)
    if [ "${now:-0}" -lt "${UPTIME_BEFORE:-0}" ]; then
        echo "  !! HOST REBOOTED during this run (uptime ${UPTIME_BEFORE}s -> ${now}s) -- discard it"
        echo "     boot reason: $($A "su -c 'getprop sys.boot.reason'" 2>/dev/null | tr -d '\r')"
        return 1
    fi
    return 0
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


# ---------------------------------------------------------------------------
# Host-side watchdog: notice that the PHONE went away, from this machine.
#
# Everything else here asks the phone questions. When the phone reboots, those
# questions stop being answerable, and a script that only polls the phone sits
# there looking like slow progress -- which is what several runs today looked
# like before the reboot was noticed by hand, minutes later.
#
# So this runs on the machine driving the test and watches for the two signals a
# reboot actually produces:
#   * adb shell stops answering (the device drops off the bus as it goes down)
#   * uptime goes BACKWARDS (the definitive one -- adb can also drop for a cable
#     or a daemon restart, but uptime only falls if the kernel restarted)
#
# It records the moment with a local timestamp, so the reboot can be lined up
# against the streamed logcat afterwards.
HOSTWD_PID=""
HOSTWD_FILE=""

host_watchdog_start() {   # $1 = label, $2 = output dir
    HOSTWD_FILE="$2/$1.hostwd.txt"
    : > "$HOSTWD_FILE"
    (
        base=$($A "su -c 'cut -d. -f1 /proc/uptime'" 2>/dev/null | tr -dc 0-9)
        echo "$(date -u +%FT%TZ) start uptime=${base:-?}" >> "$HOSTWD_FILE"
        prev=${base:-0}
        misses=0
        while :; do
            sleep 5
            now=$($A "su -c 'cut -d. -f1 /proc/uptime'" 2>/dev/null | tr -dc 0-9)
            if [ -z "$now" ]; then
                misses=$((misses + 1))
                # One miss is noise -- adb round trips fail. Three in a row (15s) is the device
                # going away, and worth recording even if it comes back.
                [ "$misses" = 3 ] && echo "$(date -u +%FT%TZ) adb unreachable (15s)" >> "$HOSTWD_FILE"
                continue
            fi
            misses=0
            if [ "$now" -lt "$prev" ]; then
                echo "$(date -u +%FT%TZ) ANDROID REBOOTED: uptime ${prev}s -> ${now}s" >> "$HOSTWD_FILE"
                echo "  boot reason: $($A 'getprop sys.boot.reason' 2>/dev/null | tr -d '\r')" >> "$HOSTWD_FILE"
                echo "  history: $($A 'getprop persist.sys.boot.reason.history' 2>/dev/null | tr -d '\r' | head -c 200)" >> "$HOSTWD_FILE"
                break
            fi
            prev=$now
        done
    ) &
    HOSTWD_PID=$!
}

host_watchdog_stop() {
    [ -n "$HOSTWD_PID" ] && kill "$HOSTWD_PID" 2>/dev/null
    HOSTWD_PID=""
}

# 0 if the watchdog saw a reboot. Any caller that reports a result should check this first:
# a reboot mid-run makes the result meaningless, and it is otherwise indistinguishable from
# whatever was being measured.
host_rebooted() {
    [ -n "$HOSTWD_FILE" ] && grep -q "ANDROID REBOOTED" "$HOSTWD_FILE" 2>/dev/null
}
