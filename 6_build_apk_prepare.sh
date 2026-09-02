#!/bin/bash
# Pull the app + prebuilt-packing repos, then overlay the freshly built crosvm / EDK2 /
# gunyah-host-share / turnip artifacts into the local prebuilt root so 7_build_apk.sh packs
# them into the APK instead of the cloud prebuilts.
set -e
cd "$(dirname "$0")"
source ./lib_branch.sh
export DROIDVM_PREBUILT_COMPRESSION_LEVEL="${DROIDVM_PREBUILT_COMPRESSION_LEVEL:-1}"

# The app is the one repo whose stable branch is master, not droidvm (lib_branch.sh).
STABLE=master clone_at DroidVM https://github.com/Droid-VM/DroidVM.git
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
# A PLATFORM library in this directory is not dead weight, it is a shadow. The daemon launches
# crosvm with LD_LIBRARY_PATH pointing here, and that is searched before /system/lib64, so our
# copy answers for every consumer -- including the platform's own libraries, which we never
# built against and whose needs we cannot see.
#
# It has now cost twice. A stale libgui.so with the wrong Surface overloads made
# /system/lib64/libmediandk.so undlopenable and killed the H.264 encoder on every device. Then
# our libc++.so (2502 symbols, older than the platform's) hid std::__1::__hash_memory from
# /system/lib64/libaudiobase.so, and crosvm would not link at all on Android 17 -- while
# working on 13 through 16, because nothing on those versions needed the symbols we were
# hiding. That is the shape of this bug: it fires on the platform version you did not test,
# for a symbol your own code never asked for.
#
# The soong collect step drags these in as crosvm's DT_NEEDED, and every one of them is
# something the device already provides. The test applied to each: does anything in the
# payload need a symbol that OUR copy has and the platform's does not? For all eleven the
# answer is none -- so shipping them can only subtract. libvulkan_freedreno.so and the glib
# family stay, because those the platform genuinely does not have.
#
# Removing rather than not-copying, because the overlay only ever adds: a lib that stops being
# built lingers from an older payload, so a stale one has to be deleted here to be gone.
for so in libgui libaaudio libbinder_ndk libc++ libbase libcap libcutils liblog \
          libminijail libnativewindow libprocessgroup; do
    rm -f "$MB/usr/lib/$so.so"
done

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

# The app ships its own match.json as a fallback, and it is NOT a copy of the module repo's:
# it also carries GH-Hugepage-Reserve, which has no .ko to ride on, so the app's file is a
# superset and cannot simply be overwritten from here. That leaves it hand-maintained, and it
# had already fallen behind -- nproc_guard shipped as a .ko for weeks with no rule in the app's
# copy. The asymmetry is what makes that easy to miss: gunyah_host_mod's own build FAILS when a
# built module has no rule, while the app's copy going stale costs one silently absent card in
# the Kernel Module tab, with only a Log.w nobody reads.
#
# So: one-directional. Every module the module repo describes must appear in the app's copy;
# extra keys there are expected and fine.
if [ -f gunyah_host_mod/match.json ] && [ -f DroidVM/app/src/main/assets/match.json ]; then
    python3 - gunyah_host_mod/match.json DroidVM/app/src/main/assets/match.json <<'PY'
import json, sys
src, app = (json.load(open(p, encoding="utf-8"))["modules"] for p in sys.argv[1:3])
missing = [k for k in src if k not in app]
if missing:
    print(f">>> WARNING: app assets/match.json has no rule for {missing}", file=sys.stderr)
    print(">>>          those modules ship as .ko but the app will not list them when the", file=sys.stderr)
    print(">>>          device match.json is missing or unread. Add them to", file=sys.stderr)
    print(">>>          DroidVM/app/src/main/assets/match.json (keep gh_hugepage_reserve).", file=sys.stderr)
PY
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
