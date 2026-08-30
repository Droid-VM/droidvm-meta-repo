## virglrenderer pre-graft range — base 8220efec (AOSP snapshot) .. f6a66611  13 commits, 57 net files

Repo: `/root/Documents/DroidVM_meta/crosvm_build/external/virglrenderer` (remote `droidvm` = Droid-VM/virglrenderer). Clone is now unshallowed, so the old graft point f6a66611 and everything below it is inspectable.

Base **8220efec** = AOSP `external/virglrenderer` snapshot ("Snap for 14055258 … 25Q4-release", 2025-09-05) — *not* DroidVM work. It already carries a **stale** copy of the src/drm native-context framework (`.clang-format`, `drm-uapi/msm_drm.h`, `drm_fence.{c,h}`, `drm_renderer.{c,h}`, `drm_util.{c,h}`, `linux/overflow.h`, `msm/msm_proto.h`, `msm/msm_renderer.{c,h}`) with `ENABLE_DRM` **off**.

Net diff `8220efec..f6a66611`: **57 files, +20 378 / −595**. Of those 57, **all 57 still exist at c7fd533**, three under new names (`src/drm/kgsl/*` → `src/drm/drm2kgsl/*`, renamed later by a7bcdd66).

This section slots **before** the existing `plans/pr-flatten/virglrenderer.md` (base f6a6661 .. c7fd533, 28 commits). Its `#` ids are `P1..P9`; when merged, they precede L1/M1/G1…/D1…/V1… and the existing G/D numbering shifts. Subject style follows the repo: `area: what`, lower-case imperative.

### Proposed flattened commits (in order)

| # | bucket | proposed subject | folds original commits | Co-authored-by | net files | notes |
|---|--------|------------------|------------------------|----------------|-----------|-------|
| P1 | G | `virgl: disable dual-source blend on Adreno GLES` | b9881a0c (**lateautumn233**) | `Co-authored-by: lateautumn233 <lateautumn233@foxmail.com>` | src/vrend_renderer.c | Per the new rule this is **not** kept as a separate authored commit — HuJK authors it, the trailer credits lateautumn233. Only commit in the range touching the virgl2/GL renderer; nothing else in either range pairs with it, so it stands alone. Survives verbatim at c7fd533 (`has_feature()` `#ifdef __ANDROID__` early-out). Also strips a trailing blank line at EOF — cosmetic, drop that hunk. Route-agnostic (G): the virgl2 context serves UEFI/fbcon/VNC on **all three** routes. |
| P2 | G | `virgl: vendor the upstream DRM native-context framework (src/drm) at <upstream ref — TBD>` | d97194c6 (**upstream-file part only**) | — | 47 A + 10 M (see below) | **This is a back-port, not new code.** ~99.6 % of d97194c6 is upstream virglrenderer MIT source copied over the stale AOSP copy. Should be a byte-identical `cp -r` of upstream `src/drm` + `src/virgl_fence.{c,h}` + `src/mesa/util/libsync.h` so a reviewer can `diff -r`. **The upstream ref is recorded nowhere in-tree** — `src/drm/drm-uapi/README` is upstream Mesa's own README, and the sibling `/root/…/virglrenderer/` checkout is another DroidVM clone, not upstream. It must be recovered (network) and pinned in the subject/body. Feature markers that bound it: `drm_context.c` exists as its own file; asahi + panfrost + i915 + amdgpu backends present; `virgl_prefixed_logv` leveled logging; `DRM_ALIGN_4`; `vdrm_ccmd_req`/`vdrm_shmem` in drm_hw.h → upstream `main`, mid-2025, well after 1.1.1. |
| P3 | G | `drm: back-port the native-context framework onto the vendored virgl core` | d97194c6 (**DroidVM adaptation part**), 051b87d4, 095e085b | — | Android.bp, prebuilt-intermediates/config.h, src/virgl_util.h, src/virglrenderer.c + adaptation hunks inside src/drm/drm_renderer.c, drm_fence.c, drm_context.c, src/virgl_fence.c | The ~72 DroidVM-written lines that make P2's upstream copy build and run on this older core: leveled-log compat shim + `virgl_log_level_flags` in virgl_util.h; `TRACE_SCOPE_BEGIN/END` given values; `hash_table_search` → `_mesa_hash_table_search` with u32 key casts; `virgl_fence.c` u64-table destroy/foreach adapted to the vendored `hash_table_u64` API; `get_device_fd` vtable assignment dropped (absent from this core); `DRM_IOCTL_SET_CLIENT_NAME` `#ifdef`-guarded (not in Android libdrm); `drm_renderer_create(..., drm_fd)` with a `fd < 0` → `drmOpenWithType` fallback and the caller passing −1; `<inttypes.h>` in drm_fence.c; `ENABLE_DRM 1` / `ENABLE_DRM_MSM` off in config.h; framework sources + `libdrm_headers` in Android.bp. **051b87d4** is a pure build fixup of d97194c6 (dedup the log enum, `PRIu64`) → folds. **095e085b** restores `virgl_fence_table_init/cleanup` in `virgl_renderer_init` — a *vendoring omission*; in a flatten the omission simply never happens, so it folds here rather than being its own "fix" commit. Note it is also the real root-cause fix for the crosvm `exit(1)`-after-first-submit that motivated the `NCTX_NO_FENCE` knob (P9). |
| P4 | D | `drm2kgsl: msm-protocol native-context backend over KGSL` | 147dea51, c1aa016c, e9c0801b, f0453560 (5d79e781 nets to zero, see below) | — | src/drm/drm2kgsl/drm2kgsl_renderer.c (was src/drm/kgsl/kgsl_renderer.c), .h, src/drm/drm2kgsl/msm_kgsl.h + hunks in src/drm/drm_renderer.c, Android.bp, prebuilt-intermediates/config.h | The actual DroidVM invention: an msm-protocol (`msm_proto.h`) server reimplemented on KGSL ioctls, so a stock freedreno/turnip guest over vdrm never learns the host has no drm/msm. Bridges guest-assigned iova (one VBO + `GPUMEM_BIND_RANGES`), import-only memory, and guest-assigned fence seqno (`KGSL_CONTEXT_USER_GENERATED_TS`). Fold the three same-day on-device fixes — each **supersedes** part of 147dea51 rather than adding a feature (see net-zero list). **Name it `drm2kgsl` from birth** (`src/drm/drm2kgsl/drm2kgsl_renderer.{c,h}`, `ENABLE_DRM2KGSL`, `CROSVM_DRM2KGSL_*`): that erases the whole post-graft **D1** rename commit (a7bcdd66 + c9011324) and resolves open questions #3/#4 of the existing plan. **Do not introduce the host BO allocator** (`kgsl_dma_heap_alloc`, `dma_heap_path`, `kctx->dma_heap_fd`) — dead at HEAD (see net-zero). Copyright header is "Copyright 2022 Google LLC / Copyright 2026 DroidVM, MIT" (msm_renderer.c derived), which the later L1 licensing commit keeps as an MIT exception. |
| P5 | D | `drm2kgsl: never explicitly unbind VBO ranges (msm BO-lifetime semantics)` | 26348f9d (**unbind hunks only**) | — | src/drm/drm2kgsl/drm2kgsl_renderer.c | Guest turnip frees a BO right after queueing a submit that still references it (drm/msm pins submit BOs until retire). Eager `BIND_RANGES` unbinds yanked mappings mid-flight → deterministic `CP DDE BR opcode error | opcode=0x00000000`. KGSL's VBO machinery makes not-unbinding correct (a bind refs the child; a later overlapping bind splits/removes stale ranges). **`kgsl_vbo_unbind()` becomes unused here and is still dead at c7fd533 — delete the function instead of tagging it `UNUSED`.** |
| P6 | D | `drm2kgsl: import every BO IO-coherent` | 26348f9d (**cache-flag hunk only**) | — | src/drm/drm2kgsl/drm2kgsl_renderer.c | Split out of 26348f9d: a distinct correctness fix with its own rationale. The guest CPU writes BOs through its own stage-1 mapping and nothing on this path issues KGSL cache maintenance (real turnip does `GPUOBJ_SYNC`; a vdrm guest cannot), so a non-snooping GPU read saw stale DRAM → smashed desktop geometry. `kgsl_flags = KGSL_MEMFLAGS_IOCOHERENT` unconditionally, regardless of the guest's `MSM_BO_CACHED*` bits. Live at c7fd533 (two sites). Keep separate from P5 — the commit message of 26348f9d only mentions the unbind story, so the cache change is currently undocumented. |
| P7 | D | `drm2kgsl: per-context VA slices — fix cross-client VBO iova collisions` | f6a66611 | — | src/drm/drm2kgsl/drm2kgsl_renderer.c | KGSL pagetables are per-process, so every guest process's turnip shared one host VBO and overlapping binds silently overwrote each other. Disjoint 8 GB slice per context (bitmask-allocated, released on destroy), handed to the guest via `GET_PARAM MSM_PARAM_VA_START/VA_SIZE`. **Direct dependency of post-graft D3** (6ea764b/9c82cb0/dc0fca0/4b95636 rework this into 64 granted-VBO-derived slices). Requires the matching patched guest turnip/gallium — cross-repo note for the body. |
| P8 | G | `virgl: serve transfers on pipe-less blob resources with a CPU copy` | c58b5266 (**src/virglrenderer.c hunks only**) | — | src/virglrenderer.c | crosvm's VNC/screenshot readback cannot import dmabufs, so scanout flush falls back to `transfer_read` with ctx_id 0, which `EINVAL`'d for blob resources with no vrend `pipe_resource` → every `ResourceFlush` failed `ComponentError(22)`, display black. `virgl_resource_transfer_blob()` copies between the blob's mapping (or a transient mmap) and the iov as a linear 32bpp image. **Post-graft G3 (eb20aa10) patches exactly this function** (map at `fd_offset`, not 0) — P8 must precede it. Bucket G: core code, and venus pool blobs are also SHM+fd_offset resources that can reach it. |
| P9 | D | *(drop candidate)* `drm2kgsl: IB visibility/scan probes and the NCTX_NO_FENCE gate` | 26348f9d (**probe hunks**), c58b5266 (**NCTX_NO_FENCE hunk**) | — | src/drm/drm2kgsl/drm2kgsl_renderer.c | `NCTX_IB_CHECK` (dump IB head/tail dwords at submit) and `NCTX_IB_SCAN` (walk IB1 for `CP_INDIRECT_BUFFER`, check each IB2 target against the object table) — investigation scaffolding for the CP-reads-zeros fault, same family as the existing plan's **D5** which is already a drop candidate; post-graft 4b95636's fault-scan probes hang off these. `NCTX_NO_FENCE` was an A/B for a crash that **P3 (095e085b) actually fixed**; the knob outlived its reason. All three still exist at c7fd533. If dropped, post-graft **D4**'s comment referencing `NCTX_NO_FENCE` needs a one-word edit. |

Suggested order: **P1 · P2 P3 P8 · P4 P5 P6 P7** (P9 dropped), then the existing L1 · M1 · G1…G4 · D1…D8 · V1…V5 — with post-graft **D1 (rename) deleted** if P4 is born as `drm2kgsl`.

#### P2 net-file breakdown (the vendoring)

*Added, pristine upstream (47):* `src/drm/amdgpu/{amdgpu_renderer.c,amdgpu_renderer.h,amdgpu_virtio_proto.h}` · `src/drm/asahi/{asahi_proto.h,asahi_renderer.c,asahi_renderer.h}` · `src/drm/drm-uapi/{README,amdgpu_drm.h,asahi_drm.h,drm.h,drm_mode.h,i915_drm.h,panfrost_drm.h,virtgpu_drm.h}` · `src/drm/drm_context.{c,h}` · `src/drm/i915/{i915_ccmd.c,i915_ccmd.h,i915_object.c,i915_object.h,i915_proto.h,i915_renderer.c,i915_renderer.h,i915_resource.c,i915_resource.h}` · `src/drm/panfrost/{panfrost_ccmd.c,panfrost_ccmd.h,panfrost_object.c,panfrost_object.h,panfrost_proto.h,panfrost_renderer.c,panfrost_renderer.h,panfrost_resource.c,panfrost_resource.h}` · `src/mesa/util/libsync.h` · `src/virgl_fence.{c,h}`
*Modified, upstream sync over the stale AOSP copy (10):* `src/drm/.clang-format` (dedup `Cpp11BracedListStyle`) · `src/drm/drm-uapi/msm_drm.h` · `src/drm/drm_fence.{c,h}` · `src/drm/drm_renderer.{c,h}` · `src/drm/drm_util.{c,h}` · `src/drm/msm/msm_proto.h` · `src/drm/msm/msm_renderer.{c,h}` · `src/drm_hw.h`

#### How much of d97194c6 is upstream vs DroidVM-written

| | files | lines |
|---|---|---|
| d97194c6 total | 53 | +16 336 / −592 |
| upstream code copied in (P2) | 47 A + 10 M | ≈ **+16 264 / −586** |
| DroidVM-written adaptation (P3) | 5 files whole + hunks in 4 vendored files | ≈ **+72 / −6** (Android.bp +9, config.h +3/−2, .clang-format −1, virgl_util.h +37/−2, virglrenderer.c +2/−1, drm_renderer.c ≈+10, virgl_fence.c ≈+8, drm_context.c ≈+2, drm_fence.c ≈+2) |

→ **≈ 99.6 % of d97194c6 is a straight vendoring of upstream virglrenderer's `src/drm`.** It must not be presented as DroidVM work, and the vendoring must be its own commit (P2) so the KGSL backend (P4) is reviewable on its own. Caveat: splitting P2/P3 exactly requires the upstream ref, because ~22 of the DroidVM lines sit *inside* otherwise-pristine vendored files (drm_renderer.c, drm_context.c, drm_fence.c, virgl_fence.c). If the ref cannot be recovered, keep d97194c6 as one commit but say plainly in the body that it is a vendoring and list those ~72 lines.

### Nets to zero

**Within this range (8220efec..f6a66611)**

- **5d79e781 in full** — its 11-line `NOTE (unsolved)` comment about the `ZONE_MOVABLE` / `FOLL_LONGTERM` pin blocker is deleted verbatim by c58b5266 six hours later. Drop the commit; the analysis belongs in a PR/issue, not the tree.
- **147dea51's per-context VBO** ↔ **e9c0801b's single global VBO** — cancel inside P4 (the per-context assumption broke once virgl2 also allocated GPU VA).
- **147dea51's `GPUOBJ_ALLOC` `size=0` + `va_len`** ↔ **c1aa016c's `size = range`** — cancel inside P4 (kernel rejects a 0-byte object).
- **147dea51's `TYPE_VK | PER_CONTEXT_TS |` priority-band drawctxt flags** ↔ **f0453560's `SAVE_GMEM | NO_GMEM_ALLOC | PREAMBLE | USER_GENERATED_TS`** — cancel inside P4 (`DRAWCTXT_CREATE` EINVAL).
- **147dea51's `kgsl_dma_heap_alloc()` call in GEM_NEW** ↔ **c58b5266's `kgsl_alloc_thp_bo()`** — the dma-heap call site is deleted by c58b5266; both allocators are dead by HEAD (below).

**Across the whole branch (to c7fd533)**

- **427e1968 "paged arena (v2) — host side" is entirely dead at HEAD.** 87405677 removed arena blessing (`iova == 0`) and the GEM_NEW run-list parsing; what survives is unreachable: `obj->nr_runs` is **never assigned** anywhere at c7fd533, so `kgsl_vbo_bind_runs()`, `struct kgsl_object::{runs,nr_runs}` and the `!obj->mem_id` re-stitch branches in GEM_SET_IOVA / map_object / get_blob never run, and `struct msm_gem_new_run` + the "Arena v2 extension" block in `src/drm/msm/msm_proto.h` are dead protocol text. **Never introduce it.** (`struct kgsl_context::arena` is the one name that survives, but at HEAD it means lateautumn233's *pre-shared* arena — introduce that in post-graft D2, not here.)
- **c58b5266's host THP-memfd BO allocator is dead at HEAD.** `kgsl_alloc_thp_bo()` (memfd + `F_SEAL_SHRINK` + PMD-aligned `MADV_HUGEPAGE`/`MADV_COLLAPSE` + transient `UDMABUF_CREATE` + KGSL import) is **defined but never called** at c7fd533 — its last caller went with 87405677 ("guest-alloc is the only way a BO gets backing"). Its `struct kgsl_object::{host_map,host_map_size}` fields are read but never written. **Never introduce it.** (Note the *udmabuf* technique itself survives in a different shape as `kgsl_arena_window()`, introduced by post-graft D2/D6; and `is_shm` **does** survive and is live — keep that one bit.)
- **147dea51's dma-heap allocator is dead at HEAD.** `kgsl_dma_heap_alloc()` has no callers; `dma_heap_path` / `kctx->dma_heap_fd` are still opened and closed at every context create and **still fail context creation if `/dev/dma_heap/system` is absent**, for nothing. **Never introduce it.**
- **`kgsl_vbo_unbind()`** — 26348f9d marks it `UNUSED`; still dead at c7fd533. Delete it in P5 rather than carrying an unused static.
- **`src/drm/kgsl/` → `src/drm/drm2kgsl/`** (a7bcdd66, post-graft): a pure rename of files this range creates. Naming P4's files `drm2kgsl` from birth makes a7bcdd66 + c9011324 disappear from the series entirely.
- **`ENABLE_DRM_KGSL` → `ENABLE_DRM2KGSL`** and the five `CROSVM_KGSL_*` → `CROSVM_DRM2KGSL_*` env names — same; born correct in P4.

Everything else from this range is live at c7fd533: the framework vendoring, the msm→KGSL backend, the global VBO + size ladder, the drawctxt flags, the `chip_id & ~0xff` fuse-byte mask (extended by post-graft ffb3aaa0), the no-unbind semantics, IOCOHERENT imports, per-context VA slices (reworked by post-graft D3), `virgl_resource_transfer_blob` (patched by post-graft G3), `virgl_fence_table_init/cleanup`, and the Adreno dual-source-blend guard.

### Consider dropping

1. **The four unused native-context backends.** `Android.bp` at c7fd533 compiles exactly `src/drm/{drm_context,drm_fence,drm_renderer,drm_util}.c` + `src/virgl_fence.c` + `src/drm/drm2kgsl/drm2kgsl_renderer.c`; `config.h` sets only `ENABLE_DRM` + `ENABLE_DRM2KGSL`. So `amdgpu/` (1 608 lines), `asahi/` (1 038), `i915/` (1 321), `panfrost/` (839) and `msm/msm_renderer.{c,h}` are **never built**, and `drm-uapi/{amdgpu,asahi,i915,panfrost}_drm.h` (6 772 lines) are never included — **≈ 11.6 k of P2's ≈ 16.3 k vendored lines are dead weight**. Keep them only if the intent is "our `src/drm` is byte-identical to upstream's, so a future upstream MR is a clean diff"; if the PR is a DroidVM-facing one, dropping them shrinks P2 by ~70 %. Owner decision — say which in P2's body either way. (`msm/msm_proto.h` **must** stay: drm2kgsl implements that protocol.)
2. **P9 in full** — `NCTX_IB_CHECK`, `NCTX_IB_SCAN`, `NCTX_NO_FENCE`. See the P9 row; drop together with the existing plan's D5 and its `NCTX_RELAX_SLICE` / `NCTX_NO_WAITTS` / `NCTX_WAITTS` siblings so the route ships one coherent set of knobs (or none).
3. **The dead allocators and arena-v2 leftovers** listed under "nets to zero" — never introducing them removes the need for the existing plan's "Consider dropping" item 6 (`drm2kgsl: remove the host allocator and arena-v2 leftovers`). Consequence to state plainly: the flattened branch's final tree then differs from c7fd533 by exactly that dead code.
4. **Bisectability caveat that comes with #3.** If P4 never allocates BO backing, then from P4 until post-graft D7 (guest-alloc flag day) `GEM_NEW` produces an object with no pages, i.e. the route does not run at any intermediate commit. Two options: **(B, recommended, and what the "never introduce" rule implies)** P4's `GEM_NEW` records iova/flags only and `get_blob()` completes the object — i.e. write P4 against the final architecture; **(A, fallback)** P4 keeps the minimal ~20-line dma-heap import so it is a working backend, and post-graft D7 deletes it as it historically did. A is honest history and bisectable; B is the cleaner series. Historically neither 147dea51 nor c58b5266 actually worked end-to-end anyway (SIGBUS, then the `FOLL_LONGTERM` EFAULT), which argues for B.
5. **Commit trailers.** Every HuJK commit in this range carries `Co-Authored-By: Claude …` + `Claude-Session: https://claude.ai/code/session_…`. Strip the session links for a public PR; keep or drop the Claude co-author trailer per project policy. P1 is the only commit that needs a *human* `Co-authored-by` trailer.
6. **`ARENA_V2_PLAN.md` / `NATIVE_CONTEXT_PLAN.md` references** in the commit bodies of d97194c6 and 427e1968 point at files that live in the DroidVM plans repo, not here — rewrite or drop those lines when the messages are rewritten.

### Coverage check

**All 13 original commits assigned: yes.**

| original | → | note |
|---|---|---|
| b9881a0c (lateautumn233) | P1 | folded, `Co-authored-by` trailer |
| d97194c6 | P2 (upstream files) + P3 (adaptation) | split |
| 051b87d4 | P3 | build fixup of d97194c6 |
| 147dea51 | P4 | minus the dma-heap allocator |
| c1aa016c | P4 | supersedes part of 147dea51 |
| e9c0801b | P4 | supersedes part of 147dea51 |
| f0453560 | P4 | supersedes part of 147dea51 |
| 5d79e781 | — | **dropped**, nets to zero within range (deleted by c58b5266) |
| c58b5266 | P8 (core) + P9 (NCTX_NO_FENCE, drop) | the THP-memfd allocator half is **never introduced** (dead at HEAD) |
| 095e085b | P3 | vendoring omission — folds into the vendoring's adaptation commit |
| 26348f9d | P5 (unbind) + P6 (IO-coherent) + P9 (probes, drop) | three-way split |
| 427e1968 | — | **dropped entirely**, dead at c7fd533 |
| f6a66611 | P7 | |

**All 57 net files assigned: yes.**

- **P1** (1): src/vrend_renderer.c
- **P2** (47 A + 10 M = 57 touched, 47 of them exclusively): the list under "P2 net-file breakdown"; of the 10 modified files it shares `src/drm/drm_renderer.c`, `drm_fence.c`, `drm_context.c`, `src/virgl_fence.c` with P3 and `src/drm/drm_renderer.c` with P4
- **P3** (5 exclusive + hunks): Android.bp, prebuilt-intermediates/config.h, src/virgl_util.h, src/virglrenderer.c, plus adaptation hunks in src/drm/drm_renderer.c, src/drm/drm_fence.c, src/drm/drm_context.c, src/virgl_fence.c
- **P4** (3 exclusive + hunks): src/drm/drm2kgsl/drm2kgsl_renderer.c, src/drm/drm2kgsl/drm2kgsl_renderer.h, src/drm/drm2kgsl/msm_kgsl.h (net-diff paths `src/drm/kgsl/*`), plus hunks in src/drm/drm_renderer.c (char-device backend slot), Android.bp, prebuilt-intermediates/config.h
- **P5 / P6 / P7 / P9**: hunks in src/drm/drm2kgsl/drm2kgsl_renderer.c only
- **P8**: hunks in src/virglrenderer.c only
- **not introduced** (would otherwise appear in `src/drm/msm/msm_proto.h`): the `struct msm_gem_new_run` + "Arena v2 extension" block from 427e1968 — msm_proto.h is still fully covered by P2's upstream sync

**SPLIT NEEDED files (this range)**

- `src/drm/drm_renderer.c` — P2 (upstream sync: extra backend table entries, capset, `debug_len/debug_name` plumbing) · P3 (`DRM_IOCTL_SET_CLIENT_NAME` guard, `fd < 0` fallback) · P4 (KGSL char-device open path + `VIRTGPU_DRM_CONTEXT_MSM` slot)
- `src/virglrenderer.c` — P3 (`drm_renderer_create(..., −1)`, `virgl_fence_table_init/cleanup`) · P8 (`virgl_resource_transfer_blob` + its two call sites)
- `src/drm/{drm_context.c, drm_fence.c}`, `src/virgl_fence.c` — P2 (upstream body) · P3 (the handful of vendored-API adaptation lines)
- `Android.bp`, `prebuilt-intermediates/config.h` — P3 (framework: `libdrm_headers`, 5 framework srcs, `ENABLE_DRM`) · P4 (`drm2kgsl_renderer.c`, `ENABLE_DRM2KGSL`)
- `src/drm/drm2kgsl/drm2kgsl_renderer.c` — P4 · P5 · P6 · P7 · P9 (split is by original commit except 26348f9d, which needs hunk-level surgery three ways)

**Corrections to the existing plan** (`plans/pr-flatten/virglrenderer.md`, "Open questions" #1): the pre-graft delta is now fully visible. Authorship of the KGSL backend is **HuJK**, not lateautumn233 — lateautumn233's only pre-graft commit is b9881a0c (vrend dual-source blend, 2026-04-07). The pre-graft work is (b) a **vendoring of upstream `src/drm`** → G bucket, not D, and (c)+(d) the KGSL backend + its five same-day fixes → D. Open questions #3 and #4 (rename-first vs in-place, L1 vs rename ordering) are resolved by naming P4 `drm2kgsl` from birth.
