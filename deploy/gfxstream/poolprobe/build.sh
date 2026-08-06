#!/bin/bash
# Build the two pool diagnostics against the phone's KMI.
#
#   ./build.sh [tag]      default: android15-6.6 (the 6.6.118 the device runs)
#
# They are deliberately NOT part of gh_hugepage_reserve. Loading a new build of that module
# means rmmod'ing it first, which returns the 6GB pool to the buddy allocator -- and
# re-acquiring 3072 order-9 pages on an already-fragmented phone is the exact thing the pool
# exists because you cannot do. A failed re-acquire leaves the device unable to start a VM
# until it reboots. These read the module's private state through kallsyms instead.
set -e
cd "$(dirname "$0")"
TAG=${1:-android15-6.6}
IMAGE=${IMAGE:-ghcr.io/ylarod/ddk-min}
mkdir -p out
cat > .exec.sh <<'INNER'
#!/bin/bash
set -e
CLANG_DIR=$(ls -d /opt/ddk/clang/clang-*); KMI=$(ls /opt/ddk/kdir/); KDIR="/opt/ddk/kdir/${KMI}"
export PATH="${CLANG_DIR}/bin:${PATH}"
B=/tmp/build; mkdir -p $B; cp /src/*.c $B/
: > $B/Makefile
for f in $B/*.c; do echo "obj-m += $(basename "${f%.c}").o" >> $B/Makefile; done
make -C "$KDIR" -j "$(nproc)" M="$B" ARCH=arm64 LLVM=1 LLVM_IAS=1 modules
for f in $B/*.ko; do llvm-strip -d "$f"; cp "$f" /out/; done
echo "OK ${KMI}"
INNER
chmod 755 .exec.sh
docker run --rm -v "$PWD:/src:ro" -v "$PWD/out:/out" "${IMAGE}:${TAG}" sh /src/.exec.sh
rm -f .exec.sh
ls -l out/
