# DroidVM 3D-accel — crosvm 啟動參數 reference

現行 3D 版 **dev** 啟動(裝置上 `/data/local/tmp/start_ga_folio.sh`)的 crosvm 呼叫全解。
這是 **direct-kernel + GPU + VNC** 的開發配置。量產 app 走 **UEFI + 無 GPU**,差異見末節。

> ⚠️ 這是 reference,不是 source of truth。實際腳本在裝置上;改任何一項先確認與此同步。

---

## 0. 啟動前 host 準備(手機端)

```sh
echo 3 > /proc/sys/vm/drop_caches       # 清 page cache
echo 1 > /proc/sys/vm/compact_memory    # 湊連續實體頁(給 folio / hugepage)
echo 3 > /proc/sys/vm/drop_caches
echo 4096 > /sys/module/udmabuf/parameters/size_limit_mb   # 解除 udmabuf 預設 64MB/handle 上限 → blob 可到 4GB
```

## 1. 環境變數(3D 承重)

| 變數 | 值 | 作用 |
|---|---|---|
| `ANDROID_EMU_VK_LOADER_PATH` | `/data/local/tmp/turnip/libvulkan_freedreno.so` | host turnip ICD(gfxstream 後端的真 GPU driver) |
| `LD_LIBRARY_PATH` | `/data/local/tmp/turnip:...` | turnip 相依庫 |
| `GFXSTREAM_GUNYAH_PIN_RINGBLOB` | `1` | ASG ring blob 回收池:pin 住不 free,同大小重用同實體頁(Gunyah SHARE 的 GPA 不可重指) |
| `GFXSTREAM_DEVICE_LOCAL_MEMORY_TYPE` | `1` | 暴露 device-local shadow memory type |
| `GFXSTREAM_ARENA_MB` | `2048` | host-visible folio 背書預算(order-9 池,吃 VM reserve 額度) |
| `GFXSTREAM_LOG_LEVEL` | `info` | gfxstream log level |

```sh
VM_MEM_MB=4096
CROSVM_ROOT=/data/local/tmp/crosvm_out
SOCK=/data/local/tmp/crosvm_gav.sock
KERNEL=/data/data/cn.classfun.droidvm/cache/boot/526795fd-0bbf-43d6-976e-287b43f75a80/kernel   # 快取 raw arm64 Image
INITRD=/data/data/cn.classfun.droidvm/cache/boot/526795fd-0bbf-43d6-976e-287b43f75a80/initrd
DISK=/storage/emulated/0/DroidVM/ubuntu-resolute-cloud-arm64-20260615_0742.qcow2
```

## 2. crosvm 命令

```sh
GFXSTREAM_LOG_LEVEL=info GFXSTREAM_ARENA_MB=2048 $CROSVM_ROOT/crosvm --log-level debug run \
  --disable-sandbox \
  --hugepages \                              # guest RAM 用大頁
  --prepare-lend-mthp-mode chunked \         # ★mlock guest RAM(不加 → host reclaim guest 頁 → SIGBUS/隨機掛)
  --no-balloon \
  --protected-vm-without-firmware \          # protected VM,direct-kernel(無 EDK2)
  --hypervisor "gunyah[blob_mode=guest-accept]" \  # ★GuestAccept:host SHARE + guest mem_accept
  --serial hardware=serial,num=1,type=stdout,earlycon=true \
  --vnc-server port=5900,input=tablet \      # 顯示 + 輸入(絕對座標 tablet 指標)
  --gpu='backend=gfxstream,context-types=gfxstream-vulkan,vulkan=true,gles=true,pci-bar-size=0x100000000,displays=[[mode=windowed[1920,1080],dpi=[320,320],refresh-rate=60]]' \
  --swiotlb 128 \                            # protected VM bounce buffer
  --params 'console=tty1 keep_bootcon root=/dev/vda2 rd.driver.blacklist=virtio_gpu modprobe.blacklist=virtio_gpu' \
  --initrd $INITRD \
  --mem 4096 --cpus 4 \
  -s $SOCK \
  --net tap-name=crosvm_ostap \
  --serial type=stdout,hardware=virtio-console,console=true \
  -b $DISK,lock=false \
  $KERNEL &
```

## 3. `--gpu=` 拆解(3D 核心)

| 子項 | 作用 |
|---|---|
| `backend=gfxstream` | gfxstream renderer(非 virglrenderer) |
| `context-types=gfxstream-vulkan` | Vulkan context type |
| `vulkan=true,gles=true` | VK + GL(zink)都開 |
| `pci-bar-size=0x100000000` | **4GB host-visible BAR** = GPU 記憶體天花板(guest 無 device-local-only type,故上限=BAR) |
| `displays=[[mode=windowed[1920,1080],dpi=[320,320],refresh-rate=60]]` | 1080p windowed |

## 4. 承重旗標(漏了會壞)

1. `--hypervisor "gunyah[blob_mode=guest-accept]"` — GuestAccept 路(host `gunyah_share_66` SHARE + guest `gunyah_guest` mem_accept)。
2. `--prepare-lend-mthp-mode chunked` — **mlock guest RAM**;漏了 host 會 reclaim guest 頁 → 隨機 SIGBUS/掛。
3. `--gpu backend=gfxstream ... pci-bar-size=0x100000000` — 4GB host-visible BAR。
4. host 端 `udmabuf size_limit_mb=4096` — 不設則 blob import 被 64MB 卡死。

## 5. dev vs 量產 app 差異

| | dev(本檔) | 量產 app |
|---|---|---|
| 開機 | direct-kernel:`--protected-vm-without-firmware $KERNEL --initrd`(快取 raw Image) | **UEFI**:EDK2 → GRUB → 磁碟 `/boot` vmlinuz+initrd |
| GPU | `--gpu backend=gfxstream ...` | **無 GPU**(virtio-gpu 載入但 idle,不 crash — 已硬化) |
| 顯示 | `--vnc-server` | Android SurfaceView(`gpu_display_android`) |
| virtio-gpu 驅動 | `--params` 用 blacklist 擋 in-tree,好讓魔改版載 | 靠 DKMS `updates/dkms` 對 in-tree 的優先權自動載(blacklist 可省) |

> 量產 app 走 UEFI 開機需磁碟 `/boot/initrd.img-<ver>` 正常(曾遇 2MB 壞 initrd → kernel panic,`update-initramfs -u` 修)。
