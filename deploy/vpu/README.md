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
| `vm.sh` | `start\|stop\|status\|argv\|log\|wait-ssh <name>`, plus `stop-all\|daemon-check\|daemon-restart` |
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
```

`argv` is the ground truth for what the daemon actually emitted; `log` is the same argv as the
daemon logged it (`CrosvmBackendInstance.java:183`) plus the boot output, which is where a
rejected flag shows up. If the daemon is not running, any verb starts it first, exactly the way
the UI does (`DaemonHelper.java:138-151`) with the stdio redirection an `adb shell` needs.

Budget **90–120 s** from `vm_start` to ssh answering.

Three verbs take no VM name:

```sh
deploy/vpu/vm.sh stop-all          # vm_stop_all, then wait until vm_list shows none running
deploy/vpu/vm.sh daemon-check      # is the running daemon the installed APK's code?  (defect D12)
deploy/vpu/vm.sh daemon-restart    # stop-all, then start with --force, then daemon-check
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
own `--pre-alloc` (off `state/<vm>.json` when a takeover is already active, else off
`/proc/<pid>/cmdline` while the VM runs, else off the last `Executing:` line in `daemon.log`),
**saves** the config keys that produce it —
`gpu_host_pool_mb`, `gpu_guest_pool_mb`, `gpu_guest_prealloc_mb`, `gpu_drm2kgsl_pool_mb`,
`gpu_venus_pool_mb` — into `deploy/vpu/state/<vm>.json`, **sets them to 0** so the daemon emits no
`--pre-alloc` at all, and stores the whole string (the daemon's GPU keys plus your media keys)
plus everything after `--` in `extra_options`:

```sh
deploy/vpu/vm_extra.sh takeover Ubuntu-resolute media-host-mb=256,media-guest-mb=128 -- \
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
deploy/vpu/vm_extra.sh takeover Ubuntu-resolute --show media-host-mb=256,media-guest-mb=128 -- \
  --virtio-media kind=loopback,card=lb0        # print what would be sent; send nothing
deploy/vpu/vm_extra.sh takeover Ubuntu-resolute --base 'drm-host-mb=64,gpu-guest-mb=1024' \
  media-host-mb=256                            # skip the search: this string is the daemon's
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
| `kvt` | `MediaDeviceKind` (+ its support table) and `MediaDeviceConfig`: the `--virtio-media` command-line surface | 3 |
| `kst` | `devices/src/virtio/media/kill.rs` — the worker's kill signal | 5 |
| `mpt` | `devices/src/virtio/media/pool.rs` — the `media_host` pool allocator, its leases and the per-helper slice carve (D49) | 6 |
| `vmt` | the fork's whole `device/` crate, `-p virtio-media` (the camera and the two video codec devices included) | 124 |
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

Two kinds of noise are expected and are not findings. `mpt` prints three `dead_code` warnings
against `pool.rs` (`next_owner`, `inner`, `lease`) — the cost of compiling one file of a crate on
its own — and several harnesses open with `Patch ... was not used in the crate graph`, because
the `[patch.crates-io]` block each one carries is crosvm's, wider than the few crates it pulls
in. What matters is the last line, and `harness.sh`'s own `N passed, M failed` summary.

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
4. **the APK**, last, with `install_apk.sh` — never a bare `adb install -r` (**D12**). It is what
   makes step 3 unnecessary: with the WP A1 APK installed and the VM's VPU switch on, the daemon
   emits the media keys itself, so `restore` the takeover and put only `--virtio-media` in
   `extra_options`. Note that the daemon restart it performs also drops any `vm_extra.sh` change,
   so re-apply after it, not before.

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
  `media-host-mb` (the app's `VpuConfig`, default 256) only if the devices' *combined* working
  set really outgrows it. The `<card>` in the pool lines is the string the guest's
  `v4l2-ctl --info` shows (`droidvm decoder`, `camera 0`, ...): the helper introduces itself on
  the tube and the VMM adopts its card for the pool log lines and the `media pool <card>`
  server thread (`ps -T`; comm clips at 15 bytes). Two more lines worth greping: every release
  is followed by `pool: "<card>" holds N bytes, pool used M of S` — the accounting, live — and
  a helper that goes away leaves `the pool connection for "<card>" is closed` plus
  `reclaiming N media_host buffers from a device that went away` as the VMM sweeps its lease
  back into the pool.
* **`log level <filter>`** — the filter the child was exec'd with, which is now the VMM's own
  (`crosvm --log-level debug run ...` → `log level debug`). Before **D57** the helper was exec'd
  with no `--log-level` at all and crosvm's syslog reads no environment variable, so every helper
  ran pinned at `info` and every `debug!` in a device backend was dead weight — which is exactly
  how the D37 investigation lost its device-side instrument. `log level info (default)` on this
  line means nothing forwarded a filter and the old behaviour applies.

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

## Measurement traps

Six ways a run has silently lied to a work package. Each one cost a session; none of them
announces itself. In short, as a checklist:

> `timeout` needs `-k` for a stalled ffmpeg; `-stream_loop` does nothing on a raw elementary
> stream; ffmpeg needs `-fps_mode passthrough` on **both** sides before comparing hw/sw decode
> md5s of a VFR camera capture; `v4l2-ctl --wait-for-event=ctrl=` wants the control **NAME**;
> `vm.sh log` is a 1 MiB ring — snapshot it between steps; `install_apk.sh`'s daemon restart
> resets the VM config (re-apply, and diff against a known-good dump).

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

**3. `-fps_mode passthrough` on both sides, before you compare md5s.** A camera capture is VFR.
Without it ffmpeg pads the output up to CFR, **and the two decoders duplicate different frames**,
so a hardware and a software decode of the same file come out the same length with different
md5s — which reads exactly like a decoder bug and is not one. B10 lost a first comparison to
this: 9 "differing" frames that were duplication, and 0 once both sides passed through
(`logs/vpu_wp/B10-acceptance.md` §1.2).

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
that follows. The A5 helper is the one to reuse: `VM=<name> logs/vpu_wp/scratch-A5/cfg.sh set ...`
to re-apply, `cfg.sh show` to read the keys back, against `scratch-A5/04_cfg_vpuon.txt` as the
reference for a VPU-on VM. A silent config reset reads exactly like a regression in whatever you
changed, which is what makes it expensive.

**And one that is not a measurement trap but reads like one:** a `debug!` from a device backend
will not appear in the log unless the helper was started at that level — see `log level` on the
launch line above (**D57**). `crosvm --log-level debug run ...` is what forwards it; before that
fix, no helper `debug!` ever reached a phone log at all.
