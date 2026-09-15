#!/bin/bash
# VPU dev rig: the VA-API smokes (design plans/VPU_DESIGN.md 7.6 point 9, acceptance B18).
#
#   va.sh fixture       <name|id>   VERIFY the 1080p reference clip in the guest (never makes it)
#   va.sh vainfo        <name|id>   vendor string + VAProfileH264High : VAEntrypointVLD
#   va.sh decode        <name|id>   ffmpeg -hwaccel vaapi -> md5, frames, both drain counts
#   va.sh mpv           <name|id>   mpv --hwdec=vaapi-copy, 300 frames, and the CAPTURE pool line
#   va.sh gst           <name|id>   gst-launch vah264dec ! fakesink, 300 buffers
#   va.sh bframes       <name|id>   a -bf 3 720p clip: VA md5 vs software md5, both drain counts
#   va.sh v4l2-still-ok <name|id>   ffmpeg h264_v4l2m2m 300/300 -- the no-regression check
#   va.sh all           <name|id>   every verb above; the decode runs 8x (VA_DECODE_RUNS)
#   va.sh install-tools <name|id>   apt-get vainfo/mpv/the va gst plugin in the guest
#
# B18 ran all of these on the lab phone. What it measured, and what therefore changed here:
# `decode` is bit-exact 8/8 at 300 frames with 0 drains and is FASTER than h264_v4l2m2m; `gst` is
# 300/300 once GST_VA_ALL_DRIVERS=1 is exported; `v4l2-still-ok` never moved. Three defects are
# open and this script is shaped around them: D83 (an intermittent std::out_of_range abort in
# V4L2StatefulDevice::queue_capture, ~1 run in 9 -- which is why `all` decodes eight times and
# counts aborts APART from wrong bytes), D84 (mpv never completes; its CAPTURE pool comes out at
# the device's bare minimum, so `mpv` now records the pool line), D85/D86 (a B-frame stream's
# tail needs one drain, and the recovery is one-shot -- which is why `bframes` exists and why the
# drain bar is two numbers, not one).
#
# WHAT EACH BAR MEANS
#
#   fixture        the clip is an ARTEFACT, not a recipe. B18 proved it cannot be re-encoded:
#                  the guest's x264 gives a different md5 at every bitrate tried, because the
#                  bytes came from the BUILD HOST's x264 in B12. So this verb verifies, and if
#                  the guest has no clip it pushes the host-side copy ($VA_FIXTURE) and verifies
#                  that. There is no encode path left to go wrong.
#   vainfo         the driver loaded at all. The vendor string proves it is OUR backend and not
#                  a fallback, and VAProfileH264High : VAEntrypointVLD is the entry the clients
#                  below look for (7.6 point 2: VA1 hard-codes the profile list, so this says
#                  nothing yet about what the device can really do -- VA1b makes it honest).
#   decode         THE bar. md5 bf32f00e5c4bca747bf7827ea5797b33 -- the same software reference
#                  B12 established and B15/B16/B17 re-verified on the V4L2 path, so a match means
#                  the VA path and the V4L2 path produce identical bytes. 300 frames. And the
#                  two drain counts of 7.6 point 5(b), which are NOT the same failure: a `sync
#                  timeout` means a client waited past its budget and the codec had to be
#                  restarted under it (0 on every clip), an `idle drain` means the codec was
#                  holding a tail nobody asked for and was flushed on purpose (0 here, 1 on a
#                  B-frame clip -- see `bframes`).
#   mpv            a real player's copy path; 300 frames decoded, none dropped. It also prints
#                  the backend's own `CAPTURE pool: min N + share S = M (surfaces K)` line,
#                  because D84's evidence is exactly that number: B18's strace read
#                  REQBUFS(CAPTURE, 21) -- the device's bare announced minimum -- where 7.6
#                  point 4 says min + min(surfaces, 8), so the client's held surfaces are coming
#                  out of the codec's own slots and both sides wait.
#   gst            GStreamer's own va plugin (vah264dec), 300 buffers to fakesink.
#   bframes        a `-bf 3` 720p stream, encoded in the guest and compared against ITS OWN
#                  software decode (not against a fixed md5 -- the encode is not reproducible).
#                  B18: bit-exact, 150/150, and exactly ONE idle drain on every run, at the end
#                  of the stream. That is not a bug to be counted down to zero: VA-API has no
#                  EOS/flush call, so a B-frame tail sits in the codec until something drains it
#                  and the client's sync of a tail frame can only be satisfied by that drain.
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

# The guest-side working directory and the reference clip.
#
# THE CLIP IS AN ARTEFACT. B12 encoded it on the build host and pushed it; B18 tried to remake it
# in the guest and got a different md5 at 20M (the recipe that used to live here, which carried
# B12's 4K bitrate), a third md5 at 8M, and a different file size again -- the guest's x264 is
# not the host's x264 and no bitrate closes that gap. So the rig identifies the clip by what it
# decodes to and OBTAINS it rather than generating it: the guest's copy if it is already right,
# otherwise the host-side copy below, pushed over scp.
VA_DIR=${VA_DIR:-/root/va}
REF_MD5=${REF_MD5:-bf32f00e5c4bca747bf7827ea5797b33}
FRAMES=${FRAMES:-300}
# The host-side artefact. B19 must place it here, from the guest overlay B18 left it on
# (/root/b12a/1080p.mp4, 10 503 274 B, software decode bf32f00e5c4bca747bf7827ea5797b33), and
# record the file's own sha256 in its report -- that sha256 is what makes a future copy of this
# file checkable without decoding it. Until it exists, `fixture` says so and fails loudly instead
# of quietly measuring the wrong bytes.
VA_FIXTURE=${VA_FIXTURE:-/root/gitrs/DroidVM/logs/vpu_wp/fixtures/1080p.mp4}
# `all` decodes eight times: D83 aborts about one run in nine, so a single pass is not evidence
# of anything and a single failure is not evidence of a wrong decode either. The `decode` verb on
# its own stays a single run (it is the one you type while iterating); VA_DECODE_RUNS overrides
# either of them.
# The B-frame probe: 5 s of 1280x720 at 30 fps with -bf 3 = 150 frames.
BF_FRAMES=${BF_FRAMES:-150}

# The two markers the backend writes when 7.6 point 5(b) fires. They are SETTINGS because the
# wording belongs to the backend, not to this script; what the design fixes is that each event
# has its own line and that the two counts are read apart:
#   sync timeout after <ms> ms on sequence <n>: DEC_CMD_STOP drain + restart (occurrence <k>)
#   idle drain after <ms> ms idle on sequence <n>: DEC_CMD_STOP drain + restart
# Anchored on the literals so a client's own "drain" chatter can never count as a recovery. If
# the backend's final wording differs, set these two rather than editing the script.
# The defaults are DOUBLE-QUOTED: in a bare ${VAR:-word} the word is quote-removed, so the \+
# that makes the literal plus of "drain + restart" a literal turns into an ERE quantifier on the
# preceding space -- "drain" followed by one or more spaces and then " restart" -- which matches
# nothing, and both counts silently read 0 on every run (B19 measured exactly that).
VA_TIMEOUT_RE="${VA_TIMEOUT_RE:-sync timeout after [0-9]+ ms.*DEC_CMD_STOP drain \+ restart}"
VA_IDLE_RE="${VA_IDLE_RE:-idle drain after [0-9]+ ms.*DEC_CMD_STOP drain \+ restart}"
# The CAPTURE pool provisioning line (7.6 point 4), read at LIBVA_MESSAGING_LEVEL=2. D84 is a
# number on this line, not a stack trace: `min N + share S` with S = 0 is the deadlock.
# Same quoting rule, and the tail stops at the surface count: the shipped backend prints
# `(surfaces K, granted G)` where the design text names only `(surfaces K)`.
VA_POOL_RE="${VA_POOL_RE:-CAPTURE pool: min [0-9]+ \+ share [0-9]+ = [0-9]+ \(surfaces [0-9]+}"

VERB=${1:-}; NAME=${2:-}
[ -n "$VERB" ] || usage
[ -n "$NAME" ] || usage
case "$VERB" in
    fixture|vainfo|decode|mpv|gst|bframes|v4l2-still-ok|all|install-tools) ;;
    *) usage ;;
esac
case "$VERB" in
    all) RUNS=${VA_DECODE_RUNS:-8} ;;
    *)   RUNS=${VA_DECODE_RUNS:-1} ;;
esac

adb_wait
ADDR=$("$SP/vm.sh" wait-ssh "$NAME") || exit 1
echo "guest: $ADDR"

# vainfo is in vainfo(1)'s own package; libva2 comes with the guest; gstreamer1.0-plugins-bad is
# where the `va` plugin (vah264dec) lives on Ubuntu 26.04; mpv brings its own vaapi support.
TOOLS="vainfo mpv gstreamer1.0-plugins-bad gstreamer1.0-tools ffmpeg"

# ---------------------------------------------------------------------------
# The fixture stage runs on the HOST, because pushing a file is a host-side act: verify what the
# guest has, and only if that is not the reference clip, send ours and verify again. Two ssh
# round trips in the worst case, none of them able to invent bytes.
# ---------------------------------------------------------------------------
guest_sw_md5() {  # the guest's software decode of its own clip, or empty if there is no clip
    "$SP/guest.sh" ssh "$NAME" "set -u
        [ -f '$VA_DIR/1080p.mp4' ] || exit 3
        ffmpeg -nostdin -y -v error -i '$VA_DIR/1080p.mp4' -fps_mode passthrough \
            -f rawvideo -pix_fmt nv12 - 2>/dev/null | md5sum | cut -d' ' -f1" 2>/dev/null |
        tr -d '\r' | tail -1
}

stage_fixture() {
    echo
    echo "=== fixture: verify $VA_DIR/1080p.mp4 in the guest ==="
    got=$(guest_sw_md5)
    if [ "$got" = "$REF_MD5" ]; then
        echo "guest clip software md5 $got -- MATCHES the reference"
        return 0
    fi
    echo "guest clip software md5 '${got:-<no clip>}' != $REF_MD5"
    if [ ! -f "$VA_FIXTURE" ]; then
        echo "FAIL: no host-side artefact at $VA_FIXTURE, and the clip is NOT reproducible" >&2
        echo "      from a recipe (B18 4.1: the guest's x264 gives a different md5 at every" >&2
        echo "      bitrate). Copy it from a guest that has it -- B18 left one at" >&2
        echo "      /root/b12a/1080p.mp4 -- and record its sha256 in the report." >&2
        return 1
    fi
    echo "pushing the host artefact $VA_FIXTURE"
    echo "  sha256 $(sha256sum "$VA_FIXTURE" | cut -d' ' -f1)  bytes $(wc -c < "$VA_FIXTURE")"
    "$SP/guest.sh" ssh "$NAME" "mkdir -p '$VA_DIR'" || return 1
    "$SP/guest.sh" scp "$VA_FIXTURE" ":$VA_DIR/1080p.mp4" || return 1
    got=$(guest_sw_md5)
    if [ "$got" = "$REF_MD5" ]; then
        echo "pushed clip software md5 $got -- MATCHES the reference"
        return 0
    fi
    echo "FAIL: even the pushed clip decodes to '${got:-<no clip>}', not $REF_MD5 --" >&2
    echo "      the host artefact is the wrong file" >&2
    return 1
}

case "$VERB" in
fixture|all|decode|mpv|gst|v4l2-still-ok)
    stage_fixture || { echo; echo "va $VERB: FAIL (fixture)"; exit 1; }
    ;;
esac
[ "$VERB" != fixture ] || { echo; echo "va fixture: PASS"; exit 0; }

# One guest-side script, one ssh round trip. VERB and the settings above are validated or are
# this file's own constants, so interpolating them into the remote environment is safe.
{ cat <<'GUEST'
set -u
fail=0
step() { echo; echo "=== $* ==="; }
bad()  { echo "FAIL: $*"; fail=$((fail+1)); }
have() { command -v "$1" >/dev/null 2>&1; }

# The package ships these in /etc/profile.d, which a non-login ssh command never reads.
export LIBVA_DRIVER_NAME=v4l2
# GStreamer 1.28's `va` plugin has its OWN vendor whitelist and its OWN variable; without this it
# registers 0 features and vah264dec does not exist (`Unsupported driver: DroidVM ...`, B18 4.4).
export GST_VA_ALL_DRIVERS=1
# The same whitelist in the old gstreamer-vaapi elements, which read the other name.
export GST_VAAPI_ALL_DRIVERS=1
# libva prints its driver search and the backend's own messages at level 2; without it a failed
# vaInitialize is one unexplained number -- and the CAPTURE pool line of 7.6 point 4 is invisible.
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

# One VA decode. Sets D_RC / D_MD5 / D_N / D_T / D_I; prints nothing, so a caller can run it in a
# loop and report the shape of the whole series instead of eight blocks of prose.
#   $1 clip   $2 log file
# -fps_mode passthrough is not optional: without it ffmpeg may duplicate or drop frames to hit
# the output rate and the md5 changes while nothing is wrong. hwdownload+format=nv12 brings the
# surface back to system memory, which is the copy path VA1 supports (7.6 point 7: export is
# VA_STATUS_ERROR_UNIMPLEMENTED, so a zero-copy client falls back cleanly instead).
# `set -o pipefail` INSIDE the substitution, not ${PIPESTATUS[0]} outside it: the pipeline runs
# inside the command substitution, so PIPESTATUS out here would describe the assignment and an
# ffmpeg that died would read as rc=0 with a wrong md5 -- the failure blamed on the codec.
va_decode_once() {
    D_MD5=$(set -o pipefail
            ffmpeg -nostdin -y -v verbose -hwaccel vaapi -hwaccel_device "$RENDER" \
              -hwaccel_output_format vaapi -i "$1" -fps_mode passthrough \
              -vf 'hwdownload,format=nv12' -f rawvideo -pix_fmt nv12 - 2> "$2" |
            md5sum | cut -d' ' -f1)
    D_RC=$?
    D_N=$(sed -n 's/.*frame= *\([0-9]\+\).*/\1/p' "$2" | tail -1); D_N=${D_N:-0}
    D_T=$(grep -Eci "$VA_TIMEOUT_RE" "$2" 2>/dev/null || true); D_T=${D_T:-0}
    D_I=$(grep -Eci "$VA_IDLE_RE"    "$2" 2>/dev/null || true); D_I=${D_I:-0}
}

# A run that died on a signal is a DIFFERENT event from a run that produced the wrong bytes, and
# in this backend they have different causes: rc >= 128 is D83's std::out_of_range abort (or a
# segfault), not a decode that disagreed with the reference. Counting them together would let
# eight aborts read as "the decoder is wrong".
do_decode() {
    step "ffmpeg -hwaccel vaapi decode of 1080p.mp4 ($RUNS run(s))"
    need_clip || return
    ok=0; mism=0; short=0; aborts=0; tsum=0; isum=0; r=1
    while [ "$r" -le "$RUNS" ]; do
        va_decode_once 1080p.mp4 decode.log
        cp decode.log "decode.$r.log"
        echo "  run $r: rc=$D_RC md5=$D_MD5 frames=$D_N sync-timeout=$D_T idle-drain=$D_I"
        if   [ "$D_RC" -ge 128 ];      then aborts=$((aborts+1))
        elif [ "$D_MD5" != "$REF_MD5" ]; then mism=$((mism+1))
        elif [ "$D_N" != "$FRAMES" ];  then short=$((short+1))
        else ok=$((ok+1)); fi
        tsum=$((tsum+D_T)); isum=$((isum+D_I)); r=$((r+1))
    done
    echo "runs $RUNS: clean $ok | md5 mismatches $mism | short counts $short | aborts $aborts"
    echo "sync timeouts $tsum (want 0)  idle drains $isum (want 0 on the reference)"
    [ "$aborts" = 0 ] || bad "$aborts of $RUNS runs died on a signal -- D83's abort, NOT a wrong decode (see $VA_DIR/decode.N.log)"
    [ "$mism" = 0 ]   || bad "$mism of $RUNS runs decoded to bytes other than $REF_MD5"
    [ "$short" = 0 ]  || bad "$short of $RUNS runs were short of $FRAMES frames"
    # A sync timeout means a client waited past its budget and the codec was restarted under it:
    # on this clip the design's bar is 0 and B18 measured 0 on all 13 clean decodes.
    [ "$tsum" = 0 ] || bad "$tsum sync timeouts -- a client waited past its budget on the reference clip"
    # An idle drain on THIS clip would mean the codec is holding frames nobody is waiting for on
    # a stream with no B-frames, which is the reorder contract of 7.6 point 3 not holding.
    [ "$isum" = 0 ] || bad "$isum idle drains on the reference clip -- expected only on a B-frame stream"
}

do_mpv() {
    step "mpv --hwdec=vaapi-copy"
    need_clip || return
    have mpv || { bad "mpv is missing -- run: va.sh install-tools <name>"; return; }
    mpv --hwdec=vaapi-copy --no-audio --vo=null --untimed --frames="$FRAMES" \
        --msg-level=all=info 1080p.mp4 > mpv.log 2>&1
    rc=$?
    tail -5 mpv.log
    # D84's number, before the verdict: how many CAPTURE buffers the pool was provisioned with
    # and how many surfaces the client had made when it was. 7.6 point 4 says min + min(N, 8);
    # B18's strace read the bare announced minimum, which is the deadlock.
    pool=$(grep -Eo "$VA_POOL_RE" mpv.log | tail -1)
    if [ -n "$pool" ]; then echo "CAPTURE pool: $pool"
    else echo "CAPTURE pool: no line matching /$VA_POOL_RE/ in mpv.log (backend wording? set VA_POOL_RE)"; fi
    t=$(grep -Eci "$VA_TIMEOUT_RE" mpv.log 2>/dev/null || true)
    i=$(grep -Eci "$VA_IDLE_RE"    mpv.log 2>/dev/null || true)
    echo "sync timeouts ${t:-0} (want 0)  idle drains ${i:-0}"
    [ "$rc" = 0 ] || bad "mpv exited $rc (see $VA_DIR/mpv.log)"
    # "Using hardware decoding (vaapi-copy)" is mpv saying it really got the backend; without it
    # mpv decodes in software and still exits 0, which is the silent pass this check exists for.
    grep -qi 'hardware decoding (vaapi' mpv.log || bad "mpv did not use vaapi (software fallback)"
    grep -qiE 'dropped|drop=[1-9]' mpv.log && bad "mpv reports dropped frames"
    grep -qi 'Stateful sync failed' mpv.log && bad "the session died on a failed sync (D84)"
    [ "${t:-0}" = 0 ] || bad "${t} sync timeouts under mpv -- D84's deadlock"
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

# The B-frame probe (D85). Encoded HERE and compared against ITS OWN software decode: this clip
# has no reference md5 and cannot have one -- the encoder is the guest's, so the bytes differ
# from host to host while the two decodes of the same file must still agree.
do_bframes() {
    step "-bf 3 720p probe: B-frame reorder and the tail drain"
    have ffmpeg || { bad "ffmpeg is missing -- run: va.sh install-tools <name>"; return; }
    if [ ! -f bframes720.mp4 ]; then
        ffmpeg -nostdin -y -v error -f lavfi -i testsrc2=size=1280x720:rate=30 -t 5 \
            -c:v libx264 -bf 3 -g 30 -pix_fmt yuv420p bframes720.mp4 ||
            { bad "the -bf 3 encode failed"; return; }
    fi
    ls -l bframes720.mp4
    sw=$(set -o pipefail
         ffmpeg -nostdin -y -v verbose -i bframes720.mp4 -fps_mode passthrough \
            -f rawvideo -pix_fmt nv12 - 2> bframes_sw.log | md5sum | cut -d' ' -f1)
    swrc=$?
    swn=$(sed -n 's/.*frame= *\([0-9]\+\).*/\1/p' bframes_sw.log | tail -1); swn=${swn:-0}
    echo "software: rc=$swrc md5=$sw frames=$swn (want $BF_FRAMES)"
    [ "$swrc" = 0 ] || { bad "the software decode of the probe clip exited $swrc"; return; }
    [ "$swn" = "$BF_FRAMES" ] || bad "the probe clip is $swn frames, not $BF_FRAMES"
    va_decode_once bframes720.mp4 bframes_va.log
    echo "VA:       rc=$D_RC md5=$D_MD5 frames=$D_N sync-timeout=$D_T idle-drain=$D_I"
    if [ "$D_RC" -ge 128 ]; then
        bad "the VA decode died on a signal (D83's abort, not a wrong decode)"; return
    fi
    [ "$D_RC" = 0 ] || bad "the VA decode exited $D_RC (see $VA_DIR/bframes_va.log)"
    [ "$D_MD5" = "$sw" ] || bad "VA md5 $D_MD5 != this clip's own software md5 $sw"
    [ "$D_N" = "$swn" ] || bad "VA decoded $D_N frames, software decoded $swn"
    # A sync timeout is still a failure here: a client that waited past its budget got its frame
    # only because the codec was restarted under it.
    [ "$D_T" = 0 ] || bad "$D_T sync timeouts on the B-frame clip"
    # Exactly one idle drain, and it is the END OF STREAM -- VA-API has no EOS or flush call, so
    # the tail a B-frame stream leaves in the codec is released by nothing else. Zero would mean
    # the tail never came out (and the frame count would say so); two would mean the drain is
    # firing mid-stream, which D86 says the session does not survive twice.
    [ "$D_I" = 1 ] || bad "$D_I idle drains, expected exactly 1 (the B-frame tail at EOS)"
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
vainfo)         do_vainfo ;;
decode)         do_decode ;;
mpv)            do_mpv ;;
gst)            do_gst ;;
bframes)        do_bframes ;;
v4l2-still-ok)  do_v4l2_still_ok ;;
all)            do_vainfo; do_decode; do_mpv; do_gst; do_bframes; do_v4l2_still_ok ;;
esac

echo; echo "failures: $fail"
[ "$fail" = 0 ]
GUEST
} | "$SP/guest.sh" ssh "$NAME" \
      "VERB='$VERB' VA_DIR='$VA_DIR' REF_MD5='$REF_MD5' FRAMES='$FRAMES' \
       RUNS='$RUNS' BF_FRAMES='$BF_FRAMES' VA_TIMEOUT_RE='$VA_TIMEOUT_RE' \
       VA_IDLE_RE='$VA_IDLE_RE' VA_POOL_RE='$VA_POOL_RE' TOOLS='$TOOLS' bash -s"
rc=$?
echo
if [ "$rc" = 0 ]; then echo "va $VERB: PASS"; else echo "va $VERB: FAIL (rc=$rc)"; fi
exit "$rc"
