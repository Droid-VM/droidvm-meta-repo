// SPDX-License-Identifier: GPL-2.0
/*
 * ghhr_probe - one-shot dump of gh_hugepage_reserve's served table, with what each
 * outstanding page actually is right now.
 *
 * WHY THIS EXISTS
 *
 * The pool loses a small fixed number of 2MB pages per VM lifecycle. Every attempt to
 * identify them from the module's own counters was ambiguous, because each counter has
 * more than one explanation:
 *
 *   page_count != 0      -> never freed, OR freed and immediately re-allocated
 *   orphan_freed == 0    -> page in use, OR owner not yet swept so it still counts live
 *   del_hit short by N   -> N frees missed the hook, but not which allocation they were
 *
 * Reasoning from those produced four different conclusions in a row, each refuted by the
 * next measurement. The pfn is the thing that is not ambiguous: given it, the page's own
 * flags say whether it is free, split, mapped, pinned, or owned by someone else.
 *
 * WHY IT IS A SEPARATE MODULE
 *
 * Adding the dump to gh_hugepage_reserve would mean rmmod'ing it to load the new build.
 * That returns the pool to the buddy allocator, and re-acquiring 3072 order-9 pages on an
 * already-fragmented phone is exactly what the pool exists because you cannot do. A failed
 * re-acquire leaves the device unable to start a VM until it reboots. So this reads the
 * other module's private table through kallsyms instead, and writes nothing.
 *
 * init returns -EAGAIN deliberately: the dump goes to dmesg and the module never stays
 * resident, so there is no teardown path to get wrong.
 *
 * Run it with no VM up. The table is read without taking served_lock -- taking another
 * module's raw spinlock by address is a worse risk than a torn read, and with the VM down
 * nothing is mutating it. The layout check below is what catches a bad read.
 */

#define pr_fmt(fmt) "ghhr_probe: " fmt
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/mm.h>
#include <linux/mmzone.h>
#include <linux/page-flags.h>

/* Must match gh_hugepage_reserve/parts/gh_data.c.inc exactly. The layout check in
 * probe_init() is what tells us if this ever drifts. */
#define SERVED_MAX	16384U
#define SERVED_NULL	0xFFFFU

struct served_node {
	unsigned long	pfn;
	pid_t		tgid;
	u16		next;
};

static int dump_max = 64;
module_param(dump_max, int, 0444);
MODULE_PARM_DESC(dump_max, "Maximum entries to print (default 64)");

/* kprobe resolves function addresses; data symbols need kallsyms_lookup_name, which is
 * itself only reachable as a function address. Same two-step gh_hugepage_reserve uses. */
static void *resolve_kfunc(const char *name)
{
	struct kprobe kp = { .symbol_name = name };
	void *addr = NULL;

	if (register_kprobe(&kp) == 0) {
		addr = (void *)kp.addr;
		unregister_kprobe(&kp);
	}
	return addr;
}

/* Is this pfn already sitting in one of the module's own arrays? A served entry whose page
 * is back in page_pool or limbo means the page was never lost at all -- only the bookkeeping
 * is stale, and served-minus-refilled overstates the loss. Worth ruling out before hunting a
 * leak that may not exist. */
#define POOL_SIZE_MAX	12288
#define LIMBO_MAX	64

static struct page **pool_arr;
static struct page **limbo_arr;
static atomic_t *pool_cnt;
static int *limbo_cnt;

static const char *where_is(unsigned long pfn)
{
	int i, n;

	if (pool_arr) {
		n = pool_cnt ? atomic_read(pool_cnt) : 0;
		if (n < 0 || n > POOL_SIZE_MAX)
			n = POOL_SIZE_MAX;
		for (i = 0; i < n; i++)
			if (pool_arr[i] && page_to_pfn(pool_arr[i]) == pfn)
				return " IN-POOL";
	}
	if (limbo_arr) {
		n = limbo_cnt ? *limbo_cnt : 0;
		if (n < 0 || n > LIMBO_MAX)
			n = LIMBO_MAX;
		for (i = 0; i < n; i++)
			if (limbo_arr[i] && page_to_pfn(limbo_arr[i]) == pfn)
				return " IN-LIMBO";
	}
	return "";
}

static void describe(unsigned long pfn, pid_t tgid, int idx)
{
	struct page *pg;
	struct folio *fo;
	unsigned long order;

	if (!pfn_valid(pfn)) {
		pr_info("[%d] pfn=%#lx tgid=%d  PFN NOT VALID\n", idx, pfn, tgid);
		return;
	}
	pg = pfn_to_page(pfn);
	fo = page_folio(pg);
	order = folio_test_large(fo) ? folio_order(fo) : 0;

	/* order tells split from intact: a pool page is order-9 when whole, and 0 once the
	 * folio has been split into 4K pages -- which is the case the order-9 free hook is
	 * structurally blind to. count==0 plus PageBuddy means it is simply free and the
	 * scavenger should have taken it; a nonzero mapcount or Anon/LRU means someone else
	 * owns it now; pinned means a GUP reference is holding it. */
	pr_info("[%d] pfn=%#lx tgid=%d count=%d mapcount=%d order=%lu%s%s%s%s%s%s%s flags=%#lx\n",
		idx, pfn, tgid,
		page_ref_count(pg),
		atomic_read(&pg->_mapcount) + 1,
		order,
		PageBuddy(pg)      ? " BUDDY"    : "",
		PageLRU(pg)        ? " LRU"      : "",
		PageAnon(pg)       ? " ANON"     : "",
		PageSlab(pg)       ? " SLAB"     : "",
		PageReserved(pg)   ? " RESERVED" : "",
		folio_test_large(fo) ? " LARGE"  : "",
		folio_maybe_dma_pinned(fo) ? " DMA-PINNED" : "",
		pg->flags);
	{
		const char *loc = where_is(pfn);

		pr_info("     ^ location:%s\n", loc[0] ? loc : " not in pool/limbo");
	}
}

static int __init probe_init(void)
{
	unsigned long (*kln)(const char *name);
	struct served_node *nodes;
	u16 *bucket;
	int *count;
	unsigned int b;
	int walked = 0, shown = 0;

	kln = resolve_kfunc("kallsyms_lookup_name");
	if (!kln) {
		pr_err("kallsyms_lookup_name not resolvable\n");
		return -ENOENT;
	}

	nodes  = (struct served_node *)kln("served_nodes");
	bucket = (u16 *)kln("served_bucket");
	count  = (int *)kln("served_count");
	if (!nodes || !bucket || !count) {
		pr_err("symbols missing: nodes=%p bucket=%p count=%p (is gh_hugepage_reserve loaded?)\n",
		       nodes, bucket, count);
		return -ENOENT;
	}

	pool_arr  = (struct page **)kln("page_pool");
	limbo_arr = (struct page **)kln("limbo_pages");
	pool_cnt  = (atomic_t *)kln("pool_count");
	limbo_cnt = (int *)kln("limbo_n");

	pr_info("served_count=%d  sizeof(served_node)=%zu  pool_count=%d limbo_n=%d\n",
		*count, sizeof(struct served_node),
		pool_cnt ? atomic_read(pool_cnt) : -1, limbo_cnt ? *limbo_cnt : -1);

	/* Walk the hash chains exactly as the module does. Two guards: a per-chain step cap so a
	 * torn or mismatched read cannot spin forever, and a total that must agree with the
	 * module's own served_count -- if it does not, the struct layout here has drifted from
	 * the module's and nothing printed below can be trusted. */
	for (b = 0; b < SERVED_MAX; b++) {
		u16 nd = bucket[b];
		int steps = 0;

		while (nd != SERVED_NULL && nd < SERVED_MAX && steps++ < 64) {
			walked++;
			if (shown < dump_max) {
				describe(nodes[nd].pfn, nodes[nd].tgid, shown);
				shown++;
			}
			nd = nodes[nd].next;
		}
	}

	if (walked != *count)
		pr_err("LAYOUT MISMATCH: walked %d entries but served_count=%d -- do not trust the dump\n",
		       walked, *count);
	else
		pr_info("walked %d entries (matches served_count), printed %d\n", walked, shown);

	/* One-shot: never stay loaded. */
	return -EAGAIN;
}

static void __exit probe_exit(void) { }

module_init(probe_init);
module_exit(probe_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("One-shot dump of gh_hugepage_reserve's served table with page state");
