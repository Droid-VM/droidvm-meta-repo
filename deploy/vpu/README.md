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
| `vm_extra.sh` | `show\|set\|clear <name>` — the VM's `extra_options` array |
| `tests/smoke_media.sh` | `<name>` — is there a working virtio-media device in the guest? |

A VM is named by either its `name` or its `id`; both go through one `vm_list` lookup.

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
deploy/vpu/vm_extra.sh show  Ubuntu-resolute
deploy/vpu/vm_extra.sh set   Ubuntu-resolute --pre-alloc <FULL MERGED STRING> --virtio-media kind=loopback
deploy/vpu/vm_extra.sh clear Ubuntu-resolute
```

**`--pre-alloc` is single-valued.** `extra_options` are appended *after* the daemon's own
arguments, so a second `--pre-alloc` **overrides** the daemon's instead of merging with it. Read
the daemon's own string off `vm.sh argv <name>` and pass the whole merged value; passing only the
media keys silently drops the GPU pools and the guest loses its GPU. On the lab VM today the
daemon emits:

```
--pre-alloc drm-host-mb=64,gpu-guest-mb=1024,gpu-guest-prealloc-mb=1024,gpu-guest-step-mb=0,gpu-guest-max-grants=0
```

`vm_modify` refuses a VM that is not `STOPPED`, so `vm_extra.sh set|clear` does too.

### `tests/smoke_media.sh`

```sh
deploy/vpu/tests/smoke_media.sh Ubuntu-resolute
```

Waits for ssh, then checks the driver is loaded, a `/dev/video*` node exists, dmesg mentions the
driver, and `v4l2-ctl --all` answers on every node. If a node's card type is `simple_device` it
captures 30 frames to `/tmp/simple.raw` and prints the byte count; if one is `loopback` it runs 10
frames through the m2m queues. Missing card types are skipped, not failed — which one exists
depends on how crosvm was launched. Any real failure makes the script exit non-zero.
Run `guest.sh install-tools` once first: the test needs `v4l2-ctl`.

---

## A typical loop

```sh
JOBS=8 taskset -c 0-7 ./2_build_crosvm.sh          # never unpinned, never more than 8 jobs
deploy/vpu/vm.sh   stop  Ubuntu-resolute
deploy/vpu/push_crosvm.sh
deploy/vpu/vm_extra.sh set Ubuntu-resolute --pre-alloc <merged> --virtio-media kind=loopback
deploy/vpu/vm.sh   start Ubuntu-resolute
deploy/vpu/vm.sh   argv  Ubuntu-resolute | grep -E 'pre-alloc|media'
deploy/vpu/tests/smoke_media.sh Ubuntu-resolute
```

If `start` comes back "went back to stopped", `vm.sh log` has the reason: crosvm rejects an
unknown flag before the guest ever runs, and that lands in the `stdio` history.
