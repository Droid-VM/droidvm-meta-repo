# Guest kernel patches (virtio-gpu + gunyah_guest)

Raw kernel-tree patches for the DroidVM guest driver changes, applied with
`-p1` on the guest kernel source (Ubuntu 7.0 series / upstream v7.0).

| # | patch | notes |
|---|-------|-------|
| 0001 | Gunyah RM memparcel support | includes the in-kernel-tree `drivers/virt/` gunyah_guest variant and a uapi field rename |
| 0002 | gate accept on `gunyah_guest_available()` | |
| 0003 | demote per-blob-create trace to `pr_debug` | |
| 0004 | blob dma-buf import with virgl 3D | |
| 0005 | skip CTX_DETACH_RESOURCE without a host context | fixes the `response 0x1200 (command 0x203)` dmesg spam vs crosvm/rutabaga; upstream-candidate |

**What the guest actually runs** is the DKMS series in
`droidvm-guest-additions/patches/<series>/` — regenerated against the pristine
distro base and verified there. The two series are the same changes except:

- DKMS 0001 keeps the uapi field name `padding` (comment documents the Gunyah
  reuse) so the driver builds against unpatched distro headers, and reads it
  as `le32_to_cpu(resp->padding)` in `virtgpu_vq.c`; this 0001 renames the
  field to `gunyah_handle` instead, which only works when the whole kernel
  (including uapi) is built patched.
- The `drivers/virt/` gunyah_guest module here corresponds to the standalone
  `droidvm-guest-additions/gunyah_guest/` module there.

When changing the driver, change the DKMS series first (it is what ships) and
mirror here; keep both series applying cleanly.
