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
2. vendor 來源:`/root/Documents/DroidVM_3d_accel/virglrenderer-upstream` = **upstream 1.3.0
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

## bring-up 戰況(2026-08-11 深夜)

**已點亮**:vulkaninfo 回報 `Virtio-GPU Venus (Adreno 830)`;kwin 全鏈 zink→venus 起得來;
guest-alloc blob 管線實測通(VENUS-DIAG:park fd→get_blob flags=0x9/0xf 成對,kwin 的
3686400 colorbuffer 帶 CREATE_GUEST_HANDLE);兩池就位;wire format 1 正確;
`--gpu virglrenderer,context-types=virgl2:venus`(**venus 單獨列會 NO_VIRGL → 2D scanout
資源建不出來**,fbcon/EDK2 全黑+ErrInvalidResourceId 風暴——已加 virgl2)。

**已修的三個 vkr in-process teardown 炸點**(kwin session 結束→FORTIFY abort→VMM 死;
詳見 memory `vkr-ring-monitor-teardown-crash`):ring_monitor 先停(vkr_context.c)、
`dev->object_mutex` 的 mtx_destroy 移到 objects/queues 清理後(vkr_device.c;bionic FORTIFY
才抓得到的上游確定性 bug)、config.h 定義 `ENABLE_RENDER_SERVER_WORKER_THREAD`
(on_worker_thread=true → teardown 真清理:DeviceWaitIdle+VK 物件 destroy+DestroyDevice)。
monitor 修驗證過(sddm restart 存活);後兩修在 build r9。

**【已破,桌面出圖 2026-08-11 15:16】**:KDE splash/桌面經 venus 全鏈渲染出圖,
fence 15→2028。解鎖組合=guest `/etc/environment.d/99-zink-debug.conf` 設
`MESA_SHADER_CACHE_DISABLE=true` + `ZINK_DEBUG=nobgc,nopc,noopt`(哪個是關鍵待二分;
根因=zink 的 `prog->base.cache_fence` 等待與 disk-cache/precompile job 的死鎖,headless venus
submit+fence 實測健康、vkcube 卡只是等 kwin 的 wayland 回應=二次受害)。
**環境變數傳遞的坑(花了整晚)**:`systemctl restart sddm` **不會重啟既存 wayland session**
(user@1000 持有;只有 `loginctl terminate-user` 會)——中間好幾輪「重啟後仍黑」其實都在看
15:03 那個卡死的舊 kwin;kwin 的 env 來源是 user-manager 的 **environment.d**
(`/usr/lib/environment.d/50-mesa-guest.conf` = mesa deb 的 zink override 同路),
per-unit drop-in/user.conf.d/etc-environment 都不可靠。workaround 若要進驗收,
寫進 mesa-guest-venus deb 的 environment.d 檔。

**【2026-08-12 全破:桌面+vkmark 都通,零 workaround】** 兩個互相糾纏的真根因,都已修+commit:
1. **vn ring mutex 重入自鎖**(mesa-venus **958d64bb23f**):`vn_ring_cs_upload_locked`
   持鎖下,guest_vram 的新 upload chunk 觸發 roundtrip → `vn_async_vkWaitVirtqueueSeqnoMESA`
   → `vn_ring_submit_command` → 同鎖重入。kwin 首個大 shader 上傳必踩(=黑畫面);
   vkmark texture 踩(=present 卡+swapchain fence 拖死 kwin)。修=`vn_ring_roundtrip_locked`。
   zink 的 SHADER_CACHE/nobgc workaround 只是繞開觸發點,**全部移除仍正常**。
2. **crosvm per-ring fence 路由**(crosvm **b7069c454**):virgl `create_fence` 一律呼全域
   `virgl_renderer_create_fence`(vrend GL timeline)→ RING_IDX fence 永不 signal;
   改路由到 `virgl_renderer_context_create_fence`。
驗證:桌面無 workaround 出圖、**vkmark 435**(vertex 451/texture 461/shading 395 @800x600,
DVFS 未鎖)、fence 3.3 萬順跑、session restart 存活(teardown 三修 virglrenderer ecc56c8)。
**MC 也過了(2026-08-12 16:29 guest 時間)**:mclaunch.py 26.2 → 主選單 → 進世界,
世界渲染零錯誤(天空/海洋/植被/手持物),log 直證 `zink Vulkan 1.4 (Virtio-GPU Venus
(Adreno 830) MESA_TURNIP)`。坑:GLFW 要 XAUTHORITY(從 kwin cmdline 抓 xauth_ 路徑),
authlib 401 是離線帳號噪音。**dev 碟三關全過、零 workaround。**

**正式驗收(2026-08-12 凌晨,overlay=venus-acceptance.qcow2,golden=acceptance-gfx-clean2)
=2/3 關過**:兩顆 deb 安裝完美(md5→Conflicts 自動移除 gfxstream→DKMS 編譯→initramfs 自動
更新,零手工)→ 重啟後桌面出圖(r25 模組生效、venus_host 探測)✓、**vkmark 457**(未手動指
ICD,deb 環境接線自證)✓;**MC 三連崩在 `zink_kopper_acquire_submit+0x1c`(SEGV_MAPERR,
gallium tc thread,zink_draw→zink_batch_rp 路)**——驗收碟穩定重現、XWayland 冷熱無關、
options.txt 正常;**dev 碟同 deb 同 host 卻能進世界**(差異未定位:golden 的 MC 首次啟動
狀態?)。下一步:hs_err 寄存器+gdb core 分析 kopper NULL 來源(swapchain 建立失敗未 bail?)、
dev/golden MC 差異二分、或 mesa 上游 kopper 修 cherry-pick。

**MC kopper crash 定位+繞過(2026-08-12):**反組譯實錘=`zink_kopper_acquire_submit+0x1c`
讀 `images[dt_idx].acquired` 時 **dt_idx=0x30000658 垃圾**——kopper acquire 失敗
(kill_swapchain 路)後 `zink_batch_rp` 仍用未初始化 index;tc thread 競態
(`GALLIUM_THREAD=0` 三連過:主選單+進世界,渲染正確)。dev 碟不踩=acquire 不失敗
(差異未定位)。**驗收三關實質全過**(MC 帶 GALLIUM_THREAD=0 註記)。
真因修法候選:zink kopper 上游韌性修 cherry-pick、查 venus 端 acquire 失敗原因
(首幀 resize/OUT_OF_DATE?)。GALLIUM_THREAD=0 不進 deb(犧牲 GL 效能)。

**kopper 續(2026-08-12 凌晨二)**:acquire_submit 護欄(mesa e14d2e5fc2c)擋掉原崩點後
crash 移到 `begin_rendering+0x17d8`——證實是**整場 tc-vs-swapchain-recreate 競態**,單點
防禦打地鼠不可行;根治=上游 tc/kopper 同步(未做)。**繞開觸發源成功**:MC `fullscreen:true`
(首幀幾何穩定→無 OUT_OF_DATE→無 recreate)下零 crash 零 workaround 進世界,世界渲染正確。
**驗收 3/3 達成**(known-issue:MC windowed 首啟動在幾何變動時仍可能踩 begin_rendering
競態;護欄+fullscreen 是實用解,真根治留上游同步修)。

**venus_host pool merge 落地(2026-08-12 深夜二,task 3 完)**:vkr `blob_id==0` shmem 改從
venus_host 池子分配(coalescing free list;`vkr_renderer_create_resource` 增 out_map_ptr/
out_fd_offset;adapter 轉遞;crosvm `virgl_pool_offset` 認兩個池窗+改名)。驗證:
`venus_host pool: 16 MiB` init、**runtime-share 歸零**(mthp 僅 boot 3 region)、
vkr-ring ×25、三關回歸全過(MC 進世界零 crash)。fusion 語意=guest 仍提位置,host 回
MAP_INFO_POOL+offset 蓋掉(池)或不帶 POOL(share 進 guest 位置=fallback)。
**兩個踩坑**:(1) vkr 私有 mmap 的 VA 與 crosvm 窗檢查(VENUS_POOL_HOST_VA)不同→probe
永 miss→ring 全滅(instance retry 風暴、vulkaninfo INITIALIZATION_FAILED)——修=直接用
VMM 映射;(2) `drm2kgsl_pool_offset` 已改名 `virgl_pool_offset`。
vkmark 單次 125(vs 前輪 457)=DVFS 雜訊類,正式基準要鎖頻/交錯 A/B。

**soak(2026-08-12 02:5x)**:r13 連跑 30+ 分鐘(MC 在世界內),crosvm 零 FORTIFY、
fence 57 萬順跑、pool 穩;MC 一次 in-game crash(hs_err_pid1916,裸位址幀,疑 kopper/tc
競態家族,檔留 guest /home/droidvm/)——host 棧穩定,應用層 crash 待符號化+上游根治。

**剩:tc/kopper recreate 競態真根治(上游同步修;現行=護欄+fullscreen 繞開)+
效能基準(鎖頻/交錯 A/B)+ fork 私有 diag(VENUS-DIAG)清理或定案。**

原「vkmark 卡在 present 的 semaphore」調查紀錄(已破,留檔):桌面(kwin/plasma,
zink 路)跑得動且持續渲染(fence→18002),但 vkmark(純 vn ICD)第一輪 texture 場景跑一陣後
卡死、SIGTERM 殺不掉(SIGKILL 可):`vn_wsi[0,0]` thread 卡
`wsi_common_queue_present → wsi_signal_dma_buf_from_semaphore → vn_GetSemaphoreFdKHR →
vn_wsi_sync_wait(futex)`——present 的 explicit→implicit sync 橋在等 render-complete
semaphore 就緒,永不來。頭號嫌疑:**venus semaphore feedback**(host GPU 把完成旗標寫進
guest_vram 池的 feedback buffer,guest CPU 輪詢)——guest-alloc import 的 **GPU 寫→guest CPU
讀**方向可能沒接通(gfxstream 時代 pattern_match 驗過該方向,venus 的 import 路要重驗;
也可能是 sync_fd export/allow_vk_wait_syncs 路)。桌面 zink 為何沒事:待查(可能 zink 的
present 同步路不同或頻率低)。查法:headless 加 semaphore 測試(vksubmit.c 擴充
signal semaphore + vkWaitSemaphores)、feedback buffer 的 VENUS-DIAG(get_blob 對應
res)、GPU 寫池頁 aliasing test(池側讀回 GPU 寫的 pattern)。

原「未解=黑畫面(kwin 不 present)」調查紀錄(已破,留檔):kwin 主執行緒卡
`zink_get_gfx_pipeline → do_futex_fence_wait`(等 pipeline 編譯 fence),venus/host 全程
無錯、fence 5/5 全 signal、ring-5 idle 空、**新 vulkaninfo instance 正常**——不是 transport
卡,是 guest 端 zink 的 pipeline 編譯 job 沒人執行/沒 signal(kwin thread 清單裡沒有 zink
compile queue thread)。假設=turnip-via-venus 露出 GPL → zink async precompile 路;
`ZINK_DEBUG=nobgc` 測試未完成(第一次 drop-in 沒進 user manager;第二次 terminate-user
撞 teardown crash)。**r9 部署後續作**:/etc/environment 已有 ZINK_DEBUG=nobgc,
完整重啟 session 驗 nobgc;若仍卡,gdb 看 fence 屬誰(zink prog cache?)、
或試 `ZINK_DEBUG=noopt`/`GALLIUM_THREAD=0`、比對 gfxstream ICD 下 zink 的 ext 差集
(GPL/pipeline_cache_control/maintenance5)。
diag 插樁:adapter VENUS-DIAG(fprintf stderr)在 attach/get_blob/park;
`GPU_SCANOUT_TRACE=1` 開 crosvm flush/scanout strace;guest `droidvm_trace=1` 開 VGBLOB。
fbcon 游標閃爍=每 0.5s flush res=2(黑畫面時 host 唯一動靜,別誤判成 kwin 在送幀);
`note_flush_route` 每字串只印一次。

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
