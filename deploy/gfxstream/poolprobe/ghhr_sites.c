// SPDX-License-Identifier: GPL-2.0
/*
 * ghhr_sites - histogram of who asks for order-9 pages, by call site.
 *
 * ghhr_probe established what the leaked pages ARE: intact order-9 compound folios,
 * refcount 1, mapcount 0, no LRU/anon/slab/buddy/pin, and not in the pool or limbo
 * arrays. So they were allocated, handed out, and their last reference was never
 * dropped. What that does not say is WHO allocated them.
 *
 * page_owner would answer it directly, but it is compiled in and switched off, and the
 * cmdline also carries stack_depot_disable=on, so turning it on means changing boot
 * arguments. This gets the same answer without a reboot: a kprobe on __alloc_pages,
 * filtered to order 9, tallying the caller's return address.
 *
 * The expectation is a lopsided histogram. Guest RAM and the two pre-alloc pools are
 * thousands of allocations from one or two sites; the two that leak, per VM lifecycle,
 * should appear as a site with a count of 2. Then %pS names it.
 *
 * A plain kprobe rather than a kretprobe: at function entry on arm64 the caller's return
 * address is still in LR, which is all this needs, and it avoids the rethook machinery.
 * Resident while collecting, unregistered on unload -- unlike ghhr_probe this one has to
 * stay loaded, so it is a separate module from the one-shot dumper.
 */

#define pr_fmt(fmt) "ghhr_sites: " fmt
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/mm.h>
#include <linux/spinlock.h>
#include <asm/ptrace.h>

#define WANT_ORDER	9
#define MAXSITE		64

struct site {
	void		*ret;
	char		comm[TASK_COMM_LEN];
	unsigned long	n;
};

static struct site sites[MAXSITE];
static int nsites;
static unsigned long total, overflow;
static DEFINE_SPINLOCK(sites_lock);

static void record(void *ret, const char *comm)
{
	unsigned long flags;
	int i;

	spin_lock_irqsave(&sites_lock, flags);
	total++;
	for (i = 0; i < nsites; i++) {
		if (sites[i].ret == ret && !strncmp(sites[i].comm, comm, TASK_COMM_LEN)) {
			sites[i].n++;
			goto out;
		}
	}
	if (nsites < MAXSITE) {
		sites[nsites].ret = ret;
		strscpy(sites[nsites].comm, comm, TASK_COMM_LEN);
		sites[nsites].n = 1;
		nsites++;
	} else {
		overflow++;
	}
out:
	spin_unlock_irqrestore(&sites_lock, flags);
}

static int alloc_pre(struct kprobe *p, struct pt_regs *regs)
{
	/* __alloc_pages(gfp, order, ...) -- order is the second argument. */
	unsigned int order = (unsigned int)regs_get_kernel_argument(regs, 1);

	if (order == WANT_ORDER)
		record((void *)regs->regs[30], current->comm);   /* LR = caller */
	return 0;
}

static struct kprobe kp = { .pre_handler = alloc_pre };

/* Read to dump, write anything to reset. Sysfs gives a 4K buffer, and MAXSITE lines with
 * a symbol each fits comfortably. */
static int sites_get(char *buf, const struct kernel_param *kp_unused)
{
	unsigned long flags;
	int i, n = 0;

	spin_lock_irqsave(&sites_lock, flags);
	n += sysfs_emit_at(buf, n, "total=%lu sites=%d overflow=%lu\n", total, nsites, overflow);
	for (i = 0; i < nsites; i++)
		n += sysfs_emit_at(buf, n, "%8lu  %-16s %pS\n",
				   sites[i].n, sites[i].comm, sites[i].ret);
	spin_unlock_irqrestore(&sites_lock, flags);
	return n;
}

static int sites_set(const char *val, const struct kernel_param *kp_unused)
{
	unsigned long flags;

	spin_lock_irqsave(&sites_lock, flags);
	memset(sites, 0, sizeof(sites));
	nsites = 0;
	total = 0;
	overflow = 0;
	spin_unlock_irqrestore(&sites_lock, flags);
	return 0;
}

static const struct kernel_param_ops sites_ops = { .get = sites_get, .set = sites_set };
module_param_cb(sites, &sites_ops, NULL, 0600);
MODULE_PARM_DESC(sites, "order-9 allocation call sites; write to reset");

static int __init sites_init(void)
{
	static const char * const names[] = {
		"__alloc_pages_noprof", "__alloc_pages", "__alloc_pages_nodemask", NULL,
	};
	int i, ret = -ENOENT;

	for (i = 0; names[i]; i++) {
		kp.symbol_name = names[i];
		ret = register_kprobe(&kp);
		if (ret == 0) {
			pr_info("hooked %s\n", names[i]);
			return 0;
		}
	}
	pr_err("no suitable __alloc_pages symbol\n");
	return ret;
}

static void __exit sites_exit(void)
{
	unregister_kprobe(&kp);
	pr_info("unhooked, total=%lu sites=%d\n", total, nsites);
}

module_init(sites_init);
module_exit(sites_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Histogram of order-9 allocation call sites");
