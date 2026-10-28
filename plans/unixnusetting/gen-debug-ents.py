#!/usr/bin/env python3
# Curated DEBUG entitlement set for the owner debug tool(s). Every scalar key is validated against the
# stock 21H461 harvest (ents-21H461*.jsonl) so nothing is invented; the two array keys are curated to the
# classes/keys a VM debug tool actually uses. Writes debug-entitlements.plist and prints size + any unknown key.
import json, plistlib, sys, os, collections
S = os.path.dirname(os.path.abspath(__file__))
stock = collections.Counter()
stock_vals = collections.defaultdict(set)
lockdownd_ents = {}
for fn in ("ents-21H461.jsonl", "ents-21H461-cryptex.jsonl"):
    for l in open(os.path.join(S, fn)):
        r = json.loads(l)
        if r["path"].endswith("/lockdownd"):
            lockdownd_ents = r["ents"]
        for k, v in r["ents"].items():
            stock[k] += 1
            if isinstance(v, list):
                for e in v:
                    if isinstance(e, str): stock_vals[k].add(e)

# scalar (bool-true) debug keys, grouped. Every one is held by a real stock debug tool
# (debugserver, dtsecurity, taskinfo, spindump, footprint, ReportCrash, DTServiceHub).
BOOLS = [
    # run outside the sandbox / without a data container (owner tools)
    "com.apple.private.security.no-sandbox",
    "com.apple.private.security.no-container",
    # --- gdb-level process debugging (debugserver + dtsecurity) ---
    "com.apple.private.cs.debugger",            # act as a debugger: bypass CS, attach, read/write target memory, set SW breakpoints
    "com.apple.private.thread-set-state",       # set a target thread's registers: HW breakpoints, single-step, change PC
    "com.apple.private.set-exception-port",     # receive the target's Mach exceptions (a breakpoint is an exception)
    "com.apple.private.host-exception-port-override",
    "com.apple.system-task-ports",              # control task port of any process (== task_for_pid): basis of all of the above
    "com.apple.system-task-ports.control",
    "com.apple.system-task-ports.read",
    "com.apple.system-task-ports.inspect",
    "com.apple.system-task-ports.name.safe",
    "com.apple.system-task-ports.token.corpse", # grab a crashed process's corpse
    "com.apple.private.pac.exception",
    "com.apple.private.stackshot",              # call-stack snapshot of any process
    "com.apple.private.memorystatus",           # memory / jetsam state
    "com.apple.private.kernel.override-cpumon",  # don't get killed by the CPU monitor while stopped
    "com.apple.private.crash-reporter",
    "com.apple.private.iosurfaceinfo",
    "com.apple.security.network.client",        # debugserver's TCP endpoint for remote lldb
    "com.apple.security.network.server",
    # launch an app in debug mode and attach (backboardd/frontboard/springboard)
    "com.apple.backboardd.debugapplications",
    "com.apple.backboardd.launchapplications",
    "com.apple.frontboard.debugapplications",
    "com.apple.frontboard.launchapplications",
    "com.apple.springboard.debugapplications",
    # run helpers as another uid / persona
    "com.apple.private.persona-mgmt",
    "com.apple.private.persona.read",
    "com.apple.private.persona.write",
    # logs, diagnostics, kexts
    "com.apple.private.logging.diagnostic",
    "com.apple.private.logging.admin",
    "com.apple.private.logging.stream",
    "com.apple.private.diagnostics",
    "com.apple.private.set-atm-diagnostic-flag",
    "com.apple.private.kernel.get-kext-info",
    "com.apple.system.diagnostics.iokit-properties",
    "com.apple.private.security.storage.DiagnosticReports.read-write",
    "com.apple.private.security.storage.AppDataContainers",  # reach app Data containers for inspection
    # device identity (paired with the MG keys below)
    "com.apple.mobileactivationd.device-identifiers",
    # power / reboot convenience while debugging
    "com.apple.iokit.powerdxpc",
    "com.apple.private.iokit.darkwake-control",
    "com.apple.powerd.lowpowermode.allow",
    "com.apple.private.xpc.launchd.userspace-reboot",
    "com.apple.private.xpc.launchd.reboot",
    # orientation injection the current probe uses
    "com.apple.backboardd.setDeviceOrientation",
]

# curated array: protected MobileGestalt keys useful for a VM (device identity + build), from the stock union
MG = ["UniqueDeviceID", "UniqueChipID", "SerialNumber", "ProductType", "ProductVersion", "BuildVersion",
      "UserAssignedDeviceName", "DeviceColor", "DeviceEnclosureColor", "RegionCode",
      "HWModelStr", "DeviceClass",
      "SysCfg", "SysCfgDict", "BootManifestHash", "WifiAddress", "EthernetMacAddress", "BluetoothAddress"]

# curated array: IOKit user-client classes a VM debug tool opens (GPU, display, report, power, HID, storage)
IOK = ["IOSurfaceRootUserClient", "AGXDeviceUserClient", "AGXDevice", "AGXSharedUserClient", "AGXCommandQueue",
       "IOAccelContext2", "IOAccelDevice2", "IOAccelSharedUserClient2", "IOAccelSubmitter2", "IOGPUDeviceUserClient",
       "IOMobileFramebufferUserClient", "IOReportUserClient", "RootDomainUserClient", "AppleSMCClient",
       "IOHIDLibUserClient", "IOHIDEventServiceFastPathUserClient", "AppleAPFSUserClient"]

# --- lockdownd pairing (parked track: for future USB-free pairing research) ---
# Two halves: the client-side gate (what gfxprobe carried) + the server / pair-record side (from lockdownd itself).
PAIRING_BOOLS = [
    # client gate: appear to lockdownd as a trusted internal client
    "com.apple.private.iamlockdown",
    "com.apple.PairingManager",
    "com.apple.PairingManager.Read",
    "com.apple.PairingManager.Write",
    "com.apple.PairingManager.RemovePeer",
    "com.apple.mobile.ldpair",
    "com.apple.lockdownd.allow-save-value",
    "com.apple.dt.remotepairing.pairingmanagement",
    "com.apple.dt.remotepairing.tunnelmanagement",
    # server / pair-record side: write /var/db/lockdown + the host identity keychain
    "com.apple.private.securityd.ae.lockdown",
    "com.apple.private.security.storage.Lockdown",
    "com.apple.private.system-keychain",
]

ent = {k: True for k in BOOLS}
ent["com.apple.private.MobileGestalt.AllowedProtectedKeys"] = MG
ent["com.apple.security.iokit-user-client-class"] = IOK
for k in PAIRING_BOOLS:
    ent[k] = True
# finegrained lockdown value get/set/remove: the full stock union, so pairing research can read/write any domain value
for fg in ("com.apple.private.lockdown.finegrained-get",
           "com.apple.private.lockdown.finegrained-set",
           "com.apple.private.lockdown.finegrained-remove"):
    vals = sorted(stock_vals[fg])
    if vals:
        ent[fg] = vals
# keychain groups holding the pair record's host key/cert (as lockdownd carries them)
ent["keychain-access-groups"] = ["com.apple.mobile.lockdownd", "lockdown-identities"]
BOOLS = BOOLS + PAIRING_BOOLS

# --- merge lockdownd's WHOLE entitlement set, so the debug shell can stand in for lockdownd ---
# Skip only the keys that would change our identity or confine us (copying them is harmful, not useful):
#   application-identifier / seatbelt-profiles -> would brand us as lockdownd or drop us into lockdownd's sandbox
#   fairplay-client -> a fixed FairPlay client id, identity not capability
LD_EXCLUDE = {"application-identifier", "com.apple.application-identifier", "seatbelt-profiles", "fairplay-client"}
ld_merged = []
for k, v in sorted(lockdownd_ents.items()):
    if k in LD_EXCLUDE:
        continue
    if isinstance(v, list):
        cur = ent.get(k, [])
        if all(isinstance(x, str) for x in v) and all(isinstance(x, str) for x in (cur if isinstance(cur, list) else [])):
            ent[k] = sorted(set(cur) | set(v))
        else:
            ent[k] = v
    else:  # bool / dict / int — the identity scalars were excluded above
        ent[k] = v
    ld_merged.append(k)

# validate
unknown = [k for k in BOOLS if stock[k] == 0]
mg_missing = [v for v in MG if v not in stock_vals["com.apple.private.MobileGestalt.AllowedProtectedKeys"]]
io_missing = [v for v in IOK if v not in stock_vals["com.apple.security.iokit-user-client-class"]
              and v not in stock_vals["com.apple.security.exception.iokit-user-client-class"]]

out = os.path.join(S, "debug-entitlements.plist")
plistlib.dump(ent, open(out, "wb"))
print("wrote", out, os.path.getsize(out), "bytes; TOTAL keys =", len(ent))
print("  explicit debug/pairing bool keys:", len(BOOLS))
print("  lockdownd keys merged in:", len(ld_merged), "(excluded for identity/sandbox:", sorted(k for k in lockdownd_ents if k in LD_EXCLUDE), ")")
print("unknown bool keys (not in stock, kept anyway):", unknown or "none")
print("MG keys not seen in stock union:", mg_missing or "none")
print("IOKit classes not seen in stock union:", io_missing or "none")
