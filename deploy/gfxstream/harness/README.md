# Benchmark / bring-up harness

Everything here exists because a measurement lied once. The comments say which one.

| file | what it is |
|---|---|
| `vm_restart.sh` | Bring the VM down and up with the pre-flight checks a launch needs |
| `mc_lib.sh` | Drive Minecraft to a fixed scene and read the numbers off the host |
| `threadcpu.sh` | Per-thread CPU of crosvm (push to the phone) |
| `kgsl_trace.sh` | Capture the KGSL timestamp-wait path from the kernel's tracepoints |
| `poolinfo.c` | Read the guest-alloc pool's total/used/largest-free (build and run in the guest) |

## Rules these encode

**Every wait is bounded.** An unbounded `until` once spent half an hour waiting for a log line a
crashed Minecraft was never going to write. Loops count, and say what they gave up on.

**Check the preconditions before launching, not the symptoms afterwards.**
- The reserve reclaims asynchronously, so "crosvm exited" does not mean its pages are back. Launching
  into a partly-reclaimed reserve does not fail at boot -- it fails later as a guest page fault the
  hypervisor answers with -ENOMEM, which kills the VM and leaks its pages, making the next attempt
  worse.
- `active_vms=0` with `served>0` is leaked pages. Only a phone reboot clears it.
- The bridge belongs to the DroidVM app and is rebuilt when it starts, so straight after a phone
  reboot the launcher's tap attach can run before `br-wifi` exists and fail silently. The guest then
  boots perfectly and is merely unreachable -- which reads as "the VM did not come up".

**Measure the thing, not a proxy for it.** `guest submits/s` counts every context together and varies
with the scene: identical runs came back 401-472. Minecraft's own once-per-frame fence wait, counted
for its thread alone, came back 90/92/88 for the same three runs. That is `mc_fps`.

**Hold the scene still.** Minecraft's saved camera angle is part of the workload -- looking at the
sky is a far lighter frame. Moving the VNC pointer while the game has the mouse grabbed *is* a
camera rotation, and the angle is saved, so it drifts run over run. `mc_start` takes focus with
xdotool (no pointer event) and teleports the player to a fixed position and heading first.

**Never edit a script while it is running.** bash reads scripts incrementally.
