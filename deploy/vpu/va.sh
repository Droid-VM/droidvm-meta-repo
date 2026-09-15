#!/bin/bash
# VPU dev rig: the VA-API smokes (design plans/VPU_DESIGN.md 7.6 point 9, acceptance B18).
#
#   va.sh fixture       <name|id>   make/verify the 1080p reference clip in the guest
#   va.sh vainfo        <name|id>   vendor string + VAProfileH264High : VAEntrypointVLD
#   va.sh decode        <name|id>   ffmpeg -hwaccel vaapi -> md5, frame count, drain count
#   va.sh mpv           <name|id>   mpv --hwdec=vaapi-copy, 300 frames, no drops
#   va.sh gst           <name|id>   gst-launch vah264dec ! fakesink, 300 frames
#   va.sh v4l2-still-ok <name|id>   ffmpeg h264_v4l2m2m 300/300 -- the no-regression check
#   va.sh all           <name|id>   every verb above, in that order; one summary at the end
#   va.sh install-tools <name|id>   apt-get vainfo/mpv/the va gst plugin in the guest
#
# NONE OF THESE HAS EVER RUN [unverified until B18]: the backend's stateful path is being
# written in the same round as this script, and the rig cannot reach a phone from the build host.
# Every bar below is the number the design names, not a number this file has seen.
#
# WHAT EACH BAR MEANS
#
#   vainfo         the driver loaded at all. The vendor string proves it is OUR backend and not
#                  a fallback, and VAProfileH264High : VAEntrypointVLD is the entry the clients
#                  below look for (7.6 point 2: VA1 hard-codes the profile list, so this says
#                  nothing yet about what the device can really do -- VA1b makes it honest).
#   decode         THE bar. md5 bf32f00e5c4bca747bf7827ea5797b33 -- the same software reference
#                  B12 established and B15/B16/B17 re-verified on the V4L2 path, so a match means
#                  the VA path and the V4L2 path produce identical bytes. 300 frames. And the
#                  drain count, which must be 0: 7.6 point 5(b) restarts the codec when a sync
#                  waits too long, and a restart that happens on the reference clip means the
#                  reorder contract (the VUI of point 3) is wrong, even though the md5 matches.
#   mpv            a real player's copy path; 300 frames decoded, none dropped.
#   gst            GStreamer's own va plugin (vah264dec), 300 buffers to fakesink.
#   v4l2-still-ok  ffmpeg h264_v4l2m2m, 300/300, unchanged. VA1 touches nothing in virtio-media,
#                  so this must be exactly what B17 measured; it is here because "the VA backend
#                  broke the V4L2 clients" is the regression nobody would look for.
#
# THE ENVIRONMENT IS NOT INHERITED. The package's /etc/profile.d/droidvm-va.sh reaches LOGIN
# shells. `ssh host command` is not one, so every verb exports LIBVA_DRIVER_NAME=v4l2 itself --
# and that is also the shape of the trap a user hits: the same command that works in their
# terminal fails from a systemd unit or a cron job.
set -u
SP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SP/lib.sh"

USAGE_RC=2
usage() {  # print the file's own header comment, up to the first line of code
    awk 'NR>1 && !/^#/ {exit} NR>1 {sub(/^# ?/, ""); print}' "$0"
    exit "$USAGE_RC"
}

# The guest-side working directory and the reference clip. B12 made this clip on the host and
# pushed it; `fixture` remakes it in the guest from the same ffmpeg recipe instead, so the rig
# carries no 10 MB binary and any guest can be brought to the same starting point -- the clip is
# identified by what it decodes to, not by where it came from.
VA_DIR=${VA_DIR:-/root/va}
REF_MD5=${REF_MD5:-bf32f00e5c4bca747bf7827ea5797b33}
FRAMES=${FRAMES:-300}
# The marker the backend writes when 7.6 point 5(b) fires (timeout -> DEC_CMD_STOP -> restart).
# Kept as a setting because the exact wording belongs to the backend, not to this script; what
# the design fixes is that there IS one line per drain and that the count is 0 on this clip.
# The exact line the stateful session emits on a sync timeout (libva-v4l2 src/stateful/session.cc):
#   "sync timeout after <ms> ms on sequence <n>: DEC_CMD_STOP drain + restart (occurrence <k>)"
# Anchored on the literal so a client's own "drain" chatter can never count as a recovery.
VA_DRAIN_RE=${VA_DRAIN_RE:-DEC_CMD_STOP drain \+ restart}

VERB=${1:-}; NAME=${2:-}
[ -n "$VERB" ] || usage
[ -n "$NAME" ] || usage
case "$VERB" in fixture|vainfo|decode|mpv|gst|v4l2-still-ok|all|install-tools) ;; *) usage ;; esac

adb_wait
ADDR=$("$SP/vm.sh" wait-ssh "$NAME") || exit 1
echo "guest: $ADDR"

# vainfo is in vainfo(1)'s own package; libva2 comes with the guest; gstreamer1.0-plugins-bad is
# where the `va` plugin (vah264dec) lives on Ubuntu 26.04; mpv brings its own vaapi support.
TOOLS="vainfo mpv gstreamer1.0-plugins-bad gstreamer1.0-tools ffmpeg"

# One guest-side script, one ssh round trip. VERB and the settings above are validated or are
# this file's own constants, so interpolating them into the remote environment is safe.
{ cat <<'GUEST'
set -u
fail=0
step() { echo; echo "=== $* ==="; }
bad()  { echo "FAIL: $*"; fail=$((fail+1)); }
have() { command -v "$1" >/dev/null 2>&1; }

# The package ships this in /etc/profile.d, which a non-login ssh command never reads.
export LIBVA_DRIVER_NAME=v4l2
export GST_VAAPI_ALL_DRIVERS=1
# B18: GStreamer 1.28's `va` plugin has its OWN vendor whitelist and its OWN variable; without
# this it registers 0 features and vah264dec does not exist (`Unsupported driver: DroidVM ...`).
export GST_VA_ALL_DRIVERS=1
# libva prints its driver search and the backend's own messages at level 2; without it a failed
# vaInitialize is one unexplained number.
export LIBVA_MESSAGING_LEVEL=2
export DEBIAN_FRONTEND=noninteractive

mkdir -p "$VA_DIR"
cd "$VA_DIR" || exit 1

RENDER=${RENDER:-/dev/dri/renderD128}

do_install_tools() {
    step "install the VA-API client tooling"
    # shellcheck disable=SC2086  # deliberate: TOOLS is a package LIST and must word-split
    if ! { apt-get update -qq && apt-get install -y -qq $TOOLS; }; then bad "apt-get install failed"; fi
    for t in vainfo mpv gst-launch-1.0 ffmpeg; do
        if have "$t"; then echo "  $t: $(command -v "$t")"; else bad "$t is still missing"; fi
    done
}

do_fixture() {
    step "reference clip $VA_DIR/1080p.mp4"
    # B12's recipe, byte for byte (logs/vpu_wp/B12-acceptance.md preamble): fixed GOP, no scene
    # cuts, 300 frames. Reproducible anywhere, which is why the clip is not shipped.
    if [ ! -f 1080p.mp4 ]; then
        echo "making it (testsrc2, 300 frames, libx264 ultrafast, GOP 30)"
        ffmpeg -nostdin -y -v error -f lavfi -i testsrc2=size=1920x1080:rate=30:duration=10 \
            -c:v libx264 -preset ultrafast -g 30 -keyint_min 30 -sc_threshold 0 \
            -pix_fmt yuv420p -b:v 20M -f h264 1080p.h264 || { bad "encode failed"; return; }
        ffmpeg -nostdin -y -v error -r 30 -i 1080p.h264 -c copy 1080p.mp4 || { bad "mux failed"; return; }
    fi
    ls -l 1080p.mp4
    # The clip IS its software decode: verifying that md5 is what makes every hardware md5 below
    # mean something. -fps_mode passthrough is not optional -- without it ffmpeg may duplicate or
    # drop frames to hit the output rate and the md5 changes while nothing is wrong.
    sw=$(ffmpeg -nostdin -y -v error -i 1080p.mp4 -fps_mode passthrough \
            -f rawvideo -pix_fmt nv12 - 2>/dev/null | md5sum | cut -d' ' -f1)
    echo "software decode md5: $sw"
    [ "$sw" = "$REF_MD5" ] || bad "software md5 $sw != $REF_MD5 -- this is not the reference clip"
}

need_clip() {
    [ -f "$VA_DIR/1080p.mp4" ] && return 0
    bad "no $VA_DIR/1080p.mp4 -- run: va.sh fixture <name>"
    return 1
}

do_vainfo() {
    step "vainfo"
    have vainfo || { bad "vainfo is missing -- run: va.sh install-tools <name>"; return; }
    vainfo --display drm --device "$RENDER" > vainfo.txt 2>&1
    rc=$?
    cat vainfo.txt
    [ "$rc" = 0 ] || bad "vainfo exited $rc"
    # The vendor string is how you tell OUR backend from a fallback: libva happily reports a
    # different driver's string and vainfo still exits 0.
    # Upstream's stateless path answers with the vendor string "v4l2" too, so "v4l2" alone cannot
    # tell our path from a fallback to it; the stateful path says "DroidVM libva-v4l2 (stateful
    # virtio-media)" (libva-v4l2 src/driver.h V4L2_STR_VENDOR_STATEFUL).
    grep -qi 'stateful virtio-media' vainfo.txt || bad "vendor string is not the stateful backend's -- a different driver (or the stateless path) answered"
    grep -Eq 'VAProfileH264High[[:space:]]*:[[:space:]]*VAEntrypointVLD' vainfo.txt ||
        bad "VAProfileH264High : VAEntrypointVLD is not listed"
}

do_decode() {
    step "ffmpeg -hwaccel vaapi decode of 1080p.mp4"
    need_clip || return
    # -fps_mode passthrough for the reason given in do_fixture. hwdownload+format=nv12 brings the
    # surface back to system memory, which is the copy path VA1 supports (7.6 point 7: export is
    # VA_STATUS_ERROR_UNIMPLEMENTED, so a zero-copy client falls back cleanly instead).
    # `set -o pipefail` inside the substitution, not ${PIPESTATUS[0]} outside it: the pipeline
    # runs INSIDE the command substitution, so PIPESTATUS out here describes the assignment and
    # an ffmpeg that died would read as rc=0 with a wrong md5 -- the failure blamed on the codec.
    md5=$(set -o pipefail
          ffmpeg -nostdin -y -v verbose -hwaccel vaapi -hwaccel_device "$RENDER" \
            -hwaccel_output_format vaapi -i 1080p.mp4 -fps_mode passthrough \
            -vf 'hwdownload,format=nv12' -f rawvideo -pix_fmt nv12 - 2> decode.log |
          md5sum | cut -d' ' -f1)
    rc=$?
    echo "rc=$rc md5=$md5"
    [ "$rc" = 0 ] || bad "ffmpeg exited $rc (see $VA_DIR/decode.log)"
    if [ "$md5" = "$REF_MD5" ]; then
        echo "md5 MATCHES the software reference $REF_MD5"
    else
        bad "md5 $md5 != $REF_MD5"
    fi
    # ffmpeg's own frame count, from the verbose log: "frame=  300".
    n=$(sed -n 's/.*frame= *\([0-9]\+\).*/\1/p' decode.log | tail -1)
    echo "frames: ${n:-unknown} (want $FRAMES)"
    [ "${n:-0}" = "$FRAMES" ] || bad "decoded ${n:-0} frames, expected $FRAMES"
    # 7.6 point 5(b): every reorder-timeout drain costs a codec restart, and the design's bar on
    # this clip is ZERO. A non-zero count with a matching md5 is still a failure -- it means the
    # bitstream's reorder promise (point 3's VUI) does not match what the codec holds.
    d=$(grep -Eci "$VA_DRAIN_RE" decode.log 2>/dev/null || true)
    echo "drain lines matching /$VA_DRAIN_RE/i: ${d:-0} (want 0)"
    [ "${d:-0}" = 0 ] || bad "${d} drain/restart lines -- the reorder contract is not holding"
}

do_mpv() {
    step "mpv --hwdec=vaapi-copy"
    need_clip || return
    have mpv || { bad "mpv is missing -- run: va.sh install-tools <name>"; return; }
    mpv --hwdec=vaapi-copy --no-audio --vo=null --untimed --frames="$FRAMES" \
        --msg-level=all=info 1080p.mp4 > mpv.log 2>&1
    rc=$?
    tail -5 mpv.log
    [ "$rc" = 0 ] || bad "mpv exited $rc (see $VA_DIR/mpv.log)"
    # "Using hardware decoding (vaapi-copy)" is mpv saying it really got the backend; without it
    # mpv decodes in software and still exits 0, which is the silent pass this check exists for.
    grep -qi 'hardware decoding (vaapi' mpv.log || bad "mpv did not use vaapi (software fallback)"
    grep -qiE 'dropped|drop=[1-9]' mpv.log && bad "mpv reports dropped frames"
}

do_gst() {
    step "gst-launch-1.0 vah264dec"
    need_clip || return
    have gst-launch-1.0 || { bad "gst-launch-1.0 is missing -- run: va.sh install-tools <name>"; return; }
    gst-inspect-1.0 vah264dec > /dev/null 2>&1 || {
        bad "no vah264dec element -- the va plugin did not load (gst-inspect-1.0 va)"; return; }
    gst-launch-1.0 -v filesrc location=1080p.mp4 ! qtdemux ! h264parse ! vah264dec \
        ! fakesink silent=false > gst.log 2>&1
    rc=$?
    [ "$rc" = 0 ] || bad "gst-launch exited $rc (see $VA_DIR/gst.log)"
    n=$(grep -cE 'chain .*[<(]fakesink' gst.log)   # 1.28 prints "(fakesink0:sink)", older "<fakesink...>"
    echo "fakesink buffers: $n (want $FRAMES)"
    [ "$n" = "$FRAMES" ] || bad "fakesink saw $n buffers, expected $FRAMES"
}

do_v4l2_still_ok() {
    step "no-regression: ffmpeg -c:v h264_v4l2m2m"
    need_clip || return
    # B15/B16/B17's own command, unchanged, including -fps_mode passthrough. VA1 does not touch
    # virtio-media, so this must still be 300/300 and bit-exact.
    md5=$(set -o pipefail
          ffmpeg -nostdin -y -v verbose -c:v h264_v4l2m2m -i 1080p.mp4 -fps_mode passthrough \
            -f rawvideo -pix_fmt nv12 - 2> v4l2.log | md5sum | cut -d' ' -f1)
    rc=$?
    n=$(sed -n 's/.*frame= *\([0-9]\+\).*/\1/p' v4l2.log | tail -1)
    echo "rc=$rc md5=$md5 frames=${n:-unknown}"
    [ "$rc" = 0 ] || bad "ffmpeg h264_v4l2m2m exited $rc"
    [ "$md5" = "$REF_MD5" ] || bad "V4L2 path md5 $md5 != $REF_MD5 -- a REGRESSION, not a VA bug"
    # B17 trap 17: a hardware decode-back frame count on a LONG fresh clip is unreliable in
    # ffmpeg's own h264_v4l2m2m dequeue path. This clip is a saved fixture, not a fresh encode,
    # and those decode 300/300 -- so a short count here is worth reading, not worth ignoring.
    [ "${n:-0}" = "$FRAMES" ] || bad "V4L2 path decoded ${n:-0} frames, expected $FRAMES"
}

case "$VERB" in
install-tools)  do_install_tools ;;
fixture)        do_fixture ;;
vainfo)         do_vainfo ;;
decode)         do_decode ;;
mpv)            do_mpv ;;
gst)            do_gst ;;
v4l2-still-ok)  do_v4l2_still_ok ;;
all)            do_fixture; do_vainfo; do_decode; do_mpv; do_gst; do_v4l2_still_ok ;;
esac

echo; echo "failures: $fail"
[ "$fail" = 0 ]
GUEST
} | "$SP/guest.sh" ssh "$NAME" \
      "VERB='$VERB' VA_DIR='$VA_DIR' REF_MD5='$REF_MD5' FRAMES='$FRAMES' \
       VA_DRAIN_RE='$VA_DRAIN_RE' TOOLS='$TOOLS' bash -s"
rc=$?
echo
if [ "$rc" = 0 ]; then echo "va $VERB: PASS"; else echo "va $VERB: FAIL (rc=$rc)"; fi
exit "$rc"
