# Arena v2(分頁式)設計規格

目標:BO 記憶體生命週期收斂為「開機祝福一塊實體頁池,之後 guest/host 兩端純頁表操作」。
碎片化結構性消失(連續永遠是虛擬的),per-BO 零 hypervisor/RM 往返。

## 分層與所有權

```
guest userspace VA ─stage-1(guest kernel,自由重映射)→ GPA(BAR)
GPA               ─stage-2(gunyah,祝福時建好後靜態)──→ host PA(arena memfd 頁)
GPU iova          ─VBO 頁表(host BIND_RANGES 多段縫合)→ host PA(同一批頁)
```

- **實體池**:host memfd(MADV_COLLAPSE 保留池 folio),祝福時 KGSL import 一次(一個 child)、
  guest blob map 一次(一個 parcel、一次 accept)。
- **分配權在 guest**(driver 手上有 fence):頁池 buddy allocator(page 粒度,傾向 2MB 對齊 run)
  + 大 VA heap(va_size 與池大小解耦,維持 64GB+)。
- **host 無 allocator**:只按 guest 給的 run list 縫合/簿記。

## 協議(msm_proto 擴充,兩端同步改,以 guest 為準)

1. **祝福**:`GEM_NEW{ iova=0, size=池大小, blob_id }` = ARENA。
   host:memfd+import(不 bind);get_blob 回 memfd(SHM)。guest 之後對它建 resource+map(唯一一次 accept)。
2. **v2 BO**:`GEM_NEW` 尾接 run list:`u32 nr_runs; struct { u64 arena_off; u64 len; } runs[]`
   (hdr.len > sizeof(req) 即判 v2)。host:驗證 runs 都在池內 →
   **一次** `BIND_RANGES{ ranges[i] = { child=arena, child_offset=run.off,
   target_offset=iova+Σlen前綴-vbo_base, length=run.len } }`(ranges_nents 原生支援多段)。
3. **legacy BO**(不帶 run list):今天的完整 per-BO 路——SCANOUT/export/import 用,
   未升級 guest 也自然全走這條(向後相容)。

## Host(virglrenderer/kgsl)要點

- obj 簿記:iova/size/run list;mem_id=0(無自有 KGSL 物件)。
- host CPU 視圖(IB_CHECK/GEM_UPLOAD/transfer fallback 用):PROT_NONE 佔位 +
  per-run `mmap(MAP_FIXED, arena_memfd, run.off)` 縫合(memfd 任意 offset map ✓);
  free 時單次 munmap 全 span。
- set_iova(≠0):以新 iova 重縫(一次 BIND_RANGES);set_iova(0)/free:純簿記
  (no-unbind 設計不變:舊 bind 持 arena child 引用,VA 重用時自動被覆蓋)。
- capset va_size:**不再縮**(維持 VBO 大小);v1 的 NCTX_ARENA_MB 縮 va_size 邏輯移除。

## Guest 要點

- **mesa vdrm**:
  - init:祝福(GEM_NEW iova=0 + resource + map)。池大小 env(預設 1GB)。
  - BO create:頁池 alloc→runs + VA heap alloc→iova → GEM_NEW+runs;
    export/WSI(VkExportMemoryAllocateInfo)/SCANOUT → legacy 路。
  - CPU map:呼叫 patched virtio_gpu 的 partial-offset mmap 把 runs 縫成線性 VA
    (GPU-only BO 免做)。
  - **fence-gated free(生命週期唯一自寫邏輯)**:BO destroy → (runs, iova, last_fence)
    入 deferred list;fence retire 時歸還頁池+VA heap。
    ⚠ 頁回收必須 gate(不只 VA):in-flight submit 經舊 VA 讀到被重用的頁=髒讀。
- **guest kernel(patched virtio_gpu,本來就我們在編)**:
  - blob GEM object 允許 partial/offset mmap(驗證範圍),供 stage-1 縫合。

## 落地順序

1. host:協議 parse + 祝福 v2 + runs 縫合 + host 縫合視圖(legacy 全保留,未升級 guest 不受影響)
2. guest mesa:池 allocator + GEM_NEW runs + fence-gated free(先不做 CPU 縫合,
   GPU-only BO 即可端到端驗證 bind 縫合正確性)
3. guest kernel:partial mmap → CPU-visible BO 接通
4. 驗收:gnome →(頂點 bug 觀察)→ vkcube → MC

## 風險備忘

- 祝福 parcel 的 RM entry 上限(1GB=512 folio entries)未實測;超限就縮池或多池。
- BIND_RANGES 多段一次 ioctl 的 nents 上限查 kgsl-ref(kgsl_ioctl.c 的 copy 迴圈)。
- 散 run 的 GPU 側 PTE 大頁率下降:buddy 傾向 2MB run 可救回大部分。

## 實作決議(2026-07-11,host 端已落地 commit a265fdd)

1. **paged BO 仍建 virtio resource**(submit 靠 res_id):host get_blob 回 dup(arena memfd)
   佔位(guest 永不 map;fd 隨 resource 銷毀);不用 blob_id 命名空間 hack。
2. **guest 偵測 host 支援**:bring-up 期用 guest env(`VDRM_ARENA=1`)閘;
   舊 host 收到 iova=0 gem_new 會 async_error,別亂送。之後再加 capset bit。
3. **CPU 映射分兩階**:mesa 池 allocator **優先單 run(池內連續)**→ CPU 指標 =
   arena_map + off,免 kernel patch 即可全功能 bring-up;多 run(碎片時)先只給
   GPU-only BO,待 guest kernel partial-offset mmap patch 落地後全面解鎖。
4. host 端狀態:祝福/run 縫合/set_iova 重縫/free/host 縫合視圖/get_blob 佔位全完成,
   對未升級 guest 回歸通過(faults 持平、無新錯)。

## Guest 端進度(2026-07-11 晚)

- mesa patch 已打(patcher: /tmp/guest_arena_patch.py 於 guest;本機副本
  ~/.claude/jobs/e01d12a3/tmp/guest_arena_patch.py):
  msm_proto.h(run struct)、virtio_priv.h(device arena 欄位+bo arena_off/len)、
  virtio_device.c(VDRM_ARENA env 祝福+池 heap)、virtio_bo.c(fast path 建/map 別名/finalize 歸還)。
- **免自建 fence-gate**:mesa 的 per-pipe retire_queue 本來就把 submit(和其 BO)
  的引用握到 out-fence signal,finalize 天然 post-retire → pool free 放 finalize 即安全。
  (同時解釋 NCTX_NO_FENCE 危害:fence 立即 signal = retire_queue 提早放 BO。)
- 部署鏈:builddir-nctx 編 libvulkan_freedreno.so → **cp 到 /opt/turnip-nctx/**(ICD 指拷貝!)
  → /etc/environment 加 VDRM_ARENA=512 → sync → host relaunch VM。
- 驗證點:guest journal「arena blessed: 512 MB」+ host console「ARENA blessed: pool=...」
  → SHARE-BLOB 只該出現一次大的(池)+ scanout 幾顆 → faults/畫面對照。
