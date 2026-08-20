# mesa (Droid-VM/mesa fork) — three branches, three PR sections

All git refs below are from the main clone `/root/gitrs/DroidVM/DroidVM_3daccel_gfxstream/mesa`.
Author key: HuJK = owner; lateautumn233 = other author (Droid-VM member); Mike Blumenkrantz = upstream
cherry-picks. Buckets per PREAMBLE: L licensing, M misc/build, G shared GPU/zink/wsi, D drm2kgsl/turnip,
X gfxstream ICD, V venus. "SPLIT" = one original commit's hunks go to more than one proposed commit.

Cross-branch facts that matter for all three sections:
- The two licensing commits are byte-identical (patch-id) on both bases: f08df78d0d0 == 732d5cbbc42,
  3f37b680916 == 9be474f1658. One flattened L commit serves every PR.
- The 6 Mike Blumenkrantz zink/tc commits (MR 42222 / 42388) are cherry-picks that exist twice with
  different SHAs (gfxstream branch 66736e76726..512f8000316, venus branch b1c43db9b02..0873b05d7bc;
  patch-ids identical). Their upstream originals (a4c07ed8819, 2c5a2d8b398, 8faf71d84f0, 4f79fe382c7,
  d79f6399961, 467022beeea) are ALREADY ancestors of the drm2kgsl base 74d4e41b2bb (mesa main), so they
  are needed only on the two 26.0.3-based PRs and must NOT be carried onto the drm2kgsl PR.
- The zink/kopper stale-dt_idx guard (e14d2e5fc2c) exists only on the venus branch but is a zink fix
  every route that runs zink hits (see memory note "kopper race worked around" — acceptance ran it on
  all 3 routes). It is G and should go on all three PRs (rebased per base).
- The gfxstream and venus PRs sit on 26.0.3 (3f173c02d16); the drm2kgsl PR sits on mesa main
  (74d4e41b2bb, 2026-08-07). Three different bases is a decision for the owner (see open questions).

---

## (1) mesa — base 3f173c02d16 (upstream 26.0.3, "VERSION: bump for 26.0.3") .. 512f8000316 (wip/3d-accel-gfxstream)  40 original commits, 31 net files

Original order (for reference): 2168f8e1e34 (lateautumn233 wip) → 33 HuJK commits → 6 Blumenkrantz
cherry-picks at the tip. Recommended PR order: backports first, then L, M, G, X.

### Proposed flattened commits (in order)

| # | bucket | proposed subject | folds original commits | net files (paths) | notes |
|---|--------|------------------|------------------------|-------------------|-------|
| B1 | G (backport) | zink: tag tc info update in a few more places | 66736e76726 | src/gallium/drivers/zink/zink_blit.c, zink_context.c (4 lines), zink_resource.c | Mike Blumenkrantz, cherry-pick of a4c07ed8819 (MR 42222). Keep verbatim, first after base. |
| B2 | G (backport) | util/tc: iterate the rp info more accurately during batch execution | 7bd536a494e | src/gallium/auxiliary/util/u_threaded_context.c | Mike Blumenkrantz, 2c5a2d8b398. Keep verbatim. |
| B3 | G (backport) | aux/tc: enforce strict resolve semantics | 96e71d32601 | src/gallium/auxiliary/util/u_threaded_context.h | Mike Blumenkrantz, 8faf71d84f0. Keep verbatim. |
| B4 | G (backport) | util/tc: store resolve geometry to rp info | 80eb5b4066c | u_threaded_context.c, u_threaded_context.h | Mike Blumenkrantz, 4f79fe382c7 (MR 42388). Keep verbatim. |
| B5 | G (backport) | util/tc: unset TC_RESOLVE_STRICT | 99c7f0e3c76 | u_threaded_context.h | Mike Blumenkrantz, d79f6399961. Keep verbatim. |
| B6 | G (backport) | zink: use tc info to handle partial resolves | 512f8000316 | src/gallium/drivers/zink/zink_context.c (39 lines) | Mike Blumenkrantz, 467022beeea. Keep verbatim. Together B1-B6 are the whole net diff of the 5 gallium files. |
| 1 | L | licensing: GPL by default, with permission to take it upstream | f08df78d0d0, 3f37b680916 | ADDITIONAL-PERMISSIONS, CONTRIBUTING.md, LICENSE.GPL-3.0, LICENSING.md | Fold the attribution fix (HuJK → Droid-VM organisation) into the original so ADDITIONAL-PERMISSIONS is right from the start. Same content as 732d5cbbc42+9be474f1658 on drm2kgsl. |
| 2 | M | build: ignore build-cross/ and install-cross/ | .gitignore hunk of 207f1816f0e (SPLIT) | .gitignore | 2 lines. Cross-build scratch dirs; only exists because 69c0ddb1761 once committed a 22 MB install-cross/ tree. Owner may fold into #1 or drop. |
| 3 | G | util/perf: don't format a trace name when no tracing backend is compiled in | 89375e82401 | src/util/perf/cpu_trace.h | Generic mesa util (skips vsnprintf in _mesa_trace_scope_begin when no perfetto/gpuvis/sysprof/atrace). Motivated by gfxstream's per-entrypoint MESA_TRACE_SCOPE, but benefits every driver; independently upstreamable. Belongs on gfxstream PR for sure; optional on venus. |
| 4 | X | gfxstream guest: pass VK_EXT/KHR_robustness2 through and tolerate null buffer descriptors | 2168f8e1e34 (robustness2 parts: cerealgenerator.py SUPPORTED_FEATURES + allowlist + null guard in on_vkUpdateDescriptorSetWithTemplate) | src/gfxstream/codegen/scripts/cerealgenerator.py, src/gfxstream/guest/vulkan_enc/ResourceTracker.cpp (allowlist lines "VK_EXT_robustness2"/"VK_KHR_robustness2"; on_vkUpdateDescriptorSetWithTemplate null guard) | AUTHOR lateautumn233 ("wip"). Keep authorship, rewrite subject/body. Zink needs nullDescriptor; without KHR alias in codegen the feature struct is not marshalled. |
| 5 | X | gfxstream guest: back every exportable allocation with a blob, dedicated resource or not | 2168f8e1e34 (on_vkAllocateMemory: `else if (hasDedicatedBuffer)` → `else`, drop the "not exportable" warning, swap importCbInfo/importBufferInfo selection to keyed on hasDedicatedImage) | ResourceTracker.cpp (on_vkAllocateMemory) | AUTHOR lateautumn233 (second half of the same "wip"). Fixes wsi_drm_check_dma_buf_sync_file_import_export probe (4096-byte export with no dedicated resource). Suggest 2 lateautumn233 commits (#4, #5); or one if the owner prefers not to split another author's commit. HuJK's #15 builds on this hunk (`if (bufferBlob && !guestBlobExport)`). |
| 6 | X | gfxstream guest: unroll push-descriptor templates guest-side, expose VK_KHR_push_descriptor | 9f65df6ece5 (minus the HOSTEXT stderr block → #17, minus the 2 allowlist lines → #7) | src/gfxstream/codegen/scripts/cereal/functable.py, src/gfxstream/guest/vulkan/gfxstream_vk_cmd.cpp, ResourceTracker.cpp (allowedExtensionNames.push_back("VK_KHR_push_descriptor"), initDescriptorUpdateTemplateBuffers pipelineBindPoint, on_vkCmdPushDescriptorSetWithTemplate), ResourceTracker.h (on_vkCmdPushDescriptorSetWithTemplate decl, pipelineBindPoint field) | Host cannot decode untyped pData; guest expands into typed vkCmdPushDescriptorSet. CLEANUP: ResourceTracker.cpp still carries the stale comment block "VK_KHR_push_descriptor is withheld for now …" plus a commented-out `// "VK_KHR_push_descriptor",` in the allowlist, and the "opt-in per process" paragraph directly contradicted by the next paragraph "is now always safe" — rewrite into one accurate comment when flattening. Inline-uniform-block entries are skipped with a logw (documented limitation). |
| 7 | X | gfxstream guest: allow VK_EXT_multi_draw, VK_EXT_vertex_attribute_divisor and VK_KHR_16bit_storage through | 7a4ba5af11d + the two `"VK_EXT_multi_draw"`, `"VK_EXT_vertex_attribute_divisor"` lines of 9f65df6ece5 (SPLIT) | ResourceTracker.cpp (allowlist) | Pure allowlist additions, host-gated by the intersection. Minecraft 26.2 needs the first two, llama.cpp the third. Could instead be folded into #6. |
| 8 | X | gfxstream guest: GFXSTREAM_MAP_LOW -- place host-visible maps in the low 4GB for 32-bit callers | 7596f6fa0f3, aec9c5ed48e, 52fd76a0b0c | src/gfxstream/guest/platform/drm/DrmVirtGpuBlob.cpp, DrmVirtGpuBlobMapping.cpp | Env-gated (default off, zero effect otherwise): MAP_FIXED_NOREPLACE bump+free-list arena in [1GiB, 3.75GiB) for wine/FEX/DXVK 32-bit callers. Comment literally says "DroidVM experiment"; upstream may see it as niche — owner decides whether it goes in the PR at all (listed under "consider dropping" too). |
| 9 | X | gfxstream guest: gate goldfish-only submit signalling on the platforms that actually signal | f4de8ff9847, 82b6fb7d25f | ResourceTracker.cpp (on_vkQueueSubmitTemplate: semaphore-prune guard + vkQueueWaitIdle block guard, `#if defined(VK_USE_PLATFORM_FUCHSIA) \|\| GFXSTREAM_ENABLE_GUEST_GOLDFISH`) | The two originals are deliberately a pair (dropping the WaitIdle stall is only safe once the semaphore prune is also gated). One commit is cleanest; keeping them as the original two is also fine (both messages are strong). vkmark 3792-4081 → 4468. |
| 10 | X | gfxstream guest: forward sampler/image-view pNext structs on Linux too | 0ef0122a5f9 | ResourceTracker.cpp (on_vkCreateSampler, on_vkCreateImageView) | Ungate YCbCr/custom-border-colour re-append; move chain iterator out of the Android guard; add VkImageViewUsageCreateInfo. Clean upstream candidate. |
| 11 | X | gfxstream guest: advertise VK_KHR_display so apps can present fullscreen | 7177dd271f7 | src/gfxstream/guest/vulkan/gfxstream_vk_device.cpp (kGuestEmulatedInstanceExtensions GFXSTREAM_VK_DISPLAY block, `display_fd = -1`), gfxstream_vk_wsi.cpp, src/gfxstream/guest/vulkan/meson.build, src/gfxstream/guest/vulkan_enc/gfxstream_vk_private.h | Opens the virtio-gpu primary node and hands it to wsi_device_init. Clean upstream candidate. |
| 12 | X | gfxstream guest: wake a parked host from every transport wait, and stop holding a vCPU for fifty million turns before sleeping | 6e2fea908a3, 7b9c82ea61f, cea499343cf, 5de944cbf18, plus the speculativeRead "pingedHost" hunk hidden inside 207f1816f0e (SPLIT) | src/gfxstream/guest/GoldfishAddressSpace/AddressSpaceStream.cpp (ensureType1Finished ping, speculativeRead ping, writeFullyAsync `\|\| deepWaitWantsPing()`, deepWaitWantsPing(), backoffSpinsBeforeSleep(), backoff()/resetBackoff() rewrite, m_lastSentOpcode capture in type1Write, "no reply to opcode" once-per-stream logw), AddressSpaceStream.h (deepWaitWantsPing decl, m_lastPingNs, m_sleepTurns, m_lastSentOpcode, m_reportedDeepWait) | Could be split in two (a: pings — 6e2fea908a3+7b9c82ea61f+207f speculativeRead hunk; b: backoff — cea499343cf), but cea499343cf reworks the ping rate limit of 7b9c82ea61f so one commit reads cleaner. CLEANUP: `uint64_t m_deepWaitPingCountdown` in AddressSpaceStream.h is dead (declared by 7b9c82ea61f, its only use removed by cea499343cf) — drop. Env: GFXSTREAM_GUEST_BACKOFF_SPINS. 5de944cbf18 (name the opcode a stalled stream waits for) is rate-limited to already-broken waits; keep here or in #18. |
| 13 | X | gfxstream guest: do not build a stream before the host has sized it | d6d482a7320 | src/gfxstream/guest/GoldfishAddressSpace/VirtioGpuAddressSpaceStream.cpp | Wait (≤2 s) for ring_config->flush_interval. Own message admits it never fires today; small robustness guard. |
| 14 | X | gfxstream guest: report the guest-alloc pool through VK_EXT_memory_budget | add5bfd6821, 207f1816f0e (main part; .gitignore → #2, speculativeRead hunk → #12) | src/virtio/virtio-gpu/virtgpu_gfxstream_protocol.h (guestAllocOffsetMb/SizeMb), src/gfxstream/guest/platform/drm/DrmVirtGpuDevice.cpp (init log + getGuestPoolInfo), src/gfxstream/guest/platform/drm/DrmVirtGpu.h, src/gfxstream/guest/platform/include/VirtGpu.h (VirtGpuGuestPoolInfo, getGuestPoolInfo), src/gfxstream/codegen/scripts/cereal/common/vulkantypes.py, src/gfxstream/codegen/scripts/cereal/transform.py, ResourceTracker.cpp (transformImpl_VkPhysicalDeviceMemoryProperties2_fromhost/_tohost), ResourceTracker.h (protos) | Depends on droidvm-guest-additions virtio-gpu GETPARAMs 0x1000/0x1001/0x1002 (same ids as vdrm_guest_pool_stats on the drm2kgsl branch). NOTE the capset fields guestAllocOffsetMb/SizeMb are only ever logged ("DROIDVM: guest-alloc pool slice") — the guest sub-allocator that add5bfd6821 announced was never written in mesa (the kernel owns the pool). Keep the header for wire-layout parity with the host vulkanCapset; consider dropping the mesa_logi. Also carries the codegen change (whole-struct transformImpl hook) which is generic gfxstream codegen. |
| 15 | X | gfxstream guest: exportable host-visible memory lives in guest pages on a pVM | 940052fc559, ec2ae71e316, ba0037b9932 | ResourceTracker.cpp (on_vkAllocateMemory: guestBlobExport route for import/dedicated-image/dedicated-buffer/no-dedicated shapes, blobId = pid<<32\|counter, mGuestBlobExports registry, immediate CoherentMemory mapping; on_vkMapMemory: drop kParamCreateGuestHandle gate, vkGetMemoryHostAddressInfoGOOGLE fallback, page-aligned mapSize; ALLOC-FAIL loge at every silent return), ResourceTracker.h (GuestBlobExport, mGuestBlobExports) | The gfxstream-route counterpart of D 43f30bb6413 and V 61f7f4c7e53 (guest pool + CREATE_GUEST_HANDLE). ba0037b9932's ALLOC-FAIL messages are error-path logging — keep. The `ALLOC-ROUTE[...]` std::call_once mesa_logw (4 lines per process, from 940052fc559) is investigation output — consider dropping (listed below). Requires host gfxstream + crosvm udmabuf import; verified kwin scanout + readback. |
| 16 | X (diag) | gfxstream guest: profile the transport waits and image-creation shapes behind env switches | 3238b4a62d7, 6c5ecd8beb5 | AddressSpaceStream.cpp (StreamWaitProfile / streamProfBegin/End/Report, `#include <time.h>`, streamProfEnd calls in readFully/ensureType1Finished/ensureType3Finished), ResourceTracker.cpp (on_vkCreateImage GFXSTREAM_IMAGE_TRACE block) | GFXSTREAM_STREAM_PROFILE(_SEC), GFXSTREAM_IMAGE_TRACE. Off by default; cost when off = one thread_local bool compare per wait. Investigation instrumentation — see "consider dropping". |
| 17 | X (diag) | gfxstream guest: put the extension tracing behind GFXSTREAM_EXT_TRACE | 197a3d5f264, ZC-EXTDBG block of 2168f8e1e34 (SPLIT, lateautumn233), HOSTEXT block of 9f65df6ece5 (SPLIT) | src/gfxstream/guest/vulkan/gfxstream_vk_device.cpp (get_device_extensions ZC-EXTDBG), ResourceTracker.cpp (HOSTEXT block after allowlist) | Two one-shot fprintf(stderr) reports about robustness/MC extensions, now env-gated. Recommendation: drop all three hunks; then 197a3d5f264 disappears entirely and #4/#6 lose their debug prints. If kept, note it partly touches lateautumn233's hunk. |
| 18 | X (diag) | gfxstream guest: record the first transfers a stream hands to the ring | 1c1f1d86d12 | AddressSpaceStream.cpp (type1Write GUEST-XFER block), AddressSpaceStream.h (m_reportedXfers) | UNCONDITIONAL: 3 mesa_logw lines per stream at startup, hex dump of first 12 bytes. Its own message says the comparison came out identical every time ("puts the framing fault above the transport"). Consider dropping. |

### Other-author commits (keep authorship)
- Mike Blumenkrantz, 6 upstream cherry-picks (B1-B6 above: 66736e76726, 7bd536a494e, 96e71d32601, 80eb5b4066c, 99c7f0e3c76, 512f8000316). Keep verbatim including "(cherry picked from …)" trailers, first after base. Needed on 26.0.3 only; already in mesa main. Root-cause reference: memory note "venus MC tc rp-info deadlock" (zink 26.0.3 tc renderpass-info desync).
- lateautumn233 2168f8e1e34 "wip" (2026-06-21): three unrelated things in one commit — (a) robustness2 codegen alias + allowlist + null-descriptor guard (→ #4), (b) ZC-EXTDBG debug prints (→ #17 / drop), (c) non-dedicated exportable memory gets a blob (→ #5). Recommend cherry-picking it as one or two lateautumn233-authored commits with a real subject; HuJK's 197a3d5f264 is a follow-up that only gates (b) — if (b) is dropped, 197a3d5f264 disappears. HuJK's 940052fc559 (#15) later rewrites the same on_vkAllocateMemory tail, so #4/#5 must precede #15.

### Nets to zero / disappears in flatten
- fd36a661709 (async vkResetCommandPool) + b0a3d691137 (its revert): zero (vk_gfxstream.xml + gfxstream_vk_cmd.cpp both restored).
- 802f4d5831a (thread-local seqno) + f80a84b5c10 (its revert): zero (gfxstream_vk_device.cpp + ResourceTracker.cpp restored).
- c4f08227484 + bee068b6c90 (stuck-wait ring dump + packet-length census) + 7dfd94ff794 (removes both): net residue is 3 blank lines in AddressSpaceStream.cpp (after `#include "AddressSpaceStream.h"` and after allocBuffer()) — whitespace only, drop in the flatten.
- 3 of the 4 things 207f1816f0e's message describes are real (memory budget), but the commit also carries the .gitignore lines and an unrelated speculativeRead ping hunk (re-authored copy of 69c0ddb1761 picked up extra hunks) — see SPLIT.

### Consider dropping from the PR
- #17 extension tracing (ZC-EXTDBG in gfxstream_vk_device.cpp, HOSTEXT in ResourceTracker.cpp, and 197a3d5f264): one-off investigation prints to stderr.
- #18 GUEST-XFER dump (1c1f1d86d12): unconditional startup log noise; its investigation concluded.
- #16 STREAMPROF + IMAGETRACE (3238b4a62d7, 6c5ecd8beb5): env-gated profiling scaffolding; useful for the owner, unlikely to be accepted upstream as-is.
- ALLOC-ROUTE once-per-shape mesa_logw inside #15 (from 940052fc559): 4 lines per process, investigation output; the ALLOC-FAIL error-path messages in the same commit are worth keeping.
- "DROIDVM: guest-alloc pool slice" mesa_logi at ICD init inside #14 (add5bfd6821): only consumer of the capset fields; header change itself is harmless.
- #8 GFXSTREAM_MAP_LOW arena: self-described "DroidVM experiment", env-gated; works (Unigine Heaven 32-bit via DXVK) but is a niche 32-bit-under-FEX workaround. Owner's call whether it belongs in an upstream-facing PR.
- Stale comments in #6 (the "withheld for now"/"opt-in per process" paragraphs and the commented-out allowlist entry) — must be cleaned even if everything else is kept.
- Dead member `m_deepWaitPingCountdown` (AddressSpaceStream.h) — remove in #12.

### SPLIT NEEDED files
- src/gfxstream/guest/vulkan_enc/ResourceTracker.cpp → #4 (allowlist robustness2 lines; on_vkUpdateDescriptorSetWithTemplate null guard), #5 (on_vkAllocateMemory `else` branch + importCbInfo/importBufferInfo swap + removed warning), #6 (push_descriptor push_back + pipelineBindPoint record + on_vkCmdPushDescriptorSetWithTemplate), #7 (multi_draw / vertex_attribute_divisor / 16bit_storage allowlist lines), #9 (on_vkQueueSubmitTemplate two `#if` guards), #10 (on_vkCreateSampler / on_vkCreateImageView), #14 (transformImpl_VkPhysicalDeviceMemoryProperties2_*), #15 (on_vkAllocateMemory guest-blob export path, on_vkMapMemory rewrite, ALLOC-FAIL/ALLOC-ROUTE), #16 (on_vkCreateImage IMAGETRACE), #17 (HOSTEXT block).
- src/gfxstream/guest/vulkan_enc/ResourceTracker.h → #6 (on_vkCmdPushDescriptorSetWithTemplate, pipelineBindPoint), #14 (transformImpl protos), #15 (GuestBlobExport / mGuestBlobExports).
- src/gfxstream/guest/GoldfishAddressSpace/AddressSpaceStream.cpp → #12 (all ping / deepWaitWantsPing / backoff / m_lastSentOpcode / "no reply to opcode"), #16 (StreamWaitProfile block + streamProfBegin/End call sites + `#include <time.h>`), #18 (GUEST-XFER block in type1Write); drop the 3 leftover blank lines.
- src/gfxstream/guest/GoldfishAddressSpace/include/AddressSpaceStream.h → #12 (deepWaitWantsPing, m_lastPingNs, m_sleepTurns, m_lastSentOpcode, m_reportedDeepWait), #18 (m_reportedXfers); drop m_deepWaitPingCountdown.
- src/gfxstream/guest/vulkan/gfxstream_vk_device.cpp → #11 (display extension block, `display_fd = -1`), #17 (ZC-EXTDBG block).
- 207f1816f0e (original) → #2 (.gitignore), #12 (speculativeRead pingedHost hunk), #14 (everything else).
- 9f65df6ece5 (original) → #6, #7 (2 allowlist lines), #17 (HOSTEXT).
- 2168f8e1e34 (original, lateautumn233) → #4, #5, #17.

### Open questions / decisions for the owner
1. Whether #4/#5 (lateautumn233's "wip") is cherry-picked as one commit or split in two; either way needs a rewritten subject while keeping `Author: lateautumn233`.
2. Drop the diagnostics (#16, #17, #18, ALLOC-ROUTE) from the PR, or keep them as a trailing "diagnostics" commit clearly separated from the fixes.
3. Keep #8 GFXSTREAM_MAP_LOW in the upstream-facing PR or hold it back as a DroidVM-only patch.
4. #9 as one commit or the original two.
5. #14 depends on kernel GETPARAM ids 0x1000-0x1002 that are DroidVM-private (same ids used by vdrm on the drm2kgsl branch); #15 depends on host gfxstream/crosvm udmabuf import (upstream reviewers will ask for the host side). #11 (drmGetDevices2 in gfxstream_vk_wsi.cpp) is fine: dep_libdrm is already in gfxstream_deps.
6. Whether the venus-branch kopper guard (e14d2e5fc2c) should be added to this PR too (it is not on this branch today; recommendation: yes, as G).

### Coverage check
- all original commits assigned: yes — 2168f8e1e34→#4/#5/#17; 9f65df6ece5→#6/#7/#17; 7a4ba5af11d→#7; 7596f6fa0f3, aec9c5ed48e, 52fd76a0b0c→#8; add5bfd6821→#14; f4de8ff9847, 82b6fb7d25f→#9; 0ef0122a5f9→#10; 7177dd271f7→#11; 6e2fea908a3→#12; 3238b4a62d7→#16; 89375e82401→#3; 6c5ecd8beb5→#16; fd36a661709+b0a3d691137→zero; 207f1816f0e→#2/#12/#14; 7b9c82ea61f→#12; c4f08227484+bee068b6c90+7dfd94ff794→zero; f08df78d0d0→#1; 197a3d5f264→#17; d6d482a7320→#13; 1c1f1d86d12→#18; 5de944cbf18→#12; 940052fc559, ec2ae71e316, ba0037b9932→#15; 802f4d5831a+f80a84b5c10→zero; cea499343cf→#12; 3f37b680916→#1; 66736e76726, 7bd536a494e, 96e71d32601, 80eb5b4066c, 99c7f0e3c76, 512f8000316→B1-B6.
- all net files assigned: yes — .gitignore→#2; ADDITIONAL-PERMISSIONS, CONTRIBUTING.md, LICENSE.GPL-3.0, LICENSING.md→#1; u_threaded_context.c/.h, zink_blit.c, zink_context.c, zink_resource.c→B1-B6; vulkantypes.py, transform.py→#14; functable.py→#6; cerealgenerator.py→#4; AddressSpaceStream.cpp→#12/#16/#18; VirtioGpuAddressSpaceStream.cpp→#13; AddressSpaceStream.h→#12/#18; DrmVirtGpu.h→#14; DrmVirtGpuBlob.cpp, DrmVirtGpuBlobMapping.cpp→#8; DrmVirtGpuDevice.cpp→#14; VirtGpu.h→#14; gfxstream_vk_cmd.cpp→#6; gfxstream_vk_device.cpp→#11/#17; gfxstream_vk_wsi.cpp, meson.build, gfxstream_vk_private.h→#11; ResourceTracker.cpp→split (see above); ResourceTracker.h→#6/#14/#15; cpu_trace.h→#3; virtgpu_gfxstream_protocol.h→#14.

---

## (2) mesa — base 3f173c02d16 (upstream 26.0.3) .. 0873b05d7bc (wip/3d-accel-venus)  43 original commits (34 shared with gfxstream + 3 venus + 6 backports re-cherry-picked), 34 net files

Shape of the branch: identical to wip/3d-accel-gfxstream up to and including 3f37b680916 (the 34
commits 2168f8e1e34..3f37b680916, merge-base of the two branches), then 3 HuJK venus commits
(61f7f4c7e53, 958d64bb23f, e14d2e5fc2c), then the same 6 Blumenkrantz cherry-picks under new SHAs
(b1c43db9b02, d9a322761fc, b1bb673028d, 803be402b54, 0dc5db14ff5, 0873b05d7bc — patch-ids identical to
66736e76726..512f8000316). Net files = the 31 gfxstream-branch files + zink_kopper.c,
vn_renderer_virtgpu.c, vn_ring.c.

### Which shared commits are generic vs gfxstream-ICD-specific
Generic (a venus PR needs/may carry them):
- B1-B6 zink/tc backports (needed: venus is the route where the tc rp-info deadlock was root-caused).
- L: f08df78d0d0 + 3f37b680916.
- G: 89375e82401 util/perf cpu_trace.h (optional for venus — generic, harmless).
- M: .gitignore hunk of 207f1816f0e (optional).
Gfxstream-ICD-specific (do NOT belong on a venus PR): everything else in the 34 shared commits —
2168f8e1e34, 9f65df6ece5, 7a4ba5af11d, 7596f6fa0f3, aec9c5ed48e, 52fd76a0b0c, add5bfd6821, f4de8ff9847,
82b6fb7d25f, 0ef0122a5f9, 7177dd271f7, 6e2fea908a3, 3238b4a62d7, 6c5ecd8beb5, fd36a661709, b0a3d691137,
207f1816f0e (except .gitignore), 7b9c82ea61f, c4f08227484, bee068b6c90, 7dfd94ff794, 197a3d5f264,
d6d482a7320, 1c1f1d86d12, 5de944cbf18, 940052fc559, ec2ae71e316, ba0037b9932, 802f4d5831a, f80a84b5c10,
cea499343cf. They only touch src/gfxstream/**, src/virtio/virtio-gpu/virtgpu_gfxstream_protocol.h and
the gfxstream codegen scripts; venus never builds them.

### Proposed flattened commits for pr/3d-accel-venus (in order)

| # | bucket | proposed subject | folds original commits | net files (paths) | notes |
|---|--------|------------------|------------------------|-------------------|-------|
| B1-B6 | G (backport) | (as in section 1) | b1c43db9b02, d9a322761fc, b1bb673028d, 803be402b54, 0dc5db14ff5, 0873b05d7bc (== 66736e76726..512f8000316) | u_threaded_context.c/.h, zink_blit.c, zink_context.c, zink_resource.c | Mike Blumenkrantz; keep verbatim, first after base. Same 6 as gfxstream PR — if both PRs are ever stacked, keep one copy. |
| 1 | L | licensing: GPL by default, with permission to take it upstream | f08df78d0d0, 3f37b680916 | ADDITIONAL-PERMISSIONS, CONTRIBUTING.md, LICENSE.GPL-3.0, LICENSING.md | identical to gfxstream #1 |
| 2 | M (optional) | build: ignore build-cross/ and install-cross/ | .gitignore hunk of 207f1816f0e | .gitignore | optional for venus |
| 3 | G (optional) | util/perf: don't format a trace name when no tracing backend is compiled in | 89375e82401 | src/util/perf/cpu_trace.h | generic; optional for venus |
| 4 | G | zink/kopper: do not index the swapchain with a stale dt_idx | e14d2e5fc2c | src/gallium/drivers/zink/zink_kopper.c | Bail out of zink_kopper_acquire_submit when dt_idx is UINT32_MAX / ≥ num_images (tc race on swapchain recreate; Minecraft SEGV). Zink-generic → also wanted on the gfxstream and drm2kgsl PRs. |
| 5 | V | venus: give guest-vram allocations the drm2kgsl guest-alloc wire shape | 61f7f4c7e53 | src/virtio/vulkan/vn_renderer_virtgpu.c | use_guest_vram → bo_blob_mem = HOST3D_GUEST + VIRTGPU_BLOB_FLAG_CREATE_GUEST_HANDLE (0x0008, defined locally if the kernel header lacks it). Venus counterpart of D 43f30bb6413 / X #15. |
| 6 | V | venus: do not take the ring mutex twice for the guest-vram upload roundtrip | 958d64bb23f | src/virtio/vulkan/vn_ring.c | vn_ring_roundtrip_locked(): submit the virtqueue seqno on the mutex-free path, encode the ring-side wait with vn_ring_submit_locked. Fixes kwin self-deadlock on first large shader upload with has_guest_vram. Follow-up to #5 (only reachable with guest vram). |

Minimal venus PR = B1-B6 + #1 + #4 + #5 + #6 (7 net files: 5 gallium tc/zink files, zink_kopper.c,
vn_renderer_virtgpu.c, vn_ring.c, plus the 4 licensing files); #2/#3 optional.

### Other-author commits (keep authorship)
- Mike Blumenkrantz B1-B6 (venus SHAs b1c43db9b02..0873b05d7bc). Verbatim.
- lateautumn233 2168f8e1e34 is on this branch but is gfxstream-only → excluded from the venus PR.

### Nets to zero / disappears in flatten
- Same as section 1 for the shared range (fd36a661709+b0a3d691137, 802f4d5831a+f80a84b5c10, c4f08227484+bee068b6c90+7dfd94ff794).
- The whole gfxstream-ICD set (31 commits) is not "zero" but is out of scope for this PR (moved to the gfxstream PR).

### Consider dropping from the PR
- Nothing venus-specific. (#2, #3 optional as noted.)

### SPLIT NEEDED files
- 207f1816f0e only for its .gitignore hunk if #2 is wanted; otherwise none — the 3 venus commits and the kopper guard each touch exactly one file.

### Open questions / decisions for the owner
1. Confirm the venus PR is cut from 26.0.3 + backports rather than from the full gfxstream branch (i.e. do NOT reuse 3f37b680916 as the venus base — that drags in 27 gfxstream-only files).
2. The kopper guard (#4) is missing from wip/3d-accel-gfxstream and wip/3d-accel-drm2kgsl even though all three routes run zink; add it to both.
3. #5 assumes the DroidVM kernel/VMM contract (HOST3D_GUEST backed from the guest pool + CREATE_GUEST_HANDLE → udmabuf). Upstream venus would want this behind a capset/param probe rather than "use_guest_vram implies it" — worth a sentence in the PR.
4. Whether to include #3 (cpu_trace) — generic; harmless either way.

### Coverage check
- all original commits assigned: yes — 34 shared: see section 1 (all either mapped to gfxstream-only commits and excluded here, or to B/L/M/G rows above); 61f7f4c7e53→#5; 958d64bb23f→#6; e14d2e5fc2c→#4; b1c43db9b02, d9a322761fc, b1bb673028d, 803be402b54, 0dc5db14ff5, 0873b05d7bc→B1-B6.
- all net files assigned: yes — 31 shared files: 5 gallium tc/zink→B1-B6, 4 licensing→#1, .gitignore→#2, cpu_trace.h→#3, remaining 21 gfxstream/codegen/protocol files→gfxstream PR only (excluded); zink_kopper.c→#4; vn_renderer_virtgpu.c→#5; vn_ring.c→#6.

---

## (3) mesa — base 74d4e41b2bb (upstream mesa main, Connor Abbott "tu: Use correct pointer for vis stream patchpoint cs fence", 2026-08-07) .. 9be474f1658 (wip/3d-accel-drm2kgsl)  25 original commits, 22 net files

Shape: this is lateautumn233's Droid-VM/mesa `dev` branch (origin/dev = eef146a7553 is an ancestor of
the tip; `git rev-list origin/dev..wip/3d-accel-drm2kgsl` = 1) plus HuJK's 9be474f1658. 20 of 25 commits
are lateautumn233; HuJK's 43f30bb6413, 4d50b92ec73, 23a873921b7, 732d5cbbc42 were already integrated into
origin/dev. So "flattening" here mostly means: keep lateautumn233's commits as they are (they already
are one-feature-per-commit with real messages, except the CI series), fold the two licensing commits,
squash the 5 CI commits into one, and reorder into L / M / G / D.

### Proposed flattened commits (in order)

| # | bucket | proposed subject | folds original commits | net files (paths) | notes |
|---|--------|------------------|------------------------|-------------------|-------|
| 1 | L | licensing: GPL by default, with permission to take it upstream | 732d5cbbc42, 9be474f1658 | ADDITIONAL-PERMISSIONS, CONTRIBUTING.md, LICENSE.GPL-3.0, LICENSING.md | HuJK. Patch-identical to gfxstream f08df78d0d0+3f37b680916. |
| 2 | M | mesa/main: return an empty string for core-profile GL_EXTENSIONS | 9c8575b06cd | src/mesa/main/getstring.c | lateautumn233. GL core-profile glGetString(GL_EXTENSIONS) returns "" instead of NULL (Qt QEGLPlatformContext strlen crash). GPU-unrelated. Upstream will likely push back (spec says NULL) — flag in PR text. |
| 3 | M (possibly not for PR) | ci: GitHub Actions workflow building the guest mesa GLVND arm64 deb | f4859706843, 6c1364fb4d2, 7889494f1a2, 8654cad05fc, ec44b80bca1 | .github/workflows/guest-mesa-glvnd-deb.yml | lateautumn233 (all five, so squashable while keeping authorship). Builds -Dvulkan-drivers=freedreno -Dgallium-drivers=zink,freedreno for /usr and /usr/local prefixes, excludes gfxstream ICDs. Droid-VM packaging infra — not upstream material; recommend keeping it out of the upstream PR (or last, clearly labelled). |
| 4 | G | wsi/wayland: make the MAILBOX image count configurable (MESA_VK_WSI_WL_MAILBOX_IMAGES) | 200a3027789 | src/vulkan/wsi/wsi_common_wayland.c | lateautumn233. NOTE: changes the DEFAULT mailbox count from 4 to 8 for every Vulkan ICD (WSI_WL_DEFAULT_MAILBOX_IMAGES 8, clamped 4..8) — behaviour change beyond DroidVM; upstream will ask why. Shared by all three routes (common WSI). |
| 5 | G | wsi/drm: batch the explicit-sync release probe (MESA_VK_WSI_DRM_BATCH_RELEASE_PROBE) | 2a23cd55d21 | src/vulkan/wsi/wsi_common_drm.c | lateautumn233. Opt-in (default false): one WAIT_ANY over all unresolved releases instead of one timeline_wait per image. Common WSI → G. |
| 6 | D | tu/a750: emit BR-only RB CCU registers outside CP_SET_THREAD_BOTH | 9452b5e9090 | src/freedreno/vulkan/tu_cmd_buffer.cc, src/freedreno/common/freedreno_devices.py (0x43051400 / 0xffff43051400 FD750 ids) | lateautumn233. Real a7xx hardware fix (per-frame CP AHB error), independently upstreamable; also needed on the HOST turnip (memory note "8gen3 host turnip CP AHB error"). Keep first among D since everything else assumes a working a750 guest. |
| 7 | D | tu/virtio: query the VA slice on the real device context | 622c4323604 | src/freedreno/vulkan/tu_device.cc, tu_device.h, tu_knl_drm_virtio.cc | lateautumn233. Re-reads MSM_PARAM_VA_START/SIZE on the VkDevice context (drm2kgsl host hands each context a disjoint slice); also NULL-hardening of virtio_device_init. |
| 8 | D | freedreno/virtio: query the context VA slice for the GL driver too | a9eb89e2bc3 | src/freedreno/drm/virtio/virtio_device.c | lateautumn233. Gallium counterpart of #7 (query_context_va_range; INFO_MSG logs are FD_MESA_DEBUG-gated, fine). Suggest subject rewrite (original "feat: add query_context_va_range function for VA slice"). |
| 9 | D | tu/virtio: hand a lazy BO's iova to the zombie VMA path | b272a38acdb | tu_knl_drm_virtio.cc | lateautumn233. Double-free of iova reservation; matches msm backend. Generic tu/virtio fix, upstreamable. |
| 10 | D | tu/virtio: add poll-first fast path for client fence/semaphore waits | 039e8b29401 | tu_device.h, tu_knl_drm_virtio.cc | lateautumn233. tu_virtio_sync vk_sync_type, TU_POLL_SPIN_US (300us), TU_NO_POLL_FIRST. vkmark 5427→9462. |
| 11 | D | tu/virtio: resolve empty submits guest-side via SYNCOBJ_TRANSFER | 70ea33132c0 | tu_knl_drm_virtio.cc | lateautumn233. Tracking syncobj + inheritance for command-less submits; TU_NO_EMPTY_SUBMIT. |
| 12 | D | tu/virtio: resolve empty submits with arbitrary waits through copy_sync_payloads | fe04b37f584 | tu_knl_drm_virtio.cc | lateautumn233. Tier-2 of #11 (vk_drm_syncobj_copy_payloads; TU_NO_EMPTY_SUBMIT_COPY). Follow-up to #11; could be squashed into it (same author) — original message is fine as is. |
| 13 | D | tu/virtio: allocate BO pages from the guest pool when the VMM offers one | 43f30bb6413 | src/freedreno/common/msm_proto.h (MSM_BO_GUEST_ALLOC 0x80000000), tu_knl_drm_virtio.cc (virtio_bo_init flag), src/virtio/vdrm/vdrm.h (supports_guest_alloc), src/virtio/vdrm/vdrm_virtgpu.c (HOST3D_GUEST + CREATE_GUEST_HANDLE, VIRTGPU_PARAM_CREATE_GUEST_HANDLE=10 probe) | HuJK. drm2kgsl guest-alloc; the D counterpart of X #15 / V #5. msm_proto.h must stay in step with virglrenderer's copy. |
| 14 | D | freedreno/virtio: request guest allocation for GL BOs when vdrm reports support | 9a7fdc670cc | src/freedreno/drm/virtio/virtio_bo.c | lateautumn233. Extends #13 to the gallium driver (MSM_BO_GUEST_ALLOC in virtio_bo_new). Follow-up to HuJK's #13. Original subject "fix(virtio): honor guest allocation support" → rewrite. |
| 15 | D | tu/virtio: size the heap from the guest pool, not from guest RAM | 4d50b92ec73 | tu_device.cc (tu_get_guest_pool_budget), tu_device.h (guest_pool_size), tu_knl_drm_virtio.cc (heap.size from pool), vdrm.h + vdrm_virtgpu.c (vdrm_guest_pool_stats; GETPARAM 0x1000/0x1001/0x1002) | HuJK. Same kernel GETPARAM ids as gfxstream #14. |
| 16 | D | tu/virtio: keep guest-pool memory coherent for the userspace fence | 6243ac58248 | tu_device.h (userspace_fence alignas(64)), tu_knl_drm_virtio.cc (tu_bo_sync_cache around userspace_fence and fence_cmds when supports_guest_alloc) | lateautumn233. Follow-up made necessary by #13 (guest-pool pages are not CPU/GPU coherent). |
| 17 | D | freedreno: spin on the control fence before a virtio wait, and invalidate it for guest-allocated BOs | 50f6f0acbe9 | src/freedreno/drm/freedreno_pipe.c, freedreno_priv.h (wait_spin_ns, control_needs_inval), src/freedreno/drm/virtio/virtio_pipe.c (FD_POLL_SPIN_US default 1200) | lateautumn233. GL-side analogue of #10 plus the cache-invalidate consequence of #14. |
| 18 | D | tu: initialize the guest-pool-backed global BO and bound allocations by the pool | eef146a7553 | tu_cmd_buffer.cc (VSC overflow cache sync), tu_device.cc (memset global, maxMemoryAllocationSize clamp, allocationSize > heap check), tu_device.h (vsc_* alignas(64)) | lateautumn233. Follow-up to HuJK's #13/#15 (recycled pool pages are not zero; large-alloc rejection). |
| 19 | D | tu: make a zeroed tu_bo mean "not in the dump BO list" | 23a873921b7 | tu_device.cc, src/freedreno/vulkan/tu_knl.h | HuJK. Generic turnip bug (dump_bo_list_idx sentinel lost by memset; NULL store in tu_dump_bo_del) — not virtio-specific; independently upstreamable. Could sit before #13. |
| 20 | D | freedreno: recognize a840 virtio guests | 30158be8f1e | src/freedreno/common/freedreno_devices.py (0x44050a00 / 0xffff44050a00 Adreno 840) | lateautumn233. Device-ID table only. Could be folded with the FD750 ids from #6 into one "freedreno: add virtio-guest chip ids for a750/a840" commit, but that would mix authorship of #6 — keep separate. |

### Other-author commits (keep authorship)
- lateautumn233 (20 commits): 9452b5e9090, 039e8b29401, 70ea33132c0, 622c4323604, b272a38acdb, 9c8575b06cd, f4859706843, a9eb89e2bc3, 6c1364fb4d2, 9a7fdc670cc, 7889494f1a2, 30158be8f1e, 8654cad05fc, 6243ac58248, 200a3027789, 2a23cd55d21, 50f6f0acbe9, fe04b37f584, ec44b80bca1, eef146a7553. This IS lateautumn233's dev branch; the PR is mostly his work. Keep every non-CI commit as its own commit; the only squash proposed is the 5 CI commits (all his) into #3, and even that only if the workflow goes in at all. Several subjects use "feat(...)/fix(...)/chore(...)" prefixes not used elsewhere in mesa — suggest reword to `area: what` (as proposed above) while keeping Author.
- HuJK follow-ups that only fix another author's commit: none. The dependency runs the other way — lateautumn233's 9a7fdc670cc, 6243ac58248, 50f6f0acbe9, eef146a7553 build on / fix consequences of HuJK's 43f30bb6413 and 4d50b92ec73, so those four must stay after #13/#15.
- The 6 Blumenkrantz zink/tc commits are NOT on this branch and must not be added: their upstream originals are already in 74d4e41b2bb.

### Nets to zero / disappears in flatten
- ec44b80bca1 removes 2 lines that f4859706843 added (push branch filter) — disappears inside #3.
- No experiment/revert pairs on this branch.

### Consider dropping from the PR
- #3 CI workflow (.github/workflows/guest-mesa-glvnd-deb.yml, 5 commits): Droid-VM packaging, not upstream material.
- #2 mesa/main getstring "" workaround: spec-contrary; upstream will likely reject; harmless to keep in the Droid-VM tree.
- #4 changes a WSI default (mailbox images 4→8) for everyone; if kept for the PR, consider defaulting to 4 and letting the env var raise it.
- Env knobs introduced by lateautumn233 (TU_POLL_SPIN_US, TU_NO_POLL_FIRST, TU_NO_EMPTY_SUBMIT, TU_NO_EMPTY_SUBMIT_COPY, FD_POLL_SPIN_US, MESA_VK_WSI_WL_MAILBOX_IMAGES, MESA_VK_WSI_DRM_BATCH_RELEASE_PROBE) are A/B switches; fine for a fork, upstream may want some as TU_DEBUG flags instead.

### SPLIT NEEDED files
- None strictly required if the lateautumn233 commits are preserved as-is: tu_knl_drm_virtio.cc, tu_device.cc, tu_device.h, tu_cmd_buffer.cc, freedreno_devices.py, vdrm.h, vdrm_virtgpu.c are each touched by several ORIGINAL commits, but every original commit maps 1:1 to a proposed commit above (no hunk of one original goes to two proposed rows). Only #3 folds several originals (all on one file).

### Open questions / decisions for the owner
1. Base: this PR is on mesa main @ 2026-08-07 while the other two are on 26.0.3. Upstream turnip work must target main anyway; the question is whether the Droid-VM `pr/3d-accel-drm2kgsl` should first be rebased onto current main (74d4e41b2bb is 10 days old at report time) — 20 of the 25 commits are turnip/freedreno and will conflict-check easily.
2. HuJK's only delta over origin/dev is 9be474f1658 (licensing attribution). Whether pr/3d-accel-drm2kgsl is cut from origin/dev (lateautumn233 authoritative) + L, or re-flattened as above, is mostly a question of who owns the branch.
3. Add the kopper guard e14d2e5fc2c (G, from the venus branch) here as well.
4. Whether #6 (a750 RB CCU) should be sent upstream separately and immediately — it is a hardware fix with no DroidVM dependency.
5. Whether #19 (tu dump BO sentinel) should also go upstream separately (generic turnip bug).

### Coverage check
- all original commits assigned: yes — 9452b5e9090→#6; 039e8b29401→#10; 70ea33132c0→#11; 622c4323604→#7; b272a38acdb→#9; 9c8575b06cd→#2; f4859706843, 6c1364fb4d2, 7889494f1a2, 8654cad05fc, ec44b80bca1→#3; 43f30bb6413→#13; 4d50b92ec73→#15; 23a873921b7→#19; 732d5cbbc42, 9be474f1658→#1; a9eb89e2bc3→#8; 9a7fdc670cc→#14; 30158be8f1e→#20; 6243ac58248→#16; 200a3027789→#4; 2a23cd55d21→#5; 50f6f0acbe9→#17; fe04b37f584→#12; eef146a7553→#18.
- all net files assigned: yes — .github/workflows/guest-mesa-glvnd-deb.yml→#3; ADDITIONAL-PERMISSIONS, CONTRIBUTING.md, LICENSE.GPL-3.0, LICENSING.md→#1; freedreno_devices.py→#6/#20; msm_proto.h→#13; freedreno_pipe.c, freedreno_priv.h, virtio_pipe.c→#17; virtio_bo.c→#14; virtio_device.c→#8; tu_cmd_buffer.cc→#6/#18; tu_device.cc→#7/#15/#18/#19; tu_device.h→#7/#10/#15/#16/#18; tu_knl.h→#19; tu_knl_drm_virtio.cc→#7/#9/#10/#11/#12/#13/#15/#16; getstring.c→#2; vdrm.h, vdrm_virtgpu.c→#13/#15; wsi_common_drm.c→#5; wsi_common_wayland.c→#4.
