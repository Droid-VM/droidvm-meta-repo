mkdir -p crosvm_build
cd crosvm_build
#repo init -u https://android.googlesource.com/platform/manifest -b android-16.0.0_r4
#rm -r external/crosvm/
#git clone git@github.com:Droid-VM/crosvm.git external/crosvm/
#git clone git@github.com:Droid-VM/libvncserver.git external/libnvcserver/

repo init -u https://github.com/Droid-VM/crosvm-minimal-manifest.git -b main -m crosvm-minimal.xml --depth 1
repo sync -c

cd ..

# Staging view for pushing to the Droid-VM org: the build-tree repos keep their
# single checkout inside crosvm_build (soong/nsjail can't follow out-of-tree
# symlinks, so the real dirs must stay here); the org-named folder next to this
# repo just symlinks into them.
STAGE="$(cd .. && pwd)/DroidVM_3daccel_gfxstream"
mkdir -p "$STAGE"
ln -sfn ../DroidVM_3d_accel/crosvm_build/external/crosvm            "$STAGE/crosvm"
ln -sfn ../DroidVM_3d_accel/crosvm_build/hardware/google/gfxstream  "$STAGE/gfxstream"
ln -sfn ../DroidVM_3d_accel/crosvm_build/external/virglrenderer     "$STAGE/virglrenderer"
