/* ext_ctrls_error_idx -- read error_idx out of the caller's own struct v4l2_ext_controls,
 * from C, on the refusal paths B9 section 8 measured through ctl.py. No Python in the way.
 *
 * This is the client that closed defect D37. V4L2 says a failed VIDIOC_G/S/TRY_EXT_CTRLS
 * writes the v4l2_ext_controls header back with error_idx set to "the index of the control
 * causing the error"; through the guest tool ctl.py that value came back 0 on every refusal,
 * which looked like the fork device or the guest driver losing it. It is neither: CPython's
 * fcntl.ioctl copies its mutable argument back only when the ioctl returns >= 0, so a Python
 * client can never see error_idx on the path where V4L2 sets it. Run from C instead and the
 * device's value arrives -- measured 7 refusals out of 7 on the phone, including the decisive
 * TRY_EXT_CTRLS the camera fails at index 1 (logs/vpu_wp/B10-acceptance.md section 7).
 *
 * Build and run in the guest (the ids below are the camera device's):
 *
 *     deploy/vpu/guest.sh scp <vm> deploy/vpu/tests/ext_ctrls_error_idx.c :/root/
 *     deploy/vpu/guest.sh ssh <vm> 'cc -O1 -o /root/eei /root/ext_ctrls_error_idx.c && \
 *                                   /root/eei /dev/video0'
 *
 * Expect: cases 1, 2, 4, 8 report error_idx = count (2, 1, 2, 2), case 3 reports 0, case 6
 * succeeds with error_idx = count = 1, and case 7 -- the one that settles it -- reports 1.
 * Any of those coming back 0 from C is a real device or driver defect; the same reading 0
 * from ctl.py is not (see the warning in that tool's header).
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/videodev2.h>

static const char *nm(unsigned long r) {
    if (r == VIDIOC_S_EXT_CTRLS) return "S_EXT_CTRLS";
    if (r == VIDIOC_TRY_EXT_CTRLS) return "TRY_EXT_CTRLS";
    return "G_EXT_CTRLS";
}

static void run(int fd, unsigned long req, const char *label, unsigned which,
                unsigned n, const unsigned *ids, const int *vals)
{
    struct v4l2_ext_control c[4];
    struct v4l2_ext_controls ec;
    memset(c, 0, sizeof(c));
    memset(&ec, 0, sizeof(ec));
    for (unsigned i = 0; i < n; i++) { c[i].id = ids[i]; c[i].value = vals[i]; c[i].size = 0; }
    ec.which = which;
    ec.count = n;
    ec.error_idx = 0;              /* the sentinel B9 used: the guest wrote 0 */
    ec.controls = c;
    int r = ioctl(fd, req, &ec);
    int e = errno;
    printf("%-58s %-14s count=%u -> %-7s errno=%-3d error_idx=%u\n",
           label, nm(req), n, r == 0 ? "OK" : "FAIL", r == 0 ? 0 : e, ec.error_idx);
}

int main(int argc, char **argv)
{
    const char *dev = argc > 1 ? argv[1] : "/dev/video0";
    int fd = open(dev, O_RDWR | O_NONBLOCK);
    if (fd < 0) { perror("open"); return 1; }
    /* the ids B9 section 8 used */
    const unsigned zoom = 0x009a090d;         /* V4L2_CID_ZOOM_ABSOLUTE */
    const unsigned ae_state = 0x00981b01;    /* the read-only control B9 used */
    const unsigned unknown = 0x00981bff;
    const unsigned bias = 0x009a0913;       /* auto_exposure_bias */
    unsigned ids[4]; int vals[4];

    /* 1: S_EXT_CTRLS zoom=150 + a read-only control at index 1 */
    ids[0] = zoom; vals[0] = 150; ids[1] = ae_state; vals[1] = 3;
    run(fd, VIDIOC_S_EXT_CTRLS, "1 S zoom=150, read-only at idx1 (device says error_idx=count)",
        V4L2_CTRL_WHICH_CUR_VAL, 2, ids, vals);
    /* 2: S_EXT_CTRLS zoom out of range */
    ids[0] = zoom; vals[0] = 5000;
    run(fd, VIDIOC_S_EXT_CTRLS, "2 S zoom=5000 (out of range)",
        V4L2_CTRL_WHICH_CUR_VAL, 1, ids, vals);
    /* 3: TRY zoom out of range */
    run(fd, VIDIOC_TRY_EXT_CTRLS, "3 TRY zoom=5000 (out of range)",
        V4L2_CTRL_WHICH_CUR_VAL, 1, ids, vals);
    /* 4: G_EXT_CTRLS with an unknown id at index 1 */
    ids[0] = zoom; vals[0] = 0; ids[1] = unknown; vals[1] = 0;
    run(fd, VIDIOC_G_EXT_CTRLS, "4 G zoom + unknown id at idx1",
        V4L2_CTRL_WHICH_CUR_VAL, 2, ids, vals);
    /* 6: a valid set (the success control) */
    ids[0] = zoom; vals[0] = 100;
    run(fd, VIDIOC_S_EXT_CTRLS, "6 S zoom=100 (valid: device sets error_idx=count)",
        V4L2_CTRL_WHICH_CUR_VAL, 1, ids, vals);
    /* 7: TRY zoom=150 + a bad value at index 1  -- the decisive case */
    ids[0] = zoom; vals[0] = 150; ids[1] = bias; vals[1] = 99999;
    run(fd, VIDIOC_TRY_EXT_CTRLS, "7 TRY zoom=150, auto_exposure_bias=99999 at idx1 (device: 1)",
        V4L2_CTRL_WHICH_CUR_VAL, 2, ids, vals);
    /* 8: a bad `which` */
    ids[0] = zoom; vals[0] = 0; ids[1] = zoom; vals[1] = 0;
    run(fd, VIDIOC_G_EXT_CTRLS, "8 G which=0x00ff0000, two items", 0x00ff0000, 2, ids, vals);
    close(fd);
    return 0;
}
