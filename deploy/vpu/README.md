# `deploy/vpu/` — the VPU dev rig

The scripts a VPU work package needs to get a crosvm onto the lab phone, start a stored VM,
reach its guest, and see whether the guest got a working V4L2 device. Implements
`plans/VPU_DESIGN.md` §9.

Everything here is host-side bash + one python IPC client. Nothing is installed on the phone
except the crosvm payload `push_crosvm.sh` writes.

---

## Phone rules (read before you run anything)

The lab phone is `172.22.74.2:5566` (`PHONE=` overrides it). `5567`/`5568` belong to other work —
do not touch them from here.

* **Never `kill -9` crosvm.** A killed crosvm leaks Gunyah RM memparcels, and the quota is only
  reclaimed by rebooting the phone; the leak then masquerades as a "concurrent memparcel limit"
  fault days later. Stop a VM with `vm.sh stop` (which is the daemon's `vm_stop`), or
  `systemctl poweroff` inside the guest. `kill -TERM` is the last resort.
* **Never reboot the phone.** The reboot destroys `br-wifi`, which the app builds once, and every
  VM loses its network until the app is opened again.
* **Never `rmmod`/`insmod` on the phone.**
* **One crosvm at a time.** Two compete for the hugepage reserve and the second dies with ENOMEM.
* **Do not modify anything under `/data/data/cn.classfun.droidvm`** other than what
  `push_crosvm.sh` writes (`usr/bin/crosvm`, its dated `crosvm.bak.*`, and the `usr/lib/*.so`
  the APK payload already ships).
* The guest disk is a throwaway overlay, but keep guest changes to what the work needs.

## Two facts about the daemon that shape all of this

1. **The port and the token change on every daemon start.** `Daemon.java:177` writes a fresh UUID
   to `run/droidvmd-token.txt` and `Server.java:98` binds a random free port into
   `run/droidvmd-port.txt`. Nothing here caches them across invocations; each run re-reads both.
2. **The shipped `droidvm` CLI cannot start a VM that already exists.** `droidvm start` sends
   `vm_create` first, and `VMInstanceStore.createVM` refuses an existing id
   (`VMInstanceStore.java:81-85`). The daemon *does* expose a bare `vm_start`; it is simply
   unreachable from the CLI. That is why `dvmipc.py` exists and why `vm.sh` speaks JSON IPC
   rather than shelling out to `droidvm`.

Also: `vm_modify` only touches the daemon's in-memory store — `files/vms.json` is written by the
app's editor alone. Anything `vm_extra.sh` sets is lost when the daemon restarts, and a daemon
restart stops every VM (`Daemon.cleanup`).

---

## The scripts

| script | what it does |
|---|---|
| `lib.sh` | sourced by the rest: `PHONE`, root-shell helpers, daemon start/port/token, `adb forward`, VM lookup, EUI-64 guest address |
| `dvmipc.py` | the JSON IPC client: `list`, `status`, `start`, `stop`, `modify`, `get`, `console-history` |
| `vm.sh` | `start\|stop\|status\|argv\|log\|wait-ssh <name>` |
| `guest.sh` | `ssh\|scp\|install-tools\|install-deb\|dmesg <name> [args]` |
| `push_crosvm.sh` | `crosvm_out/` → phone, md5-verified, dated backup, `--dry-run` |
| `vm_extra.sh` | `show\|set\|takeover\|restore\|clear <name>` — the VM's `extra_options` array |
| `tests/smoke_media.sh` | `[--mode output\|none\|all] <name>` — is there a working virtio-media device in the guest? |

A VM is named by either its `name` or its `id`; both go through one `vm_list` lookup.

`shellcheck -x` is run **from `deploy/vpu/`** — the `# shellcheck source=lib.sh` directives are
relative, so from anywhere else `-x` cannot follow them and the run is not meaningful:

```sh
cd deploy/vpu && shellcheck -x ./*.sh tests/*.sh
```

### `vm.sh`

```sh
deploy/vpu/vm.sh status   Ubuntu-resolute   # state, pid, guest address, console streams
deploy/vpu/vm.sh argv     Ubuntu-resolute   # /proc/<pid>/cmdline, one argument per line
deploy/vpu/vm.sh log      Ubuntu-resolute   # daemon's "Executing:" line + the VM's stdio history
deploy/vpu/vm.sh start    Ubuntu-resolute
deploy/vpu/vm.sh stop     Ubuntu-resolute
deploy/vpu/vm.sh wait-ssh Ubuntu-resolute   # BUDGET=240 by default
```

`argv` is the ground truth for what the daemon actually emitted; `log` is the same argv as the
daemon logged it (`CrosvmBackendInstance.java:183`) plus the boot output, which is where a
rejected flag shows up. If the daemon is not running, any verb starts it first, exactly the way
the UI does (`DaemonHelper.java:138-151`) with the stdio redirection an `adb shell` needs.

Budget **90–120 s** from `vm_start` to ssh answering.

### `guest.sh`

```sh
deploy/vpu/guest.sh ssh           Ubuntu-resolute 'uname -a'
deploy/vpu/guest.sh install-tools Ubuntu-resolute        # v4l-utils ffmpeg gstreamer1.0-tools gstreamer1.0-plugins-bad
deploy/vpu/guest.sh install-deb   Ubuntu-resolute out/droidvm-guest-additions_*.deb
deploy/vpu/guest.sh dmesg         Ubuntu-resolute -T | tail -40
deploy/vpu/guest.sh scp           Ubuntu-resolute ./file :/tmp/     # ':' = the guest side
deploy/vpu/guest.sh scp           Ubuntu-resolute :/tmp/out.raw .   # …in either direction
```

The address is derived, not discovered: the guest's SLAAC address is the EUI-64 of the NIC MAC in
the VM config, on the phone's own `/64` (read live off `wlan0`). So it is known before the guest
boots. `GUEST6=<addr>` overrides.

**Two routes in, chosen automatically.** Normally ssh goes straight to that address. When the
direct route is dead — the lab router's NDP entry for the `/128` the phone proxies on `wlan0`
sometimes never resolves, and WP G1 lost the route for a whole session while the phone itself
pinged the guest at 1.5 ms (`logs/vpu_wp/G1.md` §1) — the rig falls back on its own to a
`ProxyCommand` through the phone's root shell:

```sh
ssh -o ProxyCommand='adb -s $PHONE shell -T su -c "busybox nc -w 30 %h %p"' root@<guest>
```

The direct path is probed once per run with `ConnectTimeout=$SSH_CONNECT_TIMEOUT` (8 s); which
path was taken is printed on stderr once. `scp`, `install-deb` and `vm.sh wait-ssh` use the same
choice. `GUEST_SSH_VIA=direct|proxy` skips the probe; the netcat is whichever of `busybox` /
`toybox` the phone's root shell has (KernelSU's `/data/adb/ksu/bin/busybox` on the lab device).

### `push_crosvm.sh`

```sh
deploy/vpu/push_crosvm.sh --dry-run     # print every decision, change nothing
deploy/vpu/push_crosvm.sh               # refuses while a crosvm is running
```

`adb push` into a root-owned directory **fails silently** — it reports "1 file pushed" and the
file does not change. So every file goes to the shell-writable `/data/local/tmp/crosvm_vpu.new/`
first, is `su cp`'d into place, and is md5-compared at both hops.

A `.so` is installed **only if `$APP/usr/lib` already has one by that name**. That directory is on
crosvm's `LD_LIBRARY_PATH` and is searched before `/system/lib64`, so a library placed there
shadows the platform's for every consumer — which has already broken `libmediandk.so`'s H.264
encoder once (stale `libgui.so`) and made crosvm unlinkable on Android 17 once (our older
`libc++.so` hiding `std::__1::__hash_memory` from `libaudiobase.so`).
`6_build_apk_prepare.sh:29-48` deletes eleven such libraries from the APK payload for exactly this
reason; this script must never put one back. Today that means `crosvm_out/`'s
`libgfxstream_backend.so`, `libvirglrenderer.so` and `libvncserver.so` are installed and
`libbase/libc++/libcap/libcutils/liblog/libminijail/libnativewindow/libprocessgroup` are skipped.

The previous binary is kept as `usr/bin/crosvm.bak.<YYYYmmdd-HHMM>` before it is replaced.

### `vm_extra.sh`

The only seam for handing crosvm a flag the app does not know about yet — which is how the VPU
pools and the media device get onto the command line until WP A1 lands.

```sh
deploy/vpu/vm_extra.sh show     Ubuntu-resolute
deploy/vpu/vm_extra.sh takeover Ubuntu-resolute media-host-mb=256,media-guest-mb=128 -- --virtio-media kind=loopback,card=lb0
deploy/vpu/vm_extra.sh restore  Ubuntu-resolute
deploy/vpu/vm_extra.sh set      Ubuntu-resolute --pre-alloc <FULL MERGED STRING> --virtio-media kind=loopback
deploy/vpu/vm_extra.sh clear    Ubuntu-resolute
```

**`--pre-alloc` cannot appear twice on a crosvm command line.** It is
`Option<PreAllocConfig>` in argh (`crosvm/src/crosvm/cmdline.rs:2073`), and argh answers a
repeated `Option` flag with a fatal parse error before crosvm runs anything:

```
ERROR crosvm] arg parsing failed: Error parsing option '--pre-alloc' with value '...':
  duplicate values provided
INFO  crosvm] invalid argument
```

The VM goes straight back to `stopped`. So a second `--pre-alloc` is **not** an override and
**not** a merge — an earlier version of this file and of `vm_extra.sh merge` claimed it was, and
WP B1 found out on the phone (`logs/vpu_wp/B1-acceptance.md` §8, defect **D2**). `extra_options`
may carry a `--pre-alloc` only while the daemon emits **none**, and the daemon emits one whenever
any pool key of a Gunyah VM is non-zero (`CrosvmBackendInstance.java:421-470`). On the lab VM
today that is:

```
--pre-alloc drm-host-mb=64,gpu-guest-mb=1024,gpu-guest-prealloc-mb=1024,gpu-guest-step-mb=0,gpu-guest-max-grants=0
```

**`takeover` is the way in.** It mechanises the workaround B1 used by hand: it reads the daemon's
own `--pre-alloc` (off `/proc/<pid>/cmdline` while the VM runs, off the last `Executing:` line in
`daemon.log` when it is stopped), **saves** the config keys that produce it —
`gpu_host_pool_mb`, `gpu_guest_pool_mb`, `gpu_guest_prealloc_mb`, `gpu_drm2kgsl_pool_mb`,
`gpu_venus_pool_mb` — into `deploy/vpu/state/<vm>.json`, **sets them to 0** so the daemon emits no
`--pre-alloc` at all, and stores the whole string (the daemon's GPU keys plus your media keys)
plus everything after `--` in `extra_options`:

```sh
deploy/vpu/vm_extra.sh takeover Ubuntu-resolute media-host-mb=256,media-guest-mb=128 -- \
  --virtio-media kind=loopback,card=lb0
deploy/vpu/vm_extra.sh restore  Ubuntu-resolute      # keys back, extra_options emptied
```

The resulting command line is byte-identical to what a working merge would have produced, and
`vm.sh argv <name> | grep -c -- --pre-alloc` is 1.

**Two things a takeover costs you.**

* `PoolPreflight` sizes the huge-page reserve from those config keys
  (`GuestPoolSizing.bootGuestPreallocMb`), not from the string on the command line, so **while a
  takeover is active it under-counts by the zeroed guest pool** — 1024 MiB on the lab VM. crosvm
  still asks the RM for that memory. Check `gh_hugepage_reserve`'s `pool_avail` before starting.
* `vm_modify` writes only the daemon's **in-memory** store (`files/vms.json` is the app editor's
  alone, `app-daemon.md` §5.4), so both the zeroed keys and `extra_options` vanish on a daemon
  restart — which also stops every VM (`Daemon.cleanup`). After a restart, delete the stale
  `state/<vm>.json` and re-run `takeover`; running `restore` on it instead is harmless but
  pointless — it writes back the values the reloaded config already has.

`takeover` refuses the two configurations it cannot silence: one whose daemon string already
carries `media-host-mb`/`media-guest-mb` (the WP A1 world — use `set` with only `--virtio-media`),
and a gfxstream VM with `gpu_udmabuf` on, where the daemon emits `gfx-host-mb` even at size 0
(`CrosvmBackendInstance.java:426-431`).

**Once the WP A1 APK is installed and the VM's VPU switch is on, `extra_options` must carry no
`--pre-alloc` at all** — only `--virtio-media ...`. The daemon then emits `media-host-mb` /
`media-guest-mb` itself, and any second one is the fatal parse error above (review B3).
Check with `vm.sh argv <name> | grep -c -- --pre-alloc`: it must be 1.

`set` is the escape hatch: it replaces the whole array with exactly what you type, and it is on
you to have zeroed the daemon's keys first.

`vm_modify` refuses a VM that is not `STOPPED`, so every writing verb of `vm_extra.sh` refuses
first, before it reads or sends anything.

### `tests/smoke_media.sh`

```sh
deploy/vpu/tests/smoke_media.sh Ubuntu-resolute
deploy/vpu/tests/smoke_media.sh --mode all Ubuntu-resolute    # or --mode output | --mode none
```

Waits for ssh, then checks the driver is loaded, a `/dev/video*` node exists, dmesg mentions the
driver, and `v4l2-ctl --all` answers on every node. Then it moves real bytes:

* card `simple_device` — 30 frames to `/tmp/simple.raw`, which must be **exactly 30 × 921600**
  bytes (640×480 RGB3) with **at least two distinct frames** (the device paints a changing
  uniform colour, so 30 identical frames means nothing arrived);
* card `loopback` — 460800 random bytes (640×480 NV12) in through `--stream-from`, out through
  `--stream-to`, `--stream-count=10`, and `cmp -n 460800` between the two. This is the only step
  that proves bytes crossed the queues rather than that an ioctl returned 0.

`--mode output|none|all` reloads the guest module first (`modprobe -r virtio-media; modprobe
virtio-media driver_owned_queues=<mode> pool_debug=1`) — that is how the three driver-owned-buffer
policies of design §2.1 get exercised in turn. Without `--mode` the module is left untouched.
Either way the run ends by printing the guest's `virtio-media` dmesg lines, which is where
`pool_debug`'s dbuf alloc/free traces show up. (Reloading a module is fine **in the guest**; the
"never `rmmod`/`insmod`" rule is about the phone.)

Missing card types are skipped, not failed — which one exists depends on how crosvm was launched.
Any real failure makes the script exit non-zero. Run `guest.sh install-tools` once first: the test
needs `v4l2-ctl`.

---

## A typical loop

```sh
cd deploy/vpu && shellcheck -x ./*.sh tests/*.sh && cd -   # before committing anything here
JOBS=8 taskset -c 0-7 ./2_build_crosvm.sh          # never unpinned, never more than 8 jobs
deploy/vpu/vm.sh   stop  Ubuntu-resolute
deploy/vpu/push_crosvm.sh
deploy/vpu/vm_extra.sh takeover Ubuntu-resolute media-host-mb=256,media-guest-mb=128 -- \
  --virtio-media kind=loopback,card=lb0
deploy/vpu/vm.sh   start Ubuntu-resolute
deploy/vpu/vm.sh   argv  Ubuntu-resolute | grep -E 'pre-alloc|media'
deploy/vpu/tests/smoke_media.sh Ubuntu-resolute
```

`takeover` stores exactly what the review's test plan asks for:

```
--pre-alloc <daemon string>,media-host-mb=256,media-guest-mb=128 --virtio-media kind=loopback,card=lb0
```

### Deployment order for a whole batch

Review B3's order, confirmed by WP B1 on the phone (`logs/vpu_wp/B1-acceptance.md` §2). Each step
is a different half of the same contract, and a later one assumes the earlier one is in place:

1. **crosvm** — `vm.sh stop`, then `push_crosvm.sh` (it refuses while a crosvm runs), then
   `vm.sh start` with the **old** `extra_options` and check the guest still boots. That separates
   "the new binary is broken" from "the new flags are wrong".
2. **the guest-additions deb** — `guest.sh install-deb <deb>`, then `dkms status` and
   `modinfo virtio-media`. The guest driver has to be the one that matches the host crate before
   any media flag is worth passing.
3. **`extra_options`** — `vm.sh stop`, `vm_extra.sh takeover ...`, `vm.sh start`, then
   `vm.sh argv | grep -c -- --pre-alloc` (must be 1).
4. **the APK**, last. It is what makes step 3 unnecessary: with the WP A1 APK installed and the
   VM's VPU switch on, the daemon emits the media keys itself, so `restore` the takeover and put
   only `--virtio-media` in `extra_options`.

**`takeover` is bring-up only** — it exists for the window before that APK is installed. It
reaches into the VM's GPU pool sizes to buy one command-line slot, and nothing outside this rig
knows it did.

### `media-host-mb` is not optional on Gunyah

On a Gunyah host, crosvm refuses to start a VM that has a `--virtio-media` device and no
`--pre-alloc media-host-mb` (`virtio-media on gunyah needs --pre-alloc media-host-mb` in
`vm.sh log`). That holds **whatever the guest driver's `driver_owned_queues` is set to, `all`
included** — a mode in which the guest owns every queue and never maps a single host buffer.
The switch is a guest-side policy the host cannot see or rely on: the device has to be able to
serve a host-owned `MMAP` buffer the moment some program in the guest asks for one, and on Gunyah
the pool is the only place it can put one (the 64-bit MMIO window has room for one 4 GiB
shared-memory BAR and the GPU already has it, design §0.2/§3.3). So always pass
`media-host-mb=256` in, even for an `--mode all` run. `media-guest-mb` is the one that is
genuinely optional: without it the guest driver falls back to `dma_alloc_pages` behind the
restricted-dma-pool. All the media devices of one VM share the one `media_host` pool.

If `start` comes back "went back to stopped", `vm.sh log` has the reason: crosvm rejects an
unknown flag before the guest ever runs, and that lands in the `stdio` history.
