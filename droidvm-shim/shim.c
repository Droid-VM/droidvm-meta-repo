// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright DroidVM contributors

/*
 * Accept the guest's real memory, then get out of the way.
 *
 * NO LIBFDT, deliberately. The two things this needs from the device tree are a property read
 * (the resource manager's message-queue capabilities) and a property overwrite that does not
 * change the property's length (`/memory`'s `reg`, rewritten to cover the window instead of the
 * boot region). Neither moves a byte of the structure block, so a few hundred lines of tree walk
 * replace a library, a build dependency, and the temptation to do more here than belongs here.
 *
 * Keeping the length identical is what makes that work: whatever number of ranges `/memory`
 * arrives with -- the resource manager prepends its own low-memory donation on some generations --
 * the window is split into exactly that many pieces on the way out.
 */

#include <stdint.h>
#include <stddef.h>

#include "shim.h"

/* ------------------------------------------------------------------ device tree, read + patch */

#define FDT_MAGIC	0xd00dfeedu
#define FDT_BEGIN_NODE	0x00000001u
#define FDT_END_NODE	0x00000002u
#define FDT_PROP	0x00000003u
#define FDT_NOP		0x00000004u
#define FDT_END		0x00000009u

struct fdt_header {
	uint32_t magic, totalsize, off_dt_struct, off_dt_strings, off_mem_rsvmap;
	uint32_t version, last_comp_version, boot_cpuid_phys;
	uint32_t size_dt_strings, size_dt_struct;
};

static uint32_t be32(uint32_t v)
{
	return __builtin_bswap32(v);
}

/* Byte at a time: a device tree property value carries no alignment guarantee, and with
 * -mstrict-align a wide access to an odd address faults rather than taking a slow path. */
static void put_be64(void *p, uint64_t v)
{
	uint8_t *b = p;
	int i;

	for (i = 0; i < 8; i++)
		b[i] = (uint8_t)(v >> (56 - 8 * i));
}

static uint64_t get_be64(const void *p)
{
	const uint8_t *b = p;
	uint64_t v = 0;
	int i;

	for (i = 0; i < 8; i++)
		v = (v << 8) | b[i];
	return v;
}

static int str_eq(const char *a, const char *b)
{
	while (*a && *a == *b) {
		a++;
		b++;
	}
	return *a == *b;
}

/*
 * One pass over the structure block.
 *
 * `want_compat` finds the node carrying that string in its `compatible` list, at any depth;
 * `want_root_node` finds a node by name directly below the root (`/memory` is "memory"). The hit
 * is a pointer INTO the live tree plus a length, which is what the patching caller wants.
 *
 * The state that matters is PER NODE, not global: `/hypervisor` holds a doorbell or a message
 * queue for every virtual device, each with its own `reg`, and the resource manager's node is one
 * child among them. A walker that remembered "some node matched" and "the last reg I saw" would
 * hand back whichever `reg` happened to come last. So each open node gets a frame, and a property
 * only counts for the node it was found in.
 */
struct fdt_hit {
	uint8_t *val;
	uint32_t len;
};

struct fdt_frame {
	uint8_t	*val;			/* the property, if this node has it */
	uint32_t len;
	uint8_t	 matched;		/* this node is the one asked for */
};

#define FDT_MAX_DEPTH 24

static int fdt_find_prop(void *fdt, const char *want_compat, const char *want_root_node,
			 const char *prop, struct fdt_hit *out)
{
	struct fdt_header *h = fdt;
	struct fdt_frame stack[FDT_MAX_DEPTH];
	uint8_t *strings, *p, *end;
	int depth = 0;

	if (be32(h->magic) != FDT_MAGIC)
		return -1;
	strings = (uint8_t *)fdt + be32(h->off_dt_strings);
	p = (uint8_t *)fdt + be32(h->off_dt_struct);
	end = p + be32(h->size_dt_struct);

	while (p < end) {
		uint32_t tag = be32(*(uint32_t *)p);

		p += 4;
		switch (tag) {
		case FDT_BEGIN_NODE: {
			const char *name = (const char *)p;
			size_t n = 0;

			while (p[n])
				n++;
			p += (n + 4) & ~3u;
			if (depth >= FDT_MAX_DEPTH)
				return -1;	/* deeper than any tree we are handed */
			stack[depth].val = 0;
			stack[depth].len = 0;
			/* depth 0 is the root, so its direct children are at depth 1. */
			stack[depth].matched = (depth == 1 && want_root_node &&
						str_eq(name, want_root_node));
			depth++;
			break;
		}
		case FDT_END_NODE:
			if (depth <= 0)
				return -1;
			depth--;
			if (stack[depth].matched && stack[depth].val) {
				out->val = stack[depth].val;
				out->len = stack[depth].len;
				return 0;
			}
			break;
		case FDT_PROP: {
			uint32_t len = be32(*(uint32_t *)p);
			uint32_t nameoff = be32(*(uint32_t *)(p + 4));
			const char *pname = (const char *)(strings + nameoff);
			uint8_t *val = p + 8;
			struct fdt_frame *cur;

			p += 8 + ((len + 3) & ~3u);
			if (depth <= 0)
				break;		/* a property outside any node: malformed, ignore */
			cur = &stack[depth - 1];
			if (want_compat && str_eq(pname, "compatible")) {
				/* A compatible is a list of NUL-separated strings. */
				uint32_t off = 0;

				while (off < len) {
					if (str_eq((const char *)val + off, want_compat)) {
						cur->matched = 1;
						break;
					}
					while (off < len && val[off])
						off++;
					off++;
				}
			}
			if (str_eq(pname, prop)) {
				cur->val = val;
				cur->len = len;
			}
			break;
		}
		case FDT_NOP:
			break;
		case FDT_END:
			return -1;
		default:
			return -1;
		}
	}
	return -1;
}

/* ------------------------------------------------------------------------------ gunyah hypercalls */

#define GH_HCALL_MSGQ_SEND	0xC600801BULL
#define GH_HCALL_MSGQ_RECV	0xC600801CULL
#define GH_MSGQ_TX_PUSH		(1ULL << 0)

struct hvc_ret {
	uint64_t x0, x1, x2, x3;
};

#ifdef SHIM_TEST_NO_HVC
/* The offline test links the device-tree half of this file and nothing else: an hvc from
 * qemu-user would be an illegal instruction, and the RM is not there to answer it anyway. */
static struct hvc_ret hvc4(uint64_t f, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4)
{
	struct hvc_ret r = { ~0ULL, 0, 0, 0 };

	return r;
}
#else
static struct hvc_ret hvc4(uint64_t f, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4)
{
	register uint64_t x0 __asm__("x0") = f;
	register uint64_t x1 __asm__("x1") = a1;
	register uint64_t x2 __asm__("x2") = a2;
	register uint64_t x3 __asm__("x3") = a3;
	register uint64_t x4 __asm__("x4") = a4;
	struct hvc_ret r;

	__asm__ volatile("hvc #0"
			 : "+r"(x0), "+r"(x1), "+r"(x2), "+r"(x3), "+r"(x4)
			 :
			 : "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12",
			   "x13", "x14", "x15", "x16", "x17", "memory");
	r.x0 = x0;
	r.x1 = x1;
	r.x2 = x2;
	r.x3 = x3;
	return r;
}
#endif

/* ------------------------------------------------------------------------- resource manager RPC */

#define GH_RM_RPC_API			0x21
#define GH_RM_RPC_TYPE_REQUEST		0x01
#define GH_RM_RPC_TYPE_REPLY		0x02
#define GH_RM_RPC_TYPE_MASK		0x03
#define GH_RM_RPC_MEM_ACCEPT		0x51000011u
#define GH_RM_MEM_TYPE_NORMAL		0
#define GH_RM_TRANS_TYPE_SHARE		2
#define GH_RM_MEM_ACCEPT_MAP_CONTIGUOUS	(1u << 4)
#define GH_RM_MEM_ACCEPT_DONE		(1u << 7)
#define GH_RM_MSGQ_MSG_SIZE		240

static uint64_t rm_tx, rm_rx;
static uint16_t rm_seq;
static uint8_t rm_txbuf[64] __attribute__((aligned(8)));
static uint8_t rm_rxbuf[GH_RM_MSGQ_MSG_SIZE] __attribute__((aligned(8)));

static void put_le16(uint8_t *p, uint16_t v)
{
	p[0] = v & 0xff;
	p[1] = v >> 8;
}

static void put_le32(uint8_t *p, uint32_t v)
{
	p[0] = v;
	p[1] = v >> 8;
	p[2] = v >> 16;
	p[3] = v >> 24;
}

static void put_le64(uint8_t *p, uint64_t v)
{
	put_le32(p, (uint32_t)v);
	put_le32(p + 4, (uint32_t)(v >> 32));
}

static uint16_t get_le16(const uint8_t *p)
{
	return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t get_le32(const uint8_t *p)
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
	       ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

/*
 * MEM_ACCEPT, in the one shape that works for a scattered parcel: MAP_CONTIGUOUS with a single
 * sgl entry covering the whole thing. Without the flag the RM wants one sgl entry per physically
 * contiguous run -- a layout the guest has no way to know. (The same reasoning, and the same
 * error code when it is got wrong, is written out at length in gunyah_guest.c.)
 */
static int rm_mem_accept(uint32_t handle, uint64_t gpa, uint64_t size, uint32_t *rm_err)
{
	uint8_t *p = rm_txbuf;
	size_t off = 0;
	uint16_t seq = ++rm_seq;
	struct hvc_ret r;
	unsigned long spin;

	p[off++] = GH_RM_RPC_API;
	p[off++] = GH_RM_RPC_TYPE_REQUEST;
	put_le16(p + off, seq);
	off += 2;
	put_le32(p + off, GH_RM_RPC_MEM_ACCEPT);
	off += 4;

	put_le32(p + off, handle);
	off += 4;
	p[off++] = GH_RM_MEM_TYPE_NORMAL;
	p[off++] = GH_RM_TRANS_TYPE_SHARE;
	p[off++] = GH_RM_MEM_ACCEPT_MAP_CONTIGUOUS | GH_RM_MEM_ACCEPT_DONE;
	p[off++] = 0;
	put_le32(p + off, 0);		/* validate_label */
	off += 4;
	put_le32(p + off, 0);		/* acl_desc: no entries */
	off += 4;
	put_le16(p + off, 1);		/* sgl_desc: one entry */
	off += 2;
	put_le16(p + off, 0);		/* map_vmid 0 = to self */
	off += 2;
	put_le64(p + off, gpa);
	off += 8;
	put_le64(p + off, size);
	off += 8;
	put_le16(p + off, 0);		/* mem_attr_desc: none */
	off += 2;
	put_le16(p + off, 0);
	off += 2;

	r = hvc4(GH_HCALL_MSGQ_SEND, rm_tx, off, (uint64_t)(uintptr_t)rm_txbuf, GH_MSGQ_TX_PUSH);
	if (r.x0 != 0)
		return -1;

	/* No timer here: a bounded spin is all a boot-time shim can do, and the RM answers in
	 * microseconds when it answers at all. */
	for (spin = 0; spin < 200000000UL; spin++) {
		r = hvc4(GH_HCALL_MSGQ_RECV, rm_rx, (uint64_t)(uintptr_t)rm_rxbuf,
			 sizeof(rm_rxbuf), 0);
		if (r.x0 != 0)
			continue;
		if (r.x1 < 12)
			continue;
		if ((rm_rxbuf[1] & GH_RM_RPC_TYPE_MASK) != GH_RM_RPC_TYPE_REPLY)
			continue;	/* a notification; not ours */
		if (get_le16(rm_rxbuf + 2) != seq)
			continue;
		if (get_le32(rm_rxbuf + 4) != GH_RM_RPC_MEM_ACCEPT)
			continue;
		*rm_err = get_le32(rm_rxbuf + 8);
		return *rm_err ? -2 : 0;
	}
	return -3;
}

/* ------------------------------------------------------------------------------------- the shim */

#ifdef SHIM_TEST_NO_HVC
char shim_header[64];
static void shim_hang(void) { for (;;) ; }
#else
extern char shim_header[];
extern void shim_hang(void);
#endif

static struct shim_handoff *ho;

static void say(const char *s)
{
	size_t i = 0;

	if (!ho)
		return;
	while (s[i] && i < sizeof(ho->msg) - 1) {
		ho->msg[i] = s[i];
		i++;
	}
	ho->msg[i] = '\0';
}

static void die(uint64_t err, const char *what)
{
	if (ho) {
		ho->error = err;
		say(what);
		ho->status = SHIM_STATUS_ERROR;
	}
	shim_hang();
}

/*
 * Replace `/memory`'s reg with the window, keeping the property exactly as long as it was.
 *
 * The tree arrives describing the boot region (and, on some RM generations, a low-memory donation
 * prepended to it). Both are lent: the host cannot see them, so a buffer the guest hands to a
 * virtio device from there would be invisible on the other side. Only the window is shared, so
 * only the window may be memory as far as the payload is concerned.
 */
static int rewrite_memory_reg(void *fdt, uint64_t base, uint64_t size)
{
	struct fdt_hit hit;
	uint32_t entries, i;
	uint64_t chunk;

	if (fdt_find_prop(fdt, NULL, "memory", "reg", &hit))
		return -1;
	if (hit.len < 16 || (hit.len % 16))
		return -2;

	entries = hit.len / 16;
	/* Same number of ranges out as in, so the property keeps its length and nothing in the
	 * structure block has to move. Every piece but the last is a 2 MiB multiple. */
	chunk = size / entries;
	chunk &= ~0x1fffffULL;
	if (!chunk)
		return -3;
	for (i = 0; i < entries; i++) {
		uint64_t this_base = base + chunk * i;
		uint64_t this_size = (i == entries - 1) ? size - chunk * i : chunk;

		put_be64(hit.val + i * 16, this_base);
		put_be64(hit.val + i * 16 + 8, this_size);
	}
	return 0;
}

uint64_t shim_main(void *fdt)
{
	struct shim_header *h = (struct shim_header *)shim_header;
	struct fdt_hit hit;
	uint32_t i;

	if (h->magic != SHIM_HEADER_MAGIC || h->version != SHIM_ABI_VERSION)
		shim_hang();		/* no handoff page to complain into */

	ho = (struct shim_handoff *)(uintptr_t)h->handoff;
	if (!ho || ho->magic != SHIM_HANDOFF_MAGIC)
		shim_hang();
	ho->status = SHIM_STATUS_RUNNING;

	if (!h->payload)
		die(0, "no payload address in the header");

	if (ho->nparcels) {
		uint64_t spin;

		/* The host writes `ready` last, after every parcel is shared. */
		for (spin = 0; spin < 200000000UL && !ho->ready; spin++)
			__asm__ volatile("" ::: "memory");
		if (!ho->ready)
			die(0, "the host never finished sharing the window");

		if (ho->nparcels > SHIM_MAX_PARCELS)
			die(ho->nparcels, "too many parcels");

		if (fdt_find_prop(fdt, "gunyah-resource-manager", NULL, "reg", &hit) || hit.len < 16)
			die(0, "no gunyah-resource-manager node in the device tree");
		rm_tx = get_be64(hit.val);
		rm_rx = get_be64(hit.val + 8);

		for (i = 0; i < ho->nparcels; i++) {
			uint32_t rm_err = 0;
			int rc = rm_mem_accept(ho->parcel[i].handle, ho->parcel[i].base,
					       ho->parcel[i].size, &rm_err);

			if (rc) {
				ho->error = ((uint64_t)rm_err << 32) | (uint32_t)(-rc);
				say(rc == -3 ? "MEM_ACCEPT timed out" : "MEM_ACCEPT refused");
				ho->status = SHIM_STATUS_ERROR;
				shim_hang();
			}
		}
		ho->status = SHIM_STATUS_ACCEPTED;

		/* Prove the window is not just present but executable, which is the whole premise:
		 * write `mov x0, #42; ret` into its first words and call it. With the MMU off there
		 * is no stage-1 to blame -- a fault here is stage 2 refusing the fetch. */
		if (h->flags & SHIM_FLAG_PROBE_EXEC) {
			uint32_t *code = (uint32_t *)(uintptr_t)ho->parcel[0].base;
			int (*fn)(void) = (int (*)(void))code;

			code[0] = 0xd2800540;	/* mov x0, #42 */
			code[1] = 0xd65f03c0;	/* ret */
			__asm__ volatile("dsb sy; ic iallu; dsb sy; isb" ::: "memory");
			ho->exec_probe = (uint64_t)fn();
		}

		if (!(h->flags & SHIM_FLAG_NO_DT_REWRITE)) {
			int rc = rewrite_memory_reg(fdt, ho->parcel[0].base, ho->parcel[0].size);

			if (rc)
				die((uint64_t)(-rc), "could not rewrite /memory");
			ho->status = SHIM_STATUS_DT_DONE;
		}
	}

	ho->status = SHIM_STATUS_JUMPING;
	return h->payload;
}
