#!/bin/bash
# Pull the app + prebuilt-packing repos, then overlay the freshly built crosvm / EDK2 /
# gunyah-host-share / turnip artifacts into the local prebuilt root so 7_build_apk.sh packs
# them into the APK instead of the cloud prebuilts.
set -e
cd "$(dirname "$0")"
source ./lib_branch.sh

clone_at DroidVM https://github.com/Droid-VM/DroidVM.git
# Prebuilt root is the exception: always its main branch. The build overlays the
# freshly built crosvm/EDK2/gunyah/turnip on top (below), rather than tracking a dev branch.
[ -d DroidVM/DroidVM-Prebuilt-Root ] || git clone https://github.com/Droid-VM/DroidVM-Prebuilt-Root.git DroidVM/DroidVM-Prebuilt-Root


cd DroidVM/DroidVM-Prebuilt-Root
./auto-build.py
cd ../../.

MB=DroidVM/DroidVM-Prebuilt-Root/manual-build/arm64-v8a
mkdir -p "$MB/usr/bin" "$MB/usr/lib" "$MB/usr/share/droidvm"

# crosvm + its runtime libs (from 2_build_crosvm.sh)
if [ -f crosvm_out/crosvm ]; then
    cp -f crosvm_out/crosvm "$MB/usr/bin/crosvm"
    for so in crosvm_out/*.so; do cp -f "$so" "$MB/usr/lib/"; done
fi

# EDK2 firmware (built separately in edk2-gunyah: ./build.sh -DPCI_CAM_MODE=FALSE)
if [ -f edk2-gunyah/edk2-gunyah.fd ]; then
    cp -f edk2-gunyah/edk2-gunyah.fd      "$MB/usr/share/droidvm/edk2-gunyah.fd"
    cp -f edk2-gunyah/edk2-gunyah.vars.fd "$MB/usr/share/droidvm/edk2-gunyah.vars.fd"
fi

# Host GuestAccept module(s) (built by 4_build_gunyah_host.sh) -> manual-build so the APK
# ships them; the app's Kernel Module tab loads them from usr/lib/modules/<kmi>/.
# manual-build (not auto-build.toml): the .ko is a prebuilt we stage, not a cloned repo.
for kdir in gunyah_host_mod/dist/*/; do
    [ -d "$kdir" ] || continue
    kmi=$(basename "$kdir")
    for ko in "$kdir"*.ko; do
        [ -f "$ko" ] || continue
        mkdir -p "$MB/usr/lib/modules/$kmi"
        cp -f "$ko" "$MB/usr/lib/modules/$kmi/"
    done
done
# "Why is this needed" pages for those modules (staged by gunyah_host_mod/build.sh).
# The Kernel Module tab renders them in a WebView, reading them from
# usr/lib/modules/descr/<module-prefix>.html.
if [ -d gunyah_host_mod/dist/descr ]; then
    mkdir -p "$MB/usr/lib/modules/descr"
    cp -f gunyah_host_mod/dist/descr/*.html "$MB/usr/lib/modules/descr/"
fi

# Which devices each module is for. Without this the app falls back to its built-in
# rules, which only know the modules that existed when the app was built -- ship it
# alongside the .ko files so a module for a new SoC needs no app update.
if [ -f gunyah_host_mod/dist/match.json ]; then
    mkdir -p "$MB/usr/lib/modules"
    cp -f gunyah_host_mod/dist/match.json "$MB/usr/lib/modules/match.json"
fi

# The pages' stylesheet is app-side, not device-side: the app inlines its own copy
# into every page it renders, including the GH-Hugepage-Reserve page that ships in
# the APK (that module is not one of the .ko files, so it has no prebuilt to ride
# on). gunyah_host_mod owns the file; sync it so the two cannot drift. The app's
# copy is checked in too, so the APK still builds without this repo present.
if [ -f gunyah_host_mod/descr/style.css ]; then
    cp -f gunyah_host_mod/descr/style.css DroidVM/app/src/main/assets/descr/style.css
fi

# Host turnip Vulkan driver (built by 5_prepare_turnip.sh) -> manual-build. gfxstream needs
# it as its real GPU driver (ANDROID_EMU_VK_LOADER_PATH); without it host-visible coherent
# memory fails. -static-libstdc++, so no libc++_shared.so is needed alongside it.
if [ -f turnip/libvulkan_freedreno.so ]; then
    cp -f turnip/libvulkan_freedreno.so "$MB/usr/lib/libvulkan_freedreno.so"
fi
