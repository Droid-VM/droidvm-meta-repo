#!/bin/bash
# Provision a Linux guest for the DroidVM graphics stack, over ssh.
#
#   deploy/guest/provision.sh <ssh-target> [gfxstream|drm2kgsl|venus]
#   deploy/guest/provision.sh root@172.22.68.12 venus
#
# Installs the droidvm-guest-additions DKMS package (gunyah_guest + the patched virtio-gpu)
# and the mesa .deb. There is ONE mesa package now and it carries all three routes: it ships
# VK_DRIVER_FILES naming all three ICDs, and the Vulkan loader keeps whichever one enumerates
# a device -- the guest sees exactly one virtio-gpu capset, so exactly one answers. Nothing has
# to be installed or swapped per route.
#
# The optional route argument therefore selects nothing; it only says which driver the verify
# step should expect to see, so a mismatch is reported here rather than found later.
#
# Everything transferred is md5-verified on the far side. scp into this guest has been seen
# to truncate without reporting an error, and a half-copied .ko or .deb fails in ways that
# look like a code bug.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO=$PWD

TARGET=${1:?usage: provision.sh <ssh-target> [gfxstream|drm2kgsl|venus]}
ROUTE=${2:-}
# The package name and the ICD list live with the build recipe, in its own repo (cloned by
# step 1/8).
[ -f mesa-cross/mesa-config.sh ] || { echo "no mesa-cross/ -- run 1_build_crosvm_prepare.sh (or 8_build_guest_mesa.sh) first" >&2; exit 1; }
source ./mesa-cross/mesa-config.sh

case ${ROUTE:-gfxstream} in gfxstream|drm2kgsl|venus) ;; *) echo "unknown route: $ROUTE" >&2; exit 1 ;; esac

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

deb=$(ls -t "$REPO"/dist-guest/${MESA_PKG}_*_arm64.deb "$REPO"/${MESA_PKG}_*_arm64.deb 2>/dev/null | head -1)
[ -n "$deb" ] || { echo "no ${MESA_PKG} deb in $REPO/dist-guest -- run 8_build_guest_mesa.sh first" >&2; exit 1; }

step "target"
$SSH 'uname -srm; . /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"'

step "guest additions (DKMS)"
tar -czf /tmp/droidvm-ga.tar.gz -C "$REPO" --exclude=.git droidvm-guest-additions
put /tmp/droidvm-ga.tar.gz /tmp/droidvm-ga.tar.gz
rm -f /tmp/droidvm-ga.tar.gz
$SSH 'set -e; rm -rf /tmp/droidvm-ga && mkdir -p /tmp/droidvm-ga &&
      tar -xzf /tmp/droidvm-ga.tar.gz -C /tmp/droidvm-ga &&
      cd /tmp/droidvm-ga/droidvm-guest-additions && sudo ./install.sh'

step "mesa: $(basename "$deb")"
put "$deb" "/tmp/$(basename "$deb")"
# apt, not dpkg -i: a guest still holding one of the old per-route mesa-guest-<route> packages
# needs it REMOVED (Conflicts+Replaces), and dpkg -i would refuse instead.
$SSH "sudo apt-get install -y '/tmp/$(basename "$deb")'"

step "ICD"
icd=$(mesa_icd_list)
# The package writes its own marked block into /etc/environment from postinst, and three other
# channels besides (environment.d, profile.d, systemd system.conf.d). What is left to do here is
# strip any BARE line an older provision run appended outside that block: it would be read after
# the block and win, pinning the guest to whichever single ICD was current then.
$SSH "sudo sed -i '/^# BEGIN mesa-guest/,/^# END mesa-guest/!{/^VK_DRIVER_FILES=/d;/^VK_ICD_FILENAMES=/d;/^MESA_LOADER_DRIVER_OVERRIDE=/d}' /etc/environment"
# Every route needs this, not just the DRM one. The build is -Dgallium-drivers=zink, so it
# ships no virtio_gpu_dri.so -- and /usr/local's dri directory takes precedence over the
# distro's without falling back to it. Left unset, GNOME Shell asks the loader for the driver
# matching its DRM device, gets "virtio_gpu: driver missing", falls back to kms_swrast, and then
# fails outright with "Failed to setup: No GPUs found" -- so gdm retries the greeter until it
# gives up ("maximum number of display failures reached"). Vulkan is fine throughout, which makes
# it look like a gdm or a mesa-version problem rather than a missing GL driver.
$SSH 'grep -E "^VK_|^MESA_" /etc/environment'

step "verify"
$SSH "for f in \$(echo '$icd' | tr ':' ' '); do
        test -f \"\$f\" && echo \"  ok ICD \$(basename \"\$f\")\" || echo \"  !! ICD \$f missing\"
      done
      modinfo -F filename virtio_gpu 2>/dev/null | grep -q updates/dkms && echo '  ok virtio_gpu resolves to the DKMS build' || echo '  !! virtio_gpu is NOT the DKMS build'
      dpkg -l 'mesa-guest*' 2>/dev/null | awk '/^ii/{print \"  installed: \"\$2\" \"\$3}'"

cat <<EOF

Reboot the guest, then check from inside it:
    dmesg | grep -E 'gunyah_guest|GpuPool base|drm2kgsl_host'
    vulkaninfo | grep -E 'driverName|deviceName'
${ROUTE:+Expect driverName=$(case $ROUTE in drm2kgsl) echo turnip;; venus) echo venus;; *) echo gfxstream;; esac) for the $ROUTE route.}

If the patched virtio-gpu is loaded from the initrd rather than the rootfs, the module
must also be replaced inside the phone's initrd -- see deploy/SETUP.md, "initrd surgery".
EOF
