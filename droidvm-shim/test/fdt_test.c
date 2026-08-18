// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright DroidVM contributors

/*
 * Exercise the shim's device-tree walk and its `/memory` rewrite against a tree shaped like the
 * one the resource manager actually hands over: two ranges in `/memory`, and a `/hypervisor` full
 * of vdevices that each have a `reg` of their own with the resource manager's node buried among
 * them. That last part is the shape a walker with global rather than per-node state gets wrong,
 * and getting it wrong means the shim sends MEM_ACCEPT to a doorbell's capability id -- a boot
 * that hangs with nothing to say for itself.
 *
 * Built for aarch64 (the shim's only target) and run under qemu-user:
 *
 *   make -C .. && make test
 */

#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

/* The unit under test, minus the parts that need a hypervisor. */
#define SHIM_TEST_NO_HVC 1
#include "../shim.c"

static uint8_t blob[1 << 16];

static int fail;

static void check(int ok, const char *what)
{
	printf("%-58s %s\n", what, ok ? "ok" : "FAILED");
	if (!ok)
		fail = 1;
}

int main(int argc, char **argv)
{
	struct fdt_hit hit;
	FILE *f = fopen(argc > 1 ? argv[1] : "sample.dtb", "rb");
	size_t n;

	if (!f) {
		perror("open dtb");
		return 2;
	}
	n = fread(blob, 1, sizeof(blob), f);
	fclose(f);
	printf("dtb: %zu bytes\n", n);

	/* The resource manager's capabilities, not a doorbell's. */
	check(fdt_find_prop(blob, "gunyah-resource-manager", NULL, "reg", &hit) == 0,
	      "find the resource manager node");
	check(hit.len == 16, "its reg is one address/size pair");
	check(get_be64(hit.val) == 0x2a && get_be64(hit.val + 8) == 0x2b,
	      "its reg is the RM's, not a sibling's or its parent's");

	/* /memory, and only the one below the root. */
	check(fdt_find_prop(blob, NULL, "memory", "reg", &hit) == 0, "find /memory");
	check(hit.len == 32, "/memory has two ranges");

	/* Rewriting keeps the length, so the structure block never moves: two ranges in, two
	 * ranges out, together covering exactly the window. */
	check(rewrite_memory_reg(blob, 0x80400000, 0x40000000) == 0, "rewrite /memory to the window");
	check(fdt_find_prop(blob, NULL, "memory", "reg", &hit) == 0, "/memory still there");
	check(hit.len == 32, "and still two ranges");
	{
		uint64_t b0 = get_be64(hit.val), s0 = get_be64(hit.val + 8);
		uint64_t b1 = get_be64(hit.val + 16), s1 = get_be64(hit.val + 24);

		printf("  -> [%#llx +%#llx] [%#llx +%#llx]\n",
		       (unsigned long long)b0, (unsigned long long)s0,
		       (unsigned long long)b1, (unsigned long long)s1);
		check(b0 == 0x80400000, "first range starts at the window");
		check(b1 == b0 + s0, "the two ranges are adjacent");
		check(s0 + s1 == 0x40000000, "together they are exactly the window");
		check((s0 & 0x1fffff) == 0, "every range but the last is 2 MiB aligned");
	}

	/* A tree that does not have what we ask for must say so rather than return a neighbour. */
	check(fdt_find_prop(blob, "nothing-like-this", NULL, "reg", &hit) != 0,
	      "an absent compatible is not found");
	check(fdt_find_prop(blob, NULL, "no-such-node", "reg", &hit) != 0,
	      "an absent node is not found");

	printf("%s\n", fail ? "FAILED" : "all ok");
	return fail;
}
