/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Copyright DroidVM contributors */

/*
 * The two structures crosvm and the shim both have to agree about.
 *
 * Neither is a device tree node: the header is patched into the shim image before the VM starts
 * (the boot region is lent, so the host cannot write to it afterwards), and the handoff page lives
 * in a small SHARE'd region the host keeps access to, which is the only way a memparcel handle --
 * a number that does not exist until after GH_VM_START -- can reach the guest.
 */

#ifndef DROIDVM_SHIM_H
#define DROIDVM_SHIM_H

#define SHIM_HEADER_MAGIC   0x4d534856554d5644ULL	/* "DVMUVHSM" */
#define SHIM_HANDOFF_MAGIC  0x4f444e414853564dULL	/* "MVSHANDO" */
#define SHIM_ABI_VERSION    1u

/* Patched into the image by crosvm before the VM starts. Offset 8: the branch at offset 0 is the
 * entry point, so the header cannot start there. */
struct shim_header {
	uint64_t magic;			/* SHIM_HEADER_MAGIC */
	uint32_t version;		/* SHIM_ABI_VERSION */
	uint32_t flags;
	uint64_t payload;		/* where to jump when the window is up */
	uint64_t handoff;		/* GPA of struct shim_handoff, in a SHARE'd region */
	uint64_t dtb_max_size;		/* room the DTB may grow into while being rewritten */
	uint64_t reserved[3];
};

#define SHIM_FLAG_NO_DT_REWRITE	(1u << 0)	/* accept the window, leave /memory alone */
#define SHIM_FLAG_PROBE_EXEC	(1u << 1)	/* execute one instruction out of the window */

#define SHIM_MAX_PARCELS 8

struct shim_parcel {
	uint32_t handle;
	uint32_t reserved;
	uint64_t base;
	uint64_t size;
};

/*
 * Host -> shim, then shim -> host, in a region the host shares rather than lends.
 *
 * `ready` is written last by the host and read first by the shim: everything else in the page is
 * only meaningful once it is set, and a shim that starts before the host has finished sharing
 * would otherwise accept a handle that is still zero.
 */
struct shim_handoff {
	uint64_t magic;			/* SHIM_HANDOFF_MAGIC */
	uint32_t version;		/* SHIM_ABI_VERSION */
	uint32_t nparcels;
	uint64_t ready;			/* non-zero once every parcel below is shared */
	struct shim_parcel parcel[SHIM_MAX_PARCELS];
	/* shim -> host */
	uint64_t status;		/* SHIM_STATUS_* */
	uint64_t error;			/* the RM error code, or errno-ish detail */
	uint64_t exec_probe;		/* SHIM_FLAG_PROBE_EXEC: what the window's code returned */
	char	 msg[256];		/* free text, for the log line the host prints */
};

#define SHIM_STATUS_RUNNING	1
#define SHIM_STATUS_ACCEPTED	2
#define SHIM_STATUS_DT_DONE	3
#define SHIM_STATUS_JUMPING	4
#define SHIM_STATUS_ERROR	0xe000

#endif /* DROIDVM_SHIM_H */
