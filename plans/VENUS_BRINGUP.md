# venus bring-up 工作狀態(2026-08-11 開工)

survey 見 `plans/VENUS_SURVEY.md`。此檔是實作進度錨點(session 換手先讀這裡)。

## 使用者定調
- 先做 **guest-alloc**;測試配置 `--mem 3072`、`gpu_guest` 池 1.5G、`venus_host` 池 16M(不夠再加)。
- runtime-share 不穩=demo only;正式路線 pre-alloc 池。
- **host Vulkan 一律 turnip**(app 打包的 `/data/data/cn.classfun.droidvm/usr/lib/libvulkan_freedreno.so`,
  `ANDROID_EMU_VK_LOADER_PATH` 指路;它是 Android Vulkan HAL,只 export `HMI`,要走 hwvulkan
  bridge——參考 gfxstream `host/vulkan/VulkanDispatch.cpp`)。不用系統 QC driver。
- variant 不同時裝:venus 驗收=乾淨 Ubuntu + `droidvm-guest-additions` deb + `mesa-guest-venus` deb
  就能動;**不准動搖 gfxstream/drm2kgsl variant**。

## 關鍵事實(本輪查證)
1. **wire format 不配**:guest mesa 26.0.3 vn = wire 1 / vk.xml 1.4.334;fork virglrenderer(0.10.4 era)
   vkr = wire 0 / 1.3.228。guest 只硬擋 `wire_format_version==0`(mesa 3d3ca9b65e2,防 capset 全零),
   但編碼快照差 3 年,不賭 framing——**決策:vendor upstream venus 到 fork**。
2. vendor 來源:`/root/gitrs/DroidVM/DroidVM_3d_accel/virglrenderer-upstream` = **upstream 1.3.0
   (2026-07-06, dc35e4d)**,venus wire 1 / vk.xml 1.4.343。src/venus 檔案集比 fork 多
   vkr_acceleration_structure / vkr_descriptor_heap / vkr_host_copy / vkr_library 等。
3. **upstream 1.3 拿掉了 in-process venus**:virglrenderer.c 的 VENUS capset 只走 proxy(render
   server)。新 API = `vkr_renderer_*(ctx_id,…)` 9 函式(vkr_renderer.h;vkr_renderer.c 242 行
   thin wrapper,vkr 自帶 context table):init(flags,cbs{debug_logger,retire_fence})/fini、
   create/destroy_context、submit_cmd、submit_fence、create_resource(→fd+map_info+vulkan_info)、
   **import_resource(ctx_id,res_id,fd_type,fd,size)**(guest-alloc udmabuf 的進門)、destroy_resource。
   **決策:自寫 in-process `virgl_context` 轉接層**(仿 upstream `src/server/render_context.c`
   的呼叫序,單行程,不用 render server,避開 SELinux/打包/多行程 debug)。
4. host turnip advertise dma_buf import/export(5_prepare_turnip.sh 註解:QC blob AHB-only
   supportsDmaBuf=0 → 這正是當初 gfxstream 也要 turnip 的原因)。之前 `cmd gpu vkjson` 量的是
   QC driver,作廢(scratchpad/vkjson.txt 留檔但別引用)。
5. meta repo 架構:元件實體在 `crosvm_build/`(repo manifest),root 是 symlink;branch chain
   `wip/3d-accel-<variant>→wip/3d-accel`;`2-1_collect_crosvm.sh` 收 crosvm+NEEDED .so →
   `crosvm_out/`;guest mesa 走 `mesa-variants.sh` variant 系統(venus 要成為第三 variant,
   deb 雙向 Conflicts);guest additions 是 DKMS source deb(guest 上編);`lib_dist.sh` 出貨
   `dist-guest/`+MD5SUMS。

## 已完成(virglrenderer fork,均未 commit)
- `Android.bp`:vkr srcs(**0.10.4 檔案集,vendor 後要換成 1.3 檔案集**)+
  `prebuilt-intermediates/venus` include(codegen 產物,**vendor 後要用 upstream 的
  vkr_device_object.py 重跑**);`libvulkan` link 已按 turnip 決策移除。
- `prebuilt-intermediates/config.h`:`ENABLE_VENUS 1`。
- `src/venus/vkr_renderer.c`(舊):capset `supports_blob_id_0=true` + `use_guest_vram=true`
  ——**vendor 會蓋掉,要重施到新 vkr 的 capset 函式**(upstream `vkr_get_capset(capset, flags)`
  有 flags 參數了)。
- `src/venus/vkr_physical_device.c`:gbm `exit(-1)` → graceful(**vendor 後重施**;
  QC dma_buf assume patch 已 revert,turnip 不需要)。
- `src/venus/vkr_vulkan_shim.c`(fork 自有檔,vendor 不覆蓋):提供 vkr link-time 直呼的全部
  vk* 符號,dlopen `ANDROID_EMU_VK_LOADER_PATH` → dlsym gipa → 不行走 HMI hwvulkan bridge
  (struct 逐字抄 gfxstream VulkanDispatch.cpp,含 hw_device 的 close 欄位)→
  vkCreateInstance 成功後 eager resolve 全表。**注意:vendor 後要按新 vkr 的直呼符號集重新
  grep 校對一次**(`grep -hoE 'vk[A-Z][A-Za-z0-9]*\(' src/venus/*.c`)。

## 2026-08-11 進度更新(vendor 已完成,兩個 build 背景跑)

實際做法與原計畫的差異(都已落地):

1. **vendor 完成**:upstream 1.3.0 `src/venus/`(含 venus-protocol、vkr_device_object codegen
   重跑進 `prebuilt-intermediates/venus/`)+ `src/venus_hw.h` 整包換入 fork。fork core 其實是
   1.x 世代(meson 版號 0.10.4 是舊字串),漂移極小。
2. **免 capset 補丁**:upstream 1.3 已內建 `supports_blob_id_0=true` 與
   `use_guest_vram = flags & VIRGL_RENDERER_USE_GUEST_VRAM`(flag 1<<14,已加進 fork
   virglrenderer.h);gbm 移到 `ENABLE_GBM_ALLOCATION`(不定義=無 exit(-1) 路徑)。
3. **免 vulkan shim**:upstream 1.3 vkr 全面走 `vulkan_library` dlopen(`ENABLE_VULKAN_DLOAD`,
   proc table 吃 get_proc_addr 參數,零 link-time vk 符號)。改為 patch
   `vkr_library.c::vkr_library_load`:`ANDROID_EMU_VK_LOADER_PATH` 優先 → dlsym gipa →
   `vk_icdGetInstanceProcAddr` → HMI hwvulkan bridge(struct 逐字抄 gfxstream),成功後
   process-lifetime cache(unload 對 cache handle 不 dlclose,防 gipa dangle)。
   原 vkr_vulkan_shim.c 已刪。
4. **in-process 轉接層** `src/venus/vkr_virgl_adapter.{c,h}` 完成:virgl_context vfuncs ↔
   `vkr_renderer_*`;known_res 集合讓 attach/detach 冪等;`set_guest_blob_fd` 單 slot park
   (抄 drm2kgsl 契約),**get_blob 消化 parked fd**:`vkr_renderer_import_resource(DMABUF)`
   進 vkr + 原 fd 回給 core 當 blob(map_info=CACHED);fence 經全域 retire cb →
   `virgl_context::fence_retire`;reset=fini+re-init。virglrenderer.c 六個 VENUS 站點改接
   adapter(proxy 分支保留)。
5. **core additive**:`virgl_resource_vulkan_info` struct + `virgl_context_blob.vulkan_info` +
   `struct virgl_resource.vulkan_info`(virglrenderer.c blob→res 填入)+ Android.bp
   `src/drm/drm-uapi` include(vendored uapi 供 VIRTGPU_DRM_CAPSET_*)。
6. **mesa vn 補丁改形**(重要):guest_vram 模式不發 BLOB_MEM_GUEST,改
   **`HOST3D_GUEST` + `CREATE_GUEST_HANDLE`(0x8)**——kernel 照樣進池(guest_blob 分支)、
   crosvm 照樣 create_udmabuf+park、且 has_host_storage=true 使資源**經過 ctx->get_blob**
   (adapter 消化點);re-import 的 blob_mem 檢查自動一致,不用放寬。落點
   mesa-venus worktree(新分支 `wip/3d-accel-venus`,基於 gfxstream 26.0.3 線):
   `vn_renderer_virtgpu.c` init_renderer_info 變體 B 分支 bo_blob_mem=HOST3D_GUEST +
   bo_create_guest_handle → blob_flags。shmem 不動(HOST3D blob_id=0)。
7. **variant 系統**:mesa-variants.sh(branch/meson=`-Dvulkan-drivers=virtio`/icd=
   `virtio_icd.aarch64.json`/siblings 四處)+ lib_mesa_build case + lib_dist 報告 +
   `8_build_guest_mesa_venus.sh`;打包層(mesa-cross/package.sh)全 generic 免改。
8. **guest kernel 一行已下**:virtgpu_kms.c find_pool_base 前綴鏈加 `venus_host`(第三位)。
9. 所有 vkr/core/drm2kgsl 檔案過 gcc syntax sweep;AOSP build(build_venus_r1.log)與
   mesa venus deb build(build_mesa_venus_r1.log)在背景。
10. **HAVE_LINUX_UDMABUF_H 刻意不定義**:vkr 1.3 會用 /dev/udmabuf 做 force_udmabuf_import
    (host anon 頁,pVM 下不可 share)——guest_vram 路線用不到,先關閉減少面。

11. **build r1 過 + 符號驗證**:`crosvm_out/libvirglrenderer.so` 含 "venus adapter"×7、
    HMI bridge、ANDROID_EMU_VK_LOADER_PATH(grep -ac)。
12. **guest 兩顆 deb 建成**:`mesa-guest-venus_26.0.3...deb`(libvulkan_virtio.so +
    virtio_icd.aarch64.json + zink;dirty 後綴=vn 補丁未 commit)、
    `droidvm-guest-additions r24+dirty`(venus_host 前綴)。dist-guest 四包齊。
13. **crosvm VenusPool 全下**(build r2 驗證中):rutabaga `use_guest_vram` flag(1<<14,
    venus capset 即開)、`--pre-alloc venus-host-mb=` + `MemoryRegionPurpose::VenusPool` +
    region 建立(注意 drm 塊不推 pool_top,venus 塊從 last region 鏈)+ bless(gunyah
    mod/aarch64、geniezone)+ host-access check + env(VENUS_POOL_FD/_FD_OFFSET/_HOST_VA/
    _GPA/_SIZE)+ FDT `venus_host` 節點(fdt.rs 參數插在 gpu_guest_resv 後,call site 同位)。
14. **devvm.sh venus 模式**(本 session scratchpad,含前 session 全套工具):`VENUS=1` →
    --mem 3072、--pre-alloc gpu-guest-mb=1536,venus-host-mb=16、
    --gpu virglrenderer,context-types=venus,...,udmabuf=true,external-blob=true;
    POOL_NEED_PAGES 連動配置。

尚未做:venus_host pool merge(task 3;bring-up 先讓 ring 走 runtime-share+accept——
**已知風險**:venus 無 folio prepare callback,CS 8MB chunk 的 SHARE 是 4K-backed,若撞
RM constituent 上限,解法=resource_map_blob 對 virgl 組件 memfd 泛用呼叫
prepare_blob_backing)、各 repo commit(等 build r2 綠)、部署+bring-up(task 7)。

## 下一步(依序)
1. **Vendor**:cp upstream `src/venus/`(整包含 venus-protocol)+ `venus_hw.h` → fork;
   include 路徑適配(upstream 是 src/util/、src/vrend/ 佈局:`../vrend/vrend_winsys_gbm.h`→
   `vrend_winsys_gbm.h`;確認 fork src/mesa/util 有 xxhash.h/macros.h/list.h,缺的從 upstream
   src/util 補);重跑 codegen;Android.bp 檔案清單換新(含 vkr_renderer.c wrapper,不含 proxy)。
2. **fork core 增補(additive,不動既有路線)**:`virgl_resource.h` 加
   `struct virgl_resource_vulkan_info`;`virgl_context_blob` 加 `vulkan_info` 欄位
   (保留 fork 的 map_ptr/fd_offset/opaque_fd_metadata);virgl_log/虛擬 log callback 對接
   (upstream 用 virgl_log_callback_type)。
3. **轉接層** `src/venus/vkr_virgl_adapter.c`(fork 自有):struct virgl_context vfuncs ↔
   vkr_renderer_*;attach_resource → export_fd → import_resource(iovec-only 資源直接拒絕+log);
   get_blob → create_resource;fence 經 cbs.retire_fence(ctx_id,…) 回 fork 的
   per-context fence_retire;submit_fence flags/ring_idx 轉發;destroy 順序注意 res/ctx 生命週期。
   fork virglrenderer.c 的 VENUS capset 分支:`vkr_renderer_init(flags,cbs)` + capset/`context_create`
   接轉接層(不走 proxy_*)。
4. **重施小補丁**到新 vkr:supports_blob_id_0=true(upstream 1.3 大概已無 RENDER_SERVER flag 綁定,
   確認)、use_guest_vram=true、gbm graceful、shim 符號集校對。
5. build(`2_build_crosvm.sh`)→ 修編譯 → `grep -ac` 驗符號進 `crosvm_out`(libvirglrenderer.so)。
6. 之後才是 crosvm venus_host 池(task 4)/guest kernel 一行(task 5)/mesa venus variant(task 6)。

## 踩坑備忘(本輪)
- 中途 build 時別改 tree(debugloop 3.1);每步驗證 edit 落地(grep 新字串)。
- upstream `vkr_get_capset` 多了 flags 參數;`VKR_RENDERER_RENDER_SERVER` flag 已消失。
- venus_hw.h 是 guest/host 共用 ABI:vendor 的版本要與 mesa 26.0.3 的
  `src/virtio/virtio-gpu/venus_hw.h` 對齊(use_guest_vram 欄位 offset)。
- `vkr_renderer_init` 的 `debug_logger` 型別是 `virgl_log_callback_type`(upstream virglrenderer.h
  的新東西,fork 的 virglrenderer.h 可能沒有——additive 補)。
