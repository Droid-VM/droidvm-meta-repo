#!/bin/bash
# Build the EDK2 UEFI firmware (edk2-gunyah) that boots the Linux/Windows guests.
# Cloned at this meta repo's branch if not already present.
set -e
cd "$(dirname "$0")"
BRANCH=$(git rev-parse --abbrev-ref HEAD)

[ -d edk2-gunyah ] || git clone -b "$BRANCH" https://github.com/Droid-VM/edk2-gunyah.git
cd edk2-gunyah
./build.sh -DPCI_CAM_MODE=FALSE
