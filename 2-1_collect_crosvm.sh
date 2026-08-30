#!/bin/bash
# Collect crosvm + the .so it directly links into one easy-to-find dir.
# Run from AOSP root:  external/crosvm/crosvm_device_only/collect_crosvm.sh [outdir] [--deep]
#   (default outdir: out/crosvm_pkg ; --deep = also pull transitive deps)
# RUNPATH of crosvm is $ORIGIN, so just push the whole dir and run ./crosvm.
# NOTE: no 'pipefail' on purpose. findso()/BIN grep pipelines legitimately
# produce no match (lib not in tree -> handled by the else branch below);
# with pipefail, grep's exit 1 would abort the whole script via set -e.
set -eu
ARCH="${ARCH:-android_arm64}"
DEEP=0; DEST="out/crosvm_pkg"
for a in "$@"; do [ "$a" = "--deep" ] && DEEP=1 || DEST="$a"; done

RE=$(ls prebuilts/clang/host/linux-x86/*/bin/llvm-readelf 2>/dev/null | head -1)
BIN=$(ls out/soong/.intermediates/external/crosvm/crosvm_device_only/crosvm_device_only_bin/*/crosvm \
      2>/dev/null | grep -v unstripped | head -1)
[ -n "$RE"  ] || { echo "llvm-readelf not found"; exit 1; }
[ -n "$BIN" ] || { echo "crosvm not built yet"; exit 1; }

SKIP="libc.so libdl.so libm.so"           # bionic, always on device
mkdir -p "$DEST"; cp -f "$BIN" "$DEST/crosvm"

needed(){ "$RE" -d "$1" 2>/dev/null | awk -F'[][]' '/NEEDED/{print $2}'; }
findso(){ find out/soong/.intermediates -path "*${ARCH}*_shared*" -name "$1" 2>/dev/null \
          | grep -v unstripped | head -1; }

declare -A seen; queue=$(needed "$BIN")
while [ -n "$queue" ]; do
  next=""
  for so in $queue; do
    case " $SKIP " in *" $so "*) continue;; esac
    [ -n "${seen[$so]:-}" ] && continue; seen[$so]=1
    src=$(findso "$so")
    if [ -n "$src" ]; then
      cp -f "$src" "$DEST/"; printf '  + %-26s %s\n' "$so" "$src"
      [ "$DEEP" = 1 ] && next="$next $(needed "$src")"
    else
      printf '  ? %-26s (not in tree; assume present on device)\n' "$so"
    fi
  done
  queue="$next"
done
echo "==> $DEST"; ls -1 "$DEST"
