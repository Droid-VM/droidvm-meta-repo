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
