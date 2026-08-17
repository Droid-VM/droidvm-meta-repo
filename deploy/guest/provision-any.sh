#!/bin/bash
# Provision one Linux guest for ONE graphics route, over ssh.
#
#   deploy/guest/provision.sh <ssh-target> <gfxstream|drm2kgsl>
#   deploy/guest/provision.sh root@172.22.68.12 gfxstream
#
# Installs the droidvm-guest-additions DKMS package (gunyah_guest + the patched
# virtio-gpu) and that route's mesa .deb, then points /etc/environment at the matching
# Vulkan ICD. A guest holds one route at a time: the two mesa packages install to the same
# prefix and Conflict, so apt refuses the second rather than replacing the first one's
# libgallium behind your back.
#
# Everything transferred is md5-verified on the far side. scp into this guest has been seen
# to truncate without reporting an error, and a half-copied .ko or .deb fails in ways that
# look like a code bug.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO=$PWD

TARGET=${1:?usage: provision.sh <ssh-target> <gfxstream|drm2kgsl>}
VARIANT=${2:?usage: provision.sh <ssh-target> <gfxstream|drm2kgsl>}
# Package names and ICD paths live with the build recipe, in its own repo (cloned by step 1/8).
[ -f mesa-cross/mesa-variants.sh ] || { echo "no mesa-cross/ -- run 1_build_crosvm_prepare.sh (or a step-8 build) first" >&2; exit 1; }
source ./mesa-cross/mesa-variants.sh

case $VARIANT in gfxstream|drm2kgsl|venus) ;; *) echo "unknown variant: $VARIANT" >&2; exit 1 ;; esac

SSH="ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=no $TARGET"
step() { echo "--- $* ---"; }

# put <local> <remote> -- copy and verify. Returns non-zero if the far side differs.
put() {
    local src=$1 dst=$2 want got
    want=$(md5sum "$src" | awk '{print $1}')
    scp -q -o ConnectTimeout=15 -o StrictHostKeyChecking=no "$src" "$TARGET:$dst"
    got=$($SSH "md5sum '$dst'" | awk '{print $1}')
    [ "$want" = "$got" ] || { echo "  !! $dst md5 $got != $want (truncated transfer)" >&2; return 1; }
    echo "  ok $dst"
}

deb=$(ls -t "$REPO"/$(mesa_variant_pkg "$VARIANT")_*_arm64.deb 2>/dev/null | head -1)
[ -n "$deb" ] || { echo "no $(mesa_variant_pkg "$VARIANT") deb in $REPO -- run 8_build_guest_mesa_$([ "$VARIANT" = gfxstream ] && echo gfx || echo drm2kgsl).sh first" >&2; exit 1; }

step "target"
$SSH 'uname -srm; . /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"'

step "guest additions (DKMS)"
tar -czf /tmp/droidvm-ga.tar.gz -C "$REPO" --exclude=.git droidvm-guest-additions
put /tmp/droidvm-ga.tar.gz /tmp/droidvm-ga.tar.gz
rm -f /tmp/droidvm-ga.tar.gz
$SSH 'set -e; rm -rf /tmp/droidvm-ga && mkdir -p /tmp/droidvm-ga &&
      tar -xzf /tmp/droidvm-ga.tar.gz -C /tmp/droidvm-ga &&
      cd /tmp/droidvm-ga/droidvm-guest-additions && sudo ./install.sh'

step "mesa ($VARIANT): $(basename "$deb")"
put "$deb" "/tmp/$(basename "$deb")"
# apt, not dpkg -i: this is where a guest still holding the other route's mesa is told so.
$SSH "sudo apt-get install -y '/tmp/$(basename "$deb")'"

step "ICD"
icd=$(mesa_variant_icd "$VARIANT")
$SSH "sudo sed -i '/^VK_DRIVER_FILES=/d;/^VK_ICD_FILENAMES=/d;/^MESA_LOADER_DRIVER_OVERRIDE=/d' /etc/environment
      echo 'VK_DRIVER_FILES=$icd'    | sudo tee -a /etc/environment >/dev/null
      echo 'VK_ICD_FILENAMES=$icd'   | sudo tee -a /etc/environment >/dev/null"
# BOTH variants need this, not just the DRM one. Both are built -Dgallium-drivers=zink, so
# neither ships virtio_gpu_dri.so -- and /usr/local's dri directory takes precedence over the
# distro's without falling back to it. Left unset, GNOME Shell asks the loader for the driver
# matching its DRM device, gets "virtio_gpu: driver missing", falls back to kms_swrast, and then
# fails outright with "Failed to setup: No GPUs found" -- so gdm retries the greeter until it
# gives up ("maximum number of display failures reached"). Vulkan is fine throughout, which makes
# it look like a gdm or a mesa-version problem rather than a missing GL driver.
$SSH "echo 'MESA_LOADER_DRIVER_OVERRIDE=zink' | sudo tee -a /etc/environment >/dev/null"
$SSH 'grep -E "^VK_|^MESA_" /etc/environment'

step "verify"
$SSH "test -f '$icd' && echo '  ok ICD present' || echo '  !! ICD $icd missing'
      modinfo -F filename virtio_gpu 2>/dev/null | grep -q updates/dkms && echo '  ok virtio_gpu resolves to the DKMS build' || echo '  !! virtio_gpu is NOT the DKMS build'
      dpkg -l 'mesa-guest-*' 2>/dev/null | awk '/^ii/{print \"  installed: \"\$2\" \"\$3}'"

cat <<EOF

Reboot the guest, then check from inside it:
    dmesg | grep -E 'gunyah_guest|GpuPool base|drm2kgsl_host'
    vulkaninfo | grep -E 'driverName|deviceName'
Expect driverName=$([ "$VARIANT" = drm2kgsl ] && echo turnip || echo gfxstream).

If the patched virtio-gpu is loaded from the initrd rather than the rootfs, the module
must also be replaced inside the phone's initrd -- see deploy/SETUP.md, "initrd surgery".
EOF
