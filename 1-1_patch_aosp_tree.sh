#!/bin/bash
# Changes the crosvm build needs in AOSP projects that have no Droid-VM fork. Each is small and made in place, once; a
# `repo sync` of that project puts the original back, so 2_build_crosvm.sh runs this before every build.
#
#  - external/boringssl: crosvm's WebRTC display output (--webrtc-server) links its libdatachannel
#    (external/crosvm/third_party/libdatachannel) against libcrypto_static. That module's visibility list names every
#    user it has, and its apex_available list every APEX it may go into: crosvm is in com.android.virt.
set -e
cd "$(dirname "$0")"

BP=crosvm_build/external/boringssl/Android.bp
USER='"//external/crosvm/third_party/libdatachannel",'
APEX='"com.android.virt",'
if [ -f "$BP" ]; then
    python3 - "$BP" "$USER" "$APEX" <<'PY'
import sys
path, user, apex = sys.argv[1:]
text = open(path).read()
start = text.index('name: "libcrypto_static",\n')
end = text.index('\n}\n', start)
module = text[start:end]
changed = module
for key, item in (('visibility', user), ('apex_available', apex)):
    opening = f'    {key}: [\n'
    if changed.count(opening) != 1:
        sys.exit(f'{path}: libcrypto_static has no {key} list where this script expects it')
    if item not in changed:
        changed = changed.replace(opening, opening + f'        {item}\n')
        print(f'{path}: libcrypto_static {key} += {item}')
if changed != module:
    open(path, 'w').write(text[:start] + changed + text[end:])
PY
fi
