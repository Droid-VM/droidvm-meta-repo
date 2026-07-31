# CMDLINE v2 — 三軸解耦(memory model / VM backend / graphics-proxy model)

> v1 誤把「代理模型」讀成記憶體共享代理。已更正:**代理模型 = 圖形協議代理的層級**
> (API-level vs ioctl/native-context-level)。記憶體共享是另一件事,屬 VMM 層。

## 重構性質 / 風險(給實作者 & reviewer)
**核心解耦 = 行為不變的「code 遷移 + CLI 改寫」+ 顯式分支,零新邏輯**:fork-fold(share_blob
body 原封搬進 add_memory_region 的 protection 分支)、vm_control 收 fork、proxy 分類(純
metadata)、renderer 派生、CLI + deprecation alias。**變嚴格**:以前隱式路由(unprotected 誤走
guest-accept pvm 邏輯、runtime-guest 誤入 pre-alloc/host)靠 `VramAllocMode` enum + 派生表 +
guard 變成 by-construction 不可能。**Invariant**:`unprotected + guest-runtime = unmodified
crosvm`(BLOB_MEM_GUEST+attach_iov,零 fork 邏輯)—— 可當回歸基準。**風險全在「派生表 +
fold」對不對**——`(backend × protection × proxy) → 機制` 那張表把隱式路由顯式化,錯它=行為變,
是 review 重點。**少數「新增功能」(非純遷移,但 param-gated,不設=舊行為)**:①size-caps 簿記+
guest OOM(真新 code)②multi-arena+DTB 名(新 capability)③exceed-policy fallback(可能新行為)
④per-region 大頁閾值(全域→per-region 決策)。

## 動機
今天啟動 GPU VM 的 cmdline 把三件**正交**的事糅成一團:

```
--hypervisor "gunyah[blob_mode=guest-accept]"   # VM後端 + 記憶體共享機制 綁死
--protected-vm-without-firmware                  # 保護等級
--gpu "backend=virglrenderer,context-types=virgl2:drm,...,gunyah-pvm=true"
       # ↑ 圖形代理層級(context-types)+ 又一份共享旗標 混在 gpu arg
NCTX_KGSL_PT=1 NCTX_VRAM_MB=1024 NCTX_SHMEM_KB=64 # 記憶體模型散在 env
--prepare-lend-mthp-mode chunked                  # 記憶體模型的大頁 prep 又在別處
```

---

## 三軸定義

### 軸 A — 記憶體模型(**大部分是派生的,不是自由軸**)
根本原理:**「host 看不看得到 buffer 的實體頁」決定擁有權往哪翻**。
- host **看得到** guest RAM(KVM,或 gunyah unprotected):buffer = **guest-owned**
  (`BLOB_MEM_GUEST` + `virgl_renderer_resource_attach_iov`,host 掛 guest 頁 iovec)。
  **沒有 pool / arena / share**。這是**上游 native-context 的正常路**。
- host **看不到** guest RAM(gunyah protected):guest-owned 直接死(iovec 指向 host 看不到
  的頁)→ **翻轉成 host-owned pool**,guest 反過來映射。

| backend | 保護 | proxy | 擁有者 | 記憶體模型 | 機制 |
|---|---|---|---|---|---|
| KVM | unprot | native | guest | guest-mem-direct | BLOB_MEM_GUEST+iov(**上游**) |
| KVM | unprot | API | host | host blob | export fd |
| gunyah | **prot** | native | host | **pre-alloc arena(唯一)** | 祝福 pool,guest 映射;per-BO share 太慢 |
| gunyah | **prot** | API | host | **pre-alloc ⊕ host-share** | ← **唯一真正自由的一格** |
| gunyah | unprot | * | 皆可 | 較寬鬆 | host 看得到,也可 guest-direct |

**結論**:記憶體模型 ≈ 派生自 `(backend 記憶體隔離 × proxy 分配模式)`,使用者唯一自由度是
`(gunyah-protected, API-proxy)` = `pre-alloc` 或 `gunyah-share`。且**per-proxy**——
共存時 native 走 arena、API 走自己的選擇,**不是一個全域設定**。pre-alloc 專屬參數
`size-mb`/`shmem-kb`;gunyah-share 專屬 `exceed-policy`/`hugepage-threshold-2m`。

pre-alloc arena(host-owned pool)= **我們 fork 為 gunyah protected 加的**;上游沒有,
上游 native-context 只有 KVM guest-mem-direct 一條。

保護等級 = crosvm 既有 `ProtectionType`,不重造。runtime 共享機制見下「runtime dynamic-memory」。

### 軸 B — VM 後端(hypervisor)
`kvm | gunyah | gzvm | pkvm`。今天 crosvm 有 `kvm | gunyah | geniezone`;`gzvm`/`pkvm`
**未實作 → placeholder**(parse 過,啟動 `unimplemented!` 帶 TODO)。

### 軸 C — 代理模型(圖形協議代理的**層級**)
guest 到 host 是在圖形棧的哪一層轉發:

| 層級 | 代理什麼 | 例子 | guest 跑什麼 |
|---|---|---|---|
| **API-level** | 高階圖形 API(VK/GLES)序列化重放 | `gfxstream`、`venus`、`virgl` | 翻譯 ICD(gfxstream/venus/zink) |
| **native-context / ioctl-level** | 底層驅動 ioctl 直接轉發 | `kgsl`(Adreno)、`kbase`(Mali)、`msm-drm`(通用 drm) | **原生驅動**(stock turnip on kgsl) |

對應 crosvm 的 `--gpu context-types=` + renderer backend。我們的 kgsl_pt = native-context/kgsl。
`virgl2:drm` 就是「virgl(API 代理)+ drm(native-context 代理)」兩個 context type 並存。

---

## 分層(釐清誰是誰)
```
[圖形 API]  guest ICD ─軸C(代理層級)→ host renderer(gfxstream/venus/virgl 或 native kgsl)
[資源]      virtio-gpu blob (RESOURCE_CREATE_BLOB)         ← 標準 virtio-GPU API,GPU 專屬
[共享窗口]  virtio PCI shared-memory region (SHM_CFG)      ← 標準 virtio,virtio-fs/video 共用
[進 guest]  軸A(記憶體模型)× 軸B(後端)× 保護等級 → bless / share / 直接  ← VMM×hypervisor
```

## 共享機制派生表(不是使用者填,是查表)
| 後端(B) | 保護 | 記憶體模型(A) | → 共享機制 |
|---|---|---|---|
| gunyah | protected | pre-alloc | 開機 bless(SHARE + no-map RM 節點),整池一次 |
| gunyah | protected | gunyah-share | runtime `GuestAccept` **或** `HostShare`（見下 ⚠） |
| gunyah | unprotected | gunyah-share | runtime `HostShare` |
| kvm | (n/a) | 任一 | 直接 GuestMemory,無 proxy |
| gzvm/pkvm | * | * | **placeholder** |

> ⚠ **實作發現(2026-07-20,查證後定案):`share-mode = guest-accept | host-share`(顯式,**無 auto**,
> 不純派生),不對稱 gate:**
> - **`guest-accept`** = `/dev/gunyah_share`(`gunyah_host_share` kmod;6.1/6.6/6.12 都有)+ guest HVC accept。
>   **up-front gate:節點在不在;缺 → startup 退出。**
> - **`host-share`** = in-tree `GH_VM_SET_USER_MEM_REGION`(`/dev/gunyah` 永遠在)+ 6.6 vendor `addrspace_map`。
>   **無乾淨 probe → 做成 runtime fail**:不 up-front gate,照做 ioctl,核心不支援則 guest 存取時 SIGBUS/錯。
> - `supports_runtime_memory_attach`:guest-accept → 查節點;host-share → true(不擋,runtime fail)。
> - **本設備 6.1 mainline → 只有 guest-accept 可用;現況 gfxstream 本來就是 guest-accept**(先前以為
>   host-share 是看過時 start_nctx.sh 誤判)。host-share 留顯式是為未來 6.6 設備。

---

## 提議的 CLI surface
```
# 軸 C:圖形代理層級(留在 gpu arg,它本來就是 GPU 的)
--gpu "renderer=virglrenderer,proxy=virgl+kgsl,displays=[...]"
       #  proxy= 取代今天的 context-types=virgl2:drm(語意更白)

# 軸 A:記憶體模型(VMM 層,獨立 arg,不塞 --gpu)
--vm-mem "gpu-pool=pre-alloc,size-mb=1024,shmem-kb=64"
         # 或 gpu-pool=gunyah-share,exceed-policy=grow,hugepage-threshold=2M

# 軸 B + 保護(crosvm 既有)
--hypervisor gunyah
--protected-vm-without-firmware
```
- `--hypervisor` 拿掉 `blob_mode=`(→ 派生);`--gpu` 拿掉 `gunyah-pvm=`(重複)。
- `NCTX_*` env 由 crosvm 依 `--vm-mem` 自動設給 in-process renderer,使用者不再手 export。

## 落地順序
1. `--vm-mem` arg:`VmMemModel { GpuPool(PreAlloc{size_mb,shmem_kb} | GunyahShare{exceed,hp_threshold}) }`。
2. 後端 enum 加 `Gzvm`/`Pkvm` → placeholder。
3. `resolve_share_mech(backend, protection, mem_model)` 派生函式取代散落的 blob_mode 讀取。
4. `--gpu` 的 `context-types=` 換成語意化 `proxy=`(alias 相容舊寫法)。
5. run script 換新 arg;舊 `NCTX_*`/`blob_mode=`/`gunyah-pvm=` 留一版 deprecation alias。

---

# 軸 C 收斂 — API proxy vs native-context(ioctl) proxy 分家

> 狀態:軸 A / runtime dynamic-memory 已定案(見上)。C 在此設計,A+C 一起實作。

## 現況:上游只按 renderer(component)分,**沒有 proxy-level 概念**
上游 `RutabagaCapsetInfo { capset_id, component, name }`,`component` = renderer
(`VirglRenderer|Gfxstream|CrossDomain|2D`);`context-types=` → `calculate_capset_mask`
比對 name → flat u64 bitmask。`context-types=virgl2:drm` = 開 VIRGL2+DRM 兩 bit。

⚠ **本節下面那欄「proxy level」是我們要加的,不是上游現成的。** 上游用 renderer 分,反而把
兩類丟同桶:**VENUS(vk-API)和 DRM(kgsl-ioctl)上游都是 `VirglRenderer`**(virglrenderer
library 同時 host 兩者)。所以上游的 renderer 軸跟 proxy-level 軸正交,且正好沒把 API-proxy 跟
ioctl-proxy 分開——「混為一談」是上游的現狀。「native context」上游有(config 旗標
`Enable drm native context support`)但只是一個 capset,不是分類法。加 proxy-level 的理由:
上游 renderer 軸推不出跨軸約束(native-context ⟹ pre-alloc + guest front),我們需要。

| capset | id | proxy level | 代理什麼 | host renderer |
|---|---|---|---|---|
| VIRGL / VIRGL2 | 1/2 | **API** | GL | virglrenderer |
| VENUS | 4 | **API** | VK | virglrenderer |
| GFXSTREAM_VULKAN | 3 | **API** | VK | gfxstream |
| GFXSTREAM_GLES | 8 | **API** | GLES | gfxstream |
| GFXSTREAM_COMPOSER | 9 | **API** | composer | gfxstream |
| **DRM** | 6 | **native-context / ioctl** | 底層 drm ioctl(driver 由 host drm 後端定:kgsl/msm/kbase/amdgpu…) | virglrenderer |
| CROSS_DOMAIN | 5 | 特殊 | Wayland passthrough | — |
| GFXSTREAM_MAGMA | 7 | (driver-proxy,borderline) | Magma(Fuchsia) | gfxstream |

## 收斂模型:proxy level 是 capset 的**一等分類**,不是 flat bitmask
```
enum GraphicsProxy {
    Api(ApiKind),            // Virgl(gl) | Venus(vk) | GfxstreamVk | GfxstreamGles
    NativeContext(Driver),   // Kgsl | Msm | Kbase | Amdgpu | ...  (= DRM capset + 顯式 driver)
    CrossDomain,             // wayland,特殊
}
```
1. **native-context 把 driver 顯式化**:今天是 `DRM` capset + `NCTX_KGSL_PT` env 隱藏地選 kgsl。
   收斂成 `NativeContext(Kgsl)`,driver 進 config,不藏 env。(DRM capset 本就帶 context_type
   子欄位:`VIRTGPU_DRM_CONTEXT_KGSL=64` 等。)
2. **host renderer 由選的 proxy 派生**:venus/virgl/native:kgsl → virglrenderer;
   gfxstream-vk/gles → gfxstream。一組 proxy 必須 renderer 一致(venus+gfxstream-vk = 衝突,報錯)。
   `backend=` 多數時候可省(派生),只有同 API 多實作時要顯式(vk = venus 或 gfxstream-vk)。

## 為什麼分家有**實質**意義(不只美觀)— level 驅動跨軸約束
- `NativeContext(kgsl)` ⟹ 需 **guest kgsl_pt front 模組** + host drm/kgsl 後端;
  記憶體模型 **⟹ pre-alloc arena**(driver 自管記憶體,不 runtime share)。
- `Api(venus/virgl/gfxstream)` ⟹ 需 **guest 翻譯 ICD**;記憶體模型 **傾向 gunyah-share**
  (host-visible coherent buffer 走 runtime attach)。
- 兩者**可共存不同角色**:`[Api(Virgl), NativeContext(Kgsl)]` = virgl 走顯示/2D、kgsl 走 3D
  (今天 `virgl2:drm` 幹的事),但收斂後角色 legible、約束可查。

## CLI
```
--gpu renderer=<派生|virglrenderer|gfxstream>,proxy=[api:venus, native:kgsl]
      # level 顯式;native:<driver> 取代裸 drm + NCTX_KGSL_PT env
```
舊 `context-types=virgl2:drm` 留 alias:parse 時分類成 `[Api(Virgl2), NativeContext(Kgsl)]`
(kgsl 由既有 NCTX_KGSL_PT 或預設推),印 deprecation。

## 定案(2026-07-20 拍板)
| 項目 | 定案 | 理由 |
|---|---|---|
| 軸 A vram 表達 | **per-proxy `vram=` 子參數**,多數派生,只 `(gunyah-prot,api)` 可覆寫;無 `--vm-mem` 獨立 arg | 記憶體模型是派生的、非自由軸;共存需 per-proxy |
| 軸 C 語法 | **新 canonical `proxy=[api:*, native:*]`**;`context-types=` 留 deprecation alias(parse 時分類) | level 顯式、舊寫法不破 |
| renderer | **由 proxy target 派生**(target 帶 impl:`api:venus` vs `api:gfxstream-vk`);`renderer=` 選填覆寫 | vk 歧義靠 target 指定 impl 解掉,renderer 恆可派生 |
| 大頁閾值 | **`hugepage-threshold-kb`,預設 512**;≥512K → 大頁供給模式(order-9 從 `gh_hugepage_reserve`,size ceil `2MB*N`);放 `--hypervisor gunyah[...]` | 512K 以上才值得走大頁模組;回收經 free-hook 透明還 pool |
| exceed policy | **VMM 層 `--hypervisor gunyah[exceed-policy=fail\|fallback-4k\|fallback-normal]`** | 共享 reserve pool 實體耗盡的行為;pool 跨 VM 共享故歸 VMM |
| 顯存上限 | **host-runtime per-proxy 選填 `size-mb` / `size-hp-mb`**(api-only);超過 → **guest OOM** | 這台 VM 的 cap(≠ pool 耗盡);大頁算 ceil,size-hp-mb 只算大頁供給部分 |
| below-4GB | **掉出本 scope** —— 是 **guest CPU VA**(gfxstream ICD `mmap` 逼低,`GFXSTREAM_MAP_LOW` env / VK capture-replay),**與 GPA/crosvm/CLI 無關**。64-bit 正常走 | 見下節「below-4GB」;非記憶體模型的事 |
| vram 預設派生 | unprot→`guest-runtime`;gunyah-prot+native→`pre-alloc`;gunyah-prot+api→`pre-alloc`(可覆寫 host-runtime) | 派生表 |
| 後端 | `kvm`/`gunyah` 用既有;`gzvm`=既有 `geniezone` 直接接;`pkvm`=placeholder(`unimplemented!`+TODO) | gzvm 已存在非 placeholder |
| native+host-runtime | **parse 期報錯**(gunyah memparcel 上限) | 理論可、實務擋 |

---

# 總結 — 三層模型 / CLI / 實作清單

## 三層
- **VMM 層:runtime dynamic-memory(share/unshare)** = `add_memory_region`/`remove_memory_region`
  (通用,收編 gunyah fork)。gunyah 實現**依賴 host 模組(gunyah_share → /dev/gunyah_share)
  + guest 模組(gunyah_guest → accept/release)**。參數:`hugepage-threshold-kb`(預設 2048)。
- **GPU 層:vram-allocate(3 態,per-proxy)**
  | 模式 | 擁有者 | 機制 | 需要 |
  |---|---|---|---|
  | `guest-runtime-alloc` | guest | BLOB_MEM_GUEST+attach_iov | **unprotected**;**= 原版 crosvm,零 fork 邏輯** |
  | `pre-alloc` | host | 祝福 arena,guest 映射 | (params size-mb/shmem-kb) |
  | `host-runtime-alloc` | host/塊 | VMM `add_memory_region` runtime share | **依賴 VMM share**;**API-only** |
- **GPU 層:proxy level** = `api:{virgl|venus|gfxstream-*}` vs `native:{kgsl|msm|kbase}`。

## 約束矩陣(vram-alloc × proxy)
| proxy | guest-runtime | pre-alloc | host-runtime |
|---|---|---|---|
| **api** | ✓(unprot) | ✓ | ✓(依賴 VMM share) |
| **native-context** | ✓(unprot) | ✓ | ✗ **block 擋掉**(海量小 BO 超過 gunyah memparcel 上限;理論可、實務擋) |

## 共存(兩 proxy 都 pre-alloc)
→ **開兩塊獨立 arena**(兩個 memfd / 兩段 GPA),**reserved-memory DTB 節點名要不同**
(如 `kgsl-pool` vs `gfxstream-pool`),VM 內驅動才不會抓錯池。

## CLI(草案)
```
--hypervisor gunyah[hugepage-threshold-kb=512,exceed-policy=fallback-4k]   # backend B + 大頁閾值 + pool 耗盡策略
--protected-vm-without-firmware                  # protection(crosvm 既有)
--gpu proxy=[ native:kgsl[vram=pre-alloc,size-mb=1024,shmem-kb=64],
              api:venus[vram=host-runtime,size-mb=2048,size-hp-mb=1024] ]  # host-runtime 選填顯存 cap;超→guest OOM
```
(below-4GB 不是 CLI —— 見下,是 gfxstream per-request 屬性。)
vram 多數派生:unprot 預設 guest-runtime(=原版);gunyah-prot+native 強制 pre-alloc;
gunyah-prot+api 預設 pre-alloc、可覆寫 host-runtime。native+host-runtime → parse 期報錯。

## 實作清單(檔案 → 改動)
1. `hypervisor/src/lib.rs` — `add_memory_region -> AttachedRegion{slot, accept_token:Option}`;
   刪 `supports_blob_share`/`share_blob`/`unshare_blob`;加 `supports_runtime_memory_attach()`。
2. `hypervisor/src/gunyah/mod.rs` — share_blob 折進 add_memory_region(prot→SHARE_BLOB+token;
   unprot→memslot);unshare_blob 折進 remove_memory_region(label=gpa>>12);
   `supports_runtime_memory_attach` = prot ? `/dev/gunyah_share` 存在 : true。
   **多池**:prepare_blob_arena 支援 N 塊 + 各自 DTB reserved-memory 節點名。
3. `hypervisor/src/gunyah/mthp.rs`(+ backing helper)— `hugepage-threshold-kb`(預設 512)+
   **`exceed-policy`(VMM 層,pool 耗盡:fail/fallback-4k/fallback-normal)**;
   size≥閾值 → **大頁供給模式**:ceil `2MB*N` + `MADV_HUGEPAGE` → order-9 → `gh_hugepage_reserve`
   供給。mode-aware backing 型別:大頁模式的 `MappedRegion::Drop` = munmap 整 span(free-hook 自動
   還 pool),小頁 = 普通 munmap。
4. `hypervisor/src/kvm|geniezone` — 回傳型別跟上(accept_token=None),其餘不動。
5. `vm_control/src/lib.rs` — RegisterMemory 兩 fork→單 `add_memory_region`;
   UnregisterMemory 兩 fork→單 `remove_memory_region(region_id)`;
   host-runtime 選了但 `!supports_runtime_memory_attach()` → fatal exit;
   `RegisterMemoryForBlob` response **加 `hp_bytes: u64`**(**非 Option**;`0`=沒走大頁/fallback/KVM)
   供 proxy 簿記。4 個 construct 點(866/919/943/993,fork-collapse 後變少)補值、3 個填 0;
   consumer(api.rs:114)不需要就用 `..`。
6. `devices/src/virtio/gpu/` — `VramAllocMode{GuestRuntime|PreAlloc{..}|HostRuntime{size_mb?, size_hp_mb?}}`
   per-proxy;guest-runtime 走上游 BLOB_MEM_GUEST 路(需 unprot);host-runtime 走 VMM share +
   依閾值選 backing 供給模式(小頁/大頁);**顯存簿記**(兩計數器,依 response 回傳的**實際** hp_bytes
   累加——非 threshold 預測,因 fallback 會降級;alloc 前查 cap→超則 **guest OOM** 不 alloc,free 遞減);
   `threshold<0`→全小頁(size-hp 恆 0);**guard**:native + host-runtime → 拒絕。
7. proxy 分類(`rutabaga_gfx` / gpu)— `GraphicsProxy{Api|NativeContext(driver)|CrossDomain}`;
   native driver 顯式;renderer 派生。
8. `src/crosvm/cmdline.rs`/`config.rs` — 新 arg + deprecation alias
   (`context-types=`/`blob_mode=`/`gunyah-pvm=`/`NCTX_*`)。

---

# Runtime dynamic-memory API 約定(通用,非 GPU/非 protection 專屬)

> 修正(2026-07-20):runtime share/unshare **不是新 API**。它就是通用原語
> `Vm::add_memory_region` / `remove_memory_region`——「動態把 host 記憶體掛進運行中
> 的 guest」。每個 backend 都有實作,protection 是 backend 內部細節。gunyah 的
> `supports_blob_share`/`share_blob`/`unshare_blob` 是**該刪的平行 fork**。

pre-alloc 是開機祝福一塊(blob_fixed_map / prepare_blob_arena),走**啟動路徑**、不動態掛。
runtime(`gunyah-share`)= 每塊 region 開機後動態 `add_memory_region`。

## 通用 API(已存在的 Vm trait,無需新增)
```
add_memory_region(gpa, region: Box<dyn MappedRegion>, ro, ...) -> Result<MemSlot|Token>
    // 動態掛一塊。KVM: KVM_SET_USER_MEMORY_REGION;gzvm: GZVM_SET_USER_MEMORY_REGION;
    // gunyah: runtime SHARE。protection 在各 backend 內部分支(gunyah 已讀
    // protection_type.isolates_memory())。protected 需回傳 guest 要 accept 的 token
    // (parcel handle)——唯一與保護相關的差異,落在回傳值,不是另一套 API。
remove_memory_region(slot) -> Result<Box<dyn MappedRegion>>
    // 對應 unshare。KVM/gzvm: 刪 memslot;gunyah: GHSM_UNSHARE_BLOB / 保留(SHARE 不可逆)。
```
**收編動作**:把 gunyah 的 `share_blob`/`unshare_blob`/`supports_blob_share` 折進
gunyah 的 `add_memory_region`/`remove_memory_region`(protected → SHARE_BLOB+回 token;
unprotected → 純 memslot SHARE)。vm_control 的 `RegisterMemory` 只呼叫通用 op。

**回傳型別定案**:`MemSlot = u32`(純 slot 索引,給 remove 用),塞不下 token。
但 response `RegisterMemoryForBlob { region_id, slot, gunyah_handle: Option }` 本來就把
slot 跟 token 當並列欄位。而且現況:**protected SHARE 的 slot 是 dummy 0**(SHARE 不可逆,
移除走 `unshare_blob(label=gpa>>12)` 而非 slot)。故:
```
add_memory_region -> Result<AttachedRegion { slot: MemSlot, accept_token: Option<u64> }>
   KVM / gzvm / gunyah-unprotected → { real_slot, None }
   gunyah-protected               → { 0/dummy,  Some(token) }
```
不用 enum(不假設互斥)、不用側通道(response 本就雙欄位)。token 不污染 MemSlot 語意。

## Unshare / 生命週期(對稱於 share,收編同一條)
`remove_memory_region` **keyed on `region_id`(= gpa,`VmMemoryRegionId(GuestAddress)`)**,
不是 raw slot。backend 內部把 region_id 對應到自己的 slot(可逆)或 label=gpa>>12(protected SHARE)。
→ `vm_control` 的兩條 `UnregisterMemory` fork(`if supports_blob_share {unshare_blob} else {remove_memory_region}`)
**收編成一條** `remove_memory_region(region_id)`,對稱於 register 的收編。

**追蹤粒度 = VkDeviceMemory(guest ICD)**:每個 host-visible `VkDeviceMemory` 持有它用到的
share(s)(= virtio-gpu blob resource id 的集合)。`vkFreeMemory` →
1. **VM-internal release**:guest 驅動 `gunyah_guest_mem_release` 放掉自己的 stage-2 acceptance;
2. 送 virtio-gpu UNMAP/RESOURCE_UNREF → `UnregisterMemory(gpa)`;
3. **host unshare**:`remove_memory_region(gpa)` → gunyah `gh_rm_mem_reclaim` / KVM 刪 memslot。

**順序不可反**(release 在前、unshare 在後):host 先 unshare 會 RM 拒收 / guest 對已回收的
stage-2 SIGBUS。此 invariant 已在 virtio_gpu.rs:1387 enforced,統一模型維持不變。
一個 VkDeviceMemory 可能引用多個 share → 追成 set,銷毀時全部 release+unshare。

**適用範圍**:只有 `gunyah-share`(gfxstream/venus API-proxy)走這條 per-VkDeviceMemory unshare。
**pre-alloc(kgsl)無此流程**:arena 開機祝福一次、VM 結束才隱式收回;個別 BO / VkDeviceMemory
的釋放是純頁表(guest 端 fence-gated 歸還池),零 host round-trip、零 unshare。

## 能力查詢(取代 supports_blob_share;非 protection 軸)
```
supports_runtime_memory_attach(&self) -> bool
    // 這個 backend + 這台 guest 配置,能不能「開機後」動態掛記憶體。
    //   KVM / gzvm            : 恆 true(memslot 本就動態)
    //   gunyah unprotected    : true(runtime SHARE)
    //   gunyah protected      : 需 /dev/gunyah_share 存在(host-share kmod);缺 → false
```
這是 backend 的**能力**,不是使用者填的軸,也不 key 在 protection 上——protection 只是
gunyah 判斷「要不要 kmod」的內部條件之一。

## 參數 — 大頁閾值 + 兩種供給模式(per-region)
`hugepage-threshold-kb`(**預設 512**)= size 切點。share region 時依 size 選供給模式:
- **`< 512K` → 小頁供給**:4K 普通 backing。
- **`≥ 512K` → 大頁供給模式**:size **ceil 到 `2MB*N`**,`MADV_HUGEPAGE` → **order-9 fault** →
  **`gh_hugepage_reserve` 模組**(在 `../gh-hugepage-reserve`)的 supply hook 攔截、從 reserve
  pool 供 2MB 塊。例:2.2M→4M(N=2)、0.6M→2M(N=1)。

**回收依供給模式**(mode-aware,編在 backing `Box<dyn MappedRegion>` 的 `Drop`):
- 大頁模式:`remove_memory_region` → gh reclaim(`GH_VM_RECLAIM_REGION`)→ **整個 `2MB*N` span
  一次 munmap**。**還給 pool 是透明的**:模組的 `android_vh_free_one_page_bypass` free-hook
  自動攔 order-9 free、收回 reserve pool —— crosvm 不用顯式呼叫模組,只要 munmap 整 span。
- 小頁模式:普通 munmap(4K,不被 free-hook 攔)。
- (模組自身 knobs:`refill_enable`(VM 關機後 auto alloc-back)、`cma_reservoir_floor_mb` 等,
  管 pool 補充/CMA floor;crosvm 不碰,只負責 munmap 整塊 + exceed-policy。)

**兩個獨立限制,別混:**
- **`exceed-policy`(VMM 層,`--hypervisor gunyah[...]`)**:**共享** `gh_hugepage_reserve` pool
  實體供不出 2MB 塊時的行為 → `fail`(ENOMEM)/ `fallback-4k`(退小頁)/ `fallback-normal`。
  pool 跨 VM/系統共享,故歸 VMM。
- **`size-mb` / `size-hp-mb`(host-runtime 的 per-proxy 選填,api-only)**:這台 VM 的**顯存上限**。
  超過 → **回報 guest OOM**(`VK_ERROR_OUT_OF_DEVICE_MEMORY`),不 fallback。

**檢查順序**:host-runtime alloc → ①查 VM cap(超 → OOM,不 alloc)→ ②cap 內試供給(pool 耗盡 → exceed-policy)。

**用量統計(accounting,host-runtime 層兩計數器,free 遞減):**
- 大頁模式算 **ceil'd 大小**(1.5M→2M);小頁算實際(ceil 4K)。
- `size-mb` = 全部(小頁 + 大頁 ceil);`size-hp-mb` = **只算走大頁供給的部分**。
- 例:一個 10K + 一個 1.5M → `size-mb` = 10K + 2M;`size-hp-mb` = 2M。
- `size-hp-mb ≤ size-mb` 恆成立(hugepage 是子集);size-hp-mb 專門限制這台 VM 吃多少稀缺 2MB reserve。

**大頁供給 = gunyah 獨有;`hugepage-threshold-kb=-1` 自然關閉。** `threshold < 0` → 永不觸發大頁 →
全小頁 → size-hp-mb 恆 0(形同無效)。且 threshold 本就掛 `--hypervisor gunyah[...]`;KVM/gzvm
沒這 param、也沒 `gh_hugepage_reserve`,所以其他家不是「關閉」而是**概念不存在**。

**proxy 必須拿「實際」供給結果,不能用 threshold 預測。** 陷阱:`exceed-policy=fallback-4k`
會把本應大頁的 alloc **降級成小頁**(1.5M 請求 → pool 耗盡 → 實際小頁 → size-hp-mb 該算 0 非 2M)。
→ **backing alloc 的實際結果(`hp_bytes` / mode)隨 `RegisterMemory` response 回傳給 proxy**
(`RegisterMemoryForBlob` 加欄位);proxy 依實際 hp_bytes 累加 size-hp-mb,region 記 accounted
sizes、free 時遞減同值。threshold=-1→hp_bytes=0;正常大頁→ceil(2M*N);fallback→0。都一致。

→ 取代今天全域 `--prepare-lend-mthp-mode chunked`,改 **per-region 依 size 閾值**選模式。
供給模式 + ceil + 整塊回收全在 backing;`add/remove_memory_region` 保持 mode-agnostic。

## add_memory_region 表達力(placement 夠;與 below-4GB 無關)
`add_memory_region(guest_addr, mem_region, ...)`:`guest_addr` 落點由呼叫端 `VmMemoryDestination`
指定(`GuestPhysicalAddress(gpa)` / `ExistingAllocation{bar,offset}`);`mem_region` = **host 頁
backing**(此 API 本質是 host-page→GPA memslot;guest 頁走另一條 `attach_iov`/BLOB_MEM_GUEST)。

## below-4GB(32-bit Wine)—— **是 guest CPU 虛擬位址,不是 GPA,整個掉出本 scope**
更正(2026-07-20,查證 fork mesa):below-4GB **與 GPA / crosvm / add_memory_region / 記憶體模型
完全無關**。它是 **guest gfxstream ICD 裡 `mmap` 落在低 CPU VA**(讓 32-bit WoW64/FEX caller 能用
32-bit 指標持有;wine win32u 拒絕 >4GB 映射)。
- 位置:guest mesa = 頂層 `mesa/`(Droid-VM/mesa v26.0.3,`8_build_guest_mesa_gfx.sh` 建)
  `src/gfxstream/guest/platform/drm/DrmVirtGpuBlob.cpp`。
- 機制:`mmap(low_slot, MAP_SHARED|MAP_FIXED_NOREPLACE, dev, map.offset)` 逼進 low-VA arena
  `[1GiB, 3.75GiB)`(recycle freed slots;滿了 fallback high mmap)。
- **mode 1 = env var `GFXSTREAM_MAP_LOW=1`**:全域強制,給沒用 VK 選項的 Wine/DXVK。
- **mode 2 = VK 選項(per-request)**:capture-replay / `VkMemoryOpaqueCaptureAddressAllocateInfo`
  (ResourceTracker.cpp);正規路。64-bit app 預設關、零影響。
→ **CMDLINE_V2 不碰它**:純 guest ICD mmap 細節,crosvm/CLI 零關聯。

## GPU 整合 — 不可用就退出
- GPU 的 **runtime-alloc 模式**(= 選了 `gunyah-share`)的 blob map 走
  `vm_control` 的 `RegisterMemory` → **只呼叫通用 `add_memory_region`**
  (今天 line 883/914 的 `if supports_blob_share { share_blob } else { add_memory_region }`
  合併成一條)。
- **移除 silent fallback**:開機時若 `mem-model == gunyah-share` 但
  `supports_runtime_memory_attach() == false`(沒裝 kmod 節點 / 後端不支援動態掛)
  → **crosvm fatal exit**,不退化、不繼續跑到 runtime 才 SIGBUS。
- pre-alloc 模式**不呼叫**動態掛(走 bless / `blob_fixed_map`);兩條互斥。

---

# v3 定稿(2026-07-22)— gfx vram-alloc 模式 + CLI(取代上文 gfx 部分的 vram= 草案)

## 修正:上游本就兩條路,開關 = `--gpu udmabuf`(前文「unprot 預設 guest-runtime」不精確)
上游(含 KVM)gating 鏈:`--gpu udmabuf`(parameters.rs,預設 false)→ virtio feature bit
`VIRTIO_GPU_F_CREATE_GUEST_HANDLE`(mod.rs ~1940)→ guest `VIRTGPU_PARAM_CREATE_GUEST_HANDLE`
→ ResourceTracker 分支(~3231):有 param → **guest-alloc**(BLOB_MEM_GUEST,guest 頁→udmabuf→
gfxstream import);無 → **host-alloc**(HOST3D deferred:host memfd→map_blob→BAR)= **上游預設**。
**我們的 fork = host-alloc 路線在 protected gunyah 的 backing 補充**(per-blob runtime-share /
boot-blessed pre-alloc 池);guest-alloc 在 pVM 原生不通(host 看不到 guest 頁)→ 以池恢復(見下)。

## 參數判準(定案)
- **init 期可推理且終身不變** → 協議常數(hardcode/capset 傳遞),**不給 CLI**。例:ASG ring 尺寸
  (`GetRingParamsFromCapset`,≈0x103000→池 granule 2MB)。
- **workload 相關、使用者調** → CLI 參數。例:池大小、host slice 預算(ring 數=context 數)。
- **位置 = 消費點最近原則,不跨層傳遞**:guest_memory_layout/DTB 消費 → top-level;
  gfxstream 消費 → `--gpu`(gfx- 前綴 = per-proxy 命名空間,kgsl-/kbase- 未來同型);
  VMM RuntimeShare 消費 → `--runtime-share`(與 GPU 解耦,GPU 只透明呼 callback)。

## CLI(v3 final)
```
--pre-alloc "gfx-mb=1024,kgsl-mb=64"       # 池大小(guest_memory_layout/DTB 消費 → top;
                                           #  env-bridge NCTX_GFX_POOL_MB/NCTX_VRAM_MB)
--gpu "...,udmabuf=<bool>,vram-limit=<MB|-1|0>,pool-blob-max-kb=4096,gfx-host-pre-alloc-mb=64"
    # udmabuf(上游):false=host-alloc(預設)/ true=guest-alloc
    # vram-limit:quota「計量 only」(0=不計、-1=∞、N=cap MB);不 gate folio/callback(解耦)
    # pool-blob-max-kb:host-alloc 分流 size gate,預設 4096 可覆寫;
    #   僅「udmabuf=false ∧ vram-limit 有定義(≠0) ∧ gfx-mb 有定義」時有效,否則強制 0(=不分流)
    # gfx-host-pre-alloc-mb:池內 host slice(從 gfx-mb 切),udmabuf=true 才有效(false 時隱含=gfx-mb);
    #   gfx 的**所有** host-alloc 請求(含 ASG ring、雜項 HOST3D)先從這發,發完才試 runtime-share
--runtime-share "hugepage-threshold-kb=512,exceed-policy=fallback|oom"   # VMM,正交
```

## 模式派生表(pVM;無 mode= 選擇器,全由參數組合派生)
| udmabuf | gfx-mb | vram-limit | 模式 | 行為 |
|---|---|---|---|---|
| true | ✓ | (強制0) | **pVM guest-alloc** | guest 驅動/mesa 從 guest-slice carve BLOB_MEM_GUEST→上游 udmabuf import;host 請求走 host-slice;固定顯存=池,滿→OOM |
| false | ✓ | ✓(-1=∞) | **host-alloc 融合** | ≤pool-blob-max→池、>→runtime-share;quota=vram-limit |
| false | ✓ | ✗ | 純 pre-alloc | 全試池(不分流),滿→OOM |
| false | ✗ | ✓ | 純 runtime-share | 全 per-blob SHARE,quota 計量 |
| false | ✗ | ✗ | 純 runtime-share(不計量) | 今日預設 |
| true | ✗ | — | 上游 unprot guest-alloc | protected 下 **parse 期報錯**(pVM guest-alloc 需要池) |

## 強制/檢查規則(parse 期)
1. `udmabuf=true` → `vram-limit:=0`、`pool-blob-max-kb:=0`(顯存上限=池本身)。
2. `protected ∧ udmabuf=true ∧ 無 gfx-mb` → 報錯。
3. `gfx-host-pre-alloc-mb ≤ gfx-mb`;udmabuf=false 時忽略(隱含=gfx-mb)。
4. `vram-limit=-1` → quota=∞ 但仍算「有定義」(可啟用分流)。

## 失敗語意(fallback ladder;呼應上文「移除 silent fallback」)
啟動期 probe `supports_runtime_memory_attach()`(= /dev/gunyah_share 節點):
- **host-alloc 模式 ∧ 模組不在** → **開機 fatal exit**(不退化、不 runtime 才炸)。
- **guest-alloc 模式**:模組在 → host-slice 發完優雅外溢 runtime-share(4K/folio share;
  每 ring 一 parcel,終點 RM ~39 上限);模組不在 → **slice=硬上限**,滿了 host 端乾淨拒絕+響亮 log
  → 該 context 的 client 拿明確 VK_ERROR(有界、單 client、VM 不死)。開機不 fatal(guest-alloc
  的意義=零模組依賴)。
- 實證:ring 映射失敗 → guest `createVirtioGpuAddressSpaceStream` return nullptr(無 pipe fallback)
  → 該 client ICD init 失敗;若是 compositor → session 掛,VM 活著。**永不卡死、不降速(無慢速替代路)**。

## 解耦修正(實作時一併)
- 拆掉「`vram-limit>0` 才註冊 folio callback」耦合:callback **永遠註冊**(純橋接 dup fd→VMM),
  VMM 依 `--runtime-share` 決定 folio;vram-limit 只決定計不計量。
  (否則 udmabuf=true 強制 vram-limit=0 會順帶讓 overflow ring 失去 folio→512-entry 重 parcel。)
- `exceed-policy=oom` 目前被 gpu/mod.rs closure `.unwrap_or(0)` 吞掉(oom 實際上=fallback)→
  接通:prepare 回負值 → gfxstream 對該 alloc 回 VK_ERROR_OUT_OF_DEVICE_MEMORY。

## pVM guest-alloc = 池分段(恢復 guest-alloc 模式)
池 = [host slice: gfx-host-pre-alloc-mb | guest slice: 其餘]。分段 init 期定、終身不變
(SHARE permanent、guest heap 初始化一次,邊界動不了;runtime 變的只是 slice 內 churn)。
guest 端:改 guest 驅動/mesa,BLOB_MEM_GUEST 只從 guest slice carve(guest 頁=池頁,host 本就
看得到 → udmabuf import 在 pVM 成立);範圍經 **capset** 一次性告知(現成 GetRingParamsFromCapset
通道)。host 端:ASG ring 等一切 host-alloc 從 host slice 配,發完 → ladder 如上。DT 節點不變(整池一塊)。

## 實作順序
1. **host-alloc 融合**(全 host 側,直接解 MC 39-parcel):CLI 參數 + env 橋
   (GFXSTREAM_POOL_BLOB_MAX_KB / GFXSTREAM_POOL_HOST_MB)+ gfxstream size gate
   (on_vkAllocateMemory 池區塊加 `size≤gate`;ring 恆池優先不受 gate)+ 解耦修正。
2. **pVM guest-alloc**:guest mesa/驅動 pool-carve + capset range 告知 + 池分段。

---

## pVM guest-alloc 實作規格(2026-07-22 定,依 codebase 測繪)

**現況 = 「host 決定 offset」全鏈**:host `HostVisiblePool::alloc()`(`gfxstream/host/vulkan/HostVisiblePool.h:81-132`)選 offset → 經 map-blob response(`VIRTIO_GPU_MAP_INFO_POOL` + `pool_offset` 塞在 `virtio_gpu_resp_map_info.gunyah_handle` overload,`virtgpu_vq.c:1385-1386`)回給 guest → guest kernel `pool_resident` vram 物件 mmap `gpu_pool_base+pool_offset`(`virtgpu_vram.c:106-117`)。guest kernel/mesa 全程被動收 offset。`GFXSTREAM_POOL_HOST_MB`(crosvm `gpu.rs:130-135` 設)**目前零消費者**——partition 是 stub。

**目標 = 把每個「收 offset」翻成「產/傳 offset」**,且整條路只在 `udmabuf=true` 觸及(host-alloc 的 `udmabuf=false` 完全不碰,MC 現狀零風險)。**安全不變量:所有新分支 gate 在 capset `guestAllocSizeBytes>0`(僅 udmabuf=true 時 host 填非零)。**

**安全門檻已知:整條 udmabuf=true 從未在 pVM 跑通(memory: gfxstream-prealloc-blocked-protected),故驗證需完整 bringup,非增量。**

### 六段實作(依賴序;每段可獨立 build,但 e2e 驗證需全鏈)

1. **[A] capset guest-slice range**(host+協議,自足可驗,已做):`vulkanCapset` 兩份(`mesa/src/virtio/virtio-gpu/virtgpu_gfxstream_protocol.h` + `gfxstream/host/virtgpu_gfxstream_protocol.h`)尾端加 `guestAllocOffsetBytes` `guestAllocSizeBytes`(u64,拆 hi/lo u32 保持 4-byte 佈局)。`VirtioGpuFrontend.cpp fillCaps`(~:609 後)讀 `GFXSTREAM_POOL_SIZE`+`GFXSTREAM_POOL_HOST_MB`:host-slice=`[0,HOST_MB*1MB)`、guest-slice=`[HOST_MB*1MB, poolSize)`;填 offset=`HOST_MB<<20`、size=`poolSize-(HOST_MB<<20)`;`GFXSTREAM_POOL_HOST_MB` 缺(udmabuf=false)則兩者=0。**驗證:guest 讀 capset 印出 range**(mesa init log 或臨時 ioctl dump)。

2. **[B] mesa guest 端 offset allocator + carve**:`ResourceTracker` 加一個 free-map 子分配器(鏡像 `HostVisiblePool` 演算法),range 從 `mCaps.vulkanCapset.guestAlloc*`(`DrmVirtGpuDevice.cpp:212-236` 已讀整個 capset,新欄位自動到位)。`on_vkAllocateMemory` 的 `kParamCreateGuestHandle` 分支(`ResourceTracker.cpp:3265-3297`):`guestAllocSizeBytes>0` 時先 `carveOffset=allocator.alloc(size,align)`,失敗→ OOM(池滿=固定顯存耗盡,不外溢);把 `carveOffset` 經新欄位往下傳。`on_vkFreeMemory` 釋回。**guest 此時即知剩餘量(allocator free 總和)——這就是 task-3 括號問的「vm 知道剩餘」的來源。**

3. **[C] VirtGpuCreateBlob + DRM uAPI 帶 offset**:`VirtGpu.h:97-105 VirtGpuCreateBlob` 加 `uint64_t poolOffset`(預設 ~0 = 無);`DrmVirtGpuDevice.cpp:308-327` 映到 `drm_virtgpu_resource_create_blob`。**uAPI 無 offset 欄位**——fork 自有 guest kernel,擴充 `drm_virtgpu_resource_create_blob`(尾端加 `__u64 pool_offset`,`__u32 pad` 對齊;舊 ABI 相容因新欄位在尾且 0=無)。

4. **[kernel] create-from-guest-offset**:`virtgpu_ioctl.c:542-547` 路由——guest-alloc pool blob 要走 vram 路(現 `guest_blob` 走 shmem)。加新分支:`guest_blob && pool_offset!=~0` → `virtio_gpu_vram_create`(而非 `virtio_gpu_object_create`)。`virtgpu_vram.c:241-289`:`pool_offset` 有值時**跳過** `host_visible_mm` insert,直接 `vram->pool_resident=true; vram->pool_offset=guest_offset`;`virtio_gpu_cmd_resource_create_blob`(`virtgpu_vq.c:1444-1474`)command 加 offset 欄位傳 host。mmap 路已支援 pool_resident(`virtgpu_vram.c:106-117`)。**guest kernel 這端 mmap `gpu_pool_base+guest_offset` 即池頁,host 本就 SHARE-blessed 看得到。**

5. **[host] hon'or guest offset**:`VkDecoderGlobalState.cpp:6706-6762`——`udmabuf` 且 blob 帶 guest pool_offset 時**跳過 `hvPool->alloc()`**,直接 `poolOffset=guest_offset`(驗證落在 guest-slice 內),`handleFromFd(memfd, memfdBase()+guest_offset, size)`。rutabaga/crosvm return 路(`virtio_gpu.rs:1291-1308`)已會回報 POOL+offset,重用。

6. **[budget in guest-alloc 模式]**(呼應 task-3 括號):host-alloc 模式 budget 在 host 側填(task 2 完成)。**guest-alloc 模式:guest 是 allocator、host 不知 usage** → budget 該 guest 側填。但 entrypoint `gfxstream_vk_GetPhysicalDeviceMemoryProperties2`(生成 `func_table.cpp`)直接走 encoder 到 host,guest `ResourceTracker::on_...2` 是死碼(見 [[pin-enomem-and-vk-memory-budget]])。兩選項:(a) guest allocator 的 used/free 經既有 metadata command 回傳 host,host 側 override 讀之(統一在 host 填,較省);(b) 攔截 entrypoint(改生成碼模板,較重)。**建議 (a)**:guest-alloc 時 host 的 `sOutstandingFolioBytes` 換成「guest allocator 回報的 used」,`overrideHostVisibleMemoryBudget` 邏輯不變。→ task-3 括號答案:**能暴露,走 host-side override + guest 回報 used,不需碰 func_table。**

### offset 傳遞通道:兩條都非輕量(2026-07-22 確認)
guest allocator 選的 offset 要同時到 host(backing)與 guest kernel(mmap `gpu_pool_base+offset`)。兩條可行通道:
- **(甲)DRM uAPI**:`drm_virtgpu_resource_create_blob` 尾加 `__u64 pool_offset` → guest kernel 新 create-from-offset 分支 → command 傳 host。**需 guest kernel 改 + initrd surgery**([[kgsl-initrd-kmod-deploy]]),碰 boot 路徑。
- **(乙)VkCreateBlobGOOGLE hint**:offset 走 `VkCreateBlobGOOGLE`(chain 進 VkMemoryAllocateInfo,encoder marshal 到 host)→ host 用 guest offset 取代 `hvPool->alloc()` → map response 循現有路把 offset 回給 kernel(重用 `pool_resident`,**免 kernel/initrd**)。**但 `VkCreateBlobGOOGLE` 是 cereal codegen 生成**(goldfish_vk_marshaling/deepcopy/transform 全生成),加欄位要重跑雙邊 codegen 管線(脆弱,見 memory mesa 擴充警告)。
→ **(乙)風險較低(免內核/initrd、gate 在 udmabuf=true 對現 MC 零回歸),但仍需 codegen 改 + 未跑通的 udmabuf=true bringup**。非快速 patch。

### 已做 / 待做
- **[A] capset range:已實作+驗證+commit**(gfxstream `3a87054` / mesa / plans;udmabuf=false→0/0、udmabuf=true+host-mb=64→64/192)。啟用了死 stub `GFXSTREAM_POOL_HOST_MB`。
- **[B]~[6]:規格如上,為完整 udmabuf=true bringup**(通道甲=kernel+initrd 或 乙=cereal codegen;+ mesa sub-allocator + host honor-offset + 全鏈 e2e)。**udmabuf=true 在 pVM 從未跑通**([[gfxstream-prealloc-blocked-protected]]),故為 deliberate 大工程,非增量;與 host-alloc(現 MC 41fps 路)完全 gate 解耦、inert。建議走通道乙。
