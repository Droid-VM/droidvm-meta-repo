#!/bin/bash
# VPU dev rig: reach the guest of a stored VM over ssh.
#
#   guest.sh ssh          <name|id> [command...]   ssh into the guest (stdin is passed through)
#   guest.sh scp          <name|id> <scp args...>  any argument starting with ':' becomes
#                                                  root@[<guest>]:<rest>, so both directions work
#   guest.sh install-tools <name|id>               apt-get the V4L2 / codec test tooling
#   guest.sh install-deb  <name|id> <file.deb...>  copy to /tmp and apt-get install them
#   guest.sh dmesg        <name|id> [dmesg args]   dmesg in the guest
#
# The address is the EUI-64 of the VM's NIC MAC on the phone's own /64 (lib.sh guest_addr), so it
# is known before the guest boots. GUEST6=<addr> overrides it; PHONE=<host:port> the device.
#
# ssh goes straight to that address when the route works and falls back to a ProxyCommand through
# the phone's own root shell (adb + busybox/toybox nc) when it does not -- the fallback is
# automatic, costs one ~8 s probe, and says on stderr which path it took. GUEST_SSH_VIA=direct or
# =proxy skips the probe.
set -u
SP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SP/lib.sh"

USAGE_RC=2
usage() {  # print the file's own header comment, up to the first line of code
    awk 'NR>1 && !/^#/ {exit} NR>1 {sub(/^# ?/, ""); print}' "$0"
    exit "$USAGE_RC"
}

# v4l-utils gives v4l2-ctl (the whole smoke test); ffmpeg and the gstreamer pair are the two
# stateful-codec clients the VPU acceptance ladder uses. gstreamer1.0-plugins-bad is where
# v4l2codecs / v4l2 stateful decode lives.
TOOLS="v4l-utils ffmpeg gstreamer1.0-tools gstreamer1.0-plugins-bad"

VERB=${1:-}; NAME=${2:-}
if [ -z "$VERB" ] || [ -z "$NAME" ]; then usage; fi
shift 2
adb_wait
ADDR=$(guest_addr "$NAME") || exit 1

# Both wrappers go through lib.sh's guest_ssh_select: direct IPv6 if it connects inside
# ~8 s, otherwise tunnelled through the phone's root shell with adb + nc. Which path was
# taken is printed on stderr once per run.
gssh() { guest_ssh "$ADDR" "$@"; }

case "$VERB" in
ssh)
    gssh "$@"
    ;;
scp)
    args=()
    for a in "$@"; do
        case "$a" in
            :*) args+=("root@[$ADDR]:${a#:}") ;;
            *)  args+=("$a") ;;
        esac
    done
    guest_scp "$ADDR" "${args[@]}"
    ;;
install-tools)
    # DEBIAN_FRONTEND=noninteractive because there is no tty on the far end of BatchMode ssh.
    gssh "set -e
          export DEBIAN_FRONTEND=noninteractive
          apt-get update
          apt-get install -y $TOOLS
          v4l2-ctl --version; ffmpeg -version | head -1; gst-inspect-1.0 --version | head -2"
    ;;
install-deb)
    [ "$#" -gt 0 ] || die "install-deb: give me at least one .deb"
    remote=()
    for f in "$@"; do
        [ -f "$f" ] || die "install-deb: no such file: $f"
        guest_scp "$ADDR" "$f" "root@[$ADDR]:/tmp/" || die "install-deb: scp $f failed"
        remote+=("/tmp/$(basename "$f")")
    done
    gssh "set -e
          export DEBIAN_FRONTEND=noninteractive
          apt-get install -y --reinstall ${remote[*]}"
    ;;
dmesg)
    gssh dmesg "$@"
    ;;
*)
    usage
    ;;
esac
