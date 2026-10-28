#!/usr/bin/env python3
# Dump the XML entitlements of every Mach-O under ROOT as JSON lines: {"path": ..., "ents": {...}}.
import json, os, plistlib, struct, sys

ROOT = sys.argv[1]
out = open(sys.argv[2], "w")

def slices(f, size):
    f.seek(0)
    hdr = f.read(8)
    if len(hdr) < 8:
        return []
    magic = struct.unpack(">I", hdr[:4])[0]
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        n = struct.unpack(">I", hdr[4:8])[0]
        if n > 32:
            return []
        res = []
        for i in range(n):
            if magic == 0xCAFEBABE:
                f.seek(8 + i * 20)
                _, _, off, sz, _ = struct.unpack(">iiIII", f.read(20))
            else:
                f.seek(8 + i * 32)
                _, _, off, sz, _, _ = struct.unpack(">iiQQII", f.read(32))
            res.append(off)
        return res
    if struct.unpack("<I", hdr[:4])[0] in (0xFEEDFACF, 0xFEEDFACE):
        return [0]
    return []

def ents_of(f, base):
    f.seek(base)
    h = f.read(32)
    magic, _, _, ftype, ncmds, sizeofcmds = struct.unpack("<IiiIII", h[:24])
    hsz = 32 if magic == 0xFEEDFACF else 28
    f.seek(base + hsz)
    cmds = f.read(sizeofcmds)
    p = 0
    for _ in range(ncmds):
        cmd, csz = struct.unpack("<II", cmds[p:p + 8])
        if cmd == 0x1D:  # LC_CODE_SIGNATURE
            dataoff, datasize = struct.unpack("<II", cmds[p + 8:p + 16])
            f.seek(base + dataoff)
            sb = f.read(datasize)
            m, _, count = struct.unpack(">III", sb[:12])
            if m != 0xFADE0CC0:
                return ftype, None
            for i in range(count):
                typ, off = struct.unpack(">II", sb[12 + i * 8:20 + i * 8])
                bm, bl = struct.unpack(">II", sb[off:off + 8])
                if bm == 0xFADE7171:
                    return ftype, plistlib.loads(sb[off + 8:off + bl])
            return ftype, {}
        p += csz
    return ftype, None

def clean(v):
    if isinstance(v, (bytes, bytearray)):
        return {"$data": v.hex()}
    if isinstance(v, dict):
        return {k: clean(x) for k, x in v.items()}
    if isinstance(v, list):
        return [clean(x) for x in v]
    if hasattr(v, "isoformat"):
        return v.isoformat()
    return v

n = 0
for dp, dns, fns in os.walk(ROOT):
    for fn in fns:
        p = os.path.join(dp, fn)
        try:
            if os.path.islink(p) or not os.path.isfile(p):
                continue
            with open(p, "rb") as f:
                for base in slices(f, 0):
                    ftype, e = ents_of(f, base)
                    if e is None:
                        continue
                    out.write(json.dumps({"path": p[len(ROOT):], "ftype": ftype, "ents": clean(e)}) + "\n")
                    n += 1
                    break
        except Exception as ex:
            sys.stderr.write("%s: %s\n" % (p, ex))
print(n)
