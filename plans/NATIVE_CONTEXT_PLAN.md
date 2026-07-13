# DRM Native Context 移植計畫(turnip-in-guest,protected VM)
2026-07-11。參照:QEMU 8935982(virtio-gpu DRM native context)、Mesa MR 14900(freedreno virtio)。

## ★ 全棧就緒(2026-07-11)—— 只差裝置整合測試
| 層 | 狀態 |
|---|---|
| host: virglrenderer KGSL backend | ✅ 寫完+編譯+進 libvirglrenderer.so,commit `147dea5` |
| host: crosvm context-types=drm plumbing | ✅ **本來就完整**(capset/use_drm/virgl_renderer feature 全在),零改碼;symbols 確認在 crosvm 二進位 |
| host: 啟動變體 | ✅ `start_nctx.sh`(backend=virglrenderer,context-types=drm),已 push 到裝置 /data/local/tmp/(未執行) |
| guest: turnip-virtio | ✅ mesa 26.0.3 重編 `-Dvulkan-drivers=freedreno -Dfreedreno-kmds=msm,virtio`,tu_knl_drm_virtio.cc.o + vdrm 符號確認;非破壞 ICD `/root/turnip_virtio_icd.json` |
| **裝置整合測試** | ⏳ **待人工執行**(需重啟 VM,device-disruptive) |

### 測試步驟(user 執行)
1. 裝置上重啟 VM 走 native context:`adb shell su -c /data/local/tmp/start_nctx.sh`(取代 start.sh;會 pkill 現有 crosvm)
2. guest 內跑:`VK_ICD_FILENAMES=/root/turnip_virtio_icd.json vulkaninfo 2>&1 | head -40`
   - 期望:`driverName = turnip`、`deviceName = Turnip Adreno (TM) 830`,經 vdrm/virtio 而非 gfxstream
3. 過了再爬梯:`vkcube` → zink glxgears → Minecraft(同 ICD 環境變數)
- **回退**:跑回原 `start.sh` 即恢復 gfxstream,兩者不互相破壞

### guest turnip-virtio 重編配方(存查)
```
# 缺的 X 建置依賴:apt install libxshmfence-dev libxcb-keysyms1-dev libunwind-dev \
#   libxrandr-dev libxfixes-dev libxdamage-dev libxext-dev libx11-dev libxcb-*-dev libwayland-dev
cd /root/mesa-build/mesa-26.0.3
meson setup builddir-nctx -Dvulkan-drivers=freedreno -Dgallium-drivers= \
  -Dfreedreno-kmds=msm,virtio -Dplatforms=x11,wayland -Dbuildtype=release \
  -Dvulkan-layers= --prefix=/usr
ninja -C builddir-nctx   # 904 targets, ~數分鐘, 0 FAILED
# 產物 builddir-nctx/src/freedreno/vulkan/libvulkan_freedreno.so(含 vdrm/virtio)
```


## 結論:可行,三個關鍵疑點都有具體機制解

### 架構(目標狀態)
```
guest app → guest turnip(tu_knl_drm_virtio,mesa 現成)
          → vdrm(mesa src/virtio/vdrm,現成)
          → guest virtio_gpu(context_init CAPSET_DRM,kernel 7.0 現成)
          → crosvm rutabaga virgl(CAPSET_DRM=6 plumbing 現成,需開通 context-types=drm)
          → virglrenderer drm_context(上游 src/drm,需 vendor 進來)
          → 【新寫】kgsl_renderer:msm_proto 協議伺服端,後端打 KGSL
          → /dev/kgsl-3d0(真 Adreno 830)
```
與 gfxstream 差異:不再遠端化 Vulkan API(序列化/解碼/HMI shim 全消失),guest 跑**真 turnip**,host 只轉譯 DRM 層(BO 管理+submit)→ 接近原生性能(vkmark 目前 54%,目標逼近 100%)。

## 三個疑點與解法

### 1. host 沒有 drm/msm(只有 KGSL)
上游 msm_renderer.c(僅 1083 行)期望 drm/msm uAPI。翻譯面實測:10 個 wire ops、9 個內核命令。**tu_knl_kgsl.cc 就是現成的 msm→KGSL 羅塞塔石碑**(mesa 還 vendor 了 msm_kgsl.h uapi 頭,直接可用):
- GET_PARAM(chipid/GMEM/VA range)→ IOCTL_KGSL_DEVICE_GETPROPERTY
- GEM_NEW → IOCTL_KGSL_GPUMEM_ALLOC;GEM_CLOSE → GPUMEM_FREE_ID
- SUBMITQUEUE_NEW/CLOSE → DRAWCTXT_CREATE/DESTROY
- GEM_SUBMIT → IOCTL_KGSL_GPU_COMMAND(+ timestamp)
- WAIT_FENCE/CPU_PREP → WAITTIMESTAMP_CTXTID / SYNC_CACHE
- SET_PARAM(debug comm)→ no-op

### 2. guest 自管 iova(msm 模型)vs KGSL 內核配位址
msm 協議:guest 從 GET_PARAM 的 VA_START/VA_SIZE 拿範圍,GEM_NEW 自帶 iova。
**解法:KGSL VBO**——host 開一個大 VBO(KGSL_MEMFLAGS_VBO)當「guest iova 窗」,每個 BO 用 IOCTL_KGSL_GPUMEM_BIND_RANGES 綁在 guest 指定的 offset;VA_START 回報 VBO 基址。guest 管位址、KGSL 兜底,cmdstream 裡的位址天然有效,零 patch。tu_knl_kgsl 的 sparse 實作已在用這對 uapi(msm_kgsl.h:160,1758)。

### 3. protected VM 記憶體模型(不能直接共享,要 GuestAccept)
- **BO(大宗)**:host kgsl 分配 → dmabuf → HOST3D blob → RESOURCE_MAP_BLOB → **現有 share66 GuestAccept 路徑原封不動**(今天 gfxstream 就在 SHARE kgsl 頁,已驗證)
- **vdrm shmem ring**(guest→host 命令環 + host→guest response):上游用 VIRTGPU_BLOB_MEM_GUEST(host 直讀 guest 頁,protected VM 禁止)→ **改成 host-allocated GuestAccept ring**,照抄我們 ASG ring 的先例(HOST3D_GUEST + external memory);guest 側 vdrm_virtgpu 小改 blob 類型
- virtqueue/描述子:本來就走 swiotlb ✓

## 工作清單(依序)
1. [骨架] vendor 上游 src/drm/{drm_context,drm_fence,drm_util,drm-uapi} 進 libvirglrenderer + 新寫 src/drm/kgsl/kgsl_renderer.c(msm_proto 伺服端)+ soong 構建
2. [host] crosvm --gpu context-types 加 drm;capset 串接
3. [guest] mesa 重編 turnip-virtio(tu_knl_drm_virtio + vdrm);vdrm ring 改 GuestAccept
4. [驗收梯] guest vulkaninfo(真 turnip)→ vkcube → zink glxgears → **Minecraft**
5. [收尾] fence(kgsl timestamp→drm_fence eventfd)打磨、多 queue、殘留 gfxstream 路線共存(display/2D 仍走 gfxstream 或 cross-domain)

## Framework 漂移修復清單(2026-07-11,已套用)
上游 drm/ 樹 + vendored(舊)virgl core 的版本漂移,逐項:
- vdrm 協議:整包上游 src/drm 同步(舊 vendored msm_proto 與 guest 差 172 行,上游差 21)+ drm_hw.h 上游化(補 vdrm_ccmd_req/vdrm_shmem)
- `drm_renderer_create` 簽名 +fd 參數(virglrenderer.c call site 傳 -1)
- hash:`hash_table_search`→`_mesa_hash_table_search` + u32 key 四處補 `(void*)(uintptr_t)` cast
- logging:vendored 只有 level-less `virgl_log`;在 virgl_util.h 尾加相容層(`enum virgl_log_level_flags` + `virgl_info/error/warn/prefixed_logv` → virgl_logv)
- `TRACE_SCOPE_BEGIN/END` 空巨集虛值化(`(NULL)`/`(void)`)讓 `void* s = TRACE_SCOPE_BEGIN()` 編過
- virgl_fence.c:`_mesa_hash_table_u64_destroy` 改單參 + 手動 walk 關 fd;`hash_table_u64_call_foreach` 不存在→手動 deferred-remove walk
- `get_device_fd` vtable 成員 vendored 沒有→拔賦值(零消費者)
- `DRM_IOCTL_SET_CLIENT_NAME` #ifdef 保護(Android libdrm 無此新 ioctl)
- vendor 進來:virgl_fence.c/.h、util/libsync.h;Android.bp 加 src/drm/*.c + virgl_fence.c + libdrm_headers(頂層)
- **停用 msm backend**(ENABLE_DRM_MSM off + Android.bp 移除 msm_renderer.c):裝置無 drm/msm,其 uapi 漂移(drm_msm_gem_info/MSM_BO_CACHED_COHERENT)是白修;KGSL backend 取代它
- 現況:framework 應可編譯(backends[] 空,待加 kgsl);ENABLE_DRM 開

## 動工進度(2026-07-11 清晨)
- [x] 可行性研究完成(本文檔)
- [x] 上游 virglrenderer clone 到 `virglrenderer-upstream/`(對照用)
- [x] **重大發現:vendored `crosvm_build/external/virglrenderer` 已內建 `src/drm/` + msm nctx**(drm_renderer.c 137 行 backend 表 + msm_renderer.c 1286 行),只是 Android.bp 沒編、config.h `ENABLE_DRM/_MSM` 註釋掉 → 不用 vendor,直接在樹裡加 kgsl 後端
- [x] guest mesa 血統確認:MR 14900 完整演化版都在(freedreno/drm/virtio、vdrm、tu_knl_drm_virtio)
- [x] KGSL uapi 頭現成:mesa `src/freedreno/vulkan/msm_kgsl.h`(VBO/BIND_RANGES @ line 160/1758)
- [ ] 下一步:`src/drm/kgsl/kgsl_renderer.c`(以 vendored msm_renderer.c 為模板、tu_knl_kgsl.cc 為 KGSL 對照)+ drm_renderer.c probe 加 /dev/kgsl-3d0 + config.h/Android.bp 開編
- [ ] 協議版本對齊:host 實作以 guest mesa 的 msm_proto.h 為準(vendored 與 guest 版本需 diff 核對)
- [ ] crosvm --gpu context-types=drm 開通(rutabaga CAPSET_DRM=6 已有 plumbing)
- [ ] guest:編 turnip-virtio + vdrm;vdrm shmem ring 改 GuestAccept(ASG ring 先例)

## KGSL 後端架構(對裝置真 uapi 逐項確認,2026-07-11)
**關鍵發現:KGSL 只能 IMPORT dmabuf,不能 EXPORT**(`KGSL_USER_MEM_TYPE_DMABUF` 只在 import 側)。所以 BO 流程是反向的(和 drm/msm 的 export 相反):

每個 GEM_NEW(guest 要一塊 BO,自帶 iova):
1. host 分配 backing = **我們的 order-9 池 memfd/dmabuf**(可 GUP-pin、可 SHARE——今天 gfxstream 就在用)
2. `share66` GuestAccept SHARE 給 guest(CPU 側,guest 在某 guest-PA 看到同一批頁)
3. `IOCTL_KGSL_GPUOBJ_IMPORT`(dma_buf 型)把同一 dmabuf 匯入 KGSL → child_id(GPU 側)
4. iova 定位:開機時建一個大 **VBO**(`KGSL_MEMFLAGS_VBO`,覆蓋 guest iova 窗),GET_PARAM 回報 `VA_START=VBO_base`;GEM_NEW 時 `IOCTL_KGSL_GPUMEM_BIND_RANGES` 把 child_id 綁進 VBO,`target_offset = guest_iova - VBO_base`
   - `struct kgsl_gpumem_bind_range { child_offset, target_offset, length, child_id, op }` — 全欄位齊備確認
5. 結果:GPU 從 guest 選的絕對 iova 讀到 BO、guest CPU 從 GuestAccept map 讀同一批實體頁 → cmdstream 零 patch、零拷貝

命令翻譯表(msm_renderer.c 10 handler → KGSL):
- GEM_NEW → 上述 5 步 | GEM_SET_IOVA → BIND_RANGES(bind/unbind) | GEM_SUBMIT → IOCTL_KGSL_GPU_COMMAND | WAIT_FENCE → IOCTL_KGSL_TIMESTAMP_EVENT/WAITTIMESTAMP | GEM_CPU_PREP → SYNC_CACHE | SUBMITQUEUE → DRAWCTXT_CREATE/DESTROY | GET_PARAM(capset) → DEVICE_GETPROPERTY(chipid=Adreno830v2 已確認)
- fence:KGSL timestamp event 出 sync_file fd → 接 drm_fence.c 的 drm_timeline(eventfd 模型)

## 工作量誠實評估
- **設計:完成**(每個承重疑點都對裝置真 uapi 確認,無紙上假設)
- host framework 編譯:進行中(漂移已修 4 類:vdrm 協議整包上游化、hash_table_search 別名、get_device_fd 拔除、virgl_fence+libsync vendor、libdrm_headers)
- **剩餘=大工程**:寫 `src/drm/kgsl/kgsl_renderer.c`(鏡像 1083 行 + KGSL 翻譯 + import/VBO/bind iova 機制)、接 drm_renderer backends[]、guest 重編 turnip-virtio、然後**裝置上逐 handler 除錯**(GUP-pin KGSL-import 頁的相容性、VBO bind 對齊、fence 時序——這些只能在裝置上迭代)
- **實話:MC on native context 不是一個晚上能到的**——KGSL 後端要寫+裝置除錯,加 guest turnip 重編,是多 session 工程。今晚成果=設計完全 de-risk + host 骨架就緒 + 精確的裝置待驗清單。gfxstream 路線的 MC 仍是當前可用成果。

## KGSL backend 已實作(2026-07-11,編譯通過)
`src/drm/kgsl/{kgsl_renderer.c,kgsl_renderer.h,msm_kgsl.h}` 寫完,libvirglrenderer.so 乾淨編譯+連結。wire 到 `drm_renderer.c`(backends[] 加 kgsl + char-device open 分支跳過 drmGetVersion)、`config.h`(ENABLE_DRM_KGSL=1)、`Android.bp`(加 kgsl_renderer.c)。11 個 ccmd handler 全實作(NOP/IOCTL_SIMPLE/GEM_NEW/GEM_SET_IOVA/GEM_CPU_PREP/GEM_SET_NAME/GEM_SUBMIT/GEM_UPLOAD/SUBMITQUEUE_QUERY/WAIT_FENCE/SET_DEBUGINFO)。

### 實作中發現的兩個關鍵事實
1. **VBO 必須用 `IOCTL_KGSL_GPUOBJ_ALLOC`,不是 GPUMEM_ALLOC_ID**:`KGSL_MEMFLAGS_VBO` 在 bit 34(64-bit),而 `kgsl_gpumem_alloc_id.flags` 只有 32-bit → 編譯器 `-Werror,-Wconstant-conversion` 直接抓到。改用 `kgsl_gpuobj_alloc`(`__u64 flags` + `__u64 va_len`,size=0 純虛擬)+ `GPUOBJ_INFO` 讀回 gpuaddr。
2. **KGSL pagetable 是 per-process,不是 per-fd**(uapi 無 private-PT flag):同一 crosvm 程序內多個 guest DRM context 會共用一個 GPU VA 空間。**單 context bring-up(vulkaninfo/vkcube/MC 各自單程序)不受影響**;但兩個 turnip-virtio 程序同時跑會 VA 撞車。→ 這是**頭號未解架構風險**(多 context 隔離),留待裝置驗證後決定(per-context fork KGSL proxy / 序列化 / 主機仲裁 iova 分段)。

### 記憶體模型(已 lock)
- guest 自派 iova(util_vma_heap over va_start/va_size)→ host 用**單一大 VBO 覆蓋整個 VA 範圍** + `GPUMEM_BIND_RANGES`(target_offset = iova - vbo_base)。綁定是**加第二個 mapping**在 guest iova,child 保留自己沒用到的 gpuaddr,不衝突。
- BO backing = dma-heap `/dev/dma_heap/system` ALLOC(可 export 的 dmabuf)→ `GPUOBJ_IMPORT` 進 KGSL(KGSL 只能 import)。同一 dmabuf fd 就是回給 get_blob 的 HOST3D blob → 走現有 GuestAccept,跟 gfxstream 今天一樣。
- fence:GPU_COMMAND 用 `KGSL_CONTEXT_USER_GENERATED_TS` drawctxt,guest 自派 seqno(MSM_SUBMIT_FENCE_SN_IN)直接當 KGSL timestamp;完成後 `TIMESTAMP_EVENT(FENCE)` 出 sync_file fd → drm_timeline。

### 裝置待驗梯(依風險排序,只能 on-device 迭代)
1. **VBO 基址決定論**:每 context open 的 fd,首個 VBO alloc 的 gpuaddr 是否 == probe 報的 va_start(kgsl_renderer_create 有硬 assert,不符直接 fail)
2. **dmabuf import→VBO bind**:GPUOBJ_IMPORT 的 dmabuf 物件能否當 BIND_RANGES 的 child(#1 機制風險)
3. **BIND_RANGES 對齊**:target_offset/length 的頁對齊要求
4. **timestamp→sync_file poll 時序**:TIMESTAMP_EVENT(FENCE) fd 的 poll 語義接 drm_fence.c thread
5. GEM_CPU_PREP 目前恆回 ready(0):coherent 記憶體 OK,非 coherent readback 正確性待精修

## KGSL backend 原始規格(存查,`src/drm/kgsl/kgsl_renderer.{c,h}`)
- **註冊**:context_type = `VIRTGPU_DRM_CONTEXT_MSM`(=1)。guest turnip 是 freedreno/msm 驅動跑在 VM 裡,講 msm_proto,不知 host 是 KGSL。KGSL backend = 「msm 協議的 KGSL 實作」,不需新 context type。
- **probe/init 特判**:drm_renderer_init 用 drmOpenWithType/drmGetVersion(對 /dev/dri),KGSL 是 /dev/kgsl-3d0 純字元設備 → drm_renderer.c 要加分支:backend name="kgsl" 時直接 `open("/dev/kgsl-3d0")`,跳過 drmGetVersion,capset 從 `IOCTL_KGSL_DEVICE_GETPROPERTY` 填(chip_id/gmem/va_start=VBO_base/va_size)。
- **10 個 ccmd handler → KGSL**(wire struct 全在 msm_proto.h,payload 佈局已讀):
  - NOP → 同步點,no-op
  - GEM_NEW(blob_id,size,flags,iova)→ 池 dmabuf 分配 + GuestAccept SHARE + GPUOBJ_IMPORT + VBO BIND_RANGES(target_offset=iova-VBO_base);記 msm_object{res_id,kgsl_id,iova}
  - GEM_SET_IOVA(res_id,iova)→ BIND_RANGES bind(iova!=0)/unbind(iova==0)
  - GEM_SUBMIT(flags,queue_id,nr_bos,nr_cmds,fence,payload=submit_bo[]+submit_cmd[])→ 譯成 `struct kgsl_gpu_command`:submit_cmd{iova,size}→kgsl_command_object{gpuaddr,size};fence seqno→KGSL timestamp(guest 自派 seqno,MSM_SUBMIT_FENCE_SN_IN 語義=KGSL 用 timestamp)
  - GEM_CPU_PREP → SYNC_CACHE / WAITTIMESTAMP | GEM_SET_NAME → no-op(或 KGSL SETPROPERTY name)| GEM_UPLOAD → memcpy 到 mmap'd bo | SUBMITQUEUE_QUERY → DRAWCTXT query | WAIT_FENCE → WAITTIMESTAMP_CTXTID | SET_DEBUGINFO → no-op
- **VBO 開機建**:kgsl_renderer_create 時 GPUMEM_ALLOC(VBO,大小=va_size,flags=KGSL_MEMFLAGS_VBO)→ 記 VBO_base=gpuaddr;capset.va_start=VBO_base。
- **get_blob/export**:虛擬——BO backing 是我們 SHARE 的 dmabuf,已在 guest;host 只回 blob handle 讓 crosvm 走既有 GuestAccept share_blob(res_id→GPA)。
- **fence**:GEM_SUBMIT 出 KGSL timestamp → `IOCTL_KGSL_TIMESTAMP_EVENT`(type FENCE)出 sync_file fd → 塞 drm_timeline(drm_fence.c 的 eventfd 模型)。submit_fence(ring_idx)對應 KGSL context(drawctxt)。
- **裝置待驗(只能 on-device 迭代)**:① GPUOBJ_IMPORT 我們池 dmabuf 是否成功、gpuaddr 能否被 VBO bind ② BIND_RANGES 對齊要求(4K?2M?)③ guest 選的 iova 落在 VBO 窗內(guest turnip 的 VA allocator seed=capset.va_start)④ timestamp→sync_file fd 的 poll 時序

## 風險備忘
- kgsl VBO 綁定粒度/對齊(4K?)與 msm iova 對齊差異
- fence:virglrenderer drm_fence 是 eventfd+thread 模型,kgsl 用 timestamp event(IOCTL_KGSL_TIMESTAMP_EVENT 可發 fence fd)→ 需適配
- submit 的 in-fence(guest syncobj)語義:第一版可用 host 端序列化(單 queue)簡化
- display 整合:MC 視窗經 Xwayland/gnome → scanout 仍是 virtio-gpu 資源;native ctx BO → dmabuf → 現有 display 管線可收
- 手機 KGSL 是 vendor 版(msm_kgsl.h 以裝置實際 uapi 為準,mesa vendored 頭已對齊 A7xx/A8xx 世代)
