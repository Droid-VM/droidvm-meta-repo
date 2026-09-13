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
| `dvmipc.py` | the JSON IPC client: `list`, `status`, `start`, `stop`, `stop-all`, `modify`, `get`, `console-history` |
| `vm.sh` | `start\|stop\|status\|argv\|log\|log-level\|wait-ssh <name>`, plus `stop-all\|daemon-check\|daemon-restart` |
| `hp.sh` | `status\|expect on\|expect off\|reclaim` — the hugepage watchdog: assert the VM state instead of sleeping |
| `install_apk.sh` | `<apk>` → stop every VM, install, unpack the payload, restart the daemon, verify all of it |
| `guest.sh` | `ssh\|scp\|install-tools\|install-deb\|dmesg <name> [args]` |
| `push_crosvm.sh` | `crosvm_out/` → phone, md5-verified, dated backup, `--dry-run` |
| `vm_extra.sh` | `show\|set\|takeover\|restore\|clear <name>` — the VM's `extra_options` array |
| `harness.sh` | `<gbt\|kvt\|kst\|mpt\|vmt\|acb\|acc\|acd\|all>` — the host-side cargo harnesses; no phone, no network |
| `tests/pick_device.sh` | not a test: the guest-side snippet the three below prepend to their remote script to pick `/dev/videoN` **by capability** |
| `tests/smoke_media.sh` | `[--mode output\|none\|all] <name>` — is there a working virtio-media device in the guest? |
| `tests/compliance.sh` | `<name> [/dev/videoN]` — `v4l2-compliance -s` in the guest; the test for **D6** |
| `tests/drain.sh` | `<name> [/dev/videoN]` — one frame in, `--stream-count=10`: the **D5** reproduction |
| `tests/ext_ctrls_error_idx.c` | not a script: the C client that closed **D37** — copy it into the guest, `cc` it, and read `error_idx` off a refused `EXT_CTRLS` where Python cannot |

A VM is named by either its `name` or its `id`; both go through one `vm_list` lookup — in the
shell scripts via `lib.sh`'s `vm_info`, and in `dvmipc.py get|modify` via `Daemon.resolve`, since
the daemon's own handlers take a bare `vm_id` and never resolve a name (`GetHandler.java:27-30`).

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
deploy/vpu/vm.sh log-level Ubuntu-resolute debug   # how loud the VMM is (defect D60)
deploy/vpu/vm.sh log-level Ubuntu-resolute -       # back to crosvm's own info
deploy/vpu/vm.sh wake                              # the phone's screen, before any camera bar
```

`log-level` is the one knob that makes a `debug!` readable on a phone at all, and it is worth
knowing exactly what it does. It stores the app's per-VM `log_level` key, which
`CrosvmBackendInstance` emits as a **top-level** `--log-level <filter>` — between the crosvm
binary and `run`. That position is the whole point: `--log-level` is a `CrosvmCmdlineArgs`
option, so after `run` argh fails the entire parse (`arg parsing failed: Unrecognized argument:
--log-level`) and the VM goes straight back to stopped — which is exactly what happens if you try
to smuggle it through `vm_extra.sh set`, and why that seam could not stand in for this
(**D60**, `logs/vpu_wp/B11-acceptance.md` §8). Every media helper crosvm launches is exec'd with
the VMM's own level (`/proc/self/exe --log-level <filter> device media …`, **D57**), so one verb
moves the VMM and all three helpers together.

The value is an `env_logger` filter: a level name — `off error warn info debug trace` — or a
compound such as `info,devices::virtio::media=debug` or `debug,disk=off`. `-` (or `info`) deletes
the key, which is crosvm's own default and emits no flag. The VM must be **stopped**
(`vm_modify` accepts no other state), and the change lives in the daemon's memory only, so a
daemon restart — an `install_apk.sh`, for one — drops it. Confirm it landed on the next start:

```sh
deploy/vpu/vm.sh log-level Ubuntu-resolute debug && deploy/vpu/vm.sh start Ubuntu-resolute
deploy/vpu/vm.sh argv Ubuntu-resolute | grep -A1 -- --log-level    # before `run`, or it did not
deploy/vpu/vm.sh log  Ubuntu-resolute | grep 'log level'           # each helper's launch line
```

The rig does not check the filter; `VmmLogLevel.java` is the one parser, and a value it refuses
is dropped with a warning in `daemon.log` — the VM starts, at `info`, with no `--log-level` in
its argv. So the `argv` line above is the check, not the absence of an error from this verb.

`argv` is the ground truth for what the daemon actually emitted; `log` is the same argv as the
daemon logged it (`CrosvmBackendInstance.java:183`) plus the boot output, which is where a
rejected flag shows up. If the daemon is not running, any verb starts it first, exactly the way
the UI does (`DaemonHelper.java:138-151`) with the stdio redirection an `adb shell` needs.

Budget **90–120 s** from `vm_start` to ssh answering.

Four verbs take no VM name — three act on the daemon, and `wake` on the phone itself:

```sh
deploy/vpu/vm.sh stop-all          # vm_stop_all, then wait until vm_list shows none running
deploy/vpu/vm.sh daemon-check      # is the running daemon the installed APK's code?  (defect D12)
deploy/vpu/vm.sh daemon-restart    # stop-all, then start with --force, then daemon-check
deploy/vpu/vm.sh wake              # KEYCODE_WAKEUP + wm dismiss-keyguard, then print the state
```

`daemon-check` prints the CLASSPATH the running daemon was started with next to `pm path
cn.classfun.droidvm`, and exits non-zero when they differ (`STALE`) or when no daemon is running.
The CLASSPATH is read from `/proc/<pid>/environ`, **not** `cmdline`: the pid in
`run/droidvmd.pid` is the `app_process64` that `env` exec'd, so its cmdline is only
`/system/bin/app_process64 / cn.classfun.droidvm.daemon.Daemon [--force]`.

`daemon-restart` is `DaemonHelper.startDaemon(true)` — the same command line with a trailing
`--force`, which takes the single-instance lock away from the running daemon. It runs `stop-all`
first: the replaced daemon takes its VMs down with it (`Daemon.cleanup`), and a crosvm that ends
any way other than `vm_stop` leaks RM memparcels until the phone is rebooted. Remember that a
daemon restart also drops everything `vm_extra.sh` put in the in-memory store.

`wake` is a **camera precondition**, not a convenience: the app's `CAMERA` appop is
`foreground`-only, so a sleeping screen leaves the app `TOP_SLEEPING` and cameraserver refuses or
revokes the stream — see trap 10 for the three signatures it produces. It sends `input keyevent
KEYCODE_WAKEUP` and `wm dismiss-keyguard`, waits a second, and prints one line:

```
screen: mScreenState=ON mWakefulness=Awake screen_off_timeout=300000
```

`start` runs it by itself when the VM's config carries a `virtio_camera` row (`lib.sh`'s
`wake_for_camera`), and never fails a start over it. That is not enough on its own: the screen
sleeps again after `screen_off_timeout`, so run `wake` **immediately before** each capture — a
`guest.sh ssh` that runs `v4l2-ctl --stream-mmap`, an ffmpeg `-f v4l2` bar, the band detector —
and put the printed timeout in the report. Nothing it does outlives the session; the appop is
left exactly as found.

### Waiting on VM state: `hp.sh`

Every VM on the phone runs on memory the `gh_hugepage_reserve` module hands out, so the module's
counters *are* the VM state — and they move when `crosvm` takes or frees the memory, seconds
before `vm_list` changes its mind and a minute or two before ssh answers. `hp.sh` compares the
state you **expect** against the counters, so an acceptance step asserts instead of sleeping
(`W/debugloop.md` is the rule in the user's own words).

One hugepage is **2 MiB**; on 5566 `pool_want` is **3072** pages = 6 GiB. Everything is read from
`/sys/module/gh_hugepage_reserve/parameters/` through `lib.sh`'s root helper, one adb round trip
per sample — `refill_stat` and `vm_owners` are read in the *same* root shell, so a verdict never
mixes two instants. `POOL_DESIGN.md` §10 is the sysfs contract.

```sh
deploy/vpu/hp.sh status                                   # one screen of the counters
deploy/vpu/hp.sh expect off [--wait 30]                   # expected: no VM
deploy/vpu/hp.sh expect on  [--min-mb 4096] [--wait 20]   # expected: a VM is up
deploy/vpu/hp.sh reclaim --yes                            # the remedy for "not reclaimed"
```

**The two expected states.**

| after | `served` | `pool_avail` |
|---|---|---|
| the VM is stopped | `0` | `== pool_want` — the pool is full again |
| the VM is up | `>=` the VM's configured memory (the guest pools take more on top) | `< pool_want` |

Every answer is one line, `hp: <verdict>: <details>`, and the verdict **is** the exit code:

| exit | verdict | what it means, and what to do about it |
|---|---|---|
| 0 | `OK` | the expected state |
| 2 | `not reclaimed` | `served=0` but `pool_avail < pool_want`: the memory the last VM freed has not come back to the pool yet, and the next `start` is the one that will fail. Remedy: `hp.sh reclaim --yes` — it writes `1 > manual_release`, re-checks after 10 s, and if the pool is still short writes `3 > acquire` (CONTIG_AT+EVICT_ISOLATE) and waits for `acquire_active` to fall back to 0. |
| 3 | `vm still up` | `served != 0` where none was expected: the previous VM has not finished stopping, or something else is running. The remedy block prints the `vm_owners` line (pid / comm); confirm with `vm.sh status <name>` and stop it with `vm.sh stop`. A leftover `crosvm` the daemon has lost gets a `kill -TERM` — **never** `kill -9`, which leaks Gunyah RM memparcels until the phone is rebooted. |
| 4 | `not started` | `served=0` where a VM was expected: it never got off the ground, or it exited. Read the VM log **now** — `vm.sh log <name>`, or the app's stderr if the app launched it. Do not wait for `wait-ssh`: ssh will never answer. |
| 5 | `short` | `served > 0` but under `--min-pages` / `--min-mb`. Read it the same way as 4. |
| 1 | — | the module is not loaded, or its parameters are not readable |
| 64 | — | usage — including `reclaim` without `--yes`, which prints the two writes it would make and stops |

`--wait SECS` samples once a second until the verdict is `OK` or the time runs out, and prints a
line only when the verdict **changes** — so the last line printed is always the one it exits on,
and a slow-but-fine stop is two lines rather than thirty. `reclaim` refuses outright while
`served != 0`: pulling pages out from under a live VM is not a repair.

**`vm.sh` runs it for you.** `start` ends with `hp expect on --wait 20 --min-pages <memory_mb/2>`;
`stop` and `stop-all` end with `hp expect off --wait 30`. Those verdicts are printed and are never
fatal — the watchdog reports, `vm.sh`'s exit code still comes from the daemon. `wait-ssh` is the
one exception: it runs `hp expect on --wait 20` *before* the ssh loop and dies immediately on
`not started`, because 240 s of ssh retries against a VM that is not there only hides the reason.
`HP_CHECK=0` skips every one of these (a phone without the module).

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

### `install_apk.sh`

```sh
deploy/vpu/install_apk.sh DroidVM/app/build/outputs/apk/debug/app-debug.apk
```

**An `adb install -r` alone leaves the phone running the OLD crosvm and the OLD daemon** (defect
**D12**, `logs/vpu_wp/B3-acceptance.md` §3). Both halves look fine if nobody checks — `pm path`
and `droidvm --version` answer, the VM starts, and its argv was built by the code you thought you
replaced. The two reasons:

* the native payload under `$APP/usr` is unpacked by the app's **UI** — `SplashActivity:72` →
  `AssetUtils.needsExtractPrebuilt` → `ExtractStepFragment.runCheck`, which runs without any
  button press — and not by the install or the daemon;
* the daemon is a bare root `app_process64` started through `su`, so the package update does not
  kill it and it keeps executing the `base.apk` that was replaced. (`ps -A | grep droidvm` finds
  nothing, which is what makes it look gone.)

So the script does, in order, and verifies each step:

1. `vm_stop_all` — every VM down through the daemon's own path, and waited for;
2. `adb install -r <apk>`;
3. `monkey -p cn.classfun.droidvm -c android.intent.category.LAUNCHER 1` — one launch, which is
   what triggers the extraction;
4. poll up to 60 s (B3 measured ~15 s) until `sha256sum $APP/usr/bin/crosvm` equals the hash the
   APK itself claims: `assets/prebuilts/prebuilt-<abi>.json`'s `usr/bin/crosvm` entry, read out of
   the APK with `zipfile`. If it never matches, the app is probably sitting on a prompt on the
   phone — the script says so and stops;
5. `daemon-restart` — `stop-all` plus a `--force` start onto the new `base.apk`;
6. print `droidvm --version`, the package's `versionCode`/`versionName`, the crosvm hash, and a
   final `daemon-check`.

Doing it by hand is the same six steps; `vm.sh daemon-check` is the one that catches the mistake
afterwards.

### `vm_extra.sh`

The only seam for handing crosvm a flag the app does not know about yet — which is how the VPU
pools and the media device get onto the command line until WP A1 lands.

```sh
deploy/vpu/vm_extra.sh show     Ubuntu-resolute
deploy/vpu/vm_extra.sh takeover Ubuntu-resolute media-host-mb=320,media-guest-mb=192 -- --virtio-media kind=loopback,card=lb0
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
own `--pre-alloc` (off `state/<vm>.json` when a takeover is already active, else off
`/proc/<pid>/cmdline` while the VM runs, else off the last `Executing:` line in `daemon.log`),
**saves** the config keys that produce it —
`gpu_host_pool_mb`, `gpu_guest_pool_mb`, `gpu_guest_prealloc_mb`, `gpu_drm2kgsl_pool_mb`,
`gpu_venus_pool_mb` — into `deploy/vpu/state/<vm>.json`, **sets them to 0** so the daemon emits no
`--pre-alloc` at all, and stores the whole string (the daemon's GPU keys plus your media keys)
plus everything after `--` in `extra_options`:

```sh
deploy/vpu/vm_extra.sh takeover Ubuntu-resolute media-host-mb=320,media-guest-mb=192 -- \
  --virtio-media kind=loopback,card=lb0
deploy/vpu/vm_extra.sh restore  Ubuntu-resolute      # keys back, extra_options emptied
```

**It is repeatable** (defect D7). Re-running `takeover` on a VM that is already taken over is how
you change the media sizes or the `--virtio-media` line, and it costs no boot: the base string
comes from the `daemon_pre_alloc` saved at the *first* takeover, and the saved config keys are
never overwritten, so one `restore` still undoes any number of takeovers. The reason this needs
saying: after a takeover-launched boot the live command line and the last `Executing:` line are
**the takeover's own**, media keys and all — so anything read from them has its `media-*` keys
stripped before use, and the script says which it dropped.

```sh
deploy/vpu/vm_extra.sh takeover Ubuntu-resolute --show media-host-mb=320,media-guest-mb=192 -- \
  --virtio-media kind=loopback,card=lb0        # print what would be sent; send nothing
deploy/vpu/vm_extra.sh takeover Ubuntu-resolute --base 'drm-host-mb=64,gpu-guest-mb=1024' \
  media-host-mb=320                            # skip the search: this string is the daemon's
```

`--show` runs every guard and the whole merge and then prints the `extra_options` and the keys it
would zero, without touching the daemon or `state/` — so it is safe on a **running** VM, which is
the one case the writing verbs refuse outright.

The resulting command line is byte-identical to what a working merge would have produced, and
`vm.sh argv <name> | grep -c -- --pre-alloc` is 1.

**Two things a takeover costs you.**

* `PoolPreflight` sizes the huge-page reserve from those config keys
  (`GuestPoolSizing.bootGuestPreallocMb`), not from the string on the command line, so **while a
  takeover is active it under-counts by the zeroed guest pool** — 1024 MiB on the lab VM. crosvm
  still asks the RM for that memory. Check `gh_hugepage_reserve`'s `pool_avail` before starting
  (`hp.sh status`).
* `vm_modify` writes only the daemon's **in-memory** store (`files/vms.json` is the app editor's
  alone, `app-daemon.md` §5.4), so both the zeroed keys and `extra_options` vanish on a daemon
  restart — which also stops every VM (`Daemon.cleanup`). After a restart, delete the stale
  `state/<vm>.json` and re-run `takeover`; running `restore` on it instead is harmless but
  pointless — it writes back the values the reloaded config already has.

`takeover` refuses the two configurations it cannot silence: one with `vpu_enabled` set in the
VM's **config** (the WP A1 world — the daemon emits `media-host-mb`/`media-guest-mb` itself, so
use `set` with only `--virtio-media`), and a gfxstream VM with `gpu_udmabuf` on, where the daemon emits `gfx-host-mb` even at size 0
(`CrosvmBackendInstance.java:426-431`).

**Once the WP A1 APK is installed and the VM's VPU switch is on, `extra_options` must carry no
`--pre-alloc` at all** — only `--virtio-media ...`. The daemon then emits `media-host-mb` /
`media-guest-mb` itself, and any second one is the fatal parse error above (review B3).
Check with `vm.sh argv <name> | grep -c -- --pre-alloc`: it must be 1.

`set` is the escape hatch: it replaces the whole array with exactly what you type, and it is on
you to have zeroed the daemon's keys first.

`vm_modify` refuses a VM that is not `STOPPED`, so every writing verb of `vm_extra.sh` refuses
first, before it reads or sends anything.

### `harness.sh`

```sh
deploy/vpu/harness.sh vmt     # one harness
deploy/vpu/harness.sh all     # all eight, well under a minute from cold
```

The only part of this rig that never touches the phone. Three crates that hold VPU code cannot
be tested with cargo on the dev box — crosvm's `devices` and `src/crosvm` (a pre-existing `rand`
version mismatch, `logs/vpu_wp/M2.md` §5.3) and the virtio-media fork's `device/` (it wants nix
0.28, zerocopy 0.7 and a v4l2r that builds bindgen 0.69, none of which is in this box's offline
cargo cache) — and soong builds all three for aarch64 but runs no `rust_test`. So the unit tests
in those files run **here or nowhere**, and until now the little packages that run them were
retyped by hand each work package (`M3.md` §9 item 5).

`harness/<name>/` holds each one. Nothing in there is a copy of code under test: every harness
names the real file, by `#[path]` include (`gbt`, `mpt`, `kst`, `acb`, `acd`), as a path dependency
(`acc`), by `[lib] path` (`vmt`), or by
lifting the item out by name in a `build.rs` (`kvt`) — so a rename is a build failure, never a
stale copy quietly passing.

| harness | what it runs | tests |
|---|---|---|
| `gbt` | `devices/src/virtio/media/guest_buf.rs` — the guest scatter-gather arena and the window policy | 8 |
| `kvt` | `MediaDeviceKind` (+ its support table) and `MediaDeviceConfig`: the `--virtio-media` command-line surface | 4 |
| `kst` | `devices/src/virtio/media/kill.rs` — the worker's kill signal | 5 |
| `mpt` | `devices/src/virtio/media/pool.rs` — the `media_host` pool allocator, its leases, and the VMM-side tube that answers every helper's `Reserve`/`Release` (D49, M8) | 11 |
| `vmt` | the fork's whole `device/` crate, `-p virtio-media` (the camera and the two video codec devices included) | 127 |
| `acb` | `android_camera` (lib + `probe.rs`) and both halves of `media/android_camera_backend/` | 0 — a type-check; a failure here is a compile error |
| `acc` | `android_codec` (lib + `codec_probe`), `-p android_codec`: the MediaImage2 / Annex-B / IVF / synth unit tests | 31 |
| `acd` | both halves of `media/android_codec_backend/` -- the MediaCodec decoder and encoder backends -- against the fork's `video_decoder` and `video_encoder` devices | 0 — a type-check, like `acb` |

Each is staged into `${TMPDIR:-/tmp}/droidvm-harness/<name>` and built there, so the repo stays
clean and `target/` survives between runs; the full log of each run is `<that dir>/<name>.log`.
All of them are staged whichever one you ask for, because `mpt`'s, `acb`'s and `acd`'s manifests
point at `vmt`'s packages next door. `@W@` in a manifest is rewritten to this checkout's root as it is
staged — do not hardcode a path in one.

Two things the harnesses depend on, and what to do when they break:

* **the offline cargo cache** (`~/.cargo/registry`). Every run is `--offline` and must stay that
  way; the checked-in `Cargo.lock` of each harness is what pins it there. If cargo asks to
  download something, the lock and the cache have diverged — say so rather than dropping
  `--offline`.
* **soong's generated v4l2r bindings**, which `vmt/v4l2r/build.rs` copies into `OUT_DIR` instead
  of running bindgen (`crosvm_build/out/soong/.intermediates/.../libv4l2r_bindgen/…/bindings.rs`).
  A crosvm soong build produces them; `V4L2R_BINDINGS_RS=<path>` overrides the search.

Two kinds of noise are expected and are not findings. Several harnesses open with `Patch ... was
not used in the crate graph`, because the `[patch.crates-io]` block each one carries is crosvm's,
wider than the few crates it pulls in; and a few print `dead_code` and `deprecated` warnings from
`zerocopy` and `base`, which are the cost of compiling one file of a crate on its own. (`mpt`
used to add three of its own against `pool.rs` — `next_owner`, `inner`, `lease`. M8 gave all
three a caller, and they are gone.) What matters is the last line, and `harness.sh`'s own
`N passed, M failed` summary.

### `tests/smoke_media.sh`

```sh
deploy/vpu/tests/smoke_media.sh Ubuntu-resolute
deploy/vpu/tests/smoke_media.sh --mode all Ubuntu-resolute    # or --mode output | --mode none
```

Waits for ssh, then checks the driver is loaded, a `/dev/video*` node exists, dmesg mentions the
driver, and `v4l2-ctl --all` answers on every node. Then it moves real bytes:

* the **capture-only** node — 30 frames to `/tmp/simple.raw`, which must be **exactly 30 ×
  921600** bytes (640×480 RGB3) with **at least two distinct frames** (the device paints a
  changing uniform colour, so 30 identical frames means nothing arrived);
* the **m2m** node — ten frames of 640×480 NV12 random bytes in through `--stream-from`, out
  through `--stream-to`, `--stream-count=10`, and `cmp -n 460800` on the first frame. This is the
  only step that proves bytes crossed the queues rather than that an ioctl returned 0. Ten frames
  in, not one: a shorter file than `--stream-count` makes `v4l2-ctl` ask for a drain and hang,
  which is D5 — `tests/drain.sh` is where that belongs.

**Devices are picked by capability, never by card name** (defect D8). The m2m node —
`V4L2_CAP_VIDEO_M2M_MPLANE` or `V4L2_CAP_VIDEO_M2M` in the `Device Caps` word — is the loopback
device; a node with `V4L2_CAP_VIDEO_CAPTURE`(`_MPLANE`) and no m2m bit is the simple one. The
script prints the word, the card string and its choice for every `/dev/video*`. Until this was
fixed the byte steps matched on the card names `loopback` / `simple_device`, so the standard
launch line (`card=lb0`) skipped both of them and the run still printed `PASS`.

`--mode output|none|all` reloads the guest module first (`modprobe -r virtio-media; modprobe
virtio-media driver_owned_queues=<mode> pool_debug=1`) — that is how the three driver-owned-buffer
policies of design §2.1 get exercised in turn. Without `--mode` the module is left untouched.
Either way the run ends by printing the guest's `virtio-media` dmesg lines, which is where
`pool_debug`'s dbuf alloc/free traces show up. (Reloading a module is fine **in the guest**; the
"never `rmmod`/`insmod`" rule is about the phone.)

A device kind the launch did not create is a skip, not a failure — which of the two exists depends
on how crosvm was launched. Finding **neither** is a failure: that is the state in which the old
script printed `PASS` having streamed nothing. Any real failure makes the script exit non-zero.
Run `guest.sh install-tools` once first: the test needs `v4l2-ctl`.

### `tests/compliance.sh`

```sh
deploy/vpu/tests/compliance.sh Ubuntu-resolute                 # picks the m2m node itself
deploy/vpu/tests/compliance.sh Ubuntu-resolute /dev/video0
```

Runs `v4l2-compliance -d <dev> -s` (the streaming suite, ~40 s) in the guest, installing
`v4l-utils` first if `v4l2-compliance` is missing, and prints the `Total for` line, every failed
subtest and the tool's own exit code. This is the test for **D6**. Baseline on the B2 build
(crosvm `22d14c5`, fork `2ae6bc0`): **59, Succeeded: 48, Failed: 11** — eight of the eleven cascade
from an unimplemented `VIDIOC_PREPARE_BUF`. So a non-zero exit is *expected* until the host fix
lands: read the totals, do not just look at the exit code.

### `tests/drain.sh`

```sh
deploy/vpu/tests/drain.sh Ubuntu-resolute        # DRAIN_TIMEOUT=60 by default
```

The **D5** reproduction, deliberately: one frame of input, `--stream-count=10`, so `v4l2-ctl`
issues `V4L2_DEC_CMD_STOP` and waits for a buffer flagged `V4L2_BUF_FLAG_LAST` that the host
`loopback_device` never sends. `FAIL` with `stream rc=124` means D5 is still there; `PASS` means it
is fixed. Either way the script then runs `v4l2-ctl --info` — the hang must not leave the device
wedged, and a change that does is worse than D5.

### `tests/ext_ctrls_error_idx.c`

Not a script and not run from here: a C client to copy into the guest and compile there.

```sh
deploy/vpu/guest.sh scp Ubuntu-resolute deploy/vpu/tests/ext_ctrls_error_idx.c :/root/
deploy/vpu/guest.sh ssh Ubuntu-resolute \
  'cc -O1 -o /root/eei /root/ext_ctrls_error_idx.c && /root/eei /dev/video0'
```

It issues the seven refused `VIDIOC_G/S/TRY_EXT_CTRLS` of `logs/vpu_wp/B10-acceptance.md` §7 and
prints the `error_idx` each one wrote back. It exists because **`error_idx` cannot be read from
Python at all**: CPython's `fcntl.ioctl` copies its mutable argument back only when the ioctl
returns `>= 0`, so on the failure path — the only path V4L2 ever sets `error_idx` on — a Python
client reads back the value it sent. That, and nothing device-side, was **defect D37**: this
client reads the device's value on **7 of 7** refusals, including the `TRY_EXT_CTRLS` the camera
fails at index 1, where `ctl.py` reads `0` on all seven. `ctl.py` now prints a warning saying so.
Expect `error_idx` = `count` on cases 1, 2, 4, 8, `0` on case 3, `count` on the successful case 6,
and **`1` on case 7**; a `0` from *this* client is a real defect.

The device also logs the size and `error_idx` of every ext-controls error reply — but at
`debug!`, so only if the helper was started at that level: see the trap below.

---

## A typical loop

```sh
cd deploy/vpu && shellcheck -x ./*.sh tests/*.sh && cd -   # before committing anything here
JOBS=8 taskset -c 0-7 ./2_build_crosvm.sh          # never unpinned, never more than 8 jobs
deploy/vpu/vm.sh   stop  Ubuntu-resolute
deploy/vpu/push_crosvm.sh
deploy/vpu/vm_extra.sh takeover Ubuntu-resolute media-host-mb=320,media-guest-mb=192 -- \
  --virtio-media kind=loopback,card=lb0
deploy/vpu/vm.sh   start Ubuntu-resolute
deploy/vpu/vm.sh   argv  Ubuntu-resolute | grep -E 'pre-alloc|media'
deploy/vpu/tests/smoke_media.sh Ubuntu-resolute
```

`takeover` stores exactly what the review's test plan asks for:

```
--pre-alloc <daemon string>,media-host-mb=320,media-guest-mb=192 --virtio-media kind=loopback,card=lb0
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
4. **the APK**, last, with `install_apk.sh` — never a bare `adb install -r` (**D12**). It is what
   makes step 3 unnecessary: with the WP A1 APK installed and the VM's VPU switch on, the daemon
   emits the media keys itself, so `restore` the takeover and put only `--virtio-media` in
   `extra_options`. Note that the daemon restart it performs also drops any `vm_extra.sh` change,
   so re-apply after it, not before.

**`takeover` is bring-up only** — it exists for the window before that APK is installed. It
reaches into the VM's GPU pool sizes to buy one command-line slot, and nothing outside this rig
knows it did.

### The `accepted-*` tags: getting back to a build that was accepted

Nothing here is pushed. Seven repositories carry the VPU work — the meta checkout, `crosvm`,
the `virtio-media` fork, `DroidVM` (the app), `droidvm-guest-additions`, `v4l2r` and
`crosvm-minimal-manifest` — and a build is the seven of them *together*, which is exactly what a
branch name does not record: `wip/vpu` moves, and an acceptance report's "crosvm `114de78`" stops
being findable the moment a later work package rebases nothing and simply commits.

So each accepted build gets one **local, unpushed** tag of the same name on all seven repos:

```
accepted-b11-2026-09-06   crosvm 114de78 · fork b19f620 · v4l2r 7eb3afa · guest-additions 2c7f6ef
                          app b13bb2e · manifest 8143624 · meta 30ef120
```

Those are the heads WP **B11-acceptance** ran on, and the ones every number in that report
belongs to. The convention is `accepted-<wp>-<date>`, one tag per repo, all seven or none —
a partial set is worse than no set, because it reads as if the missing repos did not move.

To put the whole build back in front of you, in a scratch worktree that touches nothing:

```sh
W=/root/gitrs/DroidVM/DroidVM_wip_vpu
T=accepted-b11-2026-09-06
for r in . crosvm crosvm_build/external/virtio-media DroidVM droidvm-guest-additions \
         crosvm-minimal-manifest crosvm_build/external/rust/crates/v4l2r; do
    git -C "$W/$r" rev-parse --short "$T"                 # is the tag there at all?
    git -C "$W/$r" worktree add "/tmp/accepted/$r" "$T"   # a detached checkout, repo untouched
done
```

then build from `/tmp/accepted` the ordinary way (`1_build_crosvm_prepare.sh` and friends), and
`git worktree remove` each one afterwards. Two things this does **not** give you:

* **the binary itself.** The accepted crosvm of B11 — md5 `a289e03fe6e16c6f7a1d8825cc99989a`,
  14 271 944 bytes — exists **only on the phone**; `crosvm_out/` on this box has been overwritten
  since. The tags are the recipe, not the loaf. Take an md5 of `/system/bin/crosvm` on the phone
  before and after anything that could replace it, and compare it against the acceptance report.
* **a guest.** The DKMS deb the guest is running (r21 at B11) is built from the tagged
  guest-additions tree, but the guest itself is state on the phone.

`git tag -l 'accepted-*'` in any of the seven lists what exists. Tags are cheap and local; make
one at the end of an acceptance that passed, and never move one that exists.

### `media-host-mb` is not optional on Gunyah

On a Gunyah host, crosvm refuses to start a VM that has a `--virtio-media` device and no
`--pre-alloc media-host-mb` (`virtio-media on gunyah needs --pre-alloc media-host-mb` in
`vm.sh log`). That holds **whatever the guest driver's `driver_owned_queues` is set to, `all`
included** — a mode in which the guest owns every queue and never maps a single host buffer.
The switch is a guest-side policy the host cannot see or rely on: the device has to be able to
serve a host-owned `MMAP` buffer the moment some program in the guest asks for one, and on Gunyah
the pool is the only place it can put one (the 64-bit MMIO window has room for one 4 GiB
shared-memory BAR and the GPU already has it, design §0.2/§3.3). So always pass
`media-host-mb=320` in, even for an `--mode all` run. `media-guest-mb` is the one that is
genuinely optional: without it the guest driver falls back to `dma_alloc_pages` behind the
restricted-dma-pool. All the media devices of one VM share the one `media_host` pool.

If `start` comes back "went back to stopped", `vm.sh log` has the reason: crosvm rejects an
unknown flag before the guest ever runs, and that lands in the `stdio` history.

### A device helper is called `exe`, so find it by cmdline

`--virtio-media kind=...,uid=N` and `--virtio-snd ...,uid=N` run the device's backend in a child
process. The child execs `/proc/self/exe`, so its `comm` — the only thing toybox `ps` prints in
`NAME` — is **`exe`**, and `ps -A | grep "crosvm device media"` finds nothing. That is not a
missing helper; it is the process name. Two ways to see one:

**In the log, at launch.** `vm.sh log <name>` now has one line per helper, written by the VMM
just after the fork (defect D14, closed):

```
INFO  crosvm::crosvm::sys::linux::device_helpers] launched media helper: pid 766, uid 10367,
      gid 10367, kind loopback, card lb0, pool_gpa 0x1b0000000, pool served by the VMM over
      fd 37, 5 access window(s), log level info
INFO  crosvm::crosvm::sys::linux::device_helpers] launched snd helper: pid 13279, uid 10367,
      gid 10367, backend aaudio, card_index 0, log level info
```

Two fields on that line are worth knowing by name:

* **`pool served by the VMM over fd <N>`** — this helper does not allocate from the
  `media_host` pool at all: since **M8** the VMM holds the VM's one allocator, and the helper
  reserves and releases every buffer offset over the `--pool-fd <N>` tube on that line (the fd
  number is the launch line's identifier for the connection). Every helper still maps the whole
  pool; what D49's aliasing and F12's static slices used to police is now structural — one
  allocator, so two helpers can never be handed the same offset, and the space one device frees
  is space any other can have (a 4K decode can take ~190 MiB while the camera idles, which no
  128 MiB slice allowed). The helper's own half of the pair, once, as it comes up:

  ```
  INFO  ... virtio-media: serving MMAP buffers from the media_host pool (gpa 0x1b0000000,
        256 MiB), allocated by the VMM
  ```

  So `grep -E 'pool served by the VMM|allocated by the VMM|pool exhausted|pool connection' <log>`
  is the whole story: three launch lines, three serving lines, any exhaustion, and every
  connection teardown. **`media_host pool exhausted for "<card>": N bytes requested with M of P
  in use`** is still the loud, attributable `ERROR` (the client gets `ENOMEM` from
  `REQBUFS`/`CREATE_BUFS`), now only when the whole VM's pool is genuinely full — raise
  `media-host-mb` (the app's `VpuConfig`, default 320 since A6) only if the devices' *combined* working
  set really outgrows it. The `<card>` in the pool lines is the string the guest's
  `v4l2-ctl --info` shows (`droidvm decoder`, `camera 0`, ...): the helper introduces itself on
  the tube and the VMM adopts its card for the pool log lines and the `media pool <card>`
  server thread (`ps -T`, or bare `ps -AT` on the phone — never `ps -AT -o comm`, trap 7; comm
  clips at 15 bytes). Two more lines worth greping: every release is followed by
  `pool: "<card>" holds N bytes, pool used M of S` — the accounting, one line **per released
  buffer**, at `debug` since F16 (**D65**; how to switch it on and how to read a run of them is
  "Reading the pool's accounting lines after F16" below) — and a helper that goes away leaves `the pool connection for "<card>" is closed` plus
  `reclaiming N media_host buffers from a device that went away` as the VMM sweeps its lease
  back into the pool.
* **`log level <filter>`** — the filter the child was exec'd with, which is now the VMM's own
  (`crosvm --log-level debug run ...` → `log level debug`). Before **D57** the helper was exec'd
  with no `--log-level` at all and crosvm's syslog reads no environment variable, so every helper
  ran pinned at `info` and every `debug!` in a device backend was dead weight — which is exactly
  how the D37 investigation lost its device-side instrument. `log level info (default)` on this
  line means nothing forwarded a filter and the old behaviour applies. What puts a filter on the
  VMM in the first place is `vm.sh log-level <name> debug` (**D60**): before that verb existed,
  D57's forwarding was correct and unusable, and this line read `log level info` on every build.

**On the phone, by cmdline.** `/proc/<pid>/cmdline` is NUL-separated, so `device media` is only
there once the NULs are spaces:

```sh
adb -s "$PHONE" shell su -c \
  'for p in /proc/[0-9]*; do c=$(tr "\0" " " < $p/cmdline 2>/dev/null);
   case "$c" in *"device media"*|*"device snd"*) echo "$p: $c";; esac; done'
```

which prints what `logs/vpu_wp/B4-acceptance.md` §5.1 quotes — the argv including the whole
`--config-json`, so the kind, the `pool_gpa` and every access window are visible:

```
/proc/766: /proc/self/exe device media --fd 36 --config-json {"kind":"loopback",...} --pool-fd 37
```

`grep Uid: /proc/<pid>/status` then shows the uid it dropped to, and `Groups:` must be empty for
a media helper (`logs/vpu_wp/M3.md` §2.1). A helper's pid is also labelled in the VMM, so if one
dies the log says `child media helper (pid N) exited: ...` or `child snd helper (pid N) ...`
rather than reporting an anonymous child.

### `Connection reset by peer` from the media frontend means: read the helper's stderr

A VM that fails to start with

```
failed to set up the vhost-user frontend for media: ... Connection reset by peer
```

is a media helper that refused its own parameters and exited before it answered the vhost-user
handshake — `kind=camera` with a `camera_id=` the app's uid cannot see, a uid that can see no
camera at all, or a phone with no camera NDK. **The reason is on the helper's stderr, which is
the VM log** (`vm.sh log <name>`): the helper inherits the VMM's, so its own message — e.g.
`camera "1" is not one this uid can see (it lists [0])` — is a few lines above the frontend's.
The VMM now appends what it can to its own error, from `waitpid` at that moment:

```
the media helper (pid 766) exited with status 1 before the handshake -- read its stderr (the VM log)
the media helper (pid 766) did not answer the vhost-user handshake within 30 s
```

The second one is a helper that is alive but has not spoken for 30 s — a wedged `cameraserver`
is the case it was written for; look for `camera enumeration did not answer within 15 s` from the
helper itself just above it.

---

## Per-ship checklist: the four things every acceptance drops

Not traps — coverage. Each of these was in an earlier acceptance suite, each was dropped from a
later one **without a note**, and `logs/vpu_wp/critic5.md` §2.1/§3b caught all three after the
fact. They are cheap; what makes them expensive is finding out two rounds later that nobody ran
them. Run them, or say in the report which one you skipped and why.

1. **GStreamer, on whatever the current build is.** B12 accepted M8 — the change that moved every
   `media_host` buffer's allocation into the VMM — with **zero** gst runs; every gst number in the
   project (DRC 20/20, three bit-exact decoders, the encode) is pre-M8 evidence from B11. ffmpeg is
   not a substitute: it and gst ask for buffers in different shapes, and gst is the client the
   design names as the decoder's acceptance client (design §7.2).

   ```sh
   # in the guest, per B9 §2 / B11 §5.1
   gst-launch-1.0 filesrc location=1080p.mp4 ! qtdemux ! h264parse ! v4l2h264dec \
     ! videoconvert ! video/x-raw,format=NV12 ! filesink location=gst.raw
   md5sum gst.raw            # against the software decode of the same file
   ```

2. **The 3840x1644 band detector, on the current allocator.** This is the instrument that found
   **D49** (cross-helper pool aliasing) — the exact bug M8 is the structural fix for — and it has
   **still never been run against M8**: B13, B14, B15 and B15-soak all went by without it, so this
   is now the oldest un-run item on the list. A structural fix with no run of the detector that found the bug is a
   claim, not a measurement. The recipe and the flagging script are in
   `logs/vpu_wp/B10-acceptance.md` §4 / `F12-encoder.md` §4: camera at **3840x1644** into
   `v4l2h264enc`, then flag frames whose row-mean profile carries the band (B10: 0 of 141 after the
   slice carve; the number to reproduce on M8 is the same 0).

3. **A soak.** **Done once, by B15-soak** (`logs/vpu_wp/B15-soak.md` §1–§2): 120 iterations over
   60 minutes, 0 failures, VMM RSS +267 kB/min on a 5.2 GB RSS, `pool used` peak identical in all
   thirteen 5-minute windows, 0 helper exits, plus 30/30 stop/start cycles with `served` back to 0
   after every stop. That is the shape to repeat, not a box that stays ticked: run it again on any
   build that changes the pool, a backend or the helper lifecycle. Before that round, nothing in
   this project had ever run longer than **60 s** (B12's two REQBUFS storms);
   the longest *session* was an hour of many short runs. D46's UAF, D51's rate limiter, D65's log
   ring, a slow pool leak and every thermal effect are things only a soak finds. The cheapest useful
   one is an hour: a decode loop plus a camera capture loop in the guest, with the VM log snapshotted
   every ten minutes and `pool used` read at the end (it must be **0**), plus `hp.sh expect on` and a
   guest `dmesg` splat count before and after.

4. **The D81 loop: 20 fresh-encode → decode pairs.** B15-soak's decode of a *just-encoded* clip
   came up short in **14 of 120** iterations with `rc 0` and nothing on the device side (**D81**),
   while the same saved clip decoded twelve times in a row is exact. It only reproduces when the
   decode follows a fresh encode on the same helper set, so it is invisible to every bar that
   decodes a fixture. Twenty pairs, and compare each decode against the clip's own `ffprobe`
   count — not against a constant:

   ```sh
   # in the guest, per B15-soak §5.3; 20 pairs
   for i in $(seq 1 20); do
     ffmpeg -y -f v4l2 -i /dev/video0 -t 3 -c:v h264_v4l2m2m -b:v 4M clip.mp4 2>/dev/null
     n_enc=$(ffprobe -v0 -select_streams v -count_frames -show_entries stream=nb_read_frames \
                     -of csv=p=0 clip.mp4)
     ffmpeg -y -c:v h264_v4l2m2m -i clip.mp4 -fps_mode passthrough -f rawvideo out.nv12 2>/dev/null
     n_dec=$(( $(stat -c%s out.nv12) / (1280*720*3/2) ))
     echo "$i enc=$n_enc dec=$n_dec $([ "$n_enc" = "$n_dec" ] && echo ok || echo SHORT)"
   done
   ```

   **20/20 is the bar.** `-num_capture_buffers 24` does not help and is not the fix (0/5 for D64).

Two more that were carried in every critique as a phone-owner decision rather than a script are
now both **done, by B15-soak §3.1/§3.8**: a **second camera row** (two helpers, two pool threads,
`/dev/video0` + `/dev/video1`, 41 472 000 B from each, both fields of view looked at, and no extra
reserve) and a **cross-package camera contender** (there is no consent screen any more — the OEM
app evicts the VM, the guest gets `ENODEV`, `v4l2-ctl` exits 0 and a capture after the contender
closes works with no VM restart; `plans/VPU_DESIGN.md` §7.1).

**And a limitation to state, not a box to tick: concurrent, coupled decode + encode on one helper
(D64).** A 1080p decode running alongside a 1080p encode on the same helper is not bit-exact (B17:
0/6; 4K+1080p 0/3; 1080p+720p 0/3), and removing the old F19 back-pressure (F20) did not change
that — the loss stays **mixed** (aligned head-GOP loss in some runs, decoded-but-wrong pixels in
others), and the only thing F20 moved is the encoder half of the matrix, now solid 300. Sequential
use is clean (decode fully, then encode, or the reverse), GStreamer is clean both ways (DRC 20/20,
encode 300/300), and a single-session hardware decode is bit-exact and fast again (~0.71–0.95 s,
past B15). So when a bar runs a decode and an encode at once and the pixels do not match, that is
the documented limitation, not a regression — `plans/VPU_DESIGN.md` §7.4 D64 and
`logs/vpu_wp/B17-acceptance.md` §6.

### Next rig WP: three things this round worked around by hand

None of these is implemented — B16's acceptance was running live on the phone while this was
written, and the scripts it drives are not safe to change mid-run. Each is a workaround that
worked, written down so the next rig WP can make it a script's job.

1. **The config guard belongs in `vm.sh start`.** `scratch-B15s/cycles.sh` asserts the stored
   config before every start and re-applies a dump when it has reverted (**D79**, trap 14). It
   fired 0 times in 30 measured cycles and would have caught the one that cost B15-soak three of
   them. `vm.sh start` is where it belongs: read the config it is about to start, refuse (or say
   so loudly) when `vpu_enabled` is false on a VM that had it.
2. **`wait-ssh` should try the DHCPv4 address.** The EUI-64 address is dead for ~5 minutes after
   a stop/start (**D80**, trap 15) and `wait-ssh`'s 240 s budget is shorter than that, so it
   reports a guest that never came up. A third path through `GUEST_SSH_VIA=proxy` on the DHCPv4
   address answered in 14–22 s in all 30 cycles; failing that, the failure message should at
   least name DAD as a possibility.
3. **`7_build_apk.sh` needed `ANDROID_HOME` and said so a minute late.** B16-build lost ~1 minute
   of prebuilt packing before the preflight failed (`logs/vpu_wp/B16-build.md`, issue 1). The
   script now exports a default; if the SDK ever lives somewhere else, that line is where to look.

### Reading the pool's accounting lines after F16

`pool: "<card>" holds N bytes, pool used M of S` is emitted **once per `Release`**, so a REQBUFS
that frees 21 buffers writes 21 lines and a client that cycles REQBUFS writes thousands
(measured: ~9 400 releases/s, which overwrites the 1 MiB `vm.sh log` ring in under a second —
**D65**, and it cost B12 two measurements). Since **F16** that line is `debug!`, not `info!`, which
changes how you read it:

* by default it is **not in the log at all**. To get it back: `deploy/vpu/vm.sh log-level <name> debug`,
  then start the VM (**D60**; and check `vm.sh argv` shows `--log-level` *before* `run`).
* the lines are **steps, not a state**. Reading one tells you nothing; read the **last** one in a
  window for "where the pool ended up" (it must be `pool used 0 of S` once every stream is closed),
  and the **maximum** across the window for "how much this workload actually needed". The 20-line
  walk from `holds 236429312` down to `holds 0` is one device closing one 4K decode, not 20 events.
* what stays at `info!` and is what you normally grep is the rest of the set: the launch line's
  `pool served by the VMM over fd N`, the helper's `allocated by the VMM`,
  `media_host pool exhausted for "<card>": …` (the loud, attributed refusal), and the pair
  `the pool connection for "<card>" is closed` + `reclaiming N media_host buffers from a device
  that went away`.

`logs/vpu_wp/scratch-B12acc/poolacct.py` is the parser that turns a window into per-card maxima and
a final value; `newlines.py` beside it cuts the window out of a `vm.sh log` dump and says on stderr
when the ring wrapped under it.

---

## Measurement traps

Sixteen ways a run has silently lied to a work package. Each one cost a session; none of them
announces itself. In short, as a checklist:

> `timeout` needs `-k` for a stalled ffmpeg; `-stream_loop` does nothing on a raw elementary
> stream; ffmpeg's frame count lies both ways — `-fps_mode passthrough` on **both** sides of every
> md5 comparison, and **never measure this decoder with a raw elementary stream through ffmpeg at
> all** (default vsync writes 3 frames of 300 while the device decodes all 300);
> `v4l2-ctl --wait-for-event=ctrl=` wants the control **NAME**; `vm.sh log` is a 1 MiB ring —
> snapshot it between steps; `install_apk.sh`'s daemon restart resets the VM config (re-apply, and
> diff against a known-good dump); toybox `ps -AT -o ...` drops the thread `comm`, so a
> `media pool` thread counter reads 0 on a VM that has three; **`--log-level debug` slows the VMM
> enough to change a frame count — measure frame-exactness at the default level**; and **the `seek`
> the device logs at ffmpeg's EOF is ffmpeg's own close path, not a driver mistranslation**;
> **the camera needs the phone's screen awake**, because a sleeping one revokes access
> mid-capture and reads exactly like a device fault; an **overlay-only crosvm change leaves
> Gradle's `regenPrebuilts` UP-TO-DATE**, so the APK ships the previous payload unless the
> manifest sha256 is checked; and the probes are **copied, not stripped** — soong already emitted
> the stripped binary; a gst PSNR pipeline reads **24 dB of loss that is not there** unless
> `colorimetry=` is pinned on **both** sides; **assert the VPU config before every start**,
> because a daemon restart reverts it and `vm.sh start` then prints nothing at all; after a
> stop/start the guest's **IPv6 address is dead for ~5 minutes** (DAD), so reach it over DHCPv4;
> and the **first encode of a resolution after a helper starts is unfloored** — warm one up and
> discard it before measuring, sessions 2+ are 300/300 at the ffmpeg default.

And at length:

**1. `timeout` needs `-k`.** A stalled `ffmpeg` does not die of the `SIGTERM` `timeout` sends —
its threads are already deadlocked in `futex_do_wait` — and the harness waits behind it for ever,
so the budget you set is not the budget you get. Always `timeout -k 10 <budget> ffmpeg ...`: `-k`
promotes it to `SIGKILL` ten seconds later, and `rc=124` then means what you meant by it.

**2. `-stream_loop` does nothing on a raw elementary stream.** It seeks the input, and a raw
`.h264`/`.h265`/`.ivf` gives it nothing to seek by; you get one pass — `-stream_loop 2` on a
300-frame raw file returns 300, not 900 — **and the software decoder returns the same 300**, so a
hardware-vs-software comparison looks clean while measuring nothing. F10 §4's D27b recipe was
written this way and measured nothing as written; B8 §3.2 caught it. Loop an `.mp4` (or
concatenate the file first) when the point is to run the codec N times.

**3. ffmpeg's frame count lies in two directions, and `-fps_mode` only fixes one of them**
(**D32**, **D27**/**D41**). Two traps that used to be listed apart; they are the same measurement
going wrong from both ends, and the rule at the bottom is one rule.

*Too few frames.* A raw elementary `.h264` carries no container timestamps, so every frame ffmpeg
decodes arrives with the same one, and its default CFR output keeps the first and drops the rest:

```
ffmpeg -c:v h264_v4l2m2m -i 720p.h264 -f rawvideo -pix_fmt nv12 out.raw
frame=    3 fps=0.0 ... dup=0 drop=298
```

Three frames of 300, and **the software decoder writes 300**, so the two do not even have the same
length to compare. The device is innocent and says so in the VM log —
`300 bitstream buffers in, 300 frames out, 1 format change(s)`, five sessions in a row — and this
predates every 2026-09 decoder fix: B9's own artefact `ff_hw.raw` is 4 147 200 bytes, which is
those same 3 frames (`logs/vpu_wp/B11-acceptance.md` §4.3).

*Different frames.* A camera capture is VFR. Without `-fps_mode passthrough` ffmpeg pads the output
up to CFR, **and the two decoders duplicate different frames**, so a hardware and a software decode
of the same file come out the same length with different md5s — which reads exactly like a decoder
bug and is not one. B10 lost a first comparison to this: 9 "differing" frames that were duplication,
and 0 once **both** sides passed through (`logs/vpu_wp/B10-acceptance.md` §1.2).

So: `-fps_mode passthrough` (`-vsync 0` on older ffmpeg) **on both sides of any md5 comparison**,
always. And then meet the half it does not fix: on that same raw file passthrough writes **159**
frames, because ffmpeg's `v4l2m2m` decoder has no `.flush` callback and stops feeding after its
first EOF (`178 bitstream buffers in, 167 frames out`; **D27**/**D41**,
`logs/vpu_wp/F11-decoder.md`) — honest, but still not 300.

The rule is therefore not a flag but a choice of client: **measure this decoder with GStreamer**
(`v4l2h264dec` on the same file decodes 300/300, bit-exact against software), or with ffmpeg on a
**container**. Reach for a raw elementary stream only when the raw stream is the subject — a short
truncated one for `pollrace.py`, say — and never for a frame count.

**4. `v4l2-ctl --wait-for-event=ctrl=` wants the control NAME, not its id.** `ctrl=0x009a091e`
answers `unknown control` from `v4l2-ctl` itself, before any ioctl reaches the device;
`ctrl=auto_focus_status` — or `ctrl=min_number_of_capture_buffers` on the decoder — is the same
subscription and works. Take the name from `--list-ctrls` on the node. A refusal from the tool is
not a refusal from the device: check which before filing one as a defect (B8 §1's note; F10 §2's
recipe quotes both the wrong form and the wrong CID).

**5. `vm.sh log` is a 1 MiB ring.** A long acceptance session wraps it, and the evidence for step
3 is gone by the time step 9 finishes. Snapshot between steps and keep the pieces:

```sh
deploy/vpu/vm.sh log Ubuntu-resolute > scratch-<wp>/NN_vmlog_<step>.txt
wc -c scratch-<wp>/NN_vmlog_<step>.txt     # near 1 MiB means it already wrapped
```

B10 kept seven snapshots for one session; that is the right order of magnitude.

**6. `install_apk.sh` restarts the daemon, and the restart resets the VM's config.** Anything a
`vm_extra.sh takeover` or a VPU-switch edit put there is gone afterwards, so re-apply **after**
the install, never before — and diff the result against a known-good dump before trusting the run
that follows. The A5 helper is the one to reuse: `VM=<name> logs/vpu_wp/scratch-A5/cfg.sh vpuon`
to re-apply the acceptance config, `cfg.sh show` to read the keys back, against
`scratch-A5/04_cfg_vpuon.txt` as the reference for a VPU-on VM — with one correction to that
dump: **`vpuon` deletes `vpu_host_pool_mb` / `vpu_guest_pool_mb` rather than storing them**, so
the pools come from the app's defaults (320 MiB host / 192 MiB guest since A6) and a run
measures what a user's fresh VM gets. The dump's `256` / `128` are the pre-A6 values a stored key
would pin; `cfg.sh set '{"vpu_host_pool_mb":320,"vpu_guest_pool_mb":192}'` is the one line that
pins them again if a run needs a size nobody defaults to. A silent config reset reads exactly like a regression in whatever you
changed, which is what makes it expensive. And an `install_apk.sh` run is not the only way it
happens: a daemon restart nobody asked for does exactly the same thing on an idle rig, with no
error line anywhere — **trap 14**, and assert the config before every start, not just after an
install.

**7. `ps -AT -o ...` on the phone silently drops the thread name.** toybox's `ps` answers
`-AT` with `-o pid,tid,comm` **without** the thread `comm` — no error, no warning, just a column
that is the process name (or empty) — so a counter like
`ps -AT -o comm | grep -c 'media pool'` reads **0** on a VM that has three `media pool <card>`
threads running. B12 discarded two whole 20-cycle runs to this before noticing (its
`83a_l_cycles_aborted.txt` keeps them). Use bare `ps -AT` and match on the line:

```sh
adb -s "$PHONE" shell su -c 'ps -AT' | grep -c 'media pool'
```

and **validate the counter before you trust a zero**: run it once against a VM that is up (expect
3, one per media helper) and once against a stopped VM (expect 0). A counter that cannot tell
those two apart is measuring nothing, and "no stray threads after the stop" is exactly the kind of
claim it would answer wrongly in the direction you were hoping for.

**8. `--log-level debug` changes codec results — measure frame-exactness at the default level.**
The `debug!` traffic the VMM emits at `debug` is not free: B14 saw the same ten warm decodes come
out **7/10** bit-exact at `debug` and **30/30** at `info`, with the same binary, file and client
(`logs/vpu_wp/B14-accept-A.md` §1). The extra log path slows the VMM enough to shift ffmpeg's drain
timing, and a few sessions tear down early (no `drain: EOS queued` line). So raise the level only
when you need a `debug!` line (trap-9 note below), and **run every frame-exactness bar at the
default level** — `vm.sh log-level <name> -` and restart before the run, or the number you measure
is the log path's, not the codec's.

**9. The `seek` the device logs at ffmpeg's EOF is ffmpeg's own close path, not a driver bug.**
When ffmpeg finishes it calls `ff_v4l2_m2m_codec_end`, which issues one `STREAMOFF(OUTPUT)` after
EOS (B14 strace, §2): the device logs a `seek` (or, before D71's fix, a `reinit`) for it, and the
driver's `virtio_media_streamoff` forwards the client's `enum v4l2_buf_type` verbatim — there is no
mistranslation and no mid-stream `STREAMOFF(OUTPUT)`. Reading that end-of-stream `seek`/`reinit`
line as a driver or device fault sent an earlier dig down a blind alley; it is the expected shape of
ffmpeg closing the queue. (With F17's D71 fix that line reads `seek`, not `reinit`, because the
initial announce no longer leaves `format_change_pending` set for the life of the session.)

**10. The camera needs the phone's screen awake, and the failure reads as a device fault.** The
app's `CAMERA` appop on 5566 is `foreground` (`cmd appops get cn.classfun.droidvm CAMERA` →
`Uid mode: CAMERA: foreground`), so cameraserver allows a *streaming* op only while that uid is in
a foreground procstate. The lab phone's screen sleeps on its own, and with it off the app is
`TOP_SLEEPING` (`dumpsys activity oom` → `T/A/TPSL`) — still the resumed activity, and enumeration
still answers, which is why `camera_probe` happily lists all 41 YUV sizes — but the stream is
refused, or revoked **mid-operation** if it had already started. Three signatures, one event:

```
logcat     E Camera3-Device: Camera 0: notifyStatus: Camera access permission lost mid-operation:
                             Permission denied (-13)
vm.sh log  ERROR android_camera] android_camera: camera device error 4
           ERROR virtio_media::devices::camera] camera 0: session 6 ends: camera device error 4
guest      VIDIOC_DQBUF: failed: No such device        (ENODEV, and a 0-byte capture file)
```

**Only the logcat line tells this apart from D76** — at the device layer and in the guest the two
are identical, which is what makes it expensive: B15-build §5.2 lost five capture runs over four
minutes to it, and B14-accept-B's D76 diagnosis should be re-read on that basis (some of its
`camera device error 4` episodes may have been this and not a wedged HAL). So when a camera bar
fails this way, read `logcat -d | grep -iE 'Camera(2ClientBase|3-Device)'` **before** filing
anything.

The precondition is one verb, and it changes nothing that outlives the session:

```sh
deploy/vpu/vm.sh wake      # KEYCODE_WAKEUP + wm dismiss-keyguard + 1 s, then the state line
```

`vm.sh start` runs it for a VM whose config has a `virtio_camera` row, and after it the process
reads `T/A/TOP LCMNFUAT` — note the `C`, the camera capability — and the capture works first
time. Do **not** reach for the appop instead: `cmd appops set` from an adb shell is refused
(`SecurityException: uid 2000 does not have android.permission.MANAGE_APP_OPS_MODES`), and the
mode is the phone owner's decision, not a rig setting.

And the half `wake` cannot fix: the screen sleeps again after `screen_off_timeout` (**300 000 ms**
on 5566), so a long capture, or a gap between the wake and the run, walks back into it. **That is
the product-level D76** — a user's camera VM dying because the phone dimmed.

**Since WP A7 (app `843d8d9`) D76 is a per-VM switch, `camera_keep_screen_on`, default `true`.**
While any non-STOPPED VM that really attaches a camera has the switch on, the app holds a
`SCREEN_DIM_WAKE_LOCK` tagged `droidvm:camera` from `PeripheralForegroundService`, released when
the last such VM stops. So on a default VM the screen does not dim underneath a capture, and
the limitation above was expected to apply only when the switch is off — a choice, not a
regression, trading "the screen stays lit for hours" for "the screen sleeps and a capture can
die" — **but on this build B16 could not make the switch-off case fail at all** (see below). Two
things the switch does *not* buy:

* **It cannot wake a screen that is already dark.** `ACQUIRE_CAUSES_WAKEUP` needs
  `android.permission.TURN_SCREEN_ON` (`signature|privileged|appop`), which this app does not
  have; the platform prints `Not allowing device wake-up for …`, drops the flag, and grants the
  lock anyway. **`vm.sh wake` therefore stays the precondition** for every camera bar, exactly as
  below.
* **It does not touch the appop.** That is still the phone owner's setting.

**On this platform build, B16 could not reproduce the switch-off failure at all**
(`logs/vpu_wp/A7.md`, `logs/vpu_wp/B16-acceptance.md` §6 bar 3). With `camera_keep_screen_on` off
and the screen genuinely asleep (`mWakefulness=Asleep`, `mState=OFF`), a 60 s capture still
completed in full — 1500/1500, 2 073 600 000 B, `-13` count 0. The reason is in the oom line: the
app sits at `F/A/FGS -C-NFUAT` — a foreground service carrying the camera capability — **not**
`TOP_SLEEPING`/`T/A/TPSL`. `PeripheralForegroundService` runs with `FOREGROUND_SERVICE_TYPE_CAMERA`,
and that procstate alone is enough for AppOps to resolve the `foreground` CAMERA op with the
display off. So the everyday D76 outcome above — "the screen sleeps and the capture dies
mid-operation" — **is contradicted on this platform build**: the camera foreground service by
itself keeps a screen-off capture alive, which makes `camera_keep_screen_on` **belt-and-suspenders**
(the FGS carries the procstate; the switch, default on, only *also* holds the screen lit). State
this only as **B16-measured on this platform build** — whether D76's window is still reachable in
some other procstate (the app not resumed, a longer capture) B16 did not determine (B16 §6
issue 3). `vm.sh wake` still stays the precondition only for waking a screen that is already dark
(`ACQUIRE_CAUSES_WAKEUP` is refused, as above).

Check it on the phone with `dumpsys power | grep droidvm:camera`; if the lock is not held while a
camera VM runs, read the switch (`cfg.sh show`) before blaming the platform
(`plans/VPU_DESIGN.md` §7.1 and §8, the D76 row in §7.4, and `logs/vpu_wp/A7.md`).

Either way the D76 signature is still a different claim from "the HAL wedged", so a report has to
say which. Wake immediately before each camera bar and record the timeout in the report:

```sh
adb -s "$PHONE" shell settings get system screen_off_timeout    # vm.sh wake prints it too
```

It is not recoverable afterwards, and without it "the capture ran for 3 s" and "the capture ran
for 6 minutes" carry completely different weight.

**11. An overlay-only crosvm change cannot invalidate Gradle's `regenPrebuilts`, so the APK ships
the PREVIOUS payload.** `app/build.gradle.kts`'s `RegenPrebuiltsTask` declares only
`DroidVM-Prebuilt-Root/auto-build/` and `auto-build.py` as inputs, and marks `prebuiltRoot`
`@Internal` on purpose (*"hashing the whole root would drag in manual-build/, which carries
hundreds of megabytes of binaries the script never reads"*). `6_build_apk_prepare.sh`'s overlay
writes **only** into `manual-build/arm64-v8a/`, so Gradle sees nothing change. What it looks like
(B15-build §3.2):

```
> Task :app:regenPrebuilts UP-TO-DATE
> Task :app:mergeDebugAssets UP-TO-DATE          48 tasks, 6 executed -- a real repack is ~26
136531586 app-debug.apk                          byte-for-byte the size of the previous build
usr/bin/crosvm  apk=d6f53ae80715ff31b9ab237c  host=10530b8446269333e76152f8  MISMATCH
```

`7_build_apk.sh` now closes it from the rig side: it runs the task's own action itself
(`python3 auto-build.py --out DroidVM/app/src/main/assets/prebuilts`) before `./build.sh`, which
both fixes the assets and — by rewriting the task's `@OutputDirectory` — puts `regenPrebuilts`
out of date so `mergeAssets` runs; and it ends by comparing the APK's own
`assets/prebuilts/prebuilt-arm64-v8a.json` entry for `usr/bin/crosvm` against
`sha256sum crosvm_out/crosvm`, failing loudly on a mismatch. Touching the inputs is not an
alternative: Gradle hashes contents, not mtimes.

**Keep checking anyway**, and keep checking the *manifest*: `install_apk.sh` verifies the phone
against **the APK's own manifest**, so a stale APK installs, extracts and verifies clean end to
end — every check passes and the phone runs last week's crosvm. "The install passed" is not
evidence; `usr/bin/crosvm: MATCH` from `7_build_apk.sh`, or the phone's `md5sum` against
`crosvm_out/crosvm`, is.

**12. The probes are COPIED, not stripped — a second `llvm-strip` breaks comparability.** The
recipe's wording "collected stripped" describes what soong already did:

```
crosvm_build/out/soong/.intermediates/external/crosvm/android_camera/camera_probe_bin/android_arm64_armv8-a/camera_probe
crosvm_build/out/soong/.intermediates/external/crosvm/android_codec/codec_probe_bin/android_arm64_armv8-a/codec_probe
```

**are** the stripped binaries (the unstripped ones sit in `unstripped/` beside them), and every
md5 this project has ever published — `camera_probe ab23e9c2072301a330a0f587d8d0142f`,
`codec_probe 6318225f9591ae27597fbee92c959a8d`, unchanged since F11-misc and B7 — is those files'
own. Running `llvm-strip` over them again writes *different* files (313 480 / 428 144 B,
`fc52b166…` / `d05d431f…`) that match nothing anyone shipped, so the one thing the md5s are for
— "is the probe on the phone the probe in the report" — stops working (B15-build §3.1). Collect
with `cp`, then regenerate `md5sums.txt` beside them, and expect the md5s to be **unchanged**
whenever the probe sources did not move.

**13. A gst PSNR round trip reads ~24 dB of codec loss that does not exist, unless
`colorimetry=` is pinned on both sides** (**D82**). `videotestsrc` renders its pattern using the
colorimetry that was **negotiated**, and `v4l2h264enc` negotiates `bt601` where a bare `filesink`
gets the 720p default `bt709` — so these two pipelines do not draw the same source frames:

```sh
gst-launch-1.0 videotestsrc num-buffers=N ! video/x-raw,format=NV12,… ! filesink location=src.nv12
gst-launch-1.0 videotestsrc num-buffers=N ! video/x-raw,format=NV12,… ! v4l2h264enc ! … ! filesink
```

The colour-bar luma comes out as the BT.601 set (235, 210, 170, 145, 106, 81, 41) in one and the
BT.709 set (235, 219, 188, 173, 78, 63, 32) in the other. **The tell is that the "loss" is
constant on every frame**, including on a static pattern (`smpte100`, one distinct frame in 150,
22.8 dB). Put `colorimetry=` in the caps filter of **every** pipeline in the comparison, or
generate the source once and feed the same bytes to both: with `colorimetry=bt709` pinned, the
same round trip measures **35.96 dB** (and 77.58 dB on `pattern=ball`), which clears the 35 dB
bar (B15-soak §3.7/§5.4). Two smaller facts from the same dig: `v4l2h264enc` **refuses**
`colorimetry=bt601` caps outright (negotiation fails, rc 1), and
`ffmpeg -f lavfi -i testsrc2 … -c:v h264_v4l2m2m` needs an explicit `-pix_fmt nv12` or it dies
with `Could not open encoder before EOF` / `-22` — the device is not involved in either.

**14. Assert the VPU config before EVERY start — a daemon restart reverts it, and `vm.sh start`
says nothing** (**D79**). This is trap 6's mechanism (`vm_modify` writes the daemon's in-memory
store; `files/vms.json` is the app editor's) reached **without an APK install**: B15-soak had the
daemon process replaced mid-session on an idle rig, the new one reloaded `files/vms.json`, and
the next start produced a VM with `vpu_enabled false`, no camera row, pools back at 256/128 and
**zero** `media pool` threads. It started perfectly happily — `state: running`, guest ssh in 21 s,
a full boot to a login prompt — and there is **not one error line** anywhere: not in `daemon.log`,
not in the VM log, not from `vm.sh start`, not from `hp.sh`. `served` drops 2656 → 2560, which is
the only number that gives it away. A suite that does not check will measure a VM with no VPU in
it and call the result a pass, or a regression in whatever it was testing. Dump the config once at
the start of a run, and assert it before every `vm.sh start`
(`logs/vpu_wp/scratch-B15s/cycles.sh`, the guard predicate verbatim):

```sh
cfgok=$(dvm get "$VM" | python3 -c '
import json,sys
d=json.load(sys.stdin).get("data") or {}
cam=[p for p in d.get("peripherals",[]) if p.get("type")=="virtio_camera"]
print("ok" if (d.get("vpu_enabled") and d.get("vpu_codec_enabled") and len(cam)==1
      and d.get("vpu_host_pool_mb") is None and d.get("extra_options")==[]) else "REVERTED")')
[ "$cfgok" = ok ] || dvm modify <your baseline dump>.json
```

It fired 0 times in B15-soak's 30 measured cycles and would have caught the one that cost that WP
three of them. Why the daemon went away was **not** established (the rig did not restart it —
`lib.sh daemon_start` always logs `daemon: starting`, and no such line exists) [unverified].

**15. After a stop/start the guest's IPv6 address is dead for ~5 minutes, so use DHCPv4**
(**D80**). `vm.sh wait-ssh` polls the EUI-64 address the rig computes from the MAC, and after a
restart the guest's own DAD finds that address defended and drops it:

```
enp0s7: Address 2a0e:…:fefd:4d67 with tentative flag is removed,
        maybe a duplicated address is assigned on another node or link?
```

(the phone's neighbour table shows the global address `FAILED` on `wlan0` while the guest's
link-local is `STALE` on `br-wifi`). It comes back on its own about five minutes after boot, which
is longer than `wait-ssh`'s 240 s default **and** longer than its documented 300 s ceiling — so
the first two cycles of B15-soak §2 recorded a guest that never came up while its serial console
was sitting at a login prompt. The guest's DHCPv4 address answers in ~20 s throughout. Reach it
through the phone (the exact route the soak used in all 30 cycles, 14–22 s every time):

```sh
GUEST6=192.168.66.132 GUEST_SSH_VIA=proxy deploy/vpu/guest.sh ssh Ubuntu-resolute 'true'
```

Take the address from the guest's own `ip -4 addr` (or the phone's DHCP lease) once, at the start
of the run; it survives the restarts. This is the lab network, not the VM.

**16. The first encode of a resolution after a helper starts is unfloored — warm one up before
measuring frame counts** (**D78** residual, since **F20**). ffmpeg's `h264_v4l2m2m` encoder
initialises only **4** CAPTURE (bitstream) buffers by default, too few to survive its own EOF
drain, so at the default every `testsrc2` encode used to write **246–260 of 300** (B16 §5). Since
WP F20 the device floors the encoder's `REQBUFS(CAPTURE, n)` to a value it **learns from the
codec's `num-output-slots`** — `c2.qti.avc.encoder` reports 8 at 720p, floored to 16 — so at the
ffmpeg **default** the three `testsrc2` encodes and the camera-fed encode are **300/300** and
**133/133** (B17 §4). This supersedes the old "pass `-num_capture_buffers 16`" workaround: sessions
2+ need nothing. But the floor is learned from a **running** codec, so the **first** encode session
of a given fourcc per helper lifetime runs **unfloored** and can drop a couple of coded frames —
B17's session 7 dropped 2. So run one warm-up encode of each resolution after the VM starts and
discard it, or expect the first sample to come up a frame or two short. The tell is
`REQBUFS(CAPTURE, 4)` with no `=> 16` in that session's strace, and the one-per-boot device line
`encoder session N: codec fills 8 output slots; CAPTURE floor 16 for later sessions of H264`. gst
over-provisions and never sees this (`plans/VPU_DESIGN.md` §7.3, the D78 row in §7.4).

**And one that is not a measurement trap but reads like one:** a `debug!` from a device backend
will not appear in the log unless the helper was started at that level — see `log level` on the
launch line above (**D57**). `crosvm --log-level debug run ...` is what forwards it to every
helper; before that fix no helper `debug!` ever reached a phone log at all, and for two rounds
after it nothing on the phone could set the level either (**D60**). Both ends exist now:
`deploy/vpu/vm.sh log-level <name> debug`, then start the VM. If a `debug!` you are sure about
still does not appear, check `vm.sh argv` for a `--log-level` **before** `run` — that, and not
the backend, is where this usually goes wrong.
