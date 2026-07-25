# DroidVM Linux guest — 從乾淨 Ubuntu 到可用 GPU 的設定手冊

> 目標:一台乾淨的 Ubuntu cloud image guest(qcow2)+ 手機端 crosvm,
> 走到兩條 GPU 路線任一可用:**kgsl pre-alloc**(guest 原生 turnip → /dev/kgsl-3d0)
> 或 **gfxstream runtime-host**(guest gfxstream ICD → host turnip)。
> 兩路線共用同一顆 crosvm / kernel / rootfs,由啟動參數與 guest 端 ICD 切換。

## 0. 共用基礎(兩條路線都要)

| 元件 | 來源 | 部署位置 |
|---|---|---|
| crosvm(fork,含 runtime_share/VmAccept/GpuPool) | `bash 2_build_crosvm.sh` → `crosvm_out/` | 手機 `/data/local/tmp/crosvm_kgsl/`、`/data/local/tmp/crosvm_gfx/`(**兩目錄各自帶 crosvm + libgfxstream_backend.so + libvirglrenderer.so,互不共用**) |
| gunyah host 模組(`gunyah_share_mod` → /dev/gunyah_share;`gh_hugepage_reserve`) | `bash 4_build_gunyah_host.sh` | 手機 kernel(裝置已刷) |
| guest kernel + 特製 initrd | DroidVM app cache(`/data/data/cn.classfun.droidvm/cache/boot/<uuid>/`) | 由 launcher 直接 `--initrd`/kernel 指定 |
| guest DKMS 模組包(`droidvm-guest-additions/`:gunyah_guest.ko + virtio-gpu.ko(kgsl_pt front)+ virtio_gunyah_accept.ko) | guest 內 dkms build,或 host build 後推入 | guest `/lib/modules/<k>/updates/dkms/` + **initrd surgery**(見下) |

**adb push 陷阱**:`/data/local/tmp/crosvm_*` 目錄是 root-owned,`adb push` 直推會
**假成功**(回報 pushed 但檔案沒變)。必須 push 到 `/data/local/tmp/xxx.new` 再
`su 0 cp`,完成後 `md5sum` 驗證。

**initrd surgery**(改 virtio-gpu.ko / 新增 kmod 後必做,否則開機載入的是 initrd 裡的舊模組):
手機的 initrd 是特製 zstd cpio(~42MB,含 `usr/lib/modules/<k>/updates/dkms/*.ko.zst`),
guest 沒有 cpio → host 端解包(`zstd -dc | cpio -idm`)、換 .ko(zstd 壓縮)、
`find . -print0 | cpio --null -o -H newc | zstd -19` 重打包、round-trip 驗證、推回。

**殺 crosvm 的正確姿勢**:`ps -ef | grep -w crosvm | grep -v grep | grep -v con.in | grep -v run_ubuntu`
找 PID(路徑含 "crosvm" 的無關行程要排除),`su 0 sh -c "kill -9 <pid>"`,殺後等 ~14s
讓 gh pool 回收;**同時只能有一個 crosvm**(兩個會搶 pool → ENOMEM)。
guest reboot 會直接殺死 crosvm(要重跑 launcher)。**手機不可重開機**(會清掉 app 建的 br-wifi)。

## 1. kgsl pre-alloc 路線

手機端:`deploy/kgsl/relaunch_kgsl.sh`(唯一正確版;舊 run_ubuntu_kgsl.sh 的
`gunyah[blob_mode=]`/`context-types=drm` 均已 stale)。要點:
- `--hypervisor gunyah`(無 blob_mode 尾巴)
- `--gpu backend=virglrenderer,context-types=virgl2:drm,...`(**virgl2 必須在**,
  否則 NO_VIRGL → CREATE_2D 失敗 → VNC 黑屏)
- env:`NCTX_KGSL_PT=1 NCTX_VRAM_MB=1024 NCTX_SHMEM_KB=64`(pool 大小;
  正式化後 pool 是 GpuPool purpose region,RAM 尾端、SHARE bless、大頁)

guest 端:
1. DKMS 模組包(front 提供 /dev/kgsl-3d0 + /dev/kgsl_dma_heap,`.mode=0666` 已內建)
2. `deploy/kgsl/kgsl_pt_setup.sh` → `/root/kgsl_pt_setup.sh` + `deploy/kgsl/kgsl-pt-setup.service`
   → `/etc/systemd/system/`(enable)。做 bind-mount /dev/kgsl_dma_heap → /dev/dma_heap/system
3. Vulkan ICD 指向 freedreno:`/etc/environment` 設
   `VK_DRIVER_FILES=/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json`(+ zink:
   `MESA_LOADER_DRIVER_OVERRIDE=zink`)
4. turnip 版本:lfdevs 26.2-gen8 系(a830 修正)。已知 turnip 原始碼 bug:
   kgsl+wayland WSI SIGBUS(uninitialised read),繞法 `MESA_VK_WSI_DEBUG=sw,linear`
   (代價:software present ~1/10 效能、tearing、linear buffer 吃 pool)

驗收階梯:VNC 有畫面 → vulkaninfo(Adreno 830)→ vkcube → vkmark → Minecraft。

## 2. gfxstream runtime-host 路線

手機端:`deploy/gfxstream/run_ubuntu_gfx.sh`(DIR=/data/local/tmp/crosvm_gfx)
- `--gpu backend=gfxstream,context-types=gfxstream-vulkan,...,vram-limit=2048,gunyah-pvm=true`
- host-visible blob 走 runtime_share + guest-accept(一律 `VmAccept::Sync`:host 端經 transport 驅動)
- **sync 變體** `run_ubuntu_gfx_sync.sh`:與主腳本等價(accept 一律由
  gunyah_guest.ko 的泛用 accept 裝置經 virtio transport 執行)

guest 端:
1. `/etc/environment` 的 ICD 指向 gfxstream:
   `VK_DRIVER_FILES=/usr/local/share/vulkan/icd.d/gfxstream_vk_icd.aarch64.json`
2. gfxstream guest ICD 來自 top-level `mesa/`(26.0.3+patches,`8_build_guest_mesa.sh`)
3. sync 模式需要 virtio_gunyah_accept.ko(DKMS 包內)已 depmod(rootfs 即可;
   virtio id 60 → udev coldplug 自動載入)

驗收:vulkaninfo → vkcube(無需 WSI 繞法)→ vkmark(VNC GNOME 內跑)。

## 3. 兩路線切換

啟動參數已分開(crosvm_kgsl vs crosvm_gfx 兩目錄兩 launcher)。guest 端唯一要動的
是 `/etc/environment` 的 ICD 行(kgsl=freedreno+zink,gfx=gfxstream),改完
`systemctl restart gdm` 生效。(規劃中:kernel cmdline `droidvm_gpu=` 標記 +
guest 開機 service 自動改寫,見 deploy/guest/。)

## 4. 已知缺口 / 待辦

- vkmark 只能在真 VNC GNOME session 跑(ssh 環境下它自己 early-crash,與 GPU 無關)
- kgsl 的 WSI UB 修復(上游 turnip bug)與 dmabuf zero-copy present 尚未做
- sync 模式 transport 已實作待驗證;Async 未實作
- CMDLINE_V2(`plans/CMDLINE_V2.md`)的 proxy=/vram= 語法未落地,NCTX_* env 仍在用
