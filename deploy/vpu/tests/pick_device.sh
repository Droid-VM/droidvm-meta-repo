# shellcheck shell=bash
# Guest-side V4L2 device selection BY CAPABILITY, prepended to the remote script of every test
# in this directory (they pipe `cat pick_device.sh` and their own heredoc into one `bash -s`).
#
# Defect D8 (logs/vpu_wp/B2-acceptance.md §12): the smoke test used to pick its devices by card
# NAME -- `*loopback*` / `*simple_device*` -- while the launch line everyone actually uses is
# `--virtio-media kind=loopback,card=lb0`. Every byte-moving step therefore printed "skipped"
# and the run still said PASS. The card string is operator-chosen and means nothing; what the
# device IS shows up in its capability word, so match on that.
#
# The bits are V4L2's, from linux/videodev2.h:
V4L2_CAP_VIDEO_CAPTURE=0x00000001
V4L2_CAP_VIDEO_CAPTURE_MPLANE=0x00001000
V4L2_CAP_VIDEO_M2M_MPLANE=0x00004000
V4L2_CAP_VIDEO_M2M=0x00008000

# The capability word of one node, as the 0x... string v4l2-ctl prints. Prefer "Device Caps"
# (what this node can do) over "Capabilities" (what the whole driver can do); on a device that
# does not set V4L2_CAP_DEVICE_CAPS only the latter exists, so fall back to it.
dev_caps() {  # dev_caps /dev/videoN
    v4l2-ctl -d "$1" --info 2>/dev/null | awk '
        /Device Caps[[:space:]]*:/          { print $NF; found = 1; exit }
        /Capabilities[[:space:]]*:/ && !c   { c = $NF }
        END                                 { if (!found && c) print c }'
}

dev_card() {  # dev_card /dev/videoN -- for the log line only, never for the decision
    v4l2-ctl -d "$1" --info 2>/dev/null |
        sed -n 's/^[[:space:]]*Card type[[:space:]]*:[[:space:]]*//p'
}

# Sets $loop (first m2m device) and $simple (first capture-only device) from /dev/video*, and
# prints one line per node saying what it saw and what it decided. Both may end up empty -- the
# caller decides whether that is a skip or a failure (for the smoke test: a failure).
pick_devices() {
    loop=""; simple=""
    local dev caps c m2m capt kind
    for dev in /dev/video*; do
        [ -e "$dev" ] || continue
        caps=$(dev_caps "$dev")
        case "$caps" in
            0x*|0X*) ;;
            *) echo "  $dev: no capability word from 'v4l2-ctl --info' -- ignored"; continue ;;
        esac
        c=$((caps))
        m2m=$(( c & (V4L2_CAP_VIDEO_M2M_MPLANE | V4L2_CAP_VIDEO_M2M) ))
        capt=$(( c & (V4L2_CAP_VIDEO_CAPTURE | V4L2_CAP_VIDEO_CAPTURE_MPLANE) ))
        if [ "$m2m" != 0 ]; then
            kind="m2m (loopback-shaped)"
            [ -n "$loop" ] || loop=$dev
        elif [ "$capt" != 0 ]; then
            kind="capture-only (simple-shaped)"
            [ -n "$simple" ] || simple=$dev
        else
            kind="neither m2m nor capture -- ignored"
        fi
        echo "  $dev: caps $caps card '$(dev_card "$dev")' -> $kind"
    done
    echo "chosen: m2m=${loop:-<none>} capture=${simple:-<none>}"
}
