# shellcheck shell=bash
# Shared helpers for the VPU dev rig (deploy/vpu/*). Sourced, never executed.
#
# Everything here talks to one phone (PHONE, default the 5566 lab device) and to one DroidVM
# daemon on it. Two facts drive the whole design:
#
#   * the daemon's TCP port and auth token are regenerated on EVERY daemon start
#     (Daemon.java:177 writes a fresh UUID, Server.java:98 binds a random free port), so both
#     are re-read from the run dir on every call rather than cached in a file;
#   * the shipped `droidvm` CLI cannot start an already-stored VM -- `start` always goes through
#     `vm_create`, which refuses an existing id (VMInstanceStore.java:81-85). So anything that
#     starts, modifies or inspects a stored VM speaks the JSON IPC directly, via dvmipc.py over
#     `adb forward`.
#
# See logs/vpu_survey/device-5566-vm.md §1-2 and logs/vpu_survey/app-daemon.md §5.

PHONE=${PHONE:-172.22.74.2:5566}
APP=${APP:-/data/data/cn.classfun.droidvm}
RUN="$APP/run"
# shellcheck disable=SC2034  # consumed by the scripts that source this file
DAEMON_LOG="$APP/cache/daemon.log"

VPU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # consumed by push_crosvm.sh
REPO="$(cd "$VPU_DIR/../.." && pwd)"
DVMIPC="$VPU_DIR/dvmipc.py"

# ~8 s is the budget for deciding that the direct IPv6 route is dead and going through the
# phone instead (see "reaching the guest" at the bottom of this file).
SSH_CONNECT_TIMEOUT=${SSH_CONNECT_TIMEOUT:-8}
SSH_OPTS=${SSH_OPTS:--o StrictHostKeyChecking=accept-new -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=yes}

die()  { echo "$*" >&2; exit 1; }
note() { echo "$*" >&2; }

# --- adb ----------------------------------------------------------------------------------------
# `adb shell` concatenates its argv with plain spaces and loses every layer of quoting, so both
# helpers below ship exactly one base64 blob (alnum + / + = only, nothing a shell can chew on)
# and let the device decode it. That makes an arbitrary command -- pipes, awk scripts, quotes --
# survive the trip unchanged.
_b64() { printf '%s' "$*" | base64 -w0; }

# </dev/null on every adb invocation: `adb shell` forwards its own stdin to the device, so an
# unguarded one inside a function swallows the caller's stdin -- which silently ate the heredoc
# that tests/smoke_media.sh pipes into ssh, and the test "passed" having run nothing.
ash() {  # run as the shell user
    adb -s "$PHONE" shell "echo $(_b64 "$*") | base64 -d | sh" </dev/null 2>/dev/null | tr -d '\r'
}
asu() {  # run as root
    adb -s "$PHONE" shell "su -c 'echo $(_b64 "$*") | base64 -d | sh'" </dev/null 2>/dev/null | tr -d '\r'
}
apush() { adb -s "$PHONE" push "$1" "$2" </dev/null >/dev/null 2>&1; }

adb_wait() {
    local _
    for _ in $(seq 1 12); do
        adb -s "$PHONE" shell true </dev/null >/dev/null 2>&1 && return 0
        adb connect "$PHONE" </dev/null >/dev/null 2>&1
        sleep 2
    done
    die "adb: $PHONE is not reachable"
}

# --- daemon -------------------------------------------------------------------------------------
daemon_pid() {
    local pid
    pid=$(asu "cat $RUN/droidvmd.pid 2>/dev/null" | tr -dc '0-9')
    [ -n "$pid" ] || return 1
    # The pid file outlives a reboot; only /proc settles it (device-5566-vm.md §2.1).
    [ "$(asu "[ -d /proc/$pid ] && echo y")" = y ] || return 1
    echo "$pid"
}

# Start the daemon exactly the way the UI does (DaemonHelper.java:138-151), with the stdio
# redirection that DaemonHelper does not need and an adb shell does: bin/daemon is a
# double-fork+setsid wrapper that never touches its fds (unixhelper/daemon.c), so without
# </dev/null >/dev/null 2>&1 the adb shell hangs until it is killed.
daemon_start() {
    local apk libdir
    apk=$(ash "pm path cn.classfun.droidvm" | sed -n 's/^package://p' | head -1)
    [ -n "$apk" ] || die "daemon: cn.classfun.droidvm is not installed on $PHONE"
    libdir="$(dirname "$apk")/lib/arm64"
    note "daemon: starting (apk=$apk)"
    asu "env CLASSPATH=$apk LD_LIBRARY_PATH=$libdir:$APP/lib \
         $APP/bin/daemon /system/bin/app_process64 / cn.classfun.droidvm.daemon.Daemon \
         </dev/null >/dev/null 2>&1"
    local _
    for _ in $(seq 1 20); do
        sleep 1
        daemon_pid >/dev/null 2>&1 && { note "daemon: pid $(daemon_pid)"; return 0; }
    done
    die "daemon: did not come up within 20s"
}

daemon_ensure() {
    daemon_pid >/dev/null 2>&1 && return 0
    daemon_start
}

dvm_port()  { asu "cat $RUN/droidvmd-port.txt"  | tr -dc '0-9'; }
dvm_token() { asu "cat $RUN/droidvmd-token.txt" | tr -dc '0-9a-f'; }

# adb-forwards the daemon's port to the same local port and echoes it. Idempotent.
_DVM_PORT=""
_DVM_TOKEN=""
dvm_connect() {
    [ -n "$_DVM_PORT" ] && return 0
    daemon_ensure
    _DVM_PORT=$(dvm_port)
    _DVM_TOKEN=$(dvm_token)
    [ -n "$_DVM_PORT" ]  || die "daemon: no port in $RUN/droidvmd-port.txt"
    [ -n "$_DVM_TOKEN" ] || die "daemon: no token in $RUN/droidvmd-token.txt"
    adb -s "$PHONE" forward "tcp:$_DVM_PORT" "tcp:$_DVM_PORT" </dev/null >/dev/null \
        || die "adb forward tcp:$_DVM_PORT failed"
}

# dvm <dvmipc command> [args...]
dvm() {
    dvm_connect
    python3 "$DVMIPC" --port "$_DVM_PORT" --token "$_DVM_TOKEN" "$@"
}

# --- VM lookup ----------------------------------------------------------------------------------
# vm_list carries the whole stored config plus the live `state`, `pid` and `streams`
# (VMInstance.toInfoJson, app-daemon.md §5.2), so one call answers every question below.
vm_info() {  # vm_info <name-or-id> -> the VM's entry from vm_list, as JSON
    local key=$1
    dvm list | python3 -c '
import json,sys
key = sys.argv[1]
d = json.load(sys.stdin).get("data") or []
for vm in d:
    if vm.get("id") == key or vm.get("name") == key:
        json.dump(vm, sys.stdout); sys.exit(0)
sys.stderr.write("no VM named or id %r (have: %s)\n" % (key, ", ".join(v.get("name","?") for v in d)))
sys.exit(1)' "$key"
}

vm_field() {  # vm_field <json> <key> [default]
    printf '%s' "$1" | python3 -c '
import json,sys
v = json.load(sys.stdin)
for k in sys.argv[1].split("."):
    v = (v or {}).get(k) if isinstance(v, dict) else None
print(sys.argv[2] if v is None else (v if isinstance(v, str) else json.dumps(v)))' "$2" "${3:-}"
}

# vm_list reports the state as the VMState enum NAME ("RUNNING"), while vm_status lowercases it
# (StatusHandler.java:36-37). Normalise, so callers only ever compare against lowercase.
vm_state() { vm_field "$1" state STOPPED | tr '[:upper:]' '[:lower:]'; }

# --- guest address ------------------------------------------------------------------------------
# The guest gets a SLAAC address from the phone's own /64, with an EUI-64 interface id derived
# from the NIC MAC in the VM config -- so the ssh target is known before the guest has booted.
# Same construction as deploy/pseudo-unprotected/poolvm.sh's eui(), with the prefix read live off
# wlan0 instead of hard-coded, because the lab prefix is delegated and changes.
eui64_suffix() {  # eui64_suffix aa:bb:cc:dd:ee:ff
    local o
    IFS=: read -r -a o <<<"$1"
    [ "${#o[@]}" = 6 ] || die "eui64: not a MAC: $1"
    printf '%x:%x:%x:%x\n' \
        $(( ((0x${o[0]} ^ 2) << 8) | 0x${o[1]} )) \
        $(( (0x${o[2]} << 8) | 0xff )) \
        $(( 0xfe00 | 0x${o[3]} )) \
        $(( (0x${o[4]} << 8) | 0x${o[5]} ))
}

phone_prefix() {  # the /64 the phone itself lives on
    asu "ip -6 addr show wlan0" |
        awk '/inet6 / && /scope global/ && $2 ~ /\/64$/ {split($2,a,"/"); print a[1]; exit}' |
        awk -F: '{printf "%s:%s:%s:%s\n", $1, $2, $3, $4}'
}

guest_addr() {  # guest_addr <name-or-id>
    [ -n "${GUEST6:-}" ] && { echo "$GUEST6"; return 0; }
    local info mac prefix
    info=$(vm_info "$1") || exit 1
    mac=$(printf '%s' "$info" | python3 -c '
import json,sys
n = json.load(sys.stdin).get("networks") or []
print(n[0]["mac_address"] if n else "")')
    [ -n "$mac" ] || die "guest_addr: VM $1 has no network in its config"
    prefix=$(phone_prefix)
    [ -n "$prefix" ] || die "guest_addr: wlan0 on $PHONE has no global /64"
    echo "$prefix:$(eui64_suffix "$mac")"
}

# --- reaching the guest ---------------------------------------------------------------------------
# There are two ways in, and which one works is a property of the lab network on the day:
#
#   direct  ssh -6 root@<guest>  -- needs the router's NDP entry for the /128 the phone proxies on
#           wlan0 to have resolved. It usually has.
#   proxy   ssh -o ProxyCommand='adb -s $PHONE shell -T su -c "<nc> -w 30 %h %p"' -- the phone
#           itself always reaches its own guest (1.5 ms), so bridging one TCP stream through its
#           root shell works even when this box has no route to the guest at all. WP G1 lost the
#           direct route for a whole session and used exactly this for every ssh/scp/make
#           (logs/vpu_wp/G1.md §1).
#
# The choice is made once per process by probing the direct path with SSH_CONNECT_TIMEOUT, is
# announced on stderr once, and is only cached when a path actually answered -- so wait-ssh's poll
# loop keeps retrying both while the guest is still booting instead of pinning itself to the path
# that happened to fail first. GUEST_SSH_VIA=direct|proxy skips the probe.

# The netcat to run in the phone's root shell. KernelSU ships busybox under /data/adb/ksu/bin,
# Android ships toybox in /system/bin; both are on root's PATH and both bridge a TCP stream.
_PHONE_NC=""
phone_nc() {
    # shellcheck disable=SC2016  # $n is for the phone's shell, not this one
    [ -n "$_PHONE_NC" ] || _PHONE_NC=$(asu 'for n in busybox toybox; do command -v $n >/dev/null 2>&1 && { echo "$n nc"; break; }; done')
    [ -n "$_PHONE_NC" ] || die "ssh fallback: no busybox and no toybox in the root shell on $PHONE"
    printf '%s' "$_PHONE_NC"
}

GUEST_SSH_PATH=""
GUEST_SSH_EXTRA=(-6)   # ssh/scp arguments for the chosen path; the direct one just forces IPv6

_guest_ssh_probe() {  # _guest_ssh_probe <addr> -- one connect attempt with the current path
    # shellcheck disable=SC2086  # SSH_OPTS is a deliberate word list
    timeout "$(( SSH_CONNECT_TIMEOUT + 5 ))" \
        ssh $SSH_OPTS "${GUEST_SSH_EXTRA[@]}" "root@$1" true </dev/null >/dev/null 2>&1
}

guest_ssh_select() {  # guest_ssh_select <addr> -- 0 if some path answered, 1 if neither did
    [ -n "$GUEST_SSH_PATH" ] && return 0
    if [ "${GUEST_SSH_VIA:-auto}" != proxy ]; then
        GUEST_SSH_EXTRA=(-6)
        if [ "${GUEST_SSH_VIA:-auto}" = direct ] || _guest_ssh_probe "$1"; then
            GUEST_SSH_PATH=direct
            note "guest: ssh via the direct IPv6 route to $1${GUEST_SSH_VIA:+ (GUEST_SSH_VIA=$GUEST_SSH_VIA)}"
            return 0
        fi
    fi
    GUEST_SSH_EXTRA=(-o "ProxyCommand=adb -s $PHONE shell -T su -c \"$(phone_nc) -w 30 %h %p\"")
    if [ "${GUEST_SSH_VIA:-auto}" = proxy ] || _guest_ssh_probe "$1"; then
        GUEST_SSH_PATH=proxy
        if [ "${GUEST_SSH_VIA:-auto}" = proxy ]; then
            note "guest: ssh to $1 via adb+nc through $PHONE (GUEST_SSH_VIA=proxy)"
        else
            note "guest: no direct IPv6 route to $1 within ${SSH_CONNECT_TIMEOUT}s, ssh via adb+nc through $PHONE"
        fi
        return 0
    fi
    # Nothing answered: leave the choice uncached (the guest may still be booting) but keep the
    # proxy arguments, so a caller that runs anyway gets the error from the path most likely to work.
    return 1
}

guest_ssh() {  # guest_ssh <addr> [command...] -- stdin is passed through
    local addr=$1; shift
    guest_ssh_select "$addr" || true
    # shellcheck disable=SC2086,SC2029  # SSH_OPTS is a word list; the command is meant for the guest
    ssh $SSH_OPTS "${GUEST_SSH_EXTRA[@]}" "root@$addr" "$@"
}

guest_scp() {  # guest_scp <addr> <scp args...> -- the caller has already built the remote paths
    local addr=$1; shift
    guest_ssh_select "$addr" || true
    # shellcheck disable=SC2086
    scp $SSH_OPTS "${GUEST_SSH_EXTRA[@]}" "$@"
}

guest_ssh_ready() {  # guest_ssh_ready <addr>
    guest_ssh_select "$1"
}
