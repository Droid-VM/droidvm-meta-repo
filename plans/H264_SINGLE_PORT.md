# Single-port VNC H.264: the app rides encoding 50, DVH2 retires

Goal: one TCP port per VNC screen. The DroidVM app's VNC console consumes the
hardware H.264 stream over the ordinary RFB connection — encoding 50 plus one private
pseudo-encoding for the two semantics RFB negotiation cannot express — and the DVH2
side channel (`RFB port + 100`, `h264-port=`) is deleted end to end.

Two implementation halves (crosvm; app) built by different agents from THIS document.
The wire format below is the seam: both sides implement it byte-for-byte from here,
neither side invents or renegotiates it. (History: a colon in a refusal string once
cost a day because two agents read one contract two ways. The contract is here, once.)

## 1. The DroidVM pseudo-encoding (pinned, byte-exact)

- Encoding number: **0x44564831** ("DVH1" in ASCII), sent by the client in
  SetEncodings alongside 50. Vendor-style positive number in unassigned space, same
  pattern as VMware's 0x574d56xx block.
- A server rect with this encoding always has **x=0 y=0 w=0 h=0** and a **fixed
  4-byte payload**:

      u8 version   = 1
      u8 kind      0 = capabilities, 1 = heartbeat
      u8 value     kind 0: 0 = h264 stream available (encoder up or expected)
                           1 = no encoder on this host, permanent -- stop waiting
                           2 = warming: asked for, not producing yet
                   kind 1: 0
      u8 reserved  = 0

  A client must ignore unknown `kind`s and any payload bytes past the fourth
  (there are none in v1); a server must never send this rect to a client that did
  not advertise 0x44564831.
- **Caps rect**: sent as a single-rect FramebufferUpdate, consuming one outstanding
  request, (a) as the first answer after the client advertises the pseudo-encoding,
  and (b) again whenever the value changes (encoder came up; encoder declared
  permanently failed). The pixel/h264 content answers the client's next request —
  clients re-request immediately, so this costs one round trip once.
- **Heartbeat rect**: only to clients that advertised 0x44564831 AND are enrolled on
  the h264 stream with an encoder running: when the client's request has been in
  custody with an empty stream queue for 3 seconds, answer it with a heartbeat rect.
  The 3s cadence and its meaning are exactly DVH2's (vnc_h264.rs's old
  HEARTBEAT_INTERVAL reasoning carries over verbatim: a still screen and a dead
  stream are indistinguishable without it). Clients without the pseudo-encoding keep
  today's behavior: the request is held silently.
- Client liveness rule (app side): while consuming h264, silence — no 50-rect and no
  heartbeat — longer than 10 seconds means the stream (or connection) is dead:
  reconnect, and on repeated failure fall back to the pixel path. Mirrors the DVH2
  read-timeout policy.

## 2. crosvm half

Base: commit 1005d16ff (encoding 50 broadcaster) plus the uncommitted snd fix.
All in gpu_display unless noted.

1. `vnc_h264_rfb.c`: extension `pseudoEncodings` becomes {50, 0x44564831, 0};
   `enablePseudoEncoding` records DVH-awareness per client and queues the initial
   caps rect. Per-client state grows: `dvh_aware`, `pending_caps` (+ current caps
   value), custody-idle timestamp. `displayHook` order: pending caps → emit caps
   update; else stream queue → emit h264 update (unchanged); else DVH-aware, encoder
   up, custody idle ≥ 3s → emit heartbeat. New broker entry point for the Rust drain
   thread's periodic tick (it already wakes every 100ms in `poll_output`) to check
   idle custody and `wake_client` those due a heartbeat; and one to broadcast a caps
   change (encoder up / permanently failed).
2. `vnc_h264.rs`: DELETE the side channel — listener, accept thread, `Channel`,
   `ClientSlot`, refusal strings, `MAGIC_*`, heartbeat writer, `H264_PORT_OFFSET` —
   the drain thread and `Encoder` stay, now feeding only the RFB broker.
   `wants_frames()` = broker client count alone. Push caps transitions into the
   broker where `encoder_failed`/first-encoder-up are decided today. The module doc
   is rewritten again: one door, on the RFB port.
3. `gpu_display_vnc.rs` / `devices/src/virtio/gpu/mod.rs` / config plumbing: remove
   the `h264_port` parameter and `h264-port=` CLI key end to end. An old command
   line naming `h264-port=` must FAIL parsing (loud, not silently ignored) — mixed
   deploys are already forbidden in this project, and a silently dropped key is how
   stale configs pass gates.
4. Multi-screen, isolation, vendor-tree rules, lock order: all inherited unchanged
   from the encoding-50 round; do not weaken any of them.

## 3. App half

The console (`ui/vm/display/vnc/`) today: RFB client for pixels/input + a separate
DVH2 TCP client (`h264/H264SideChannel`, `H264StreamProtocol`) feeding
`H264ConsoleDecoder` via `H264ConsolePipeline`, gated by `H264ProbePolicy`, and it
learns the side-channel port from the daemon's `vnc_info` IPC (`h264_port`).

1. The app RFB client advertises [0x44564831, 50, ...existing] and grows two rect
   parsers: encoding 50 (u32 BE length + u32 BE flags + Annex-B payload → hand the
   payload to the existing decoder; honour the reset flags by resetting the decoder;
   rect w/h is the coded size) and 0x44564831 (4-byte payload per §1). DesktopSize
   handling stays as it is.
2. `H264ConsolePipeline` sources from those rects instead of the side channel;
   `H264SideChannel` and `H264StreamProtocol` are deleted; `H264ProbePolicy`
   becomes the §1 client rules (caps value 1 = permanent fallback, 2 = wait, 0 =
   decode; 10s silence = reconnect). `H264ConsoleDecoder` is unchanged except reset.
3. Remove `h264_port` end to end: `VMScreenConfig` key + `effectiveVncH264Port`,
   the editor field `et_screen_vnc_h264_port` (ScreenBindingRow + layout + strings),
   `VncInfoHandler`'s response field, and `CrosvmBackendInstance`'s `,h264-port=`
   argument. Reading an old vms.json that still has the key: the key is simply
   ignored (config readback must not fail on it). The daemon must not emit the flag
   — against the new crosvm it would refuse to start (see §2.3), which is the
   intended loud failure for a mixed deploy, not something to paper over.
4. Old-server compat (new app, old crosvm, e.g. a still-running VM): the server
   ignores both encodings and serves pixels; the app sees neither caps nor 50-rects
   and must simply stay on the pixel path (no infinite "warming" wait: no caps rect
   within ~5s of connect = treat as value 1).

## 4. Verification (the verifier runs; listed so both halves know the bar)

1. Seam test, server side: python client advertising [50, 0x44564831] receives the
   caps rect first (byte-exact per §1), then SPS/PPS/IDR-first h264 rects; after 5s
   of still screen, heartbeat rects at ~3s cadence; a client advertising only [50]
   never receives a 0x44564831 rect; a client advertising neither gets pixels.
2. Seam test, app side: unit test feeding the app parser the LITERAL bytes the
   python client asserted (same fixtures, copied not re-derived).
3. On device: app console shows the u26 screen via RFB-50 (logcat/pipeline evidence,
   not just a picture); `netstat` on the phone shows NO listener on RFB+100;
   TigerVNC (no DVH1) still renders; legacy python client still gets pixels.
4. Idle screen in the app console for >30s: connection stays up (heartbeats), and
   pulling the VM down mid-view produces the app's dead-stream handling, not a hang.
5. vms.json from before the change (with `h264_port`) loads; the editor no longer
   shows the field; daemon-built args contain no `h264-port=`.

## 5. Rules for both agents

- Wire format comes from §1 of this file; if an agent believes it is wrong or
  incomplete, it STOPS and says so in its report instead of adjusting it.
- crosvm build: `bash 2_build_crosvm.sh` from the meta root; flock on
  crosvm_build/out/.lock; never edit sources mid-build. App build:
  `./gradlew :app:assembleDebug`.
- Neither agent commits, pushes, deploys, or touches the peer session's uncommitted
  files (crosvm: vm_memory/udmabuf, android_camera/; app: VPU/camera set incl.
  AndroidManifest, VMInstance, PeripheralType, edit/peripheral/*, and the camera/VPU
  hunks inside VMEditGraphicsTab.java and values/strings.xml — strings edits go in
  as NEW hunks that leave the camera/VPU block untouched).
- Reports: raw facts, file-by-file, with build provenance (artifact vs source
  mtimes, plus a distinctive-string probe with positive and negative controls).
