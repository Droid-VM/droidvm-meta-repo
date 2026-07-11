# Guest mesa (gfxstream_vk ICD + zink) — DroidVM 3d-accel snapshot

Canonical full tree: **Crosvm-Android/mesa @ 3d-accel** (branch committed
locally; not pushable by this org — snapshot the load-bearing files here).
Build in the `mesa-arm64` docker container:

    docker start mesa-arm64
    docker exec mesa-arm64 ninja -C /src/mesa/build-guest \
        src/gfxstream/guest/vulkan/libvulkan_gfxstream.so \
        src/gallium/targets/dri/libgallium-26.0.3.so
    # deploy both to guest /usr/local/lib/aarch64-linux-gnu/ ; then `sync`

This produces BOTH the gfxstream_vk ICD and gallium/zink from one tree.
(The on-guest /root/mesa-build/mesa-26.0.3 tree is a vulkan-only trap — do
not build the guest GL stack there; see droidvm-guest-canonical-tree memory.)

## Load-bearing changes over stock mesa-26.0.3 (this dir)

- `src/gfxstream/guest/vulkan_enc/ResourceTracker.{cpp,h}`:
  - device-extension allowlist adds VK_KHR_16bit_storage (llama.cpp/ggml),
    VK_EXT_robustness2 (zink nullDescriptor), VK_KHR_push_descriptor +
    VK_EXT_multi_draw (Minecraft official Vulkan).
  - on_vkGetPhysicalDeviceFeatures2 answers Robustness2 features TRUE (the
    generated encoder cannot marshal the struct; the host force-enables the
    real feature at createDevice — see gfxstream host VulkanRobustness).
  - template descriptor update path null-guards VK_NULL_HANDLE buffers.
  - push-descriptor-with-template unrolled guest-side into typed writes.
- `src/gfxstream/guest/vulkan/gfxstream_vk_cmd.cpp`: typed push emit.
- `src/gfxstream/codegen/scripts/cereal/functable.py`: codegen for the above.
