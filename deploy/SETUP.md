# DroidVM Linux guest — 從乾淨 Ubuntu 到可用 GPU 的設定手冊

> 目標:一台乾淨的 Ubuntu cloud image guest(qcow2)+ 手機端 crosvm,
> 走到兩條 GPU 路線任一可用:**gfxstream**(guest gfxstream ICD → host turnip,
> 四種記憶體配置)或 **drm2kgsl native context**(guest 真 turnip → vdrm/virtio →
> host virglrenderer 的 DRM native context → KGSL)。
> 兩路線共用同一顆 crosvm / kernel / rootfs / DKMS,由啟動參數與 guest 端 ICD 切換。

## 0. 共用基礎(兩條路線都要)

| 元件 | 來源 | 部署位置 |
|---|---|---|
| crosvm(fork,含 runtime_share/VmAccept/GpuPool/Drm2KgslPool) | `bash 2_build_crosvm.sh` → `crosvm_out/` | 手機 `/data/local/tmp/crosvm_gfx/`、`/data/local/tmp/crosvm_drm2kgsl/`(**兩目錄各自帶 crosvm + libgfxstream_backend.so + libvirglrenderer.so,互不共用**) |
| gunyah host 模組(host-share / kvcalloc / gh_unmovable / udmabuf) | `bash 4_build_gunyah_host.sh` → `gunyah_host_mod/dist/<kmi>/` | APK 打包進 `usr/lib/modules/<kmi>/`,由 app 的 Kernel Module 分頁載入 |
| 大頁保留模組 `gh_hugepage_reserve` | 獨立 repo(`../gh-hugepage-reserve`),**不在 4_ 腳本內** | 手機開機早期載入 |
| guest kernel + 特製 initrd | DroidVM app cache(`/data/data/cn.classfun.droidvm/cache/boot/<uuid>/`) | 由 launcher 直接 `--initrd`/kernel 指定 |
| guest DKMS 模組包(`droidvm-guest-additions/`:`gunyah_guest.ko` + patched `virtio-gpu.ko`) | guest 內 dkms build,或 host build 後推入 | guest `/lib/modules/<k>/updates/dkms/` + **initrd surgery**(見下) |

`gunyah_guest.ko` 同時提供 RM `mem_accept` 與 `VmAccept::Sync` 的 virtio accept 裝置
(不再是獨立的 `virtio_gunyah_accept.ko`)。

**adb push 陷阱**:`/data/local/tmp/crosvm_*` 目錄是 root-owned,`adb push` 直推會
**假成功**(回報 pushed 但檔案沒變)。必須 push 到 `/data/local/tmp/xxx.new` 再
`su 0 cp`,完成後 `md5sum` 驗證。`deploy/gfxstream/bringup.sh` 已自動做這件事,
且**三個檔都驗**:`crosvm`、`libgfxstream_backend.so`、`libvirglrenderer.so`。
最後一個容易被忘記,但它是 crosvm 的 `DT_NEEDED`——舊的 .so 會讓 crosvm 在 exec
就失敗,**五種配置一起死**,不是只有 drm2kgsl。

**initrd surgery**(改 virtio-gpu.ko / 新增 kmod 後必做,否則開機載入的是 initrd 裡的舊模組):
手機的 initrd 是特製 zstd cpio(~42MB,含 `usr/lib/modules/<k>/updates/dkms/*.ko.zst`),
guest 沒有 cpio → host 端解包(`zstd -dc | cpio -idm`)、換 .ko(zstd 壓縮)、
`find . -print0 | cpio --null -o -H newc | zstd -19` 重打包、round-trip 驗證、推回。

**關 crosvm 的正確姿勢**:guest 內 `systemctl poweroff`,或 `deploy/gfxstream/harness/vm_restart.sh`。
**絕對不要 `kill -9`**:被 kill 的 crosvm 會洩漏 RM memparcel,一路吃掉配額直到**手機重開**,
之後偽裝成「並發 memparcel 上限」的假故障。真的卡死時只有 `kill -TERM` 可用。
**同時只能有一個 crosvm**(兩個會搶 pool → ENOMEM)。guest reboot 會直接殺死 crosvm
(要重跑 launcher)。**手機不可重開機**(會清掉 app 建的 br-wifi)。

**`ulimit -l unlimited`**:crosvm 現在會拒絕 SHARE 一個 mlock 不起來的 pool
(沒 pin 的頁可能被 host kernel 搬走,而 RM 的 stage-2 永遠不會更新)。五個 launcher
都已內建這行;若啟動時看到 `could not be mlocked`,先查這個。

## 1. gfxstream 路線(四種記憶體配置)

手機端 launcher 都在 `deploy/gfxstream/`,`DIR=/data/local/tmp/crosvm_gfx`:

| 配置 | launcher / 旗標 | 期望的 host log 特徵 |
|---|---|---|
| 純 pre-alloc | `run_ubuntu_gfx_prealloc.sh`(`--pre-alloc gfx-host-mb=1024`,無 vram-limit,無 udmabuf) | 有 GFXPOOL 配置行,**零** GUNYAH-SHARE-BLOB 行 |
| fusion | 同上 + `vram-limit=2048,pool-blob-max-kb=4096` | 兩種都有,in-flight parcel 有上限 |
| 純 runtime-share | `run_ubuntu_gfx.sh`(無 `--pre-alloc`、環境無 `NCTX_GFX_POOL_MB`) | 只有 SHARE 行。RM 的 ~39 parcel 天花板是**這個配置的已知極限,不是回歸** |
| guest-alloc | `--pre-alloc gfx-host-mb=256,gfx-guest-mb=1024` + `udmabuf=true` | guest dmesg `has_create_guest_handle=1` + drm_buddy pool 行 |

共通:`--gpu backend=gfxstream,context-types=gfxstream-vulkan,...,gunyah-pvm=true`,
host-visible blob 的 accept 一律 `VmAccept::Sync`(host 端經 transport 驅動 guest accept)。

guest 端:
1. ICD 指向 gfxstream:`VK_DRIVER_FILES=/usr/local/share/vulkan/icd.d/gfxstream_vk_icd.aarch64.json`
2. guest ICD 來自 `mesa` 的 `wip/3d-accel-gfxstream` 分支(26.0.3+patches),
   `bash 8_build_guest_mesa_gfx.sh` 產出 `mesa-guest-gfxstream_<ver>_arm64.deb`,
   `sudo apt install ./mesa-guest-gfxstream_<ver>_arm64.deb`(prefix `/usr/local`)
3. **guest ICD 與 host decoder 是同一份 codebase,版本必須一致**。混到別的版本時
   症狀是 VNC 全黑(mutter 是經 gallium 合成,不是經 Vulkan ICD),而且 git bisect 查不到。

驗收:vulkaninfo → vkcube → vkmark(要在真 VNC GNOME session 裡跑)→ Minecraft。

## 2. drm2kgsl native context 路線

手機端:`deploy/drm2kgsl/run_drm2kgsl_nctx.sh`(`DIR=/data/local/tmp/crosvm_drm2kgsl`)。要點:
- `--gpu backend=virglrenderer,context-types=virgl2:drm,...`(**virgl2 必須在**,
  否則 virgl renderer 根本沒初始化 → CREATE_2D ComponentError(22) → VNC 黑屏)
- `--pre-alloc drm-host-mb=8`:boot-blessed 的 `Drm2KgslPool` purpose region,
  virglrenderer 的 drm2kgsl backend 從裡面切每一個 BO。拿掉就退回 runtime-share。
- `CROSVM_DRM2KGSL_DIAG=0`:drm2kgsl backend 的診斷計數器**預設開啟且每筆走 `ANDROID_LOG_ERROR`**,
  任何 drm2kgsl 效能數字採信前先確認它是關的。
- 不用 `vram-limit` / `gunyah-pvm`(兩個都是 gfxstream 專屬的消費者)

guest 端:
1. 同一份 DKMS(不需要同事的 kernel fork;他那條分支的 8 個 commit 裡只有 2 個是新的,
   arena offset 那個已被我們的 `pool_offset` wire 取代,display source release 尚未採用)
2. ICD 指向 freedreno:`VK_DRIVER_FILES=/usr/local/share/vulkan/icd.d/freedreno_icd.aarch64.json`
   +(zink)`MESA_LOADER_DRIVER_OVERRIDE=zink`
3. drm2kgsl mesa 來自 `mesa` 的 `wip/3d-accel-drm2kgsl` 分支(26.3.0-devel,含 tu/virtio 工作),
   `bash 8_build_guest_mesa_drm2kgsl.sh` → `mesa-guest-drm2kgsl_<ver>_arm64.deb`,
   `sudo apt install ./mesa-guest-drm2kgsl_<ver>_arm64.deb`(prefix `/usr/local`)

驗收階梯:VNC 有畫面 → `vulkaninfo` 顯示 driverName=turnip(經 vdrm)→ vkcube → vkmark → Minecraft。

## 3. 兩路線切換

啟動參數已分開(`crosvm_gfx` vs `crosvm_drm2kgsl` 兩目錄兩 launcher)。guest 端**一台 VM 裝一份 mesa**:
兩個 deb 都裝在 `/usr/local`,並透過共用的 `mesa-guest` 虛擬名稱互相 `Conflicts`,
所以同一台 VM 裝第二個時 dpkg 會直接拒絕。切換 = `apt remove` 舊的、裝新的,再改
`/etc/environment` 的 `VK_DRIVER_FILES`,`systemctl restart gdm` 生效。

**為什麼要靠 dpkg 擋而不是直接解 tarball**:兩邊都提供 libgallium / libEGL / ICD manifest,
而桌面合成走的是 gallium 不是 Vulkan ICD。直接解壓會讓桌面吃到後解壓的那一份 libgallium,
症狀是全黑的 VNC scanout 且沒有任何錯誤訊息——這個坑已經踩過一次,而且 git bisect 查不到。

## 4. 已知缺口 / 待辦

- vkmark 只能在真 VNC GNOME session 跑(ssh 環境下它自己 early-crash,與 GPU 無關)
- drm2kgsl 的 `VIRTIO_GPU_F_DISPLAY_SOURCE_RELEASE`(fenced RESOURCE_FLUSH,ring 63)尚未採用:
  crosvm 側 `9f5dc46` 會開兩條 thread 跑無 timeout 的 `poll(fd, -1)`,卡住只能 kill -9,
  而 kill -9 會洩漏 memparcel。要用之前得先補 timeout。
- drm2kgsl 沒有 guest-alloc 路徑(vdrm 只發 `VIRTIO_GPU_BLOB_MEM_HOST3D`,virgl 的
  `BLOB_MEM_GUEST` 進不了 DRM context);要做得改 msm_proto 協議,見 `plans/ARENA_V2_PLAN.md`
- `deploy/gfxstream/` 的五個 launcher 有大量重複段落(tap/bridge/記憶體準備),尚未抽共用
