# soong-patches

Changes to AOSP projects inside `crosvm_build/` that are ours but do not belong
to any Droid-VM fork.

Five projects in that tree are Droid-VM forks and are checked out along the
branch chain (`lib_branch.sh: checkout_soong`). This one is not: `external/zstd`
is upstream AOSP with no fork of ours, and forking a whole repository to carry
two lines is a worse trade than carrying the two lines here — the same reasoning
`edk2-gunyah` uses for its patch overlay.

    external/zstd            libzstd's visibility list does not name crosvm, so
                             `disk`'s qcow2 zstd-cluster support fails soong
                             analysis with "depends on //external/zstd:libzstd
                             which is not visible to this module".

`external/libvncserver` used to be here too. It is a Droid-VM fork, so its change
belongs on a branch the chain can select, not in a patch: it now ships on that
fork's `wip/3d-accel` / `pr/3d-accel` and is listed in `checkout_soong`'s loop.

`1_build_crosvm_prepare.sh` applies these after `repo sync`, every run. A sync
resets the working tree, so re-applying is the normal path, not a repair:
`apply_soong_patches` treats "already applied" as success and only fails when a
patch neither applies nor is present.

To refresh one after upstream moves, regenerate rather than hand-edit:

    git -C crosvm_build/external/<p> format-patch -o soong-patches/external/<p> <base>..HEAD
