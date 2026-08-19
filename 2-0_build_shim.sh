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
# Named here AND passed to cargo, so the two cannot disagree. They did once: .cargo/config.toml
# moved to the softfloat target and this script went on copying out of the old directory, so every
# build for a full morning shipped a stale binary -- one with the SIMD instructions the move was
# made to get rid of. A VM that traps on its first instruction says nothing about why.
TARGET=aarch64-unknown-none-softfloat

# cd rather than --manifest-path: cargo looks for .cargo/config.toml relative to the working
# directory, and that file is what names the bare-metal target and the linker script. From the
# repo root the same command quietly builds for the host and fails on the first `hvc`.
( cd $SHIM && cargo build --release --target $TARGET )
# Anything left behind by a build for another target is a trap for the next person to read this.
rm -rf $SHIM/target/aarch64-unknown-none
mkdir -p "$OUT"
cp $SHIM/target/$TARGET/release/droidvm-shim "$OUT"/shim.elf
aarch64-linux-gnu-objcopy -O binary "$OUT"/shim.elf "$OUT"/shim.bin

# No FP/SIMD, checked rather than assumed. The shim runs before anything sets CPACR_EL1.FPEN, so
# one such instruction is an undefined-instruction trap in a VM with no handler and no console.
simd=$(aarch64-linux-gnu-objdump -d "$OUT"/shim.elf | grep -cE '\s(q|v)[0-9]+(\.|,|\])' || true)
[ "$simd" -eq 0 ] || {
    echo "shim uses $simd FP/SIMD operands: it runs before CPACR_EL1.FPEN is set and would trap"
    aarch64-linux-gnu-objdump -d "$OUT"/shim.elf | grep -E '\s(q|v)[0-9]+(\.|,|\])' | head
    exit 1
}
# The copy crosvm compiles in. Kept in the source tree rather than in out/ because that is where
# include_bytes! looks, and because a stale one is then visible to git rather than invisible.
cp "$OUT"/shim.bin crosvm/hypervisor/src/gunyah/shim.bin

# The shim shares its lent region with the guest's device tree, which crosvm puts at
# AARCH64_SHIM_FDT_OFFSET = 2 MiB. `_shim_end` is past the stack and the BSS -- neither of which
# is in the flat binary -- so it, not the file size, is what must stay below that.
end=$(aarch64-linux-gnu-nm "$OUT"/shim.elf | awk '$3 == "_shim_end" { print strtonum("0x" $1) }')
[ -n "$end" ] || { echo "no _shim_end in the shim: the linker script did not do what it says"; exit 1; }
[ "$end" -le $((0x200000)) ] || {
    printf 'shim ends at %#x, past the device tree at 0x200000 (AARCH64_SHIM_FDT_OFFSET)\n' "$end"
    exit 1
}

size=$(stat -c%s "$OUT"/shim.bin)
echo "shim.bin: $size bytes"
# It shares the boot region with the device tree; there is no reason for it ever to approach this,
# and a shim that did would be doing something that does not belong in a shim.
[ "$size" -le $((1024 * 1024)) ] || { echo "shim is over 1 MiB: it does not belong in the boot region"; exit 1; }
