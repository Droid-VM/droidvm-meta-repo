# Guest mesa 26.0.3 patched files (nctx)

整檔快照自 guest /root/mesa-build/mesa-26.0.3(該樹無 git)。包含:
- tu_knl_drm_virtio.cc:per-context VA slice 覆寫(GET_PARAM 優先於 capset)
  + TU_NO_VA_REUSE 診斷閘(zombie stage-2 跳過 heap free)
- drm/virtio/*:gallium 同款 slice 覆寫 + arena v2 guest 實作
  (注意:turnip 不走這層——zink 桌面的 arena 需另移植到 tu_knl,見 ARENA_V2_PLAN.md)
- common/msm_proto.h:arena v2 run-list 協議擴充(與 host vendored 同步)

重建:ninja -C builddir-nctx src/freedreno/vulkan/libvulkan_freedreno.so
部署:cp → /opt/turnip-nctx/libvulkan_freedreno.so(ICD 指拷貝)
