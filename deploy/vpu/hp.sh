#!/bin/bash
# VPU dev rig: the hugepage watchdog -- compare the VM state you EXPECT against the counters the
# gh_hugepage_reserve module actually has, instead of sleeping and hoping.
#
#   hp.sh status                                      one screen of the module's counters
#   hp.sh expect off [--wait SECS]                    expect no VM:  served=0, pool_avail=pool_want
#   hp.sh expect on  [--min-pages N|--min-mb M] [--wait SECS]
#                                                     expect a VM:   served>=N, pool_avail<pool_want
#   hp.sh reclaim [--yes]                             the remedy for "not reclaimed"
#
# Every VM on the phone runs on memory this module hands out, so its counters ARE the VM state,
# and they settle long before ssh does. One hugepage is 2 MiB; on the lab phone pool_want is
# 3072 pages = 6 GiB. Everything is read from /sys/module/gh_hugepage_reserve/parameters/
# through the rig's root helper, one adb round trip per sample (POOL_DESIGN.md §10 is the sysfs
# contract; W/debugloop.md is the two expected states in the user's own words).
#
# Every answer is one line -- `hp: <verdict>: <details>` -- and the verdict is the exit code:
#
#   0   OK              the expected state
#   2   not reclaimed   served=0 but pool_avail<pool_want: the pages the last VM freed are not
#                       back in the pool yet.  Remedy: `hp.sh reclaim --yes`.
#   3   vm still up     served!=0 where none was expected: the previous VM has not finished
#                       stopping, or something else is running.  Confirm with `vm.sh status`,
#                       then SIGTERM the leftover crosvm -- never -9.
#   4   not started     served=0 where a VM was expected: it never got off the ground, or it
#                       exited.  Read the VM log NOW (`vm.sh log <name>`, or the app's stderr);
#                       do not wait for wait-ssh.
#   5   short           served>0 but under --min-pages/--min-mb.
#   1   the module is not loaded, or its parameters are not readable.
#   64  usage.
#
# --wait SECS samples once a second until the verdict is OK or SECS elapse, and prints a line
# only when the verdict CHANGES -- so the last line printed is always the one it exits on.
set -u
SP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SP/lib.sh"

USAGE_RC=64   # 2, 3, 4 and 5 are verdicts here, so usage does not get the rig's usual 2
usage() {  # print the file's own header comment, up to the first line of code
    awk 'NR>1 && !/^#/ {exit} NR>1 {sub(/^# ?/, ""); print}' "$0"
    exit "$USAGE_RC"
}

HP_PARAMS=/sys/module/gh_hugepage_reserve/parameters
HP_MB_PER_PAGE=2

# --- one sample ---------------------------------------------------------------------------------
# refill_stat and vm_owners are read in the SAME root shell: two adb round trips would be two
# different instants, and a watchdog that reports a mix of them is worse than no watchdog.
hp_state=""; hp_pool_avail=""; hp_pool_total=""; hp_served=""; hp_pool_want=""
hp_active_vms=""; hp_acquire_active=""; hp_acquire_mode=""; hp_acquire_stop_reason=""
hp_owners=""

hp_sample() {
    local raw stat k v
    raw=$(asu "cat $HP_PARAMS/refill_stat 2>/dev/null; echo '@@owners'; cat $HP_PARAMS/vm_owners 2>/dev/null")
    case "$raw" in *@@owners*) ;; *) return 1 ;; esac
    stat=$(printf '%s\n' "$raw" | sed -n '1,/^@@owners$/p' | sed '$d')
    hp_owners=$(printf '%s\n' "$raw" | sed -n '/^@@owners$/,$p' | sed '1d')
    hp_state=""; hp_pool_avail=""; hp_pool_total=""; hp_served=""; hp_pool_want=""
    hp_active_vms=""; hp_acquire_active=""; hp_acquire_mode=""; hp_acquire_stop_reason=""
    while IFS='=' read -r k v; do
        case "$k" in
            state)               hp_state=$v ;;
            pool_avail)          hp_pool_avail=$v ;;
            pool_total)          hp_pool_total=$v ;;
            served)              hp_served=$v ;;
            pool_want)           hp_pool_want=$v ;;
            active_vms)          hp_active_vms=$v ;;
            acquire_active)      hp_acquire_active=$v ;;
            acquire_mode)        hp_acquire_mode=$v ;;
            acquire_stop_reason) hp_acquire_stop_reason=$v ;;
        esac
    done <<<"$stat"
    # served/pool_avail/pool_want are the three every verdict is made of; anything else may be
    # missing on an older module without making the answer wrong.
    case "$hp_served$hp_pool_avail$hp_pool_want" in
        *[!0-9]*|"") return 1 ;;
    esac
    return 0
}

hp_sample_or_die() {
    hp_sample && return 0
    die "hp: gh_hugepage_reserve is not loaded on $PHONE, or $HP_PARAMS/refill_stat is not readable"
}

mib() { echo $(( $1 * HP_MB_PER_PAGE )); }

# --- verdicts -----------------------------------------------------------------------------------
# Each sets VERDICT (the printed word), DETAILS (the rest of the line) and RC (the exit code).
VERDICT=""; DETAILS=""; RC=0

hp_verdict_off() {   # expected: no VM -- served=0 and the pool is back to full
    if [ "$hp_served" -ne 0 ]; then
        VERDICT="vm still up"; RC=3
        DETAILS="served=$hp_served pages ($(mib "$hp_served") MiB), active_vms=${hp_active_vms:-?}, pool_avail=$hp_pool_avail/$hp_pool_want"
    elif [ "$hp_pool_avail" -ge "$hp_pool_want" ]; then
        VERDICT="OK"; RC=0
        DETAILS="no VM -- served=0, pool_avail=$hp_pool_avail/$hp_pool_want pages"
    else
        VERDICT="not reclaimed"; RC=2
        DETAILS="served=0 but pool_avail=$hp_pool_avail/$hp_pool_want pages, short $(( hp_pool_want - hp_pool_avail )) ($(mib $(( hp_pool_want - hp_pool_avail ))) MiB); state=${hp_state:-?} acquire_active=${hp_acquire_active:-?}"
    fi
}

MIN_PAGES=0
hp_verdict_on() {    # expected: a VM is up -- served covers its memory, the pool is drawn down
    if [ "$hp_served" -eq 0 ]; then
        VERDICT="not started"; RC=4
        DETAILS="served=0 -- no VM is holding any hugepage; pool_avail=$hp_pool_avail/$hp_pool_want, active_vms=${hp_active_vms:-?}"
    elif [ "$hp_served" -lt "$MIN_PAGES" ]; then
        VERDICT="short"; RC=5
        DETAILS="served=$hp_served pages ($(mib "$hp_served") MiB), under the $MIN_PAGES ($(mib "$MIN_PAGES") MiB) expected; pool_avail=$hp_pool_avail/$hp_pool_want"
    else
        VERDICT="OK"; RC=0
        DETAILS="a VM is up -- served=$hp_served pages ($(mib "$hp_served") MiB)"
        [ "$MIN_PAGES" -gt 0 ] && DETAILS="$DETAILS >= $MIN_PAGES ($(mib "$MIN_PAGES") MiB)"
        DETAILS="$DETAILS, pool_avail=$hp_pool_avail/$hp_pool_want"
    fi
}

hp_owner_lines() {  # the pids that hold pages, indented, for a remedy block
    if [ -n "$hp_owners" ]; then
        printf '%s\n' "$hp_owners" | sed 's/^/    /'
    else
        echo "    (vm_owners is empty)"
    fi
}

# The three remedies, in the terms W/debugloop.md states them.
hp_remedy() {
    case "$VERDICT" in
    "not reclaimed")
        echo "hp: remedy: the pages the last VM freed have not come back to the pool yet."
        echo "    deploy/vpu/hp.sh reclaim --yes            # does exactly the two steps below"
        echo "    echo 1 > $HP_PARAMS/manual_release"
        echo "    # then, if pool_avail is still short:"
        echo "    echo 3 > $HP_PARAMS/acquire               # CONTIG_AT+EVICT_ISOLATE"
        echo "    # and wait for refill_stat's acquire_active to go back to 0."
        ;;
    "vm still up")
        echo "hp: remedy: something still holds hugepages --"
        hp_owner_lines
        echo "    confirm with: deploy/vpu/vm.sh status <name>   (and vm.sh stop <name>)"
        echo "    a leftover crosvm that the daemon has lost: kill -TERM it -- NEVER kill -9,"
        echo "    a killed crosvm leaks Gunyah RM memparcels until the phone is rebooted."
        ;;
    "not started"|"short")
        echo "hp: remedy: read the VM log NOW, do not wait for wait-ssh --"
        echo "    deploy/vpu/vm.sh log <name>               # the daemon's Executing: line + stdio"
        echo "    or the app's stderr if the VM was launched from the app."
        echo "    The VM either failed to launch or exited; ssh will never answer."
        ;;
    esac
}

# --- the poll loop ------------------------------------------------------------------------------
# Prints a line only when the verdict changes, so a --wait that ends OK is two lines at most and
# the last line printed is always the one the exit code carries.
hp_poll() {  # hp_poll <off|on> <secs>
    local want=$1 secs=$2 end last=""
    end=$(( $(date +%s) + secs ))
    while :; do
        hp_sample_or_die
        if [ "$want" = off ]; then hp_verdict_off; else hp_verdict_on; fi
        if [ "$VERDICT" != "$last" ]; then
            echo "hp: $VERDICT: $DETAILS"
            last=$VERDICT
        fi
        [ "$RC" -eq 0 ] && return 0
        [ "$(date +%s)" -lt "$end" ] || return "$RC"
        sleep 1
    done
}

# --- verbs --------------------------------------------------------------------------------------
VERB=${1:-}
[ -n "$VERB" ] || usage
shift

case "$VERB" in
status)
    [ "$#" -eq 0 ] || usage
    adb_wait
    hp_sample_or_die
    echo "pool_avail:  $hp_pool_avail / $hp_pool_want pages   ($(mib "$hp_pool_avail") / $(mib "$hp_pool_want") MiB)"
    echo "pool_total:  ${hp_pool_total:-?} pages (proven capacity)"
    echo "served:      $hp_served pages ($(mib "$hp_served") MiB)"
    echo "active_vms:  ${hp_active_vms:-?}"
    echo "state:       ${hp_state:-?}"
    echo "acquire:     active=${hp_acquire_active:-?} mode=${hp_acquire_mode:-?} stop_reason=\"${hp_acquire_stop_reason:-?}\""
    echo "vm_owners:"
    hp_owner_lines
    # Say which of the two expected states this is, so `status` alone answers the question the
    # rest of the script exists for.
    if [ "$hp_served" -ne 0 ]; then
        hp_verdict_on
    else
        hp_verdict_off
    fi
    echo "hp: $VERDICT: $DETAILS"
    exit 0
    ;;
expect)
    WHAT=${1:-}; [ -n "$WHAT" ] || usage; shift
    case "$WHAT" in on|off) ;; *) usage ;; esac
    WAIT=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --wait)       WAIT=${2:-}; shift 2 || usage ;;
            --wait=*)     WAIT=${1#--wait=}; shift ;;
            --min-pages)  MIN_PAGES=${2:-}; shift 2 || usage ;;
            --min-pages=*) MIN_PAGES=${1#--min-pages=}; shift ;;
            --min-mb)     MIN_PAGES=$(( ( ${2:-0} + HP_MB_PER_PAGE - 1 ) / HP_MB_PER_PAGE )); shift 2 || usage ;;
            --min-mb=*)   MIN_PAGES=$(( ( ${1#--min-mb=} + HP_MB_PER_PAGE - 1 ) / HP_MB_PER_PAGE )); shift ;;
            *) usage ;;
        esac
    done
    case "$WAIT" in ''|*[!0-9]*) usage ;; esac
    case "$MIN_PAGES" in ''|*[!0-9]*) usage ;; esac
    [ "$WHAT" = off ] && [ "$MIN_PAGES" -ne 0 ] && die "hp: --min-pages/--min-mb make no sense with 'expect off'"
    adb_wait
    hp_poll "$WHAT" "$WAIT" && exit 0
    rc=$RC
    hp_remedy
    exit "$rc"
    ;;
reclaim)
    YES=0
    while [ "$#" -gt 0 ]; do
        case "$1" in --yes) YES=1; shift ;; *) usage ;; esac
    done
    adb_wait
    hp_sample_or_die
    hp_verdict_off
    if [ "$hp_served" -ne 0 ]; then
        # Reclaiming under a live VM is not a repair, it is a fight with the VM that owns the
        # pages. Refuse, and say who holds them.
        echo "hp: $VERDICT: $DETAILS"
        hp_remedy
        exit 3
    fi
    if [ "$RC" -eq 0 ]; then
        echo "hp: $VERDICT: $DETAILS -- nothing to reclaim"
        exit 0
    fi
    echo "hp: $VERDICT: $DETAILS"
    if [ "$YES" -ne 1 ]; then
        echo "hp: reclaim would write, as root on $PHONE:"
        echo "    echo 1 > $HP_PARAMS/manual_release      # then re-check after 10s"
        echo "    echo 3 > $HP_PARAMS/acquire             # if still short; then poll acquire_active"
        echo "hp: re-run with --yes to actually do it."
        exit "$USAGE_RC"
    fi
    echo "hp: reclaim: echo 1 > manual_release"
    out=$(asu "echo 1 > $HP_PARAMS/manual_release 2>&1")
    [ -n "$out" ] && echo "hp: reclaim: manual_release said: $out"
    sleep 10
    hp_sample_or_die
    hp_verdict_off
    if [ "$RC" -eq 0 ]; then
        echo "hp: $VERDICT: $DETAILS -- manual_release was enough"
        exit 0
    fi
    echo "hp: reclaim: still short ($hp_pool_avail/$hp_pool_want); echo 3 > acquire"
    out=$(asu "echo 3 > $HP_PARAMS/acquire 2>&1")
    [ -n "$out" ] && echo "hp: reclaim: acquire said: $out"
    end=$(( $(date +%s) + 120 ))
    while [ "$(date +%s)" -lt "$end" ]; do
        sleep 2
        hp_sample_or_die
        [ "${hp_acquire_active:-0}" = 0 ] && break
    done
    if [ "${hp_acquire_active:-0}" != 0 ]; then
        echo "hp: reclaim: acquire_active is still 1 after 120s (state=${hp_state:-?}, pool_avail=$hp_pool_avail/$hp_pool_want)"
        echo "hp: reclaim: let it finish, or abort it with: echo 0 > $HP_PARAMS/acquire"
        exit 2
    fi
    echo "hp: reclaim: acquire finished -- stop_reason=\"${hp_acquire_stop_reason:-?}\""
    hp_verdict_off
    echo "hp: $VERDICT: $DETAILS"
    [ "$RC" -eq 0 ] || hp_remedy
    exit "$RC"
    ;;
*)
    usage
    ;;
esac
