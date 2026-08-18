#!/bin/bash
# The boot shim for protected-pseudo-unprotected VMs, built before crosvm because crosvm embeds it.
#
# soong cannot build this: it targets bare metal, links against its own script and is emitted as a
# flat binary, none of which the Android Rust rules describe. So it is built here with cargo and
# dropped next to the crate that includes it. rustc records `include_bytes!` inputs in its
# dep-info, and soong feeds those depfiles to ninja, so changing the shim rebuilds crosvm without
# anything else being told about it.
set -e
cd "$(dirname "$0")"
SHIM=crosvm/droidvm-shim
OUT=crosvm_build/out/shim

# cd rather than --manifest-path: cargo looks for .cargo/config.toml relative to the working
# directory, and that file is what names the bare-metal target and the linker script. From the
# repo root the same command quietly builds for the host and fails on the first `hvc`.
( cd $SHIM && cargo build --release )
mkdir -p "$OUT"
cp $SHIM/target/aarch64-unknown-none/release/droidvm-shim "$OUT"/shim.elf
aarch64-linux-gnu-objcopy -O binary "$OUT"/shim.elf "$OUT"/shim.bin
# The copy crosvm compiles in. Kept in the source tree rather than in out/ because that is where
# include_bytes! looks, and because a stale one is then visible to git rather than invisible.
cp "$OUT"/shim.bin crosvm/hypervisor/src/gunyah/shim.bin

size=$(stat -c%s "$OUT"/shim.bin)
echo "shim.bin: $size bytes"
# It shares the boot region with the device tree; there is no reason for it ever to approach this,
# and a shim that did would be doing something that does not belong in a shim.
[ "$size" -le $((1024 * 1024)) ] || { echo "shim is over 1 MiB: it does not belong in the boot region"; exit 1; }
