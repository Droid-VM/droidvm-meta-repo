#!/usr/bin/env python3
"""DroidVM daemon IPC client for the VPU dev rig.

Host-side client; reach the daemon through `adb forward tcp:<port> tcp:<port>` (lib.sh's
`dvm_connect` does that for you). Cleaned-up descendant of the survey client at
logs/vpu_survey/raw-5566-vm/dvmipc.py.

Three properties of the protocol shape this file (all verified in
logs/vpu_survey/app-daemon.md §5.1 and device-5566-vm.md §1.2):

  * Framing is a 4-byte little-endian length followed by that many bytes of UTF-8 JSON. The Java
    sender appends a NUL that COUNTS TOWARD THE LENGTH (Protocol.java:49-59) and the reader
    strips a trailing NUL if present (:44), so we do the same on the way in and never send one.
  * `auth` must complete before anything else. ClientHandler dispatches each request onto a
    thread pool (ClientHandler.java:98), so two requests written back-to-back are NOT ordered --
    every request here waits for its own response before the next one is written.
  * The daemon broadcasts unsolicited `{"type":"event",...}` frames to every connected client
    (Server.java:42-74), so they interleave with responses. Responses are therefore matched on
    `request_id`, and events are dropped (or echoed to stderr with --events).

Exit status is 0 when the response says success, 1 otherwise.
"""

import argparse
import json
import re
import socket
import struct
import sys
import uuid

MAX_PAYLOAD = 8 << 20  # Protocol.java:22


class Daemon:
    def __init__(self, host, port, timeout, show_events=False):
        self.sock = socket.create_connection((host, port), timeout)
        self.sock.settimeout(timeout)
        self.show_events = show_events

    def _send(self, obj):
        body = json.dumps(obj).encode()
        self.sock.sendall(struct.pack("<I", len(body)) + body)

    def _recv_exactly(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise EOFError("daemon closed the connection")
            buf += chunk
        return buf

    def _recv(self):
        (n,) = struct.unpack("<I", self._recv_exactly(4))
        if n > MAX_PAYLOAD:
            raise ValueError("frame of %d bytes exceeds the 8 MiB protocol limit" % n)
        return json.loads(self._recv_exactly(n).rstrip(b"\0").decode())

    def call(self, command, **params):
        rid = str(uuid.uuid4())
        self._send(dict(type="request", request_id=rid, command=command, **params))
        while True:
            msg = self._recv()
            if msg.get("type") == "response" and msg.get("request_id") == rid:
                return msg
            if self.show_events:
                sys.stderr.write("event: %s\n" % json.dumps(msg))

    def auth(self, token):
        resp = self.call("auth", token=token)
        if not resp.get("success"):
            raise SystemExit("auth failed: %s" % resp.get("message", resp))

    def resolve(self, key):
        """Accept a VM name where the daemon insists on a vm_id.

        Every ipc/vm handler reads a bare `vm_id` out of the request and looks it up by id
        (GetHandler.java:27-30 and friends) -- unlike the `droidvm` CLI, which resolves names
        first. So `dvmipc.py get Ubuntu-resolute` used to answer "VM not found" while
        `vm.sh`/`vm_extra.sh` worked, because those resolve through vm_list themselves
        (lib.sh's vm_info). Do the same here; an exact id match wins and costs one extra call.
        """
        resp = self.call("vm_list")
        vms = resp.get("data") or []
        for vm in vms:
            if vm.get("id") == key:
                return key
        for vm in vms:
            if vm.get("name") == key:
                return vm["id"]
        raise SystemExit("no VM named or id %r (have: %s)"
                         % (key, ", ".join(vm.get("name", "?") for vm in vms)))


def decode_console(blob):
    """The console history blob is %XX-encoded (VMInstance.java:611-620)."""
    return re.sub(r"%([0-9A-Fa-f]{2})", lambda m: chr(int(m.group(1), 16)), blob)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--token", required=True, help="contents of run/droidvmd-token.txt")
    ap.add_argument("--timeout", type=float, default=60.0)
    ap.add_argument("--events", action="store_true", help="echo interleaved daemon events to stderr")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list", help="vm_list: every VM, config + live state/pid/streams")
    sub.add_parser("stop-all", help="vm_stop_all: stop every running VM (takes no id)")
    for name, helptext in (
        ("status", "vm_status: the lowercase VMState"),
        ("stop", "vm_stop"),
        ("get", "vm_get: the stored config (name or id)"),
    ):
        p = sub.add_parser(name, help=helptext)
        p.add_argument("vm_id")
    p = sub.add_parser("start", help="vm_start: start an ALREADY STORED VM (the CLI cannot)")
    p.add_argument("vm_id")
    p.add_argument("--clear-logs", action="store_true")
    p.add_argument("--boot-entry")
    p = sub.add_parser("modify",
                       help="vm_modify: replace a stored config (VM must be STOPPED); the "
                            "config's own 'id' may be a name")
    p.add_argument("config", help="path to a whole VMConfig JSON object, or - for stdin")
    p = sub.add_parser("console-history", help="vm_console_history, %%XX-decoded")
    p.add_argument("vm_id")
    p.add_argument("stream", nargs="?", default="stdio")
    p.add_argument("--json", action="store_true", help="print the raw response instead of the text")
    args = ap.parse_args()

    d = Daemon(args.host, args.port, args.timeout, args.events)
    d.auth(args.token)

    if args.cmd == "list":
        resp = d.call("vm_list")
    elif args.cmd == "status":
        resp = d.call("vm_status", vm_id=args.vm_id)
    elif args.cmd == "stop":
        resp = d.call("vm_stop", vm_id=args.vm_id)
    elif args.cmd == "get":
        resp = d.call("vm_get", vm_id=d.resolve(args.vm_id))
    elif args.cmd == "stop-all":
        resp = d.call("vm_stop_all")
    elif args.cmd == "start":
        extra = {}
        if args.clear_logs:
            extra["clear_logs_before_start"] = True
        if args.boot_entry:
            extra["boot_entry"] = args.boot_entry
        resp = d.call("vm_start", vm_id=args.vm_id, **extra)
    elif args.cmd == "modify":
        text = sys.stdin.read() if args.config == "-" else open(args.config).read()
        cfg = json.loads(text)
        if not cfg.get("id"):
            raise SystemExit("modify: the config must carry its own 'id' (ModifyHandler.java:59-70)")
        cfg["id"] = d.resolve(cfg["id"])
        resp = d.call("vm_modify", config=cfg)
    elif args.cmd == "console-history":
        resp = d.call("vm_console_history", vm_id=args.vm_id, stream=args.stream)
        if resp.get("success") and not args.json:
            sys.stdout.write(decode_console(resp.get(args.stream) or ""))
            return 0
    else:  # unreachable: argparse enforces the choice
        raise SystemExit("unknown command %r" % args.cmd)

    json.dump(resp, sys.stdout, indent=1)
    sys.stdout.write("\n")
    return 0 if resp.get("success") else 1


if __name__ == "__main__":
    sys.exit(main())
