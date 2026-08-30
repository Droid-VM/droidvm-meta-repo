// Fullscreen direct present over VK_KHR_display: no compositor, no window system.
// Enumerates the guest's displays, takes the first mode, and clears+presents N frames.
//   gcc -O2 -o vkdisplay_test vkdisplay_test.c -lvulkan -lm && ./vkdisplay_test [frames]
#include <fcntl.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <vulkan/vulkan.h>

// Markers go out with write(2) -- no stdio buffer to lose when the VM (or the phone)
// dies mid-call. fd 1 reaches the ssh client on the dev host; the serial copy is a
// second chance in case the network path is the thing that broke.
static int mk_serial = -2;
static void mk(const char* fmt, ...) {
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf) - 2, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    buf[n++] = '\n';
    (void)!write(1, buf, (size_t)n);
    if (mk_serial == -2) mk_serial = open("/dev/ttyS0", O_WRONLY | O_NONBLOCK);
    if (mk_serial >= 0) (void)!write(mk_serial, buf, (size_t)n);
}

#define CHECK(x)                                                        \
    do {                                                                \
        VkResult _r = (x);                                              \
        if (_r != VK_SUCCESS) {                                         \
            fprintf(stderr, "%s failed: %d\n", #x, _r);                 \
            return 1;                                                   \
        }                                                               \
    } while (0)

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int stage_at_most(const char* want) {
    // VKD_STAGE=enum|surface|swapchain|present -- stop after that step, so a crash can be
    // attributed to one call instead of "somewhere in the present path".
    const char* s = getenv("VKD_STAGE");
    return s && !strcmp(s, want);
}

int main(int argc, char** argv) {
    const uint32_t frames = argc > 1 ? (uint32_t)atoi(argv[1]) : 600;

    const char* inst_exts[] = {VK_KHR_SURFACE_EXTENSION_NAME, VK_KHR_DISPLAY_EXTENSION_NAME};
    VkInstanceCreateInfo ici = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .enabledExtensionCount = 2,
        .ppEnabledExtensionNames = inst_exts,
    };
    VkInstance inst;
    CHECK(vkCreateInstance(&ici, NULL, &inst));

    uint32_t ndev = 1;
    VkPhysicalDevice pdev;
    CHECK(vkEnumeratePhysicalDevices(inst, &ndev, &pdev));
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(pdev, &props);
    printf("device: %s\n", props.deviceName);

    uint32_t ndisp = 0;
    CHECK(vkGetPhysicalDeviceDisplayPropertiesKHR(pdev, &ndisp, NULL));
    printf("displays: %u\n", ndisp);
    if (!ndisp) {
        fprintf(stderr, "no display -- is the card node free (stop the compositor) and readable?\n");
        return 1;
    }
    VkDisplayPropertiesKHR* disps = calloc(ndisp, sizeof(*disps));
    CHECK(vkGetPhysicalDeviceDisplayPropertiesKHR(pdev, &ndisp, disps));
    printf("  display 0: '%s' %ux%u\n", disps[0].displayName ? disps[0].displayName : "?",
           disps[0].physicalResolution.width, disps[0].physicalResolution.height);

    uint32_t nmode = 0;
    CHECK(vkGetDisplayModePropertiesKHR(pdev, disps[0].display, &nmode, NULL));
    VkDisplayModePropertiesKHR* modes = calloc(nmode, sizeof(*modes));
    CHECK(vkGetDisplayModePropertiesKHR(pdev, disps[0].display, &nmode, modes));
    VkExtent2D extent = modes[0].parameters.visibleRegion;
    printf("  mode 0: %ux%u @ %.2f Hz\n", extent.width, extent.height,
           modes[0].parameters.refreshRate / 1000.0);

    if (stage_at_most("enum")) {
        printf("stage=enum done\n");
        return 0;
    }

    VkDisplaySurfaceCreateInfoKHR sci = {
        .sType = VK_STRUCTURE_TYPE_DISPLAY_SURFACE_CREATE_INFO_KHR,
        .displayMode = modes[0].displayMode,
        .planeIndex = 0,
        .transform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR,
        .alphaMode = VK_DISPLAY_PLANE_ALPHA_OPAQUE_BIT_KHR,
        .imageExtent = extent,
    };
    VkSurfaceKHR surface;
    CHECK(vkCreateDisplayPlaneSurfaceKHR(inst, &sci, NULL, &surface));

    printf("display surface created\n");
    fflush(stdout);
    if (stage_at_most("surface")) {
        printf("stage=surface done\n");
        return 0;
    }

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueCount = 1,
        .pQueuePriorities = &prio,
    };
    const char* dev_exts[] = {VK_KHR_SWAPCHAIN_EXTENSION_NAME};
    VkDeviceCreateInfo dci = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &qci,
        .enabledExtensionCount = 1,
        .ppEnabledExtensionNames = dev_exts,
    };
    VkDevice dev;
    CHECK(vkCreateDevice(pdev, &dci, NULL, &dev));
    VkQueue queue;
    vkGetDeviceQueue(dev, 0, 0, &queue);

    VkSurfaceCapabilitiesKHR caps;
    CHECK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(pdev, surface, &caps));
    uint32_t nfmt = 0;
    CHECK(vkGetPhysicalDeviceSurfaceFormatsKHR(pdev, surface, &nfmt, NULL));
    VkSurfaceFormatKHR* fmts = calloc(nfmt, sizeof(*fmts));
    CHECK(vkGetPhysicalDeviceSurfaceFormatsKHR(pdev, surface, &nfmt, fmts));

    VkSwapchainCreateInfoKHR swci = {
        .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = surface,
        .minImageCount = caps.minImageCount < 3 ? 3 : caps.minImageCount,
        .imageFormat = fmts[0].format,
        .imageColorSpace = fmts[0].colorSpace,
        .imageExtent = extent,
        .imageArrayLayers = 1,
        .imageUsage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .preTransform = caps.currentTransform,
        .compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = VK_PRESENT_MODE_FIFO_KHR,
        .clipped = VK_TRUE,
    };
    VkSwapchainKHR swapchain;
    CHECK(vkCreateSwapchainKHR(dev, &swci, NULL, &swapchain));

    uint32_t nimg = 0;
    CHECK(vkGetSwapchainImagesKHR(dev, swapchain, &nimg, NULL));
    VkImage* images = calloc(nimg, sizeof(*images));
    CHECK(vkGetSwapchainImagesKHR(dev, swapchain, &nimg, images));
    printf("swapchain: %u images, format %d, %ux%u\n", nimg, fmts[0].format, extent.width,
           extent.height);

    fflush(stdout);
    if (stage_at_most("swapchain")) {
        printf("stage=swapchain done\n");
        return 0;
    }

    VkCommandPool pool;
    VkCommandPoolCreateInfo pci = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
    };
    CHECK(vkCreateCommandPool(dev, &pci, NULL, &pool));
    VkCommandBuffer cmd;
    VkCommandBufferAllocateInfo cbai = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    CHECK(vkAllocateCommandBuffers(dev, &cbai, &cmd));

    VkSemaphoreCreateInfo semci = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    VkSemaphore acquired, rendered;
    CHECK(vkCreateSemaphore(dev, &semci, NULL, &acquired));
    CHECK(vkCreateSemaphore(dev, &semci, NULL, &rendered));
    VkFenceCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    VkFence fence;
    CHECK(vkCreateFence(dev, &fci, NULL, &fence));

    mk("MK loop.enter frames=%u", frames);
    double start = now_s();
    for (uint32_t f = 0; f < frames; f++) {
        uint32_t idx;
        mk("MK f=%u acquire.begin", f);
        CHECK(vkAcquireNextImageKHR(dev, swapchain, UINT64_MAX, acquired, VK_NULL_HANDLE, &idx));
        mk("MK f=%u acquire.ok idx=%u", f, idx);

        VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
        CHECK(vkBeginCommandBuffer(cmd, &bi));
        VkImageSubresourceRange range = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        VkImageMemoryBarrier to_dst = {
            .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image = images[idx],
            .subresourceRange = range,
            .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        };
        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                             VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &to_dst);
        float t = (float)f / 60.0f;
        VkClearColorValue color = {
            .float32 = {0.5f + 0.5f * sinf(t), 0.3f, 0.5f + 0.5f * cosf(t), 1.0f}};
        vkCmdClearColorImage(cmd, images[idx], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &color, 1,
                             &range);
        VkImageMemoryBarrier to_present = to_dst;
        to_present.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        to_present.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        to_present.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        to_present.dstAccessMask = 0;
        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT,
                             VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, NULL, 0, NULL, 1,
                             &to_present);
        CHECK(vkEndCommandBuffer(cmd));

        VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_TRANSFER_BIT;
        VkSubmitInfo si = {
            .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &acquired,
            .pWaitDstStageMask = &wait_stage,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &rendered,
        };
        mk("MK f=%u submit.begin", f);
        CHECK(vkQueueSubmit(queue, 1, &si, fence));
        mk("MK f=%u submit.ok", f);

        // Render without ever presenting: separates "the GPU work on a swapchain image"
        // from "the page flip that puts it on the CRTC".
        if (stage_at_most("submit")) {
            VkResult sr = vkWaitForFences(dev, 1, &fence, VK_TRUE, 5000000000ull);
            mk("MK f=%u submit_only.fence.rc=%d", f, sr);
            if (sr != VK_SUCCESS) return 2;
            CHECK(vkResetFences(dev, 1, &fence));
            continue;
        }

        VkPresentInfoKHR pi = {
            .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &rendered,
            .swapchainCount = 1,
            .pSwapchains = &swapchain,
            .pImageIndices = &idx,
        };
        mk("MK f=%u present.begin idx=%u", f, idx);
        CHECK(vkQueuePresentKHR(queue, &pi));
        mk("MK f=%u present.ok", f);
        // A bounded wait: UINT64_MAX here would hang the run instead of reporting a
        // present that never completes.
        VkResult fr = vkWaitForFences(dev, 1, &fence, VK_TRUE, 5000000000ull);
        mk("MK f=%u fence.rc=%d", f, fr);
        if (fr != VK_SUCCESS) {
            mk("MK f=%u fence.TIMEOUT -- giving up", f);
            return 2;
        }
        CHECK(vkResetFences(dev, 1, &fence));
        mk("MK f=%u frame.done", f);
        if (getenv("VKD_FRAME_SLEEP_MS")) usleep(atoi(getenv("VKD_FRAME_SLEEP_MS")) * 1000);
    }
    double elapsed = now_s() - start;
    printf("presented %u frames in %.2f s -> %.1f FPS\n", frames, elapsed, frames / elapsed);

    vkDeviceWaitIdle(dev);
    vkDestroySwapchainKHR(dev, swapchain, NULL);
    vkDestroyDevice(dev, NULL);
    vkDestroySurfaceKHR(inst, surface, NULL);
    vkDestroyInstance(inst, NULL);
    return 0;
}
