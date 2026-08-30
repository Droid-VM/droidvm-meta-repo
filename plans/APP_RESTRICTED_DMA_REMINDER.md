# App: restricted-DMA reminder rework + log filter + exporter default

Two user-requested changes in the DroidVM app repo
(`/root/Documents/DroidVM_meta/DroidVM`). No daemon-protocol, no
crosvm, no schema changes.

## Task A — the "host access to lent memory region" reminder

### Today (all grounded, read these files first)

- `app/src/main/java/cn/classfun/droidvm/lib/diag/LogHelper.java` — subscribes to
  daemon VM log events, keeps per-VM `LogContext` (`Map<String, RingBuffer> log`,
  per-stream ring buffers), runs a static array of `LogHelperHandler`s per line;
  a matched handler `show()`s once (`isOnce`, 2s delay).
- `app/src/main/java/cn/classfun/droidvm/lib/diag/handler/OsKernelWithoutRestrictPoolHandler.java`
  — matches stream=="stderr" && contains `"host access to lent memory region at 0x"`,
  shows a dialog: title `log_helper_no_restrict_pool_title`, message says "kernel does
  not support Restricted DMA Pool, replace the kernel", neutral button opens the wiki
  URL (`log_helper_no_restrict_pool_url`).
- The log line shape (real example, from crosvm stderr):
  `[2026-08-26T00:04:50.940175477+00:00 ERROR devices::virtio::virtio_pci_device] pcivu-sound activate failed: failed to get host address: host access to lent memory region at 0x105600000 (purpose=GuestMemoryRegion) in protected VM`
  The failing device is the token before " activate failed" (`pcivu-sound` here).
- The VM log viewer: `app/src/main/java/cn/classfun/droidvm/ui/vm/console/VMConsoleActivity.java`
  — a Termux TerminalView that runs, via `su -c`, either
  `droidvm logs <vmId> <stream>; sleep 2` (EXTRA_LOGS=true, history dump) or
  `exec droidvm console --raw <vmId> <stream>` (live). Extras: EXTRA_VM_ID,
  EXTRA_VM_NAME, EXTRA_STREAM, EXTRA_LOGS. `escapedString()` is already used for
  shell-escaping.

### Wanted

1. **The dialog tells the truth about both causes and names the devices.**
   - Message head: `%s 的以下裝置存取了保護區域記憶體:` (vmName) followed by a
     bulleted list of the DISTINCT device names extracted from every matching line
     currently in that VM's stderr ring buffer / seen so far (e.g. `• pcivu-sound`).
     Parse: `(\S+) activate failed` on each matching line; a matching line without
     that shape lists as a raw fallback (don't drop it silently).
     Handlers are process-wide singletons shared across VMs: any accumulated state
     must be keyed by vmId, and must reset when that VM's log context resets
     (see how LogHelper manages LogContext lifecycles — on VM stop/restart the list
     must not leak into the next boot).
   - Message body then explains BOTH causes:
     (a) the guest kernel may lack `CONFIG_DMA_RESTRICTED_POOL` → replace the kernel
     (or use the built-in DroidVM kernel);
     (b) the guest DRIVER for the listed device(s) may not be ported → install the
     ported drivers: Windows https://github.com/Droid-VM/gunyah-guest-drivers-windows
     Linux https://github.com/Droid-VM/droidvm-guest-additions
     Make the two GitHub URLs tappable (linkified message TextView, or keep them in
     the text and let autoLink handle it — verify it actually works in a
     MaterialAlertDialog, don't assume).
   - Buttons: OK (positive), 開啟 Log (negative or neutral), wiki URL (existing
     `log_helper_open_url` behavior) — keep all three; pick the layout that fits
     MaterialAlertDialog's 3-slot model.

2. **開啟 Log button** → starts `VMConsoleActivity` with EXTRA_VM_ID/EXTRA_VM_NAME,
   EXTRA_STREAM="stderr", EXTRA_LOGS=true, and a NEW `EXTRA_FILTER` prefilled with
   `host access to lent memory region at`.

3. **Filter feature in the console/log page** (generic, not specific to this error):
   - A toolbar action "過濾" on VMConsoleActivity: prompts for a filter string
     (dialog with a text field, prefilled with the current filter), empty = no filter.
   - Implementation fitting the architecture: the page content is a subprocess pipe,
     so filtering = restarting the terminal session with the command piped through
     `grep -F -- '<filter>'` (toybox grep exists on the device; escape with the
     existing `escapedString`). Both modes (logs dump and live console) should honor
     it; `--line-buffered` on the live path if toybox supports it — check, and if it
     doesn't, accept block buffering for live mode and say so in a comment.
   - EXTRA_FILTER sets the initial filter; the toolbar shows filtered state (e.g.
     title suffix or checked icon) so the user can tell.

4. **Strings**: every new/changed string in all THREE files: `values/strings.xml`,
   `values-zh-rCN/strings.xml`, `values-zh-rTW/strings.xml` (project convention;
   zh strings for the message per the user's own wording above, en equivalent).

## Task B — exporter default + menu order

- `app/src/main/java/cn/classfun/droidvm/lib/store/vm/DisplayExporter.java`:
  enum NONE(0,"none")/NATIVE(1,"native")/VNC(2,"vnc"), persisted BY NAME.
- `VMScreenConfig.getExporter()` defaults to `DisplayExporter.NONE` via `optEnum`.
- Labels: `create_vm_screen_exporter_none` = "None"/"無".

Wanted:
1. Default exporter for a screen = **NATIVE** (原生顯示). Before flipping the
   `optEnum` fallback wholesale, check what a stored config WITHOUT the exporter key
   means in the wild (does the editor always write the key on save? does the daemon
   read this same accessor when starting a VM?). If flipping the readback fallback
   would silently light up screens on existing VMs that were saved as
   exporterless-meaning-NONE, put the NATIVE default at the creation/template site
   instead and leave readback compatible. Document the choice in a comment where it
   lives.
2. Picker order: 原生顯示 / VNC / Sink(丟棄). Check how the picker builds its items
   (EnumPicker autoItems — enum declaration order?). Reordering enum declarations is
   allowed ONLY after verifying nothing depends on ordinal() (persistence is by name;
   `getValue()` fields stay as they are).
3. Rename the NONE label to "Sink (discard)" / "Sink（丟棄）" / zh-rCN equivalent, in
   all three strings files.

## Rules

- The repo working tree contains ANOTHER session's uncommitted work (VPU/camera:
  VMInstance.java, PeripheralType.java, edit/peripheral/*, new lib/peripheral/ files,
  AndroidManifest.xml). DO NOT touch, revert, stage, or reformat those files. Your
  changes must be limited to the files this plan implies.
- Build check: `./gradlew :app:assembleDebug` from the DroidVM dir must succeed.
  Do NOT install on any device, do NOT commit, do NOT push. The verifier deploys.
- Code style: comments state constraints/reasons only; match surrounding style.
- Deliverable: uncommitted working-tree changes + handoff report: files changed with
  a paragraph each, the Task B default-site decision and its evidence, the grep
  buffering answer, any deviation from this plan and why, and the exact APK path +
  proof the build ran after your last edit (artifact vs source mtimes).
