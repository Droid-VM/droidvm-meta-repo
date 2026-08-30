#!/bin/bash
# Build the EDK2 UEFI firmware (edk2-gunyah) that boots the Linux/Windows guests.
# Cloned at this meta repo's branch if not already present.
set -e
cd "$(dirname "$0")"
source ./lib_branch.sh

clone_at edk2-gunyah https://github.com/Droid-VM/edk2-gunyah.git
cd edk2-gunyah
./build.sh -DPCI_CAM_MODE=FALSE
