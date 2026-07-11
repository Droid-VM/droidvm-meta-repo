mkdir -p crosvm_build
cd crosvm_build
#repo init -u https://android.googlesource.com/platform/manifest -b android-16.0.0_r4
#rm -r external/crosvm/
#git clone git@github.com:Droid-VM/crosvm.git external/crosvm/
#git clone git@github.com:Droid-VM/libvncserver.git external/libnvcserver/

repo init -u https://github.com/Droid-VM/crosvm-minimal-manifest.git -b main -m crosvm-minimal.xml --depth 1
repo sync -c

cd ..
