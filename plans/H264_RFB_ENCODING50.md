# Open H.264 (RFB encoding 50) for third-party VNC clients

Goal: TigerVNC (>=1.13) and noVNC clients that advertise the **Open H.264 encoding
(number 50)** receive the hardware-encoded H.264 stream over the **standard RFB port**.
The DVH2 side channel keeps working unchanged. This is a **crosvm-only** change
(gpu_display Rust + C); no app, daemon, or vms.json schema changes.

## 0. Normative references — read these FIRST, the wire format is theirs, not ours

- rfbproto spec, "Open H.264 Encoding":
  https://raw.githubusercontent.com/rfbproto/rfbproto/master/rfbproto.rst
  (encoding number 50; rect payload = `u32 length` + `u32 flags` + `length` bytes of
  H.264 Annex-B; flags: RESET_CONTEXT / RESET_ALL_CONTEXTS. Verify the exact bit values
  and the rect-geometry rules from the spec text, do not trust this summary.)
- TigerVNC client decoder (the de-facto conformance target):
  https://github.com/TigerVNC/tigervnc — `common/rfb/H264Decoder.cxx`,
  `H264DecoderContext.cxx` (note how contexts are keyed by rect geometry and what the
  reset flags do to them).
- noVNC decoder: https://github.com/novnc/noVNC — `core/decoders/h264.js`.

If the two client implementations disagree with the spec, **match the clients**.
NOTE: the vendored libvncserver's `rfbEncodingH264 0x48323634` (rfbproto.h) is an
older, abandoned proposal — it is NOT this. Use 50; define our own constant.

## 1. Current architecture (read before touching)

All in `crosvm/gpu_display/src/` (crosvm repo, branch wip/3d-accel; the checkout is a
symlink into crosvm_build/external/crosvm — a SHARED build tree, see §6):

- `vnc_server_bridge.c/.h` — C bridge over the vendored LibVNCServer
  (`crosvm_build/external/libvncserver`, pthread build: `LIBVNCSERVER_HAVE_LIBPTHREAD=1`,
  so `cl->sendMutex` exists and clients have their own input threads;
  `rfbRunEventLoop(screen, -1, TRUE)` at vnc_server_bridge.c:307). Compiled as
  `cc_library_static { name: "libvnc_server_bridge" }` in gpu_display/Android.bp:73.
- `vnc_frame_consumer.h` — the frame bus: ingest runs once per offered frame, then each
  registered consumer gets the same `vnc_frame_offer` (whole frame + damage bands + a
  GPU import id + cursor state). LibVNCServer is one consumer; H.264 is another.
- `vnc_h264.rs` — the whole H.264 rung today: `H264Consumer::start(server_ptr, port)`
  binds the DVH2 side-channel TCP port, spawns accept + drain threads, registers on the
  frame bus. `Encoder` wraps `android_h264_enc_*` FFI (AMediaCodec in
  Virtualization/libs/android_display_backend/crosvm_android_display_client.cpp).
  Encoder is created lazily on the first offer with someone waiting
  (`Channel::is_wanted`), rebuilt on resize, `request_sync_frame()` on client join,
  SPS/PPS cached via `codec_config()`. The drain thread `poll_output()`s compressed
  frames and writes them to the single DVH2 client.
- `gpu_display_vnc.rs` — `DisplayVnc::new_tcp(.., h264_port: Option<u16>)`; the port is
  `Some` **iff the screen's transport ceiling allows gpu-hw** (and then defaults to
  RFB+100). `consumer_generation()` is how the sink asks "did the consumer set change"
  → a sync frame is requested. Multiple screens = multiple servers, each with its own
  DisplayVnc + optional H264Consumer.

## 2. Design (decided — do not re-litigate)

The RFB-50 path **rides the existing H264Consumer**: it exists exactly when the side
channel exists (same transport-ceiling gate, same shared encoder, same drain thread).
One encoder, one Annex-B stream, N receivers:

- DVH2 side channel: unchanged, still single-client with `busy` refusal.
- RFB-50 clients: new C broadcaster, fed by the Rust drain thread.

### 2a. New C broadcaster: `vnc_h264_rfb.c` / `vnc_h264_rfb.h`

- Registered as a LibVNCServer **protocol extension** (`rfbRegisterProtocolExtension`,
  once per process via `pthread_once`) with `pseudoEncodings = {50, 0}` and
  `enablePseudoEncoding` — rfbserver.c:2562+ routes unknown SetEncodings numbers there,
  so **no vendor-tree patch is needed for detection**. `encodingNumber == 0` means
  "reset encodings" → client leaves h264 mode. The extension is process-global while
  servers are per-screen: route per-client state to the right server via `cl->screen`
  (attach the broker instance to the bridge's server struct; look it up from
  `screen->screenData`, which the bridge already owns).
- Per-client state: `joining` (needs SPS/PPS + IDR + RESET_CONTEXT before deltas),
  bounded outgoing queue, alive/backpressure bookkeeping.
- Entry from Rust (drain thread):
  `vnc_h264_rfb_submit(server, data, len, is_config, is_idr, width, height)`.
  Policy per client: joining → hold until a frame with `is_idr` arrives, then emit
  cached config + that IDR with RESET_CONTEXT set; joined → emit deltas in order.
  A queue overflow (cap it: a few MB or ~1s of stream) → drop the queue, mark the
  client `joining` again (it will resync on the next IDR); repeated overflow →
  `rfbCloseClient`.
- Wire: each emission is one complete FramebufferUpdate message written under
  `cl->sendMutex`: msg header (type 0, pad, nRects=1) + rect header
  (x=0, y=0, w=frame_w, h=frame_h, encoding=50) + `u32 length` + `u32 flags` + payload.
  Confirm against TigerVNC whether rect w/h must equal the client's framebuffer size
  and how DesktopSize interacts (see §2d).
- **Update-request semantics**: RFB is nominally request-driven. Check what TigerVNC/
  noVNC actually do (they keep continuous requests outstanding). Implement the robust
  version: track whether the client has an outstanding FramebufferUpdateRequest (the
  bridge/libvncserver already tracks this for the pixel path — find it in rfbserver.c);
  if none, queue (bounded) and flush when the next request arrives. If investigation
  shows send-on-arrival is what other servers do and clients accept, that is allowed,
  but write down the evidence in a comment.
- **Isolation invariant**: a stalled RFB-50 client may lose *itself*, never stall the
  drain thread, the DVH2 client, other RFB clients, or the producer. `rfbWriteExact`
  blocks; so either (a) write with the socket's send buffer capped + a write timeout on
  the fd (mirroring vnc_h264.rs's `cap_send_buffer`/`CLIENT_WRITE_TIMEOUT` reasoning,
  see the long comments there) and treat timeout as client death, or (b) per-client
  writer thread. Pick one, document why, keep the invariant.
- **Suppress the pixel path** for a client while it is in h264 mode: its damage-driven
  Tight/ZRLE rects must stop (double encode + double bandwidth otherwise), and cursor
  pseudo-encoding rects must stop too — the encoded stream already has the cursor
  composited (CursorOverlay). `screen->displayHook`/`displayFinishedHook` and/or
  clearing the client's update region are the tools; prefer hooks over vendor patches.
  When the client leaves h264 mode (SetEncodings without 50 / reset), restore the
  pixel path and force a full-screen mark so it repaints.

### 2b. Rust side (`vnc_h264.rs`)

- `wants_frames()` (and the internal `is_wanted` logic that gates encoder creation and
  frame feeding) extends to: side-channel wanted **|| rfb h264 client count > 0**
  (new FFI `vnc_h264_rfb_client_count(server)`).
- Join → sync frame: C broker bumps a join generation; Rust polls it where it already
  polls its own (`connect_generation` feeds `DisplayT::consumer_generation`) and calls
  `encoder.request_sync_frame()`. Reuse the existing mechanism, do not invent a second.
- Drain thread: after handing a frame to the DVH2 channel, also
  `vnc_h264_rfb_submit(...)`. IDR detection: AMediaCodec output flags
  (`BUFFER_FLAG_SYNC_FRAME=1`, `BUFFER_FLAG_CODEC_CONFIG=2`) are already surfaced as
  `PollOutput::Frame { flags }` — verify what vnc_h264.rs currently does with config
  frames (it caches SPS/PPS) and pass both booleans through.
- Resize: the encoder is rebuilt; DVH2 disconnects its client (header states geometry).
  For RFB: call `vnc_h264_rfb_reset(server, w, h)` → all clients marked `joining`
  (next IDR carries RESET_CONTEXT + new geometry). The bridge's existing resize path
  (rfbNewFramebuffer → DesktopSize to clients that negotiated it) stays as is — find
  and read it first.

### 2c. What must NOT change

- DVH2 protocol, refusal tokens, heartbeat, single-client semantics: untouched.
- Behavior for clients that never advertise 50: byte-identical (regression gate).
- The transport-ceiling gate: no h264_port → no consumer → no RFB-50 either. A client
  advertising 50 on a cpu/gpu-ceiling screen just gets Tight/ZRLE as today (the
  extension is only registered/armed when the consumer exists — or is registered but
  inert for servers without a broker; either way the observable behavior is "ignored").
- Vendored libvncserver: prefer zero patches. If a hook is genuinely missing, the patch
  must be minimal, commented, and called out in the handoff report.

### 2d. Open questions the implementer must answer from the references (write the
answers as code comments at the point of use)

1. Exact flag bit values and whether RESET_ALL_CONTEXTS is ever needed by a server.
2. Whether one FramebufferUpdate may carry only the h264 rect or may mix rect types,
   and whether w/h must equal the current framebuffer size.
3. How resize is expected to look on the wire for an h264 client (DesktopSize then
   reset-flagged rect? in which order?).
4. Whether clients tolerate a config-only (SPS/PPS, zero pictures) rect, or config must
   be concatenated in front of the IDR payload in one rect (DVH2 concatenates; the
   safest default is the same).

## 3. Files

- NEW `gpu_display/src/vnc_h264_rfb.c`, `gpu_display/src/vnc_h264_rfb.h`
- EDIT `gpu_display/src/vnc_server_bridge.c/.h` — create/destroy the broker with the
  server, expose it, extension registration
- EDIT `gpu_display/src/vnc_h264.rs` — submit/wants/join/reset plumbing (FFI decls)
- EDIT `gpu_display/Android.bp` — add the new .c to `libvnc_server_bridge` srcs
- CHECK `gpu_display/build.rs` + host target in Android.bp — if the bridge is compiled
  for host builds too, the new file must build there as well (stub behind the same
  feature the bridge already uses, if any)

## 4. Build & verify (implementer)

- Build with the repo scripts from the meta root
  (`/root/Documents/DroidVM_meta`): `bash 2_build_crosvm.sh`
  (soong; takes a while). The tree under `crosvm_build/` is SHARED with peer sessions:
  take the flock on `crosvm_build/out/.lock` the way the scripts do (wait, never kill),
  and NEVER edit source files while a build is in flight (the build silently compiles
  the pre-edit version — measured before).
- `cargo test` does not work in this tree. For pure-logic pieces (queue/join state
  machine) a scratch crate copy under the session scratchpad is fine if wanted.
- Deliverable: uncommitted working-tree changes + a written handoff: what was built,
  where the binary is, the answers to §2d, any vendor patch, any deviation from this
  plan and why. Do NOT commit, do NOT push, do NOT deploy to any phone.

## 5. Acceptance (verifier runs these; listed so the implementer knows the bar)

On 5568 (adb 10.53.12.1:5568), u26 VM reconfigured to a VNC screen with the gpu-hw
transport tier, new crosvm deployed:

1. Python RFB client advertising [50, Tight]: server sends encoding-50 rects; framing
   matches §0 spec byte-for-byte; extracted Annex-B stream decodes with ffmpeg; decoded
   dimensions == screen; first delivered payload starts SPS PPS IDR with reset flag.
2. Second h264 client joins mid-stream: gets SPS/PPS + IDR + reset first, both clients'
   streams stay decodable.
3. Legacy client (no 50): normal Tight/Raw rects, pixel-correct (existing rfb.py
   tooling), regardless of whether an h264 client is connected.
4. DVH2 side channel: unchanged handshake and stream while RFB-50 clients are active.
5. Stalled h264 client (connect, stop reading): others unaffected; stalled one dropped
   within its timeout; VM/producer never blocks.
6. Real third-party client if cheaply available on the Linux host (tigervnc-viewer
   under Xvfb + screenshot): picture visible. Stretch goal, not a gate.

## 6. Environment facts (do not rediscover)

- crosvm checkout: `/root/Documents/DroidVM_meta/crosvm` (symlink into
  `crosvm_build/external/crosvm`), branch wip/3d-accel, ~14 local unpushed commits —
  leave them alone; standing rule: NO pushing anywhere.
- Peer sessions build in the same tree; gfxstream/ worktree gets branch-switched by
  peers (not needed here).
- Vendored libvncserver: `crosvm_build/external/libvncserver` (pthread config).
- The encoder C++ (`android_h264_enc_*`): Virtualization repo,
  `libs/android_display_backend/crosvm_android_display_client.cpp` — should not need
  changes (sync-frame + config caching already exist); if a change is truly needed,
  flag it in the handoff instead of improvising.
