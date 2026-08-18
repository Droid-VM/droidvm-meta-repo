# droidvm-shim

The first thing a pseudo-unprotected VM runs.

crosvm boots this VM with only a small LEND'd region -- enough for this shim and the device tree --
and leaves the guest's real RAM as a hole: declared to nobody, backed by nothing, until the host
SHAREs it as a Gunyah memparcel and *the guest* accepts it. The host cannot accept on the guest's
behalf (the resource manager refuses `MEM_ACCEPT_FLAG_MAP_OTHER`), so something inside the VM has
to do it before any real payload runs. That is this.

    [0x8000_0000  boot region, LEND'd]  shim + DTB + handoff page
    [        ...  window, SHARE'd RWX]  kernel / EDK2 / initrd / all of the guest's RAM
    [        ...  pools, MMIO]

What it does, in order:

1. reads the handoff page the host filled in after `GH_VM_START`: how many memparcels, and each
   one's handle, address and size;
2. finds the resource manager's message-queue capabilities in the device tree the RM patched;
3. `MEM_ACCEPT`s each parcel at its fixed address, so the window becomes ordinary guest memory;
4. rewrites `/memory` to the window and drops the boot region from it -- the boot region is lent,
   so the host cannot see it, and anything the guest DMAs from there would not work;
5. jumps to the payload with `x0` still pointing at the device tree.

There is no jumping back, and nothing patches the payload: the payload sits at its own address and
this shim is simply what the hypervisor started instead.
