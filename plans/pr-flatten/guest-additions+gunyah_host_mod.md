# Flattened PR commit lists: droidvm-guest-additions (A) and gunyah_host_mod (B)

Both repos are flattened FROM THE EMPTY TREE (whole repo is 3d-accel work). Buckets per
PREAMBLE: L licensing / M misc, GPU-unrelated / G GPU-common / D drm2kgsl / X gfxstream / V venus.
One extra label is used below: **base** = "import the vendored upstream driver, unmodified" — it is
not a feature but must precede every commit that patches those files, so it sits right after L.

Two facts that affect BOTH repos (details in the per-repo sections):

1. **lateautumn233-authored material is buried inside HuJK "initial import" commits.**
   - A: `gunyah_guest/gunyah_guest.c` v1 (RM client, ~236 lines) + the virtio_gpu memparcel-accept /
     `host_visible_guard` / `VGBLOB-DBG` hunks in 6a84605 are byte-identical to lateautumn233's
     guest-kernel commit `f056a12bb2cd` (2026-07-06, author+committer lateautumn233; local copy at
     `/root/Documents/DroidVM_3d_accel/lateautumn233_attemp/linux`, exported as
     `guest-patches/linux/0001-...patch` with `From: lateautumn233`).
   - B: `gunyah_host_share/GKI6.1/{gunyah_share_mod.c,uapi_gunyah_share.h,README.md}` (added by HuJK
     in d9b104c) are byte-identical to lateautumn233's `2a8df05 Initial commit: gunyah_share_mod`
     (2026-07-05, `/root/Documents/DroidVM_3d_accel/lateautumn233_attemp/gunyah_share_mod`);
     the 6.6 module's `uapi_gunyah_share.h` is the same file, and 97cf7e0's message says the 6.6
     module was adapted from "the l233 6.1 module".
   Recommendation: commit those pieces with `--author="lateautumn233 <lateautumn233@foxmail.com>"`
   (or at minimum `Co-authored-by:`), separate from HuJK's changes. Owner decides.
2. **Both org default branches are NOT ancestors of wip/3d-accel.** A: origin/wip-3d-accel = 529f081
   is a single commit with unrelated history. B: origin/wip-3d-accel = b14d65e IS on wip/3d-accel's
   history (5th commit) — a normal PR is possible there. For A, GitHub cannot open a PR between
   branches with no merge base; see "base rebase" under A.

---

## (A) droidvm-guest-additions — base EMPTY TREE .. 0fce564 (wip/3d-accel)  33 original commits, 43 net files

Repo: `/root/Documents/DroidVM_meta/droidvm-guest-additions`. Subject style in
this repo: `area: what` lower-case (`virtio_gpu:`, `gunyah_guest:`/`guest:`, `install:`,
`packaging:`, `build:`, `licensing:`, `tests:`, `dynpool_test:`).

Vendored base: `virtio_gpu/*.c,*.h` = Linux 7.1-rc4 `drivers/gpu/drm/virtio` (verified against
`lateautumn233_attemp/linux` @ 5200f5f493f7) with three out-of-tree build tweaks:
`virtio_gpu/Makefile` (new), `virtgpu_trace.h` `TRACE_INCLUDE_PATH .`, `virtgpu_prime.c`
`.invalidate_mappings` -> `.move_notify` (build against Ubuntu 7.0 headers). Everything else in
`virtio_gpu/` vs upstream (1183 added lines) is DroidVM work and is assigned below.
`git diff <upstream 7.1-rc4> net` is saved at scratchpad `upstream_delta.diff` if useful.

### Proposed flattened commits (in order)

| # | bucket | proposed subject | folds original commits | net files (paths) | notes |
|---|--------|------------------|------------------------|-------------------|-------|
| A1 | L | licensing: GPL-2.0-or-later by default, with permission to take it upstream; attribute to Droid-VM | 577babf, 9dfedf2 | ADDITIONAL-PERMISSIONS, CONTRIBUTING.md, LICENSE.GPL-2.0, LICENSING.md | SPDX header lines of 577babf land inside the commits that create the files (A5, A12). LICENSING.md already names `gunyah_guest/` and `tests/` as DroidVM-written and `virtio_gpu/` as patched upstream. |
| A2 | base | virtio_gpu: import the 7.1-rc4 virtio-gpu driver as an out-of-tree module | 6a84605 (upstream part of `virtio_gpu/`) | virtio_gpu/Makefile, virtio_gpu/virtgpu_{debugfs,display,drv,fence,gem,ioctl,kms,object,plane,prime,submit,trace_points,vq,vram}.c, virtio_gpu/virtgpu_{drv,trace}.h | Pristine upstream + the 3 build tweaks above; NO DroidVM hunks. Give it a message naming the exact upstream commit (5200f5f493f7). `virtio_gpu/uapi/linux/virtio_gpu.h` deliberately NOT here — see "consider dropping" (dead, shadowed by kernel header). If based on 529f081 instead of empty (see below) this commit collapses to a 5-file delta. |
| A3 | M | packaging: DKMS source package, top-level Makefile, install.sh | 6a84605 (Makefile, dkms.conf, README.md), b510200, 3f2a227, 5927cf0 (install.sh hunk), 6e8f34d+e789f33 (Makefile/dkms.conf hunks; net = comment "accept transport folded into gunyah_guest"), 3060f8b (install.sh hunk) | Makefile, dkms.conf, README.md, install.sh | Route-agnostic (installs whichever `mesa-guest-<variant>` .deb via DROIDVM_MESA_URL). Ordering wrinkle: dkms.conf/Makefile name `gunyah_guest/` which arrives in A5; if per-commit buildability matters move A3/A4 after A7. README.md is stale (title `# gunyah_guest_mod`, describes the removed memparcel-accept path, "pending re-verification") — rewrite in this commit. |
| A4 | M | packaging: build .deb/.rpm from one payload; hooks.sh initramfs/dkms rules; version by commit count; per-kernel initramfs | 8762c0a, fc5d9d0, 3060f8b (hooks.sh hunk), 5927cf0 (rest) | build-packages.sh, packaging/hooks.sh, tests/test-hooks.sh, dkms.conf (REMAKE_INITRD comment hunk, SPLIT with A3), install.sh (dkms 1.0 cleanup + loop hunks, SPLIT with A3) | Could be merged into A3 if the owner wants one packaging commit; kept separate because .deb/.rpm + hooks is a distinct feature with its own test. Add `*.deb`/`*.rpm` to a `.gitignore` here (there is none; six .debs got committed by 2c75798). |
| A5 | G | gunyah_guest: Gunyah RM client module (raw-HVC mem_accept/mem_release) — **AUTHOR lateautumn233** | 6a84605 (`gunyah_guest/` part), 577babf (SPDX line) | gunyah_guest/Makefile, gunyah_guest/gunyah_guest.c (Part 1: RM client, `gunyah_guest_available/mem_accept/mem_release`), gunyah_guest/linux/gunyah_guest.h (v1 declarations), virtio_gpu/linux/gunyah_guest.h (identical copy) | Byte-identical (+2 MODULE_ lines) to lateautumn233's `drivers/virt/gunyah_guest.c` in f056a12bb2cd. Recommend committing with lateautumn233 as author; HuJK's later Makefile `$(PWD)`->`$(CURDIR)` (b510200) can ride in A3 or here. |
| A6 | G | gunyah_guest: virtio-gunyah-accept transport (crosvm VmAccept::Sync) folded into the RM-client module | 6e8f34d, e789f33, 0e8f8fe (gunyah_guest.c MAP_IPA_CONTIGUOUS comment hunk), a23294d (gunyah_guest side: keeps exports) | gunyah_guest/gunyah_guest.c (Part 2: vga_* accept/release queues, probe/remove, module init registers virtio driver), dkms.conf comment (SPLIT, A3) | 6e8f34d's separate `virtio_gunyah_accept/` dir nets to zero (moved into gunyah_guest.c by e789f33). |
| A7 | G | gunyah_guest: pool control queue and exported gunyah_pool_grow/shrink/query API | 548eb4e, 24857a5 (gunyah_guest hunks: `gunyah_pool_test_ref` debug hook) | gunyah_guest/gunyah_guest.c (queue 2, `vga_pool_request`, `gunyah_pool_*`), gunyah_guest/linux/gunyah_guest.h, virtio_gpu/linux/gunyah_guest.h, dynpool_test/linux/gunyah_guest.h (all three headers identical) | `gunyah_pool_query_range` comes from ce7e962 (A15), keep it there. `gunyah_pool_test_ref` is debug-only — see "consider dropping". |
| A8 | G | dynpool_test: driver that exercises a growable pool (grow/shrink/query/busy, multi-pool select) | 82f6af9, 24857a5 (dynpool hunks), c67fa3b | dynpool_test/Makefile, dynpool_test/dynpool_test.c, dynpool_test/linux/gunyah_guest.h (also touched by A7/A15) | Test-only module; not in dkms.conf. Owner may prefer to drop from PR (see below). |
| A9 | G | virtio_gpu: host-visible BAR under Gunyah — guard the BAR base GPA and 2MB-align blob nodes | 6a84605 (`host_visible_guard` hunks — **lateautumn233** material), 0e8f8fe (`drm_mm_insert_node_generic` 2MB align hunk in vram_map) | virtio_gpu/virtgpu_drv.h (host_visible_guard field), virtio_gpu/virtgpu_kms.c (guard reserve/remove), virtio_gpu/virtgpu_vram.c (vram_map alignment) — all SPLIT | Runtime-share BAR path is used by every route for non-pool HOST3D mappable blobs. Attribute the guard to lateautumn233 (Co-authored-by) if not split out. |
| A10 | G | virtio_gpu: map pool-resident host blobs (VIRTIO_GPU_MAP_INFO_POOL) at gpu_pool_base + offset from a /reserved-memory host pool node | 0e8f8fe (pre-alloc hunks: MAP_INFO_POOL define, pool_resident/pool_offset, map_cb, mmap pool path, `virtio_gpu_find_pool_base*`), a23294d (map_cb reads `resp->padding` as pool offset; removes memparcel accept), 5927cf0 (kms.c "host pool: %s base" log naming the node), 24857a5 (kms.c/drv.h `gfx_host`/`drm2kgsl_host` rename hunks — final names) | virtio_gpu/virtgpu_drv.h (MAP_INFO_POOL, pool_resident, pool_offset, gpu_pool_base), virtio_gpu/virtgpu_kms.c (`virtio_gpu_find_pool_base_named`, `virtio_gpu_find_pool_base`, init log), virtio_gpu/virtgpu_vq.c (map_cb hunk), virtio_gpu/virtgpu_vram.c (mmap pool_resident branch + Gunyah comments) — all SPLIT | Mechanism is shared by X/D/V; the three node NAMES in `virtio_gpu_find_pool_base()` are split out as A17/A18/A19 (3 lines each). Owner may just keep all three names here and drop A17-A19. |
| A11 | G | virtio_gpu: guest-alloc pool (gpu_guest) — back BLOB_MEM_GUEST from a guest-owned drm_buddy pool, negotiate CREATE_GUEST_HANDLE, bound scatter, report budget | 0e8f8fe (guest-alloc + cacheable + CREATE_GUEST_HANDLE + ctx_id/blob_id hunks), 489a77c (drm_buddy scatter, stitched mmap, 3 getparams), f203a46, 4f6d47e (guest_pool_max_nents 16384), 4ca7bf7 (say which backing; restricted-dma-pool warn), f6ae582 (comm/pid in logs), 24857a5 (`gpu_guest` node rename), fd9b8d0 (`droidvm_trace` param + `virtio_gpu_trace()`) | virtio_gpu/virtgpu_drv.c (feature bit + droidvm_trace param, SPLIT with A20), virtio_gpu/virtgpu_drv.h (F_CREATE_GUEST_HANDLE/PARAM defines, POOL_*_KIB, guest_pool_* fields, buddy compat macro, prototypes, virtio_gpu_trace), virtio_gpu/virtgpu_ioctl.c (BLOB_FLAG_CREATE_GUEST_HANDLE, getparams, verify_blob guest_alloc branch, create_blob routing + traces), virtio_gpu/virtgpu_kms.c (has_create_guest_handle, guest_pool_init/fini calls), virtio_gpu/virtgpu_vram.c (guest_pool_* section, mmap stitching, dma-buf map path minus ce7e962 parts) — all SPLIT | CREATE_GUEST_HANDLE / guest-alloc is used by gfxstream, venus (vn_renderer_virtgpu) and drm2kgsl (vdrm) guests — G, not X. `droidvm_trace` could be its own tiny commit; folded here since it only guards guest-alloc traces. |
| A12 | G | tests: gpool_test probes the guest-alloc scatter bound from userspace | 00790a1, bac6534 (comment kgsl->drm2kgsl), 577babf (SPDX lines) | tests/gpool_test.c | |
| A13 | G | virtio_gpu: blob-path diagnostics — VGBLOB-DBG failure logs and pr_debug entry trace | 6a84605 (VGBLOB-DBG pr_err hunks in ioctl.c/vram.c — **lateautumn233** material; pr_debug demote = HuJK guest-patch 0003) | virtio_gpu/virtgpu_ioctl.c, virtio_gpu/virtgpu_vram.c (vram_create pr_errs) — SPLIT | Separate so it can be dropped/renamed easily; see "consider dropping". Alternatively fold into A11. |
| A14 | G | *(other author, keep)* feat(virtio_gpu): add range query for guest pool allocations — lateautumn233 | ce7e962 | gunyah_guest/gunyah_guest.c (+`gunyah_pool_query_range`, release fix), gunyah_guest/linux/gunyah_guest.h, virtio_gpu/linux/gunyah_guest.h, dynpool_test/linux/gunyah_guest.h, virtio_gpu/virtgpu_drv.h, virtio_gpu/virtgpu_ioctl.c (`drm_gem_object_put` on error paths), virtio_gpu/virtgpu_vq.c (unref_cb releases pool blocks), virtio_gpu/virtgpu_vram.c (dynamic pool grow/shrink/reclaim work, scatter dma-buf map, deferred block release) | Subject badly understates it: this is "dynamic (growable) guest-alloc pool: grow/shrink the SHARE'd prefix via gunyah_pool_*, reclaim work, release blocks after RESOURCE_UNREF reply". Applies cleanly after A11 (its parent was f6ae582). Suggest asking lateautumn233 to reword or keep as-is with authorship. |
| A15 | G | *(other author, keep)* feat(virtio-gpu): update pixel format handling — lateautumn233 | 075d260 | virtio_gpu/virtgpu_drv.h (`VIRTIO_GPU_PRIMARY_FORMAT`=ABGR8888), virtio_gpu/virtgpu_display.c, virtio_gpu/virtgpu_gem.c (dumb format), virtio_gpu/virtgpu_plane.c (formats + ABGR translate) | Native scanout path (Android AHB RGBA_8888). It REPLACES the accepted XRGB fb format, which broke fbdev — fixed by A16. |
| A16 | G | virtio_gpu: keep accepting the console's XRGB framebuffer format so fbdev/VT works | 3d3532a (display.c hunk only) | virtio_gpu/virtgpu_display.c (SPLIT: fix on top of A15) | HuJK follow-up that ONLY fixes lateautumn233's 075d260. Cleaner alternative: amend A15 to add ABGR instead of replacing XRGB (authorship preserved) and drop A16. Owner decides. |
| A17 | X | virtio_gpu: look up the gfxstream host pool under `gfx_host` | 0e8f8fe (`gpu_blob_reserved` lookup) -> 24857a5 (`gfx_host`) | virtio_gpu/virtgpu_kms.c (first name in `virtio_gpu_find_pool_base`, SPLIT) | 3 lines. X is otherwise EMPTY in this repo — everything "gfxstream pre-alloc"-named is in fact route-shared (A10/A11). |
| A18 | D | virtio_gpu: also find the host pool base under `drm2kgsl_host` | dc9471d, bac6534 (kms.c rename), 24857a5 (`drm2kgsl_host`), 5927cf0 (verification note) | virtio_gpu/virtgpu_kms.c (second name, SPLIT) | 5 lines. |
| A19 | V | virtio_gpu: probe the `venus_host` pool node | 2c75798 (kms.c hunk only; NOT the six .deb files) | virtio_gpu/virtgpu_kms.c (third name, SPLIT) | 7 lines. |
| A20 | M | virtio_gpu: virtio_gpu.fbdev module parameter (fbdev client registration switch, default on) | 497b1d3, 3d3532a (drv.c hunk: default back to on) | virtio_gpu/virtgpu_drv.c (fbdev param + `if (virtio_gpu_fbdev) drm_client_setup`, SPLIT with A11) | Bucket M per instruction (console/fbdev). Must come after A2 (patches the vendored driver) — put it right after A2 if strict L-M-G order is wanted; the XRGB acceptance half of the same story is A16 because it depends on A15. |
| A21 | G | virtio_gpu: do not send CTX_DETACH_RESOURCE from files that never created a context | 0fce564 | virtio_gpu/virtgpu_gem.c | Upstream-candidate bugfix (also exists as guest-patches/linux/0005). Route-agnostic. |

Ordering note: strict L -> M -> G would be A1, A2(base), A3, A4, A20, A5.., but A20 needs A2 and A3/A4 reference A5's module. Recommended practical order: A1, A2, A20, A3, A4, A5..A16, A17, A18, A19, A21 (A21 can go anywhere after A2).

### Other-author commits (keep authorship)
- **ce7e962 lateautumn233** "feat(virtio_gpu): add range query for guest pool allocations" — 8 files, 393+/44-. Keep verbatim (cherry-pick) after A11/A12 (its historical parent is f6ae582). No HuJK follow-up fixes it; note the c67fa3b dynpool_test change is independent.
- **075d260 lateautumn233** "feat(virtio-gpu): update pixel format handling" — keep verbatim after A11..A14. HuJK's **3d3532a display.c hunk (A16) only fixes this commit** (re-adds XRGB that 075d260 removed).
- **Hidden lateautumn233 material inside HuJK's 6a84605** (see top): gunyah_guest.c v1 (+ .h), virtio_gpu `host_visible_guard`, VGBLOB-DBG logs, the memparcel-accept path (the last nets to zero anyway). Recommend A5 be authored lateautumn233; A9/A13 carry `Co-authored-by: lateautumn233`.
- The merge 26073f7 (HuJK) has no content of its own; disappears.

### Nets to zero / disappears in flatten
- 6e8f34d `virtio_gunyah_accept/{Makefile,linux/gunyah_guest.h,virtio_gunyah_accept.c}` — moved into gunyah_guest.c by e789f33 (feature survives as A6; the dir does not).
- virtio_gpu memparcel accept path (6a84605 `gunyah_handle`/`gunyah_accepted`, accept in mmap; 0e8f8fe "accept real size, MAP_IPA_CONTIGUOUS" vram.c hunks; guest-patch 0002 gate) — removed by a23294d. Only comments explaining the history remain (A10).
- 0e8f8fe page-bitmap allocator (`guest_pool_bitmap`, `bitmap_find_next_zero_area`) — replaced by drm_buddy in 489a77c.
- f203a46 default `guest_pool_max_nents=1024` -> 4f6d47e 16384.
- DT node names: `gpu_guest_reserved`/`gpu_blob_reserved` (0e8f8fe) -> `kgsl_reserved` (dc9471d) -> `drm2kgsl_reserved` (bac6534) -> `gfx_host`/`drm2kgsl_host`/`gpu_guest` (24857a5). Only the final names exist.
- 497b1d3 fbdev default OFF -> 3d3532a default ON (param survives, A20).
- 5927cf0 "gfxstream pre-alloc" wording of the pool-base log -> node-name log (A10).
- 26073f7 merge commit.
- 3d3532a's stray blank-line deletion in virtgpu_gem.c line ~51 (cosmetic diff vs upstream) — recommend NOT carrying it (keeps upstream delta minimal); if kept, it goes in A16.

### Consider dropping from the PR
- **Six `.deb` binaries** at repo root (`droidvm-guest-additions_1.0+droidvm.*.deb`, 6 x ~75 KB) — accidentally committed by 2c75798. Build artifacts; drop and add `*.deb *.rpm` to `.gitignore` (A4).
- **`virtio_gpu/uapi/linux/virtio_gpu.h`** — vendored copy that the build never sees (drv.h comment: "the build uses the kernel's <linux/virtio_gpu.h> ... shadowed by the kernel header's include guard"); it still carries the obsolete `gunyah_handle` field rename and a MAP_INFO_POOL comment referring to it. Dead + misleading. If kept, it must be A2 (upstream) + the 7-line MAP_INFO_POOL comment (A10).
- **`gunyah_pool_test_ref`** export (24857a5) — self-described "Debug only ... Not for production callers". Only dynpool_test uses it. Drop, or keep together with A8 if dynpool_test ships.
- **`dynpool_test/`** (A8) and **`tests/gpool_test.c`** (A12) — bring-up test drivers/programs. Fine to keep as tests, but they are not packaged; owner decides.
- **`VGBLOB-DBG:` prefix** on the surviving pr_err/pr_debug lines (A13, ~10 sites in ioctl.c/vram.c) — debug-era naming; rename to plain `virtio-gpu:` messages before submission or drop the pr_debug entry trace entirely.
- README.md content (title `# gunyah_guest_mod`, memparcel-accept description, "pending re-verification", `curl ... /wip/3d-accel/install.sh` one-liner pointing at the WIP branch) — rewrite in A3.
- `dkms.conf` comment "the runtime memparcel accept transport ... is now folded INTO gunyah_guest.ko" reads as history; trim in A3/A6.

### SPLIT NEEDED files
- `virtio_gpu/virtgpu_drv.h`: upstream (A2) | host_visible_guard field (A9) | MAP_INFO_POOL define + pool_resident/pool_offset + gpu_pool_base (A10) | CREATE_GUEST_HANDLE/PARAM defines, POOL_*_KIB, guest_pool_* device fields, buddy compat macro, guest_pool_* prototypes, virtio_gpu_trace macro (A11) | dynamic-pool fields (`gpu_guest_pool_id/prealloc/backed/step`, `guest_pool_reclaim_work`, `release_object` proto — ce7e962, A14) | `VIRTIO_GPU_PRIMARY_FORMAT` (075d260, A15).
- `virtio_gpu/virtgpu_kms.c`: upstream (A2) | guard reserve/remove (A9) | `virtio_gpu_find_pool_base_named`, `virtio_gpu_find_pool_base` skeleton, `gpu_pool_base` init + "host pool: %s base" log (A10) | has_create_guest_handle + guest_pool_init/fini calls (A11) | `gfx_host` name (A17) | `drm2kgsl_host` name (A18) | `venus_host` name (A19).
- `virtio_gpu/virtgpu_vram.c`: upstream (A2) | vram_map 2MB alignment (A9) | mmap pool_resident branch + Gunyah history comments (A10) | guest_pool section (init/fini/alloc/free/stats/create, max_nents, mmap stitching, backing log) (A11) | vram_create VGBLOB-DBG pr_errs (A13) | ce7e962 hunks (grow/shrink/reclaim, dma-buf scatter map, release_object) (A14).
- `virtio_gpu/virtgpu_ioctl.c`: upstream (A2) | CREATE_GUEST_HANDLE flag/getparams/verify_blob/routing + traces (A11) | VGBLOB-DBG pr_errs + pr_debug (A13) | `drm_gem_object_put` on error paths (ce7e962, A14).
- `virtio_gpu/virtgpu_vq.c`: upstream (A2) | map_cb MAP_INFO_POOL hunk (A10) | unref_cb/unref_resource release hunks (ce7e962, A14).
- `virtio_gpu/virtgpu_drv.c`: upstream (A2) | `VIRTIO_GPU_F_CREATE_GUEST_HANDLE` feature + `droidvm_trace` param (A11) | `fbdev` param + conditional `drm_client_setup` (A20).
- `virtio_gpu/virtgpu_display.c`: upstream (A2) | PRIMARY_FORMAT (A15) | `+ != DRM_FORMAT_HOST_XRGB8888` (A16).
- `virtio_gpu/virtgpu_gem.c`: upstream (A2) | dumb format (A15) | context_created guard (A21).
- `gunyah_guest/gunyah_guest.c`: Part 1 RM client (A5) | Part 2 accept transport (A6) | pool queue + API + test_ref (A7) | query_range + release fix (A14).
- `gunyah_guest/linux/gunyah_guest.h`, `virtio_gpu/linux/gunyah_guest.h`, `dynpool_test/linux/gunyah_guest.h` (identical): v1 decls (A5) | pool API + test_ref (A7) | query_range (A14). dynpool copy first appears at A8.
- `dkms.conf`: base (A3) | REMAKE_INITRD comment (A4) | accept-transport comment (A6 or drop).
- `install.sh`: b510200/3f2a227 body (A3) | 8762c0a dkms-1.0 cleanup + 3060f8b per-kernel loop (A4).
- `Makefile` (top): A3 only (6e8f34d/e789f33 add+remove of the accept module net to zero).

### Open questions / decisions for the owner
1. **Base for the PR.** wip/3d-accel and origin/wip-3d-accel (529f081) share no ancestor -> GitHub will refuse the PR. Options: (a) build pr/3d-accel ON TOP of 529f081 — 529f081 already holds gunyah_guest v1 + memparcel-accept virtio_gpu nearly identical to 6a84605 (`git diff 529f081 6a84605` = Makefile, dkms.conf, README.md, virtio_gpu/Makefile, 5 lines of ioctl.c pr_debug), so A2+A5+A9+A13's lateautumn233 material is then already on the base (attributed to HuJK there — same attribution question), and A2 shrinks to "add DKMS build glue"; (b) force-push a new default branch from the flattened history. (a) is far less churn; the list above stays the same except A2/A5/A9/A13 become deltas.
2. Author attribution of lateautumn233's f056a12 material (A5/A9/A13) and how to credit — separate authored commits vs Co-authored-by.
3. Keep A17/A18/A19 as 3 tiny per-route commits or fold the three node names into A10.
4. A16 vs amending 075d260.
5. Ship dynpool_test/gpool_test/test_ref in the PR or not.
6. Drop the vendored `virtio_gpu/uapi/` header (dead) or keep it in A2 for reference.
7. Whether A20 (fbdev switch) is really M or should just be G — kept M per instruction.

### Coverage check
- all original commits assigned: **yes** — 6a84605 (A2/A3/A5/A9/A13; memparcel part nets to zero), b510200 (A3), 6e8f34d (A6; dir nets to zero), 0e8f8fe (A6/A9/A10/A11; accept hunks net to zero), e789f33 (A6), a23294d (A6/A10; net effect = removal), 489a77c (A11), dc9471d (A18), 3f2a227 (A3), f203a46 (A11), 00790a1 (A12), 4ca7bf7 (A11), 4f6d47e (A11), bac6534 (A12/A18), 5927cf0 (A3/A4/A10), 577babf (A1 + SPDX in A5/A12), 548eb4e (A7), 82f6af9 (A8), 24857a5 (A7/A8/A10/A11/A18), 8762c0a (A4), f6ae582 (A11), fd9b8d0 (A11), fc5d9d0 (A4), ce7e962 (A14, other author), 9dfedf2 (A1), 075d260 (A15, other author), 2c75798 (A19; .debs dropped), 26073f7 (merge, disappears), c67fa3b (A8), 497b1d3 (A20), 3d3532a (A16/A20; gem.c blank line dropped), 3060f8b (A3/A4), 0fce564 (A21).
- all net files assigned: **yes** — 43 files: 4 licensing (A1); Makefile, dkms.conf, README.md, install.sh (A3/A4); build-packages.sh, packaging/hooks.sh, tests/test-hooks.sh (A4); 6 x .deb (consider dropping — else A4); dynpool_test/* (A8); gunyah_guest/* (A5/A6/A7/A14); tests/gpool_test.c (A12); virtio_gpu/Makefile + 14 upstream .c/.h (A2 + splits); virtio_gpu/linux/gunyah_guest.h (A5/A7/A14); virtio_gpu/uapi/linux/virtio_gpu.h (consider dropping — else A2+A10).

---

## (B) gunyah_host_mod — base EMPTY TREE .. 9c7557e (wip/3d-accel)  29 original commits, 29 net files

Repo: `/root/Documents/DroidVM_meta/gunyah_host_mod`. Org default origin/wip-3d-accel =
b14d65e IS an ancestor (5th commit), so a PR against it is possible; the flatten below is from empty
per instruction — if the owner bases pr/3d-accel on b14d65e, B2/B5 lose the pieces already there
(gunyah_share_66.c v1..v5 at `GKI6.6/`, docker_exec.sh, the .ko, README stub) and B5 becomes
"move + rename + 6.12/kvcalloc/pr_fmt changes". Subject style: `area: what` (`udmabuf:`,
`gh_unmovable:`, `gunyah_host_share 6.6:`, `host-share:`, `kvcalloc:`, `build.sh:`, `licensing:`).

### Proposed flattened commits (in order)

| # | bucket | proposed subject | folds original commits | net files (paths) | notes |
|---|--------|------------------|------------------------|-------------------|-------|
| B1 | L | licensing: GPL-2.0-or-later by default, with permission to take it upstream; attribute to Droid-VM | f491c7a, 46664b4 | ADDITIONAL-PERMISSIONS, CONTRIBUTING.md, LICENSE.GPL-2.0, LICENSING.md | SPDX header lines of f491c7a land in B3/B4/B5/B7/B8/B9. LICENSING.md names `udmabuf/udmabuf.c` as derived kernel code — correct. |
| B2 | M | build.sh: build every module per GKI KMI via ddk-min docker into dist/<kmi>/ | 79f1eff (build.sh, root .gitignore, README skeleton), dfde4b2 (android14-6.1 tag), 181910d (drop NEEDHDR/-I machinery), d9b104c (6.1 host-share target line) | build.sh (skeleton `build_mod` + module target lines — SPLIT: targets for kvcalloc/gh_unmovable/udmabuf could ride here or in B3/B7/B8), .gitignore, README.md (intro + layout paragraphs, SPLIT) | Route-agnostic packaging infra. `gunyah_host_share/GKI6.6/docker_exec.sh` + `GKI6.6/.gitignore` (97cf7e0) are the pre-build.sh recipe — see "consider dropping". |
| B3 | M | gunyah_kvcalloc: reproduce the 6.1 gh_vm_mem_alloc kvcalloc fix (>2GB guest pinned-page array) as a kprobe module | 79f1eff (kvcalloc part), 181910d (vendor gh_vm layout, drop vm_mgr.h), e46764b (kvcalloc hunks: kallsyms-resolve `account_locked_vm`/`gh_rm_get_vmid`, diag pr_errs), f491c7a (SPDX) | gunyah_kvcalloc/GKI6.1/Makefile, gunyah_kvcalloc/GKI6.1/README.md, gunyah_kvcalloc/GKI6.1/gunyah_kvcalloc_mod.c, build.sh (kvcalloc target, SPLIT), README.md (kvcalloc section, SPLIT), descr/gunyah_kvcalloc.html (SPLIT with B4 if per-module) | **M, not G**: it patches Gunyah's VM-memory pinning (`gh_vm_mem_alloc/reclaim`) so a large guest boots on downstream 6.1 at all — needed by ANY >2GB VM, no GPU dependency, nothing GPU-side calls it. Note e46764b's message records a known outstanding double-free ("BUG: Bad page state on gh_vm_free") on OPPO 6.1.118 — say so in the commit or fix first. |
| B4 | M | ship each module's "why is this needed" page and its device rules alongside the .ko | 357c863 (descr/, match.json, build.sh `build_descr`/`stage_match`, README) | descr/style.css, descr/gh_unmovable.html, descr/gunyah_host_share.html, descr/gunyah_kvcalloc.html, descr/udmabuf.html, match.json, build.sh (staging functions, SPLIT), README.md (SPLIT) | Module-manager plumbing = M. Alternative: keep only style.css/match.json/build.sh here and put each `descr/<module>.html` in that module's commit (B3/B5/B7/B8). 357c863 ALSO hid ~90 lines of host_share 6.12 logic under this subject — those go to B5, not here. |
| B5 | G | gunyah_host_share: runtime SHARE_BLOB module for upstream gunyah (6.6/6.12) — liveness-GC reclaim, bounded retry, kvcalloc page array, 6.12 label namespace + RESET_FAILED | 97cf7e0, 93d4184, ed85989, b14d65e (move; .ko dropped), 6e8b7d3, 79f1eff (move), cf2d43a, 357c863 (rename `gunyah_share_66.c` -> `gunyah_share_mod.c` + `pr_fmt` + `vm_status_off`/`GHSM_LABEL_NS`/`reset_failed` hunks), f491c7a (SPDX) | gunyah_host_share/GKI6.6/gunyah_share_mod.c, gunyah_host_share/GKI6.6/uapi_gunyah_share.h, gunyah_host_share/GKI6.6/.gitignore, gunyah_host_share/GKI6.6/docker_exec.sh (or drop), build.sh (6.6/6.12 targets, SPLIT), README.md (host_share section, SPLIT), descr/gunyah_host_share.html (if per-module) | Used by every route (BAR runtime-share, dynamic pool grow) -> G. `uapi_gunyah_share.h` is byte-identical to lateautumn233's 6.1 header and the module was "adapted from the l233 6.1 module" (97cf7e0) — put a `Co-authored-by: lateautumn233` / "based on" line in the message. Optionally split into two commits: (a) v1 module, (b) 6.12 support (label NS + RESET_FAILED) — the latter is a distinct feature buried in 357c863. |
| B6 | G | *(other author, keep)* refactor(ghsm): switch mem_entries to kvcalloc — lateautumn233 | 0a9d951 | gunyah_host_share/GKI6.6/gunyah_share_mod.c | Applies on top of B5 (its parent 357c863 is folded there). No HuJK follow-up touches it. |
| B7 | G | host-share: 6.1 downstream gh_* SHARE_BLOB module (Crosvm-Android/gunyah_share_mod) — **AUTHOR lateautumn233** + HuJK follow-up | d9b104c (source), e46764b (GKI6.1 hunk: kallsyms-resolve `account_locked_vm`/`gh_rm_get_vmid` on OPPO 6.1.118), f491c7a (SPDX) | gunyah_host_share/GKI6.1/README.md, gunyah_host_share/GKI6.1/gunyah_share_mod.c, gunyah_host_share/GKI6.1/uapi_gunyah_share.h, build.sh (6.1 target, SPLIT) | Byte-identical to lateautumn233's 2a8df05. Recommend: commit B7a with lateautumn233 authorship (the three files as they were), then B7b HuJK "6.1: resolve unexported symbols via kallsyms" (5 lines) as the follow-up that only fixes it. GKI6.1/README.md is Chinese and references l233's local backup path `~/gunyah-share-backup-129ebe2013a8/` — stale, trim. |
| B8 | G | gh_unmovable: non-movable pinnable memory for small GPU blobs (all KMIs) | d1aef9f, f491c7a (SPDX) | gh_unmovable/GKI6.6/gh_unmovable.c, build.sh (3 targets, SPLIT), README.md (section, SPLIT), descr/gh_unmovable.html (if per-module) | Bucketed G as instructed, BUT: the only caller in the tree today is gfxstream host (`host/vulkan/VkDecoderGlobalState.cpp` small-blob memfd retype); nothing in virglrenderer/crosvm/venus/drm2kgsl calls `GH_UNMOVABLE_MAKE`. The mechanism (make any memfd FOLL_LONGTERM-pinnable for gunyah_share) is route-agnostic, so G is defensible; if the owner buckets by consumer it is X. |
| B9 | G | udmabuf: /dev/udmabuf provide / override / paramonly module for GKI 6.1/6.6/6.12 (kvmalloc arrays, size/list limits, CFI-safe seals, folio-era override, LTO-rename escape hatch) | 97db2f0, 5048681 (module part), 882e20c, d47171f, b61bb46, 63bbe97, ad6fbc5, eeb6052, 9c7557e; 6ad6378 nets to zero (see below); f491c7a (SPDX on udmabuf_test — goes to B10) | udmabuf/udmabuf.c, build.sh (3 targets, SPLIT), README.md (udmabuf section, SPLIT), descr/udmabuf.html (if per-module) | **G, not D-only**: consumers are crosvm's virtio-gpu guest-alloc import (`devices/src/virtio/gpu/*` — serves gfxstream, venus and drm2kgsl guest-alloc, and guest-alloc'd scanout resources), gfxstream host `common/base/UdmabufCreator_linux.cpp`, virglrenderer venus `vkr_device_memory.c` and `drm2kgsl_renderer.c`. `match.json` even says "nothing Gunyah about it: any SoC". Could be split into (a) native provider 97db2f0, (b) override + limits, (c) CFI/folio/LTO hardening — but the file was rewritten so many times that one commit is the honest flatten. |
| B10 | G | udmabuf: on-device tests (udmabuf_test create/list/CLOEXEC/pattern; udmabuf_stress entry-count ladder) | 5048681 (udmabuf_test.c), 4e276e5, f491c7a (SPDX) | udmabuf/udmabuf_test.c, udmabuf/udmabuf_stress.c | Test programs; keep or drop with B9. |
| B11 | D | udmabuf: kgsl_frag_test — measure whether KGSL imports a fragmented dma-buf | 0d899ae | udmabuf/kgsl_frag_test.c | drm2kgsl-only measurement harness (GPUOBJ_IMPORT / GPUMEM_BIND_RANGES over a scattered udmabuf). See "consider dropping". |

X: none. V: none.

### Other-author commits (keep authorship)
- **0a9d951 lateautumn233** "refactor(ghsm): switch mem_entries to kvcalloc" — keep verbatim as B6, directly after B5. Merge a951453 (HuJK) is empty and disappears.
- **Hidden lateautumn233 material inside HuJK's d9b104c** (GKI6.1 module, header, README = l233's 2a8df05 verbatim) and **97cf7e0** (uapi header identical; module adapted from it): see B5/B7 notes. HuJK's e46764b GKI6.1 hunk only fixes lateautumn233's module (B7b).

### Nets to zero / disappears in flatten
- Placeholders `GKI6.1/.gitkeep`, `GKI6.12/.gitkeep` (b14d65e) -> removed by 79f1eff / d9b104c.
- Path moves `gunyah_share_66.c` -> `GKI6.6/` (b14d65e) -> `gunyah_host_share/GKI6.6/` (79f1eff) -> `gunyah_share_mod.c` (357c863); `.gitignore`/`docker_exec.sh`/`uapi_gunyah_share.h` moves likewise. Only final paths exist.
- 79f1eff kvcalloc `#include "vm_mgr.h"` + build.sh `NEEDHDR` / `-I<kdir>/drivers/virt/gunyah` machinery -> removed by 181910d.
- 79f1eff build.sh 6.1 tag `android15-6.1` -> dfde4b2 `android14-6.1`.
- 5048681 mode names `hijack`/`noop` -> 63bbe97 `override`/`paramonly`; 882e20c module list_limit default 8192 -> d47171f 16384; 882e20c "raise built-in list_limit" as the primary path -> b61bb46 ioctl redirect (the raise survives only as paramonly/fallback).
- **6ad6378** (memfd_fcntl third arg `unsigned long`) -> **eeb6052** removed the kallsyms memfd_fcntl pointer entirely (reads `SHMEM_I()->seals`). 6ad6378 nets to zero; its lesson is in eeb6052's message.
- a951453 merge commit.

### Consider dropping from the PR
- **`gunyah_host_share/GKI6.6/package/ko/gunyah_share_66/android15-6.6.ko`** (34 KB prebuilt, added by b14d65e; tracked despite `GKI6.6/.gitignore` listing `package/` and `*.ko`). Build artifact — drop.
- **`gunyah_host_share/GKI6.6/docker_exec.sh`** — original DDK docker recipe (97cf7e0), unreferenced by anything in the repo, superseded by `build.sh`, and it copies a `/src/abi/kapi_abi.gen.h` that does not exist here. Drop (and then `GKI6.6/.gitignore` can be folded into the root `.gitignore`).
- **`udmabuf/kgsl_frag_test.c`** (B11) — one-off measurement to answer a design question ("does KGSL take a multi-entry sg_table?"); the answer is recorded in 0d899ae's message. Evidence scaffolding; drop or keep as a test.
- **`gunyah_host_share/GKI6.1/README.md`** — Chinese notes referencing l233's `~/gunyah-share-backup-...` and "命门探针" probe; stale for a PR. Trim to the essentials or drop (the module header comment repeats it in English).
- README.md still says "v5:" and describes history ("was ... now ..."); tidy in B2/B4/B5/B9 splits.
- kvcalloc's known double-free (e46764b message) — decide before shipping B3.

### SPLIT NEEDED files
- `build.sh`: skeleton + `build_mod` (B2) | 6.6/6.12 host-share targets (B5) | 6.1 host-share target (B7) | kvcalloc target (B3) | gh_unmovable targets (B8) | udmabuf targets + comment (B9) | `build_descr`/`stage_match` + `descr` verb (B4). Simplest alternative: whole build.sh in B2 as it stands (all targets present up-front) — the owner may prefer that over 6 hunks.
- `README.md`: intro/layout (B2) | host_share section (B5/B7) | kvcalloc section (B3) | gh_unmovable section (B8) | udmabuf section (B9) | descr/match paragraph (B4).
- `gunyah_host_share/GKI6.6/gunyah_share_mod.c`: v1..v5 + kvcalloc pages + 6.12 hunks + pr_fmt (B5) | mem_entries kvcalloc (0a9d951, B6).
- `gunyah_host_share/GKI6.1/gunyah_share_mod.c`: l233 verbatim (B7a) | e46764b kallsyms hunk (B7b) | SPDX (B1's rule, lands in B7a).
- `gunyah_kvcalloc/GKI6.1/gunyah_kvcalloc_mod.c`: 79f1eff+181910d (B3) | e46764b diag/kallsyms (B3, or a B3b "6.1: resolve unexported symbols" together with B7b — e46764b touched both modules for the same OPPO 6.1.118 reason; keeping e46764b as ONE small commit after B3 and B7 is a valid alternative).
- `descr/*.html`: all in B4, or one per module (B3/B5/B8/B9) — owner's call.

### Open questions / decisions for the owner
1. Base: from empty (as instructed) vs on top of b14d65e (org default, already an ancestor). On b14d65e the pre-existing `GKI6.6/gunyah_share_66.c` v1-v5, `docker_exec.sh`, `.gitignore`, `.ko`, `uapi_gunyah_share.h`, README stub are already there and B5 becomes move+rename+6.12 changes.
2. Attribution of lateautumn233's 6.1 module (B7) and the shared uapi header (B5): separate authored commit vs Co-authored-by.
3. gh_unmovable: G (mechanism) or X (sole consumer is gfxstream host)?
4. kvcalloc: confirmed M (VM-memory fix, not GPU) — agree?
5. udmabuf: one commit or split provider / override / hardening?
6. Keep e46764b as one cross-module commit ("6.1 OPPO 6.1.118: kallsyms-resolve account_locked_vm/gh_rm_get_vmid") after B3+B7, or fold per module as listed.
7. Whether descr/*.html live in B4 or per module.

### Coverage check
- all original commits assigned: **yes** — 97cf7e0 (B5; docker_exec/.gitignore consider dropping), 93d4184 (B5), ed85989 (B5), b14d65e (B5 move; .ko drop; README stub B2), 6e8b7d3 (B5), 79f1eff (B2/B3), d9b104c (B7/B2), 181910d (B3/B2), dfde4b2 (B2), cf2d43a (B5), d1aef9f (B8), 97db2f0 (B9), 5048681 (B9/B10), 0d899ae (B11), 882e20c (B9; partly nets to zero), d47171f (B9), b61bb46 (B9), f491c7a (B1 + SPDX lines), 4e276e5 (B10), 63bbe97 (B9), 357c863 (B4/B5), 46664b4 (B1), 0a9d951 (B6, other author), a951453 (merge, disappears), e46764b (B3/B7b), 6ad6378 (nets to zero via eeb6052), ad6fbc5 (B9), eeb6052 (B9), 9c7557e (B9).
- all net files assigned: **yes** — 29 files: 4 licensing (B1); .gitignore, build.sh, README.md (B2 + splits); descr/* x5, match.json (B4); gh_unmovable/GKI6.6/gh_unmovable.c (B8); gunyah_host_share/GKI6.1/* x3 (B7); gunyah_host_share/GKI6.6/{gunyah_share_mod.c,uapi_gunyah_share.h} (B5/B6), GKI6.6/.gitignore + docker_exec.sh (B5 or drop), GKI6.6/package/.../android15-6.6.ko (drop); gunyah_kvcalloc/GKI6.1/* x3 (B3); udmabuf/udmabuf.c (B9); udmabuf/udmabuf_test.c, udmabuf/udmabuf_stress.c (B10); udmabuf/kgsl_frag_test.c (B11 or drop).
