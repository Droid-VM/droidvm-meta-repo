# iPadOS 27／macOS 27 的 kernel space 統一

11-13 盤點（使用者要求「盡可能統一成同一套程式碼／邏輯」）。比對對象：我們的 iPadOS 27（fork `patches/xnu-12377` 的
arm64e 與 OS series 加裝置 repo `ipados27/patches/xnu-12377`，共 97 個補丁；驅動在 `package/`）、另一位開發者的 macOS 27
（`Droid-VM/macOS-DroidVM` 的 `macOS` 分支 58359aa：50 個補丁、`overlay/kext/`、對我們原始碼的補丁系列），以及上游 UniXNU
的 macOS profile（`profiles/os/macos-27.3-26C5035r`，49 個補丁）。這邊沒有 macOS VM，所有 macOS 端的判斷都只來自讀碼。

逐補丁、逐驅動的原始比對筆記（由比對工具產出，每條標了證據等級 R＝讀過 diff、H＝只讀標頭與檔案清單、T＝只看標題）：
[kernel-patches.md](kernel-unify/kernel-patches.md)、[drivers-notes.md](kernel-unify/drivers-notes.md)、
[upstream-notes.md](kernel-unify/upstream-notes.md)。

## 1. 結論

兩條線是同一套程式碼分岔出去的，不是兩個設計。

- 兩邊都從 `xnu-12377.121.6`（`ac9718f`）編，同一個機型設定（BCM2837）。我們 97 個補丁裡有 38 個在 macOS 線以相同程式碼存在。
- macOS 線的音訊與 VideoToolbox 驅動就是我們 `package/` 的檔案（釘在等同 `main` 的 commit）加補丁，而且那些補丁都能套在
  我們的 `main` 上。
- macOS 編譯時多一個 `-DXNU_TARGET_OS_OSX`（macOS kext 的 vtable 排法，IOService 275 格對 171 格）。**二進位不能共用，
  原始碼可以**：這只是一個編譯定義。

## 2. 真正不同的地方

| 差異 | 能不能在同一棵樹用建置開關解決 |
|---|---|
| `XNU_TARGET_OS_OSX` 的 kext ABI | 能，一個定義。上游已有 `target = "macosx"` 的開關；我們 fork 的腳本寫死 `-DXNU_TARGET_OS_IOS` |
| kext 還是編進 kernel | 裝置程式碼能共用；macOS 線的補丁是 5 個 `#if !DROIDVM_NATIVE_KEXT` 區塊。上游自己的 macOS 移植是編進 kernel，所以 kext 是 macOS 線的選擇，不是 macOS 的要求 |
| kernel collection 還是 fileset 配對 | 各 OS 的工具選擇，kernel 裡差很少。macOS 的 kernelcache 留有符號，按名字配；iPadOS 被 strip，按審過的位址配 |
| PCIe 還是 virtio-mmio | macOS 線已是逐裝置的開關，走 PCIe 時用 Apple 自己的 AppleVirtIO；GPU、音訊、視訊仍在 mmio。我們 8 個驅動檔各帶一份 mmio 與 ring 程式碼，還沒有共用的傳輸層 |
| 單一 APFS 容器還是 Data store | 能，我們的佈局本來就用巨集包著 |
| 開機（DarwinBoot／ADT） | 能。我們的 DarwinBoot 已含 macOS 線兩個補丁的內容，只差兩個常數（512 MB 視窗與 kernel 上限；我們是 256 與 128） |

另外兩點不是技術差異而是習慣：macOS 線的 macOS 專屬修改多半放在 `#ifdef BCM2837` 底下或沒有 guard（50 個補丁只有 3 個用
`XNU_TARGET_OS_OSX`）；它在 Linux 上用上游 LLVM 21 編，我們用 Xcode 的 clang。

## 3. 寫了兩次的九件事

其中三件兩邊互相衝突（標 ✗）：

| 主題 | iPadOS 27 | macOS 27 |
|---|---|---|
| 使用者位址空間寬度 ✗ | `ipados27-bringup`：真正的 47-bit pmap | 0010：39-bit pmap 上疊一層 L0（512 GiB），連帶需要 0043 與關 Gigacage |
| AMP 排程 ✗ | `droidvm-amp` 加 `DroidVMCpufreq.c`（Edge scheduler） | 0021：sched_amp、兩個 cluster |
| AMFI 介面第 5 版 ✗ | `darwin26-kpi` 在 amfi.c 重排 | 0029 在標頭插入成員 |
| 使用者 PAC 金鑰 | `native-pac-keys` 加 `ipados27-bringup` | 0009 |
| arm64 行程關 A key | `droidvm-native-pac-user-jop`、`-ib`（連 DB、IB 都關） | 0042 |
| shared region 的 4K slide | `native-4k-shared-region-slide` | 0013 |
| idle 走 WFI | `non-apple-idle-wfi` 加 `non-apple-vcpu-park` | 0020 |
| 27 的 kext 需要的 KPI | `darwin26-kpi`（自取的名字 `*_ext`） | 0024（macOS 匯出的名字 `*_with_length`） |
| owner chain | `offline-owner-*` 加 VerifiedRoot | 0008 |

macOS 線另有 4 個我們沒有的通用修正（0017 codeLimit 之後的 4K 頁、0039、0044 mmap 對齊 16K、0045 PAR_EL1 ISB），
上游已把其中幾個收進共用層。反方向，我們有 17 個 macOS 線沒有、但依性質它也需要的補丁（vCPU park 與啟動 flush、
`zzx-pmap-sync-flush`、16-bit ASID、`native-pac-user-ib`、dyld 16K 等）。

## 4. 驅動

| 功能 | 兩邊的距離 |
|---|---|
| 音訊、VideoToolbox | 同一份檔案；macOS 線多 4 與 12 個補丁（191 與 1523 行） |
| GPU 3D（`DroidVMGpu`、`DroidVMVirtioGpu3D`） | 同一份檔案，macOS 線釘在較舊的 commit |
| 區塊、AES、Data store | 同一份檔案，小差異 |
| 顯示傳輸（`DroidVMVirtioGpu.cpp`） | 同一份檔案，差 310 行；framebuffer 類別各寫一份 |
| 網路、輸入 | 各寫一份（448 對 686 行、973 對 963 行） |
| 中斷（ArmCpu） | 同一份檔案，macOS 線多 7 個補丁（128 個 SPI、MSI） |
| USB | 只有 macOS 線（PCIe 上的 Apple xHCI） |
| 電池、感測器、cpufreq、virtio-console、keystore | 只有我們 |

macOS 線對我們原始碼的 40 個補丁：19 個是 iPadOS 也該拿的通用改進（音訊 3、視訊 11、ArmCpu 4、ArmDTPlatform 2 中的大部分），
12 個我們已經有，5 個 macOS 專屬，4 個只為了 kext 包裝。要注意兩點：音訊 0005 與視訊 0013 把 1 ms 輪詢換成中斷，但讀的
ADT 屬性叫 `gic-spi`，我們的叫 `droidvm,intid`；視訊 0008 會把距上一幀不到 31 ms 的畫面全部回報成丟棄，不能直接進來。

## 5. 建議的結構

```
UniXNU fork        patches/xnu-12377/            一池主題補丁
  profiles/arch/arm64e/.../series                共用：非 Apple 核心、4K kernel、與工具鏈無關的修正
  profiles/os/ipados-27.../series                iPadOS：它的 kext 的 KPI、SystemOS union、text fixup
  profiles/os/macos-27.../series                 macOS（target = macosx）：OSX 缺口、macOS KPI、firmlink
  診斷用 series                                   兩邊的除錯補丁，release 不帶
UniXNU-droidvm     patches/xnu-12377/series      板級共用：vCPU park、timebase、PAC、AMP、serial、GPU hook
  ipados27/…/series、macos27/…                   各 OS 的板級補丁與設定
  package/                                       驅動一份：傳輸與裝置檔共用，類別外殼依 OS 家族，
                                                 建置模式 built-in（預設）或 DROIDVM_NATIVE_KEXT=1
```

共用層的規則：macOS 的建置和 iPadOS 的建置只能差在 `XNU_TARGET_OS_OSX`、OS 的 series 與各 OS 的設定；`BCM2837` 不當 OS 的 guard。

## 6. 步驟（由便宜、安全的開始）

「I」＝只靠 iPadOS 就能驗證；「I=」＝iPadOS 的 kernel 二進位不變即可驗證；「M」＝要 macOS 開機測。

| # | 步驟 | 驗證 | 狀態 |
|---|---|---|---|
| 1 | ArmCpu 的行內組譯（見第 7 節） | I | ✅ 11-13 完成 |
| 2 | fork 的 arch series 跟上上游：`native-at-par-sync`、較新的 `native-4k-shared-region-slide` 與 `native-pac-keys`；加 0017 與 0044 | I | ✅ 11-13 原始碼（fork 365ff09：par-sync、shared-region-slide、0017、0044、0039；`native-pac-keys` 的上游版本沒收，見第 9 節）；iPadOS 開機測試待做 |
| 3 | kext 專用的區塊進 `package/`（音訊 0001、視訊 0001、顯示 0001）：沒定義 `DROIDVM_NATIVE_KEXT` 時無作用 | I= | ✅ 音訊、視訊（device 0596720、2f75613）；顯示 0001 未收 |
| 4 | 把 macOS 線的通用驅動補丁收進 `main`：音訊 0002、0003、0005；視訊 0002–0005、0007、0009–0013；pl030-rtc。兩種中斷屬性名都接受；視訊 0008 不收。**收完之後 iPadOS guest 才能用 msm_vidc 直通後端** | I | ✅ 11-13 音訊、視訊全收（0008 改成開機參數 `droidvm-vt-thin-us`，預設關），兩種中斷屬性名、沒有就輪詢（device 2cd4c8e、a229647）；5566 開機與 MediaCodec 編解碼通過；msm_vidc 直通還沒解出畫面（第 9 節）；pl030-rtc、顯示 0002–0004 未收 |
| 5 | macOS 線把釘的 commit 推到 `main`：它的音訊、視訊補丁縮到只剩 0008，NativeAdreno、DroidVMGpu、DarwinBoot 的補丁消失 | M | |
| 6 | 編譯器 workaround 移進共用層（由 `__has_builtin` 等 guard 保護，Xcode clang 下無作用） | I= | ✅ 11-13 原始碼（fork a2b713f）；Xcode 下目標檔是否不變待 Mac 建置確認 |
| 7 | 給 macOS kernel 我們的 host 安全組：16-bit ASID、vCPU park、啟動 flush、pmap sync flush 等 | M | |
| 8 | macOS 的補丁系列改疊在共用層上：前兩個大補丁化進 arch series，16 個 macOS 專屬的改用 `XNU_TARGET_OS_OSX` guard 放進 macOS series，12 個診斷的進診斷 series | I=、M | ✅ 11-13 原始碼（fork 0b98053、554c181、a6970da；device 782c974、f60ffc2），沒有編譯過 |
| 9 | fork 收上游的 `target` 開關，macOS kernel 用同一條流程建 | M | ✅ 開關（fork c69fdf6，與上游同字）；macOS kernel 經我們的流程編譯待做 |
| 10 | 第 3 節那九件事各留一份實作 | I 再 M | 11-13 macOS 層一律用我們的實作（第 9 節）；擁有者鏈／磁碟佈局未定 |
| 11 | 從 8 個驅動檔抽出 virtio 傳輸層（mmio 或 PCI、中斷掛接），網路與輸入才能共用裝置程式碼 | I 再 M | |
| 12 | macOS 的包裝（編進 kernel 或 kext）與根檔案系統佈局定案 | M | |

第 1–4、6 步只需要我們自己，不改變 macOS 的行為。第 10–12 步要兩位開發者一起決定。

## 7. 比對過程查到的我們這邊的問題

- **ArmCpu 的行內組譯（已修，11-13）。** 在 arm64 Darwin 上，組譯字串裡的分號是註解的開頭。CPU 驅動有 17 處寫成
  `"a; b; c"`，Apple clang 只編出第一條：讀計數器的 `isb; mrs cntvct_el0` 只剩 `isb`（回傳暫存器裡原有的值）、
  SPI IPI 前的關中斷 `mrs daif; msr daifset, #2; isb` 只剩讀取、送 SGI 的 `dsb ishst; msr icc_sgi1r_el1; isb` 只剩 barrier、
  寫中斷控制器暫存器後的 barrier 全部沒有。在 Mac 上用同一個編譯器重現，並在建出的 `ArmCpu.o` 確認（修正前後：`isb` 15→35、
  讀 `CNTVCT_EL0` 0→14、寫 `ICC_SGI1R_EL1` 1→3）。修正取自 macOS 線的 `ArmCpu-arm64-assembly.patch`
  （ArmCpu 246b76d，fork 6aa7443）。8 Elite Gen 5 的手機上開機、Metal Check、VideoToolbox 編解碼正常。
  **連帶要重新檢查的舊結論：「Gunyah 會丟掉 guest 的 SGI」——當時 SGI 根本沒有寫出去。**我們的板子用 `armcpu-spi-ipi=1`，
  不走 SGI，所以現在沒有影響；要不要改回 SGI 需要另外測。
- **shared region pager（未修）。** fork 的 `native-4k-shared-region-slide` 少了「取下一頁前先放掉來源頁」，macOS 線的 0013
  與上游較新的版本都有；上游的說明是 `apfs_pagein_with_verification` 底下會自己鎖死自己。屬於第 2 步。

## 8. 還不知道的

- macOS 執行期的一切（這邊沒有 macOS VM）；macOS 線實際部署用哪些 PCIe 開關、kernel 參數。
- iPadOS 27.0.1 的 Sandbox 用不用 end-rename-swap hook（0041）；macOS userland 需不需要 `darwin26-syscalls`。
- macOS 線為什麼不需要 `public-pmap-sart`，它的 collection 怎麼註冊 `native-security-init` 處理的安全政策。
- macOS 的 keystore、電池、睡眠在那條線怎麼服務（`overlay/kext` 裡沒有）。

## 9. 11-13 晚：一套原始碼的實作（使用者：「內核融合統一成一份 code」）

### 結構

| 層 | 位置 | 誰用 |
|---|---|---|
| arch | fork `profiles/arch/arm64e/patches/xnu/series` | 兩個 OS |
| OS | fork `profiles/os/ipados-27.0.1-24A446`（target ios）、**新** `profiles/os/macos-27.0.1-26A434`（`target = "macosx"`，VirtualMac2,1 26A434） | 各自 |
| 板級共用 | device `ipados27/patches/xnu-12377/series` | 兩個 OS |
| 板級 OS 專屬 | 同目錄 `ipados.series`（5 個：GPU client 的 sandbox／kobject 授權、surface GPU wait、text fixup）、**新** `macos.series`（9 個） | 各自 |
| 診斷 | fork `profiles/os/macos-27.0.1-26A434/patches/xnu/diag.series`（7 個，不在預設清單） | 選用 |

- 同一個 board 服務兩個 OS：`ipados27/board.toml` 的 `[os_overrides."macos-27.0.1-26A434"]` 換掉 patch_series 與
  config_fragments；`unixnu build -D ipados27 --os macos-27.0.1-26A434 kernel` 選 macOS。iPadOS 建置不讀那張表。
- `target` 開關（fork c69fdf6）與上游 origin/main 同一段文字：iPadOS 預設 ios，不變。
- 驅動（`package/`）本來就是一份；macOS 線的音訊、視訊補丁已收（第 6 節第 3、4 步）。

### macOS 線 50 個 kernel 補丁的去處（逐檔分類：[macos-vs-treeB.md](kernel-unify/macos-vs-treeB.md)）

- 已相同（S）：0001、0002 的共同部分、0004、0005、0012、0031、0040。
- macOS 專屬（M）：改成 `XNU_TARGET_OS_OSX` guard。OS 層 9 個：其中 6 個用上游 macOS-27.3 的寫法（`macos-target-kernel`、
  `macos-darwin26-kpi`、`macos-shared-region-size`、`macos-user-address-space`、`macos-kqworkloop-limits`、
  `macos-end-rename-swap`），加 `macos-machine-config`（照 macOS 線的選項）、`macos-deny-exec`、`macos-block-descriptors`。
  板級 `macos.series` 9 個：timebase 從 0 起算、external method hook、KC 版面、AMFI page shift、boot manifest 佔位、
  外接碟可見、jetsam 下限、rootauth、未驗證根的 stub（只有 `-DXNU_OWNER_ROOT_UNVERIFIED=1` 才編）。
- 上游 LLVM 的 workaround（T）：進 arch 層，全部用 `__has_builtin` 等條件，Xcode clang 走原本的程式碼。
  macOS 線 Linux 建置主機的 Makefile 等不收（那是它的工具鏈，不是 macOS）。
- 診斷（D）：7 個進 `diag.series`；0014、0019、0034 依賴 0002 的 exception.c 骨架，沒收。
- 通用修正（G）：0017、0039、0044、0045 進 arch 層（fork 365ff09），iPadOS 也拿。
- 寫了兩次的（I）：一律留我們的。0010 使用者位址空間 → 我們的 47-bit pmap，macOS 得到 128 TiB，0043 的 256 GiB GPU
  carveout 與關 Gigacage 都不需要了；0021 AMP → 我們的 Edge＋`DroidVMCpufreq`（macOS 線沒有這個驅動時 Edge 用預設
  偏好）；0029 AMFI v5 → 我們在註冊時重排；0009／0042 PAC → 我們的 native-pac-keys＋pac-user-jop／ib；0011 → 我們的
  Darwin 26 spawnattr 轉換（macOS 線那版讀錯了版面）。

### 驗證

- iPadOS 原始碼：純重整（板級分兩層）後與之前位元組相同（tree 873c7a0f）；之後只多 arch 層的 5 個修正（5 個檔）與
  6 個編譯器條件區塊（IOWorkLoop.cpp、IOServicePM.cpp、kalloc.c、kalloc.h、IOLib.h、base.h）。工具：
  scratchpad `kunify/xnutree.py`，照管線的順序把各層補丁套到乾淨的 ac9718f。
- macOS 原始碼：116 個補丁全部套得上，`diag.series` 也套得上；與 macOS 線的原樹差 165 個檔，每個都有分類，沒有說不出
  原因的。
- **macOS 目標的編譯（Mac，我們的流程，`unixnu build -D ipados27 --os macos-27.0.1-26A434 kernel`）**：116 個補丁在管線上
  全部套上；XNU 本體以 `XNU_TARGET_OS_OSX` 編譯通過；板級 archive 中 corecrypto、ArmDTPlatform、ArmCpu、libpthread、
  VirtioMmioBlock、RamBlock、DroidVM 儲存、KeyStoreState、GPU、SoftwareAES 與 `build-droidvm-devices`（音訊、視訊、網路、
  輸入等驅動）都以 macOS 目標編過。沒過的兩個是 HID 輸入與 legacy display：它們拿 **iPadOS 的 fileset** 核對原始類別的
  vtable 槽位，macOS 的 vtable 排法不同；而 kernel 腳本硬性要求 legacy display 的 archive，所以最後的連結沒有走到。
  要嘛為 macOS 拿 macOS kernelcache 做這兩個的核對，要嘛 macOS 的 override 不帶它們（macOS 線本來就用自己的 kext）——
  這是第 12 步的決定。編譯時用了佔位的根 volume UUID（macOS profile 還沒有 `[root]` 表），擁有者公鑰從 iPadOS 的建置複製。
- **沒有 macOS VM 開機。**

### 還沒定的

1. **擁有者鏈與磁碟佈局（第 12 步）**：macOS 線是單一 APFS 容器、root-only 的開機清單（0002／0008），我們是兩個 volume
   （OS＋SystemOS）。用 macOS 線的旗標建這套 kernel，會去找一個它的磁碟上沒有的 SystemOS volume。要決定 macOS 用哪種。
2. macOS 的 AMFI／CoreEntitlements 是否需要 KDK 的真實 `CEKernelAPI_t` 版面（0003），我們只有 stub。
3. macOS 線的 k27 建置若改吃這套原始碼：要加 `-DXNU_OWNER_ROOT_UNVERIFIED=1`、保留它自己的 DriverKit iig sed。
4. 上游 macOS 寫法帶來的小差異：compressor pool 用嵌入式的大小、`pid_hibernate` 回 ENOSYS 而非 ENOTSUP。
5. board 的 archives／components 沒有被 macOS 覆寫，macOS 建置也會帶它們（內建驅動）；這是第 12 步「編進 kernel 還是
  kext」的同一個問題。

## 10. 11-14：單一 APFS 容器、kext 化的評估（使用者問）

### 單一容器兩個 OS 都能開嗎

能。真的 iPad 與 Mac 都從一個 APFS 容器開機（System、Data、Preboot 在同一容器），macOS 線也已經這樣跑。對 macOS 這是
必要條件：firmlink（`/Users` 等接到 Data）只在同一容器、同一 volume group 裡成立。iPadOS 沒有這個需求，我們才能拆開放。

- kernel 端改動小：擁有者鏈按 volume UUID 找 SystemOS 與 Data（`XNU_OWNER_CACHE_VOLUME_UUID`、`XNU_OWNER_DATA_VOLUME_UUID`），
  根的開機清單也帶 UUID；換成同一容器裡的 volume 也找得到。
- 要重做的是兩件與 OS 無關的事：
  1. **驗證**：VerifiedRoot 是對「整個唯讀映像的區塊裝置」逐塊驗證（`native_verified_block_root_authorized(device)`）。
     同一個可寫容器裡 System volume 的區塊散在各處、容器本身一直在變，這套用不上。換成 Apple 的封印系統 volume（APFS
     封印快照，根雜湊在開機清單）或另一套方案；macOS 線現在是關掉驗證（每個裝置都放行，rootauth=0）。
  2. **VM 之間共用**：現在同一支手機的 VM 共用唯讀的 os.img／systemos.img，Data 是共用種子上的 copy-on-write。單一容器
     就是每台 VM 一整份；要保留共用得把 Data store 的區塊層 COW 擴大到整個容器（種子容器＋每台 VM 的覆寫層）。
- iPadOS 的 SystemOS cryptex 在真機放 Preboot、開機時 graft；我們是另一個 volume union-mount 到 `/`。放進同一容器時
  可以繼續 union-mount 那個 volume。

### 我們的驅動能不能全部做成 kext

現況：所有驅動都編進 kernel，再把 kernel 放進 Apple 的 fileset；沒有一個在 iPadOS 上以 kext 跑過。macOS 線的 kext 是
同一份原始碼加 `-DDROIDVM_NATIVE_KEXT=1`、一個小 starter（比對到 IOResources 就呼叫驅動的啟動函式），由它自己的 KC
連結器（`k27/kc-build27.py`、`scripts/kc_native.py`）當成獨立 kext 連進 kernel collection；未定義符號照名字對 kernel
與 collection 裡的 kext 解析（macOS 的 kernelcache 留著符號），所以不限公開 KPI，也能直接繼承 Apple kext 的類別。

| 類別 | 驅動 |
|---|---|
| 已有 kext 版（macOS 線在用） | 音訊、VideoToolbox（兩者的 kext 區塊已收進 `main`）、virtio-gpu 顯示（補丁未收）、GPU 3D（`DroidVMGpuKext`）、AES、區塊（`NativeVirtioBlock`）；網路與輸入是它另寫的一份 |
| 只差包裝（同音訊的 starter 即可） | 電池、動作感測器（Motion、SensorProcessor）、cpufreq、virtio-console（含 GNSS）、virtio-media 傳輸、keystore |
| kernel 直接呼叫它，要先改成「kext 啟動時註冊 hook」 | 啟動策略（`native_board_launch_policy`）、儲存與 Data store（`native_source_storage_start`、`sheng_boot_watchdog_policy`，且根掛載前就要在）、板級 late probe（`native_legacy_display_probe`／`_late_probe`，依序啟動各裝置）、GPU 授權與 IOSurface 等待（`droidvm_user_client_trap_hook` 等）、排程追蹤、頁面資訊、timebase；約十來個入口。macOS 線 0018 的 `virt_set_external_method_hook` 就是註冊式 hook 的寫法 |
| 留在 kernel | ArmCpu（中斷控制器、IPI、計時器）、ArmDTPlatform（platform expert）、開機參數、24 MHz timebase、VerifiedRoot 與擁有者鏈。macOS 線也是把 ArmCpu／ArmDTPlatform 連進 kernel |

iPadOS 端最大的障礙在打包，不在驅動：

- 我們的打包工具（XnuPrelink `emit_prelink.py`）只能把我們的 kernel 放進 Apple 的 fileset、選要留哪些 Apple kext，
  不能加自己的 kext；要先有 iPadOS 版的 KC 連結器（macOS 線的 `kc_native.py` 是起點）。
- iPadOS 的 kernelcache 沒有符號：kext 不能照名字連到 Apple kext 裡的類別（IOAudio2Device、IOHIDDevice、IOGPU、
  IOMobileFramebuffer…），仍要用現在執行期認養父類別的做法（12 個檔案在用）；這在 kext 形式下照樣可行，只是「直接
  繼承」的好處在 iPadOS 拿不到。
- HID 輸入、legacy display 對原始類別 vtable 槽位的核對，兩個 OS 各一張表，kext 化不會消掉這件事。

## 11. kext 化（11-14 開工，使用者同意的順序：連結器 → 註冊式 hook → 分批搬）

### 第 1 步：iPadOS 的 kext 連結器（device b1c279e、1924879、599e3ed，11-14 推送）

- `ipados27/kexts/NAME.json` 宣告一個 kext：原始碼（`package/`）、attach 函式（可多個，依序）、取代的內建物件、
  OSBundleLibraries、需要時的編譯紀錄。內建建置（`build-droidvm-devices.py`、late probe）讀同一份清單，把它們排除。
- `build-droidvm-kexts.py`：用 kernel 自己的編譯紀錄加 `DROIDVM_NATIVE_KEXT=1` 編，配上通用啟動器
  `package/DroidVMKextStarter.cpp`（IOResources 在 IOBSD 之後比對到它，就在自己的執行緒呼叫 attach）。
- `fileset-add-kexts.py`：prelink 之後把 kext 連進 24A446 的 collection，成為獨立的 fileset entry（MH_KEXT_BUNDLE 標頭、
  `LC_FILESET_ENTRY`、root chained fixups、kmod_info、`_PrelinkInfoDictionary`）。位置照 arm_vm_init 的規則：`__TEXT`
  在 `__PRELINK_TEXT`，程式碼在我們 kernel 的 `__TEXT_EXEC` 之前，常數在 `__LASTDATA_CONST` 之後，資料在
  `__PRELINK_DATA` 之後，用被丟掉的 Apple kext 留下的空洞、整個 chain page。kmod_info start／stop 的簽章從 Apple kext
  讀（IA、diversity 0xe4fe，和 macOS 線寫死的一致）。連結器是 macOS 線的 `kc_native.py`，原樣收進來。
- release 帶 `kexts.json`（各 kext 的位置與符號），deploy27.sh 併進 rig 的 `kernel.nm`，peek／health 照名字讀。
- 已在 Mac 上建出：電池、音訊、VideoToolbox（含 virtio-media）、cpufreq、virtio-console 五個 kext 都在 collection 裡；
  kernel 少了它們照樣連結（沒有別處直接呼叫）；每個指標都落在自己的 kext 或 kernel 內；kmod_info 正確。
- **11-14 在 5566 開機驗證**（手機用 adb 重開後池子回到 3072）：五個 kext 都由 OSKext 載入並跑完 attach——電池 stage 4
  （電量 80%、持續輪詢）、音訊的 virtio-snd 走中斷且系統的音訊服務開了播放串流（0 丟幀）、VideoToolbox 解碼 H.264 294
  fps／HEVC 403 fps／10-bit 正常、編碼 154 fps、cpufreq stage 4、virtio-console 加一個埠測試時出現
  `/dev/cu.vport0p0`。Metal Check 通過、沒有 panic。同一次開機也驗了 fork 的 arch 層修正（mmap 16K 對齊等）。

### 第 3 步：分批搬（11-14）

| kext | 內容 | 5566 驗證 | device |
|---|---|---|---|
| DroidVMBattery | 電池 | stage 4，電量持續更新 | b1c279e |
| DroidVMAudio | 音訊＋virtio-snd | 中斷模式，系統音訊服務播放、0 丟幀 | 1924879 |
| DroidVMVideo | virtio-media＋VideoToolbox host＋paravirt | 解碼 294／403 fps、編碼 154 fps | 1924879 |
| DroidVMCpufreq | vCPU 效能請求 | stage 4 | 1924879 |
| DroidVMConsole | virtio-console tty | 加測試埠後出現 `/dev/cu.vport0p0` | 1924879 |
| DroidVMNetwork | 從原始碼編的 IONetworkingFamily＋virtio-net＋Wi-Fi | stage 6，en0／en1，ssh 走它 | 1b8e68d |
| DroidVMSoftwareAES | NativeAES（依賴 IOCryptoAcceleratorFamily） | stage 3，已知答案測試通過，開機正常 | b4ac3b1 |
| DroidVMInput | 觸控、鍵盤、筆、觸控板、動作感測器、感測器通道（依賴 IOHIDFamily） | HID stage 3，6 個 virtio-input，點擊送達 guest | 409e3af |

- 第 2 步（kernel 直接呼叫驅動）目前只遇到一處：共用的 `LegacyDisplayProbe.cpp` 直接呼叫 `native_hid_input_probe`，改成以
  `DROIDVM_KEXT_INPUT` 編譯時交給 kext（未定義時行為不變，iPadOS 17 不受影響）。
- 連結器（`kc_native.py`）為這幾批加了三件事：`__DATA_CONST,__assert` 區段、絕對符號（`.set`），以及「指向絕對符號的
  64-bit 值直接寫入、不進 chain」（HID 樁的原始位址常數）。`__BOOTDATA,__static_if` 不帶（只有 kernel 自己的會被改寫，
  kext 保留編譯時的預設，DEVELOPMENT kernel 上 assert 一樣是開的）。
- kext 宣告可以依賴 Apple 的 kext（OSBundleLibraries），由 OSKext 保證載入順序：AES 依賴 IOCryptoAcceleratorFamily、輸入
  依賴 IOHIDFamily；內建時這些順序要靠驅動自己延後註冊。

### 還留在 kernel 裡的

- 平台與診斷，照設計留著：ArmCpu、ArmDTPlatform、開機參數、24 MHz timebase、擁有者鏈與 VerifiedRoot、啟動策略、檔案信箱、
  頁面資訊、排程追蹤、late probe 本身。
- 還沒搬的驅動：
  - keystore（keychain 與資料保護；board 另有 `component:AppleKeyStoreState`，關係要先釐清）
  - 儲存（根掛載前就要在，`native_source_storage_start` 由 bsd_init 呼叫）
  - GPU 與顯示：最大的一塊，kernel 直接呼叫它的入口最多（kobject／sandbox 授權、IOSurface GPU 等待、Adreno 探測），
    第 2 步的工作主要在這裡。
