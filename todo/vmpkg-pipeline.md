# 構建流水線：原始碼 → App 可直接匯入的 vmpkg

2026-11-21。使用者：「幫我整理一下 xnu 這邊 guest os 有關的有哪些倉庫？我想整理一下構建流程，整理一份構建流水線最終產出
vmpkg 可以直接 app 匯入使用。流水線過程可以指定 ios/macos 版本，設備類型（ipad 還是 iphone 還是 macbook）」

第 1 節是倉庫清單，第 2 節是現在的流程和它離「App 匯入」還差什麼，第 3–5 節是設計與 vmpkg 格式，第 6–7 節是 App 端要補的與還沒驗證的，
第 8 節是分階段的做法，第 9 節是要使用者決定的事。建置樹、rig 與 17／27 兩條線的現況見 [builds.md](builds.md)（第 2–3 節）。

## 1. XNU guest 相關的倉庫

### 1.1 我們維護的（Droid-VM 組織）

工作分支都是 `wip/hackintosh`；ownervisor、applebox 是 `main`。本機 clone 都在 `/root/gitrs/UniXNU/` 下。

| 倉庫 | 在流水線裡做什麼 | 本機 clone |
|---|---|---|
| Droid-VM/UniXNU（UniXNU/UniXNU 的 fork） | 建置系統 `unixnu`、XNU 補丁、OS profile（`profiles/os/*`）、GPU userland 的建置腳本（Turnip、metal2vulkan、Metal plugin），以及下面這些 submodule 的 pin | `orgrepos/UniXNU-m1101` |
| Droid-VM/UniXNU-droidvm（裝置 repo） | DroidVM 這塊「板子」：根目錄是 iPadOS 17 的 board，`ipados27/` 是 iPadOS 27 與 macOS 27 的 board；板級驅動 `package/`、整條建置 `ipados27/scripts/build-droidvm-all.py`、rig 工具 `tools/rig/` | `UniXNU-droidvm-main` |
| Droid-VM/DarwinBoot（fork 的 `drivers/DarwinBoot`） | UEFI 載入器：從韌體的 FDT 生成 ADT（RAM、裝置、CPU 叢集、PCIe 主橋） | `orgrepos/DarwinBoot-rebase` |
| Droid-VM/ArmCpu（`drivers/ArmCpu`） | CPU、中斷控制器、IPI、MSI | `orgrepos/ArmCpu` |
| Droid-VM/NativeMetal（`drivers/AdrenoMetal`） | Metal plugin：AdrenoMetal 前端加 metal2vulkan 橋 | `orgrepos/NativeMetal-rebase` |
| Droid-VM/NativeAdreno（GitHub 上叫 Adreno740，`drivers/Adreno740`） | GPU 的 kernel 端（user client、surface、execbuf）；刻意停在 627836d | `orgrepos/NativeAdreno-rebase` |
| Droid-VM/NativeMobileDisplay（`drivers/GopFramebuffer`） | 顯示：GOP framebuffer 後端 | `orgrepos/NativeMobileDisplay-rebase` |
| Droid-VM/ownervisor | 除錯 shell：服務管理、ssh、debugserver、libimobiledevice；裝置 repo 的 `feeds.toml` 釘 commit | `orgrepos/ownervisor` |
| Droid-VM/applebox | Apple 開源指令的多合一執行檔；ownervisor 釘它 | `orgrepos/applebox` |

### 1.2 直接用上游的（UniXNU 組織，fork 的 submodule）

- `drivers/`：ArmDTPlatform、ArmVirtPlatform、SoftwareAES、QcomGeniSpi、AppleKeyStoreState、RamBlock、VirtioMmioBlock、VirtioMmioConsole。
- `kits/`：AdrenoFirmware、AdrenoPM4、AirNir、ArmSmmu4K、XnuPrelink、VerifiedRoot。
- UniXNU/ShengHidInput：iPadOS 17 的 HID 驅動，由裝置 repo 根目錄的 `feeds.toml` 釘。

### 1.3 建置時才抓、釘在腳本裡的外部來源

- apple-oss-distributions：xnu（12377.121.6，ac9718f）、libpthread、libplatform、libdispatch、AvailabilityVersions、IOHIDFamily、
  IOStorageFamily、Libc、bootstrap_cmds。
- Mesa（gitlab.freedesktop.org；Turnip 的 Darwin 層是 fork 裡的補丁）與 metal2vulkan（steelbrain/metal2vulkan 555b13d5，加 fork 的補丁）：
  pin 在 fork 的腳本資料裡，每次建置實際用的 commit 記在 `release.json` 的 `gpu_sources`。
- Apple 的 IPSW（OS profile 裡的 URL）：kernelcache、DeviceTree、OS／SystemOS／App 映像、trust cache。

### 1.4 相關、但不在這條流水線裡的

- **Droid-VM/macOS-DroidVM**：另一位貢獻者的 macOS 27 線，有自己的 KC 連結器（`k27/`）與建置腳本，以「釘 commit 加補丁」的方式吃我們的原始碼。
  我們的 macOS 從 11-14 起改由上面這套流程建；它要不要改吃我們的原始碼，是 [kernel-unify.md](kernel-unify.md) 的第 5 步，要使用者決定。
- **Droid-VM/gfxbench**：guest 裡用的測試 App（IPA），不進 vmpkg。
- **host 端**（vmpkg 跑在它上面，不屬於 guest）：Droid-VM/DroidVM（App，匯入 vmpkg 的就是它）、crosvm、edk2-gunyah（UEFI 韌體），以及
  DroidVM-Prebuilt-Root → DroidVM-Prebuilts（App 第一次執行時解出來的 runtime）。

## 2. 現在的流程，以及它離「App 匯入」還差什麼

**現在**：Mac 上跑 `ipados27/scripts/build-droidvm-all.py --os <profile> --unique-chip-id … [--generation DIR]`（setup → … → release
共 10 步），產生 `release/`。rig 的 `deploy27.sh` 用 adb 把檔案推上手機，`--new-vm` 再透過 daemon IPC 建 VM。所以「VM 怎麼設定」只存在 rig
的 json 裡，手機上的檔案是腳本擺好的。

`release/` 的內容（11-18 的兩個 release）：

| 檔案 | iPadOS 27 | macOS 27 |
|---|---|---|
| `droidvm-disk.img`：開機碟（UniXNU.efi、DarwinBoot.efi、KC、ADT、trust、root policy、Data seed） | 320 MiB | 640 MiB |
| `os.img`（唯讀） | 9.0 GiB | 13.2 GiB |
| `systemos.img`（唯讀） | 5.6 GiB | 2.7 GiB |
| `app.img`（唯讀，macOS 的 App cryptex） | — | 52 MiB |
| `kernel.macho`、`kernel.native.macho`、`kexts.json`：符號，不進 VM | | |
| `plugin/`（給沿用舊 Data 的 VM）、`release.json`（每個 commit 與雜湊） | | |

**還差的**：

1. **沒有 vmpkg 輸出。**
2. **VM 設定搬不走。** rig 的設定把 OS 映像和 Data store 寫在 `extra_options`（`--virtio-mmio-block /data/media/0/…`），不是 `disks`；
   音訊、media 的 `uid=` 也寫死。App 匯出只帶 `disks` 和韌體，匯入也只重寫這兩者的路徑：照現在的設定打包，換一支手機就找不到磁碟。
3. **Data store 是在手機上生的**（`make-data-store.sh`：16–32 GiB 的稀疏檔，block 0 是標籤）。放進 vmpkg 壓縮後幾乎不佔空間，
   但 App 匯入是逐 byte 寫出（`VMImportTask.copyEntry` 不跳過全 0 的區塊），手機會真的被寫掉 16–32 GiB。
4. **韌體**：5566 上 iPadOS VM 用另外放的 `edk2-virtio-gpu.fd`，macOS VM 用 App 內建的；App 內建的 edk2 是 09-09 的。
5. **App 附帶的 runtime 太舊**（11-19 查到）：crosvm 是 10-27 的，沒有 `--virtio-mmio-snd`、`--virtio-mmio-console`、`--virtio-mmio-media`、
   `--mbi-spis`。所以 MMIO 音訊、media 的 vmpkg 在「只裝了 App」的手機上開不起來；我們的手機能跑，是因為手動換過 binary。
   **這是 vmpkg 能不能給別人用的前提**（第 9 節第 1 點）。
6. **unique chip id**（`--unique-chip-id`，平台 seed）現在每個 rig 一個。vmpkg 要嘛每次建置隨機產生，要嘛固定一個；同一個 vmpkg 匯入幾次，
   這些 VM 的 chip id 都一樣。
7. **macOS 的 Data seed 要 root 權限才做得出來**：Mac 上沒有免密碼 sudo，現在是在 lima 裡做。
8. 小問題：macOS release 的 `release.json` 的 `board` 欄位寫成 iPadOS 的 profile（取的是 board.toml 的預設 `os_profile`，不是 `--os`）。

## 3. 流水線的參數

```
build-vmpkg.py --os <OS profile，或簡寫如 ipados-27.0.1、macos-27.0.1> --device <ipad|iphone|mac>
               [--name 名稱] [--screen 2048x2732@120] [--memory-mb 5120] [--cpus 6] [--data-gib 16]
               [--unique-chip-id HEX|random] [--firmware FD] [--debug-shell on|off] [--volume-mib 500] [--out DIR]
```

- `--os` 選 fork 的 OS profile，決定 IPSW、XNU 版本與補丁。`--device` 選「機型 profile」：產品型號、device class、chip id、ADT 身分、
  預設畫面與縮放、Data seed 的偏好設定，以及綁在那一版 build 上的人工資料。
- 兩者合起來對到裝置 repo 的一個 board 目錄；不支援的組合直接拒絕，並印出缺了什麼。

目前有哪些組合：

| | 17.7.11 | 26.5.2 | 27.0.1 |
|---|---|---|---|
| `ipad` | iPad7,1（17 的 board；10-29 之後沒建過，狀態不明） | 上游有 profile（iPad17,3），我們沒建過 | ✅ iPad17,3 J820AP（主線） |
| `iphone` | — | — | ❌ 沒做。上游社群的裝置 repo 有 iOS 27.0.1（24A446）的 iPhone profile（iPhone17,1），目前只有一個登記為 `available` |
| `mac` | — | — | ✅ VirtualMac2,1（macOS 27.0.1，26A434）；上游另有 macos-27.3-26C5035r |

**關於「macbook」**：現在 macOS 的身分是 VirtualMac2,1，用的是 Apple 虛擬機的 kernelcache 與 DeviceTree。如果要系統把自己當成 MacBook
（「關於本機」的機型、筆電才有的設定），就要換成實機機型的 kernelcache 與 DeviceTree（同一個 UniversalMac IPSW 裡就有），等於重新 bring-up
一次；要改多少沒查過。建議 `--device mac` 先就是 VirtualMac2,1，確定需要時再加 `macbook`。

**加一個組合的工作量主要不在流水線**，而在綁著「一版 build、一個機型」的資料（[builds.md](builds.md) 第 4 節）：`fileset-reviewed.json`、
`legacy-display-24A446.json`、`hid-device-24A446.json`、profile 的 `original-classes.json`、QuartzCore 的 text fixup、ADT 身分、kext 清單、
Data seed。換 OS 版本或機型，這些都要重做或重映射。

## 4. 流水線的階段

```
resolve → build（Mac）→ package（make-vmpkg.py）→ verify（格式、上機）→ publish（要使用者同意）
```

1. **resolve**：由（`--os`、`--device`）找到 board 目錄、OS profile 與 VM 範本；確認 checkout 都是乾淨的，並記下每個 commit。
2. **build**：在 Mac 上跑現有的 `build-droidvm-all.py`，步驟不改。一律用「全新 VM」模式（不加 `--generation`；新 seed，也就是新的 volume UUID）：
   vmpkg 匯入後就是一台新 VM，Data store 是空的。
3. **package**：新寫的 `make-vmpkg.py`，Mac、Linux 都能跑，只需要 Python 和 zstd。
   - VM 設定由裝置 repo 的範本生成，每個機型一份（`vmpkg/<device>.vm.json`），只用 App 自己的欄位：
     - `virtio_transport: mmio`。
     - `disks` 依序為開機碟（唯讀）、`os.img`（唯讀）、`systemos.img`（唯讀）、macOS 再加 `app.img`（唯讀），最後是 `data-store.img`。
     - 音訊用 VIRTIO_SOUND 周邊，解碼／編碼用 `vpu_enabled`（uid 由 App 自己填）。
     - 畫面尺寸與刷新率寫在 `screens`。
     - `extra_options` 只留沒有路徑、沒有 uid 的：`--battery type=goldfish`、`--pre-alloc drm-host-mb=8,…`；App 補上之前，還要加
       `--virtio-mmio-media`。
   - `data-store.img`：照 `make-data-store.sh` 的格式產生（稀疏檔，block 0 放標籤）。
   - 韌體：預設用 App 內建的；指定 `--firmware` 時以 `boots`（kind `uefi`）帶進去。
   - 照 App 的格式（第 5 節）寫出：標頭、manifest、`zstd(tar(manifest.json, 各檔案))`。預設分卷 500 MiB：`<名稱>.vmpkg` 是小的索引檔，
     資料在 `.001`、`.002`…。manifest 多一個 App 不讀的欄位，放 `release.json` 的內容，從 vmpkg 本身就查得到它是哪一版建的。
4. **verify**：
   - 格式：同一支腳本照 App 的讀法（`PackageHeader`、`PackageInput`、`VolumeSet`、`TarReader`）讀回來，逐檔比對大小與 sha256
     （`release.json` 裡有）。不用手機，可以放進 CI。
   - 上機（5566）：把 vmpkg 推到手機，用 App 匯入（或 daemon IPC 的 `vm_import`）建 VM，開機、跑 `health.py`、截圖確認到了主畫面或桌面。
5. **publish**：要使用者同意才做。vmpkg 裡有從 IPSW 解出來的 Apple 系統映像（`os.img`、`systemos.img`），公開散布就等於散布 Apple 的系統，
   授權上有問題。建議只在自己的機器之間傳，或只公開流水線，讓人自己建。

## 5. vmpkg 格式（照 App 的 `lib/pkg`、`daemon/vm/pkg` 讀到的）

- **標頭 24 bytes**：`VMPKG\0`；u16 manifest_version（偏移 6）、u16 app_version_code（8）、u16 manifest 長度（10，所以 manifest 最多 64 KiB）、
  u16 壓縮方式（12；0 無、1 gzip、2 xz、3 zstd）、u16 分卷數（14；0 是單檔）、i64 資料長度（16；分卷時為 0）。全部 little-endian。
- 標頭之後補 0 到 4096，接著是 manifest JSON，再補 0 到下一個 4096 的倍數（剛好對齊時再多補一整頁）。
- **單檔**：接著是壓縮過的 tar，第一項是 `manifest.json`，再依序是每個磁碟、每個開機檔；最後補 0 到 4096 的倍數。
- **分卷**：索引檔在 manifest 之後放 `{"magic":"VMPV","version":1,"data_size":…,"volumes":[{"index","size","crc32"}…]}`；壓縮資料切在
  `.001`、`.002`…（最多 999 卷，每卷至少 16 MiB）。
- **manifest**：`manifest_version`（沒用到 backing chain 就是 1）、`format: "vmpkg"`、`app_version`、`app_version_code`（必須與標頭相同）、
  `compression: "zstd"`、`vm`（VM 設定，不含 `id` 與 `disks`）；`disks` 每項有 `index`、`readonly`、`bus`、`name`、`format`、`size`、
  `archive_path`、`attached`；`boots` 每項有 `archive_path`、`name`、`kind`、`size`；另有 `networks`。
- **tar**：大於 8 GiB 的項目用 GNU base-256 寫大小（Python 的 `tarfile` 用 GNU 格式時就是這樣），App 讀得懂。
- **匯入時**：每個 vmpkg 在目標資料夾裡開一個以 VM 名稱命名的子資料夾，磁碟放裡面、開機檔放 `boot/`；依 `index` 的順序重寫 VM 的 `disks`、
  換掉韌體路徑，VM 拿一個新的 id。

## 6. App 端要補的

1. **匯入時稀疏寫出**：整塊都是 0 就 seek 跳過，最後 `setLength`。Data store 才不會真的寫滿，`os.img` 裡的空洞也省下來。
   舊版 App 一樣讀得懂這種 vmpkg，只是會把空間寫滿。
2. **MMIO 模式自動加 `--virtio-mmio-media`**（11-19 查到的缺口）。
3. **App 附帶 runtime 的更新**（crosvm、virglrenderer、host Turnip、edk2、udmabuf）：要使用者同意，因為會經 CI 發到 DroidVM-Prebuilts，
   影響每一個人。

## 7. 還沒驗證的

- **iPadOS 全部磁碟走 MMIO、開機碟排第一個。** macOS VM 本來就是這樣，iPadOS 的範本則是開機碟走 PCI。兩邊是同一份驅動，但 iPadOS 沒在這個
  順序下開過機。
- **壓縮率**沒量。全是 0 的 Data store 幾乎不佔空間；OS 映像能壓多少要實測。
- **同一個 vmpkg 匯入兩次**：兩台 VM 的 chip id 與 Data seed UUID 相同，各有自己的 Data store，照理沒事，但沒試過。
- **建置只能在 Mac 上跑**（hdiutil、Apple 的工具鏈）。GitHub 代管的 macOS runner 磁碟偏小，CI 大概要用自己的 Mac；沒試過。

## 8. 分階段的做法

1. **先打包現有的兩個組合**（`ipad` 加 27.0.1、`mac` 加 27.0.1）：`make-vmpkg.py`（含格式驗證）、兩份 VM 範本，App 補上稀疏匯入與
   `--virtio-mmio-media`；在 5566 用 App 匯入並開機。這一步不用等任何決定。
2. **一條指令**：`build-vmpkg.py --os --device` 把 build 與 package 包在一起；組合表放在裝置 repo（`vmpkg/targets.toml`）。
3. **整理機型 profile**：把綁著「一版 build、一個機型」的資料搬進每個組合自己的目錄，讓「加一個組合」只是加一個目錄和一組資料。
4. **iPhone**：限時試作（[builds.md](builds.md) 5.3 的建議），從社群的 iPhone17,x profile 起步。要使用者決定。
5. **MacBook 身分**：確定需要再做。

## 9. 要使用者決定

1. **App 附帶的 runtime 要不要更新**（第 6 節第 3 點）。不更新的話，vmpkg 只能用在我們手動換過 binary 的手機上。
2. **iPhone 要不要開始**：11-13 的建議是先不開、之後限時試作；這次流水線把它列成了參數。
3. **「macbook」指的是什麼**：只要 macOS（現在的 VirtualMac2,1 就夠），還是要真的 MacBook 機型身分。
4. **vmpkg 要不要發布、發到哪裡**：見第 4 節第 5 點的授權問題。
