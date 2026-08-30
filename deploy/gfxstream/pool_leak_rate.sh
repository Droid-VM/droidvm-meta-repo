#!/bin/bash
# How much of the reserve pool does one VM lifecycle fail to return?
#
#   deploy/gfxstream/pool_leak_rate.sh [cycles] [mode...]     default: 3 poweroff sigterm
#
# The premise under test is "every shutdown shrinks the pool a little". A single session-long
# reading says otherwise -- 2774 pages lent, 2773 returned -- but that number spans several VM
# lifecycles, several kills and a reboot, so it cannot say WHICH path loses pages or how often.
# This measures one lifecycle at a time.
#
# Why it matters: we are considering replacing the module's system-wide free hook
# (android_vh_free_one_page_bypass, which watches every order-9 free in the system) with an
# explicit donate ioctl on crosvm's exit path. Donate recovers 100% on every path it runs on and
# leaves no window for an unmovable page to squat the block, but it cannot run on SIGKILL. Deciding
# whether that trade is worth making needs to know what today's hook actually loses, per shutdown,
# on the paths donate would cover.
#
# The counters, from /sys/module/gh_hugepage_reserve/parameters:
#   total_served    cumulative 2MB pages handed to VMs since insmod
#   total_refilled  cumulative pages taken back (by the free hook OR by the reacquire scavenger)
#   pool_avail      pages currently in the pool
#   pool_total      capacity: pages the module believes it holds (avail + served)
#   orphan_inuse    pages whose owner is gone and whose block someone else now occupies -- the
#                   permanent losses, and the number donate is meant to drive to zero
#   del_hit/del_miss/take_fail  free-hook forensics (reclaim_debug)
#
# served-minus-refilled per cycle is the headline. A cycle that returns everything reads 0.
#
# NOTE ON SIGKILL: not a default mode. It leaks memparcels the RM will not reclaim until the phone
# reboots, which then makes preflight refuse every subsequent cycle. Pass it explicitly if you want
# it, and expect the run to end there.
set -u
cd "$(dirname "$0")"
PHONE=${PHONE:-10.53.12.1:5568}
GUEST=${GUEST:-root@172.22.68.12}
OUT=${OUT:-/tmp/mc_bench/poolleak}
A="adb -s $PHONE shell"
SSH="ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no $GUEST"
P=/sys/module/gh_hugepage_reserve/parameters
mkdir -p "$OUT"
. "$(dirname "$0")/harness/preflight.sh"

CYCLES=${1:-3}; shift 2>/dev/null || true
MODES=${*:-"poweroff sigterm"}

crosvm_pid() { $A "su -c 'pgrep -f \"[c]rosvm --log-level\"'" 2>/dev/null | tr -dc 0-9 | head -c 8; }
par()        { $A "su -c 'cat $P/$1'" 2>/dev/null | tr -d '\r'; }
stat_of()    { par refill_stat | sed -n "s/^$1=//p" | tr -dc 0-9; }
dbg_of()     { par reclaim_debug | sed -n "s/^$1=//p" | tr -dc 0-9; }
summ_of()    { par served_summary | sed -n "s/^$1=//p" | tr -dc 0-9; }

# Reconcile before reading. served_summary reports served_count live but the orphan tallies come
# from the LAST reconcile, which may be minutes old -- reading it cold gives stale orphan numbers
# next to a fresh tracked count, which is how "tracked=1 with orphan_inuse=0" was first misread.
# The write also runs the reacquire scavenger, so this is deliberately what a shutdown gets today.
snapshot() {   # $1 = label
    $A "su -c 'echo 1 > $P/reconcile'" >/dev/null 2>&1
    sleep 1
    echo "$1 served=$(stat_of total_served) refilled=$(stat_of total_refilled)" \
         "avail=$(stat_of pool_avail) total=$(stat_of pool_total)" \
         "tracked=$(summ_of tracked) orphan_inuse=$(summ_of orphan_inuse)" \
         "del_hit=$(dbg_of del_hit) del_miss=$(dbg_of del_miss) take_fail=$(dbg_of take_fail)"
}
field() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }

# The reacquire scavenger is capped at REACQUIRE_BATCH=64 pages per reconcile, so one write can
# only ever recover 128 MB. A VM holding 3000 pages that escaped wholesale would need ~48 writes.
# Loop until it stops making progress, so the measurement reports what the mechanism can recover
# given time -- not what one write happens to catch. The difference between the two is itself a
# finding, so both are recorded.
drain_reconcile() {   # echoes: <passes> <pages recovered>
    local before after total=0 i
    before=$(stat_of total_refilled)
    for i in $(seq 1 60); do
        $A "su -c 'echo 1 > $P/reconcile'" >/dev/null 2>&1
        sleep 1
        after=$(stat_of total_refilled)
        [ "${after:-0}" -le "${before:-0}" ] && { echo "$i $total"; return; }
        total=$((total + after - before))
        before=$after
    done
    echo "60 $total"
}

run_cycle() {   # $1 = mode, $2 = cycle number
    local mode=$1 n=$2 pid before after one_pass drained
    echo "---------- $mode cycle $n ----------"
    preflight || { echo "  refusing to start"; return 3; }
    bridge_up || return 3

    before=$(snapshot before)
    echo "  $before"

    # purepool: every guest page comes from the reserve pool, so the cycle exercises the maximum
    # number of served pages. A mode that also uses runtime-share would understate the loss.
    $A "su -c 'setsid sh /data/local/tmp/crosvm_gfx/run_ubuntu_gfx_purepool.sh </dev/null >/dev/null 2>&1 &'" >/dev/null 2>&1
    local up=no i
    for i in $(seq 1 64); do
        sleep 5
        [ -n "$(crosvm_pid)" ] || { echo "  !! crosvm died during boot (${i}x5s)"; return 1; }
        $SSH 'echo up' 2>/dev/null | grep -q up && { up=yes; echo "  guest up after $((i*5))s"; break; }
    done
    [ "$up" = yes ] || { echo "  !! guest never came up"; return 1; }
    pid=$(crosvm_pid)

    # Let the guest touch memory: boot alone leaves much of the pool lent but untouched, and an
    # untouched page has never been faulted into a folio, so its teardown is not the one we care
    # about. A short memory walk forces the folios to exist before we tear them down.
    $SSH 'dd if=/dev/zero of=/dev/null bs=1M count=2048 2>/dev/null; \
          head -c 1500000000 /dev/zero > /dev/shm/touch 2>/dev/null; rm -f /dev/shm/touch' >/dev/null 2>&1
    sleep 5
    echo "  served while up: $(summ_of tracked) pages, avail=$(stat_of pool_avail)"

    case $mode in
        poweroff) $SSH 'systemctl poweroff' >/dev/null 2>&1 ;;
        sigterm)  $A "su -c 'kill -TERM $pid'" >/dev/null 2>&1 ;;
        sigkill)  $A "su -c 'kill -9 $pid'" >/dev/null 2>&1 ;;
    esac
    for i in $(seq 1 40); do sleep 3; [ -n "$(crosvm_pid)" ] || break; done
    if [ -n "$(crosvm_pid)" ]; then
        echo "  !! crosvm still alive 120s after $mode -- not a clean measurement"
        return 1
    fi
    echo "  crosvm gone after $((i*3))s"

    # RECONCILE_GRACE_MS is 10s: inside it the module keeps orphan entries alive so late frees can
    # still match the hook. Waiting past it means the numbers below are settled rather than
    # mid-flight.
    sleep 12
    one_pass=$(snapshot "after-1-reconcile")
    echo "  $one_pass"
    drained=$(drain_reconcile)
    after=$(snapshot after-drain)
    echo "  $after"
    echo "  drain: $(echo "$drained" | cut -d' ' -f1) passes recovered $(echo "$drained" | cut -d' ' -f2) more pages"

    local s0 s1 r0 r1 a0 a1 oi
    s0=$(field "$before" served); s1=$(field "$after" served)
    r0=$(field "$before" refilled); r1=$(field "$after" refilled)
    a0=$(field "$before" avail);  a1=$(field "$after" avail)
    oi=$(field "$after" orphan_inuse)
    echo "  ==> lent $((s1 - s0)), returned $((r1 - r0)), LOST $(( (s1-s0) - (r1-r0) )) pages" \
         "($(( ((s1-s0) - (r1-r0)) * 2 )) MB); avail $a0 -> $a1; orphan_inuse=$oi"
    echo "$mode|$n|$((s1-s0))|$((r1-r0))|$(( (s1-s0)-(r1-r0) ))|$a0|$a1|$oi|$(echo "$drained" | tr ' ' '/')" \
        >> "$OUT/results.psv"
    uptime_check || return 4
    return 0
}

echo "modes: $MODES   cycles each: $CYCLES"
: > "$OUT/results.psv"
for m in $MODES; do
    for c in $(seq 1 "$CYCLES"); do
        run_cycle "$m" "$c" || { echo "  cycle aborted (rc=$?)"; break; }
    done
done

echo
echo "mode|cycle|lent|returned|lost|avail_before|avail_after|orphan_inuse|drain_passes/pages"
cat "$OUT/results.psv" 2>/dev/null
