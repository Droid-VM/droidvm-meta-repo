/* Read the guest-alloc pool figures the driver now reports, straight off the render node.
 * Standalone rather than wired into mesa yet: it proves the ioctl works before anything
 * depends on it, and it is the tool to check the numbers against later. */
#include <stdio.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sys/ioctl.h>
#include <drm/drm.h>

struct getparam { uint64_t param; uint64_t value; };
#define DRM_VIRTGPU_GETPARAM 0x03
#define IOCTL_GETPARAM \
    DRM_IOWR(DRM_COMMAND_BASE + DRM_VIRTGPU_GETPARAM, struct getparam)

#define P_TOTAL 0x1000
#define P_USED  0x1001
#define P_LARGEST 0x1002
#define P_GUEST_HANDLE 10

static int q(int fd, uint64_t id, int *out) {
    struct getparam p = { .param = id, .value = (uint64_t)(uintptr_t)out };
    *out = -1;
    return ioctl(fd, IOCTL_GETPARAM, &p);
}

int main(int argc, char **argv) {
    const char *dev = argc > 1 ? argv[1] : "/dev/dri/renderD128";
    int fd = open(dev, O_RDWR);
    if (fd < 0) { perror("open"); return 1; }
    int gh = 0, total = 0, used = 0, largest = 0;
    if (q(fd, P_GUEST_HANDLE, &gh))    printf("CREATE_GUEST_HANDLE: unsupported\n");
    else                               printf("CREATE_GUEST_HANDLE: %d\n", gh);
    if (q(fd, P_TOTAL, &total) || q(fd, P_USED, &used) || q(fd, P_LARGEST, &largest)) {
        printf("pool params: unsupported by this kernel module\n");
        close(fd); return 2;
    }
    printf("guest-alloc pool: total=%d KiB (%.1f MiB)  used=%d KiB (%.1f MiB)  largest-free=%d KiB (%.1f MiB)\n",
           total, total / 1024.0, used, used / 1024.0, largest, largest / 1024.0);
    if (total == 0) printf("  (no gpu_guest_reserved node -> guest-alloc pool not configured)\n");
    else printf("  fragmentation: %.1f%% of free space is outside the largest run\n",
                (total - used) ? 100.0 * ((total - used) - largest) / (total - used) : 0.0);
    close(fd);
    return 0;
}
