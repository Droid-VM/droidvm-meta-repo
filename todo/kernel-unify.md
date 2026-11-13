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
| 2 | fork 的 arch series 跟上上游：`native-at-par-sync`、較新的 `native-4k-shared-region-slide` 與 `native-pac-keys`；加 0017 與 0044 | I | |
| 3 | kext 專用的區塊進 `package/`（音訊 0001、視訊 0001、顯示 0001）：沒定義 `DROIDVM_NATIVE_KEXT` 時無作用 | I= | |
| 4 | 把 macOS 線的通用驅動補丁收進 `main`：音訊 0002、0003、0005；視訊 0002–0005、0007、0009–0013；pl030-rtc。兩種中斷屬性名都接受；視訊 0008 不收。**收完之後 iPadOS guest 才能用 msm_vidc 直通後端** | I | |
| 5 | macOS 線把釘的 commit 推到 `main`：它的音訊、視訊補丁縮到只剩 0008，NativeAdreno、DroidVMGpu、DarwinBoot 的補丁消失 | M | |
| 6 | 編譯器 workaround 移進共用層（由 `__has_builtin` 等 guard 保護，Xcode clang 下無作用） | I= | |
| 7 | 給 macOS kernel 我們的 host 安全組：16-bit ASID、vCPU park、啟動 flush、pmap sync flush 等 | M | |
| 8 | macOS 的補丁系列改疊在共用層上：前兩個大補丁化進 arch series，16 個 macOS 專屬的改用 `XNU_TARGET_OS_OSX` guard 放進 macOS series，12 個診斷的進診斷 series | I=、M | |
| 9 | fork 收上游的 `target` 開關，macOS kernel 用同一條流程建 | M | |
| 10 | 第 3 節那九件事各留一份實作 | I 再 M | |
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
