# iPadOS 17 → iPadOS 27（UniXNU guest on DroidVM）

2026-10-29 起。使用者：「我想直接 bump 到 ipados 27」，並要求先確認三支手機在 Gunyah pseudo-unprotected 下的硬體可行性，
再參考 Droid-VM/macOS-DroidVM（branch `macOS`）的補丁開工。

目標：iPadOS 27.0.1（24A446，上游 profile 的 iPad17,3／J820AP，chip 33090）以 arm64e guest 在 DroidVM 上開到桌面，
功能追平目前的 iPadOS 17.7.11（21H461）guest。iPadOS 17 在整個移植期間保持可 build、可部署（不拆掉舊路）。

## 0. 可行性（2026-10-29 已驗）

iPadOS 18 起使用者空間只有 arm64e：guest 必須在 EL1 能用 ARMv8.3 PAC。探測工具：裝置 repo `tools/rig/pacprobe/`
（Linux Image 格式的小 payload，用 app 的 crosvm 以 `--hypervisor gunyah --protected-vm-pseudo-unprotected --hugepages`、
1 vCPU 釘在每顆實體核心各開一次；讀 ID 暫存器、寫讀五組 key、PACGA、SCTLR EnIA/IB/DA/DB、PACIA/IB/DA/DB＋AUT、錯誤 modifier、
BLRAA/RETAA/LDRAA，EL1 與 EL0 各一輪）。

| 手機 | 核心 | 結果 |
|---|---|---|
| 8 Elite Gen 5（SM8850） | 8/8 | 可用：ISAR2 APA3=5（QARMA3＋FPACCOMBINE）、GPA3=1；SVE 可見、SME 隱藏 |
| 8 Elite（SM8750P） | 8/8 | 可用：ISAR1 APA=5（QARMA5＋FPACCOMBINE）、GPA=1；SVE、SME 皆隱藏 |
| 8 Gen 3（SM8650） | A520、A720、X4 三種核心都有跑完的 | 可用：ISAR2 APA3=5、GPA3=1；SVE、SME 隱藏 |

- 五組 key 在 EL1 可寫可讀（Gunyah 沒清 HCR_EL2.APK/API），PAC 指令 EL1/EL0 都正常，AUT 失敗走 FPAC 例外（ESR EC 0x1C）。
- Gunyah 給 guest 的 MIDR 一律是虛擬的 0x000f0480：arm64e kernel 要接受不認得的 CPU。
- SME 在三支都被藏：iPadOS 26/27 dyld cache 裡的 SME 函式不會被選（XNU 只公佈 CPU 有的功能）。
- 目前 iPadOS 17 guest 的 XNU 回報「沒有 FEAT_PAuth」是假象：xnu-10063 commpage 只看 ISAR1.API（Apple 的 IMP DEF 演算法），
  Qualcomm 用架構標準的 QARMA（APA／APA3）。上游 arm64e profile 已補這段偵測。
- **8 Gen 3 的陷阱**：那支手機上這種 128 MiB 的小 pseudo-unprotected VM 不穩（shim 或 payload 吃到 EC 0 例外、讀寫 gpa 0），
  一次被 `timeout` 以 SIGTERM 砍掉卡住的 VM 時**整支手機重開**（Gunyah 下 guest 卡住後被硬砍，同 2026-10-25 的 watchdog bite 型態）。
  之後改成：探測 payload 不再 WFE（結束一律 PSCI SYSTEM_OFF）、例外超過 64 次自行關機、逾時改 `crosvm stop` 控制 socket——
  之後卡住的幾輪都正常收掉、手機沒事。大 VM（iPadOS 17、UEFI）在同一支手機上跑幾小時都正常。

## 1. 兩個來源

**A. 上游 UniXNU `feat/ipados27-gpu-parity`**（13 個 repo 同名分支；我們已在 2026-10-29 合進 GPU 那一半，見 PROGRESS）：
- `profiles/os/ipados-27.0.1-24A446`（xnu-12377.121.6 ＋ Darwin 26 syscalls、IPSW pin、prelink roots、ADT root/chosen）、
  `profiles/arch/arm64e`（PAC key 管理、build config、XNU patch series）、`patches/xnu-12377/*`。
- kernelcache 是 `MH_FILESET`、kext 直接 branch 進 kernel：iPadOS 17 的 prelink 不適用 → XnuPrelink 的 fileset emitter（76452c6）。
- build 腳本 `--target ios27`（arm64e）：metal bridge（`-Z build-std`）、Metal plugin、Turnip；`kernel_target.py`；wallpaper ipados27 overlay；
  seed `--build`；AdrenoMetal 在 arm64e 版把 EDR headroom 鎖在 1（不然 iPadOS 27 會選 'RGhA' 半浮點 framebuffer）。
- 上游自己的狀態：Sheng（SM8550，原生）iPadOS 26.5.2 到過 launchd、SpringBoard；27 的 GPU addon、seed、display adapter 都有，實機證據不全。

**B. Droid-VM/macOS-DroidVM `macOS`**：同樣 DroidVM crosvm/Gunyah 上把 **macOS 27.0.1（26A434）arm64e、xnu-12377** 開到桌面＋Metal。
直接可借的（patch 名照該 repo）：
- xnu-12377：0003 使用者 JOP key（預設 jop pid 1、shared region pager 用行程 key 簽、不對 3P plugin 關 key、遮 PAC 例外位）；
  0004 使用者 VA 寬度（硬體 T0SZ 17，從第一條指令起經一層 L0 shim，pmap 幾何仍 39-bit）；0005 拿掉 kqworkloop 限制；
  0007 `native_pmap_user_mappings`；0008 shared region pager 16 KiB slide page 死結；0010 idle 一律 WFI（Gunyah trap WFI、放行 WFE，
  不然 vCPU 空轉吃滿 host）；0011 AMP（ADT cluster-type 由 host 容量決定）；0012 `exec-env=`；0009 診斷（boot-arg gated）。
- DarwinBoot：接受 arm64e、回收記憶體與 512 MiB kernel 區。ArmCpu：12377 開機中斷、arm64 assembly、idle WFI。
- 顯示：swap_submit record 尺寸換算（27 的 1760 bytes vs 26.5 family 的 1416）、RGhA→BGRA8 查表、gen-iomfb-abi 的 PAC discriminator
  陷阱（被巢狀型別遮住的全域型別要寫 `::Name`，否則 swap 完成時 kernel PAC panic）。
- kernel collection 的組法（kc-build、kc-segaddrs）、Linux 上 build XNU（compat/xnu-linux）。

## 2. 階段

| 階段 | 內容 | 驗收 |
|---|---|---|
| P0 | 可行性 | 已完成（上表） |
| P1 | fork 吃進上游 iPadOS 27／arm64e（profiles、xnu-12377 series、腳本、XnuPrelink、DarwinBoot、VerifiedRoot bump）；裝置 repo 加 27 的 board 變體（`os_profile = ipados-27.0.1-24A446`），17 的 board 不動 | 兩個 board 都能 `unixnu status`，17 照舊 build |
| P2 ✅ | DroidVM 的 kernel 改動 port 到 xnu-12377（arm64e、BCM2837 machine config）；裝置 package 的 C++ driver 以 arm64e 編（ptrauth vtable）；B 的 0003/0004/0005/0008/0010 進 series | arm64e kernel link 成功 |
| P3 | 24A446 fileset prelink；DarwinBoot arm64e；J820 ADT（24A446 DeviceTree＋DarwinBoot 依 FDT 動態補 RAM/裝置/CPU） | DarwinBoot 交給 kernel，arm_init 有輸出 |
| P4 | 開到 launchd → SpringBoard（PAC key、T0SZ、shared region、sandbox、owner chain／Data seed） | 鎖定畫面（軟體算圖即可） |
| P5 | 顯示（virtio-gpu scanout、BGRA）、輸入、GPU（arm64e AdrenoMetal＋Turnip ios27＋我們的 virtgpu 後端）、網路、音訊、電池、動作感測 | 桌面＋Metal，iPadOS 17 現有功能逐項追平 |
| P6 | arm64e 使用者工具（ownervisor、dropbear、applebox、ipatool、debugserver、libimobiledevice）、27 的 Data seed、桌布、自動化腳本 | `build-droidvm-all.py` 從零 build 出 27 的 release |

## 3. 已知風險

- Darwin 26 的 XNU 原始碼尚未公開：上游用 xnu-12377 補 Darwin 26 syscalls；遇到 ABI 差異要逐個補。
- 8 Gen 3 那支手機上的 Gunyah 路徑（6.1 kernel、舊 RM）對小 VM 不穩，大 VM 是否受影響要在 P3/P4 留意；測試一律走 hugepage 程序並開 hostwatch。
- 機型從 J120（A10X）換成 J820：動作感測、MobileGestalt、桌布（@1x vs @2x）、per-process jetsam 上限都會變。
- 我們 iPadOS 17 路徑上的每個 kernel patch、driver、seed 腳本都要重新驗一次；「追平」清單以 PROGRESS 的已完成里程碑為準。

## 4. 狀態（2026-10-29 更晚）

- P1、P2、P3 完成（2026-10-29 更晚）：6 顆 CPU、BSD、APFS 起來，24A446 原版 OS volume 以 root 掛載、SystemCryptex 掛上；
  停在 owner chain 的 Data mount（還沒有 27 的 Data seed）。fork 已 bump 到上游 6ad1297（GPU userland 與 RamBlock 例外，見 PROGRESS）。
- P4 進行中（近午夜）：Data seed、trust cache 完成，launchd 與上百個 daemon 起來，SpringBoard 啟動後 crash、launchd 關機（卸載時
  vnode_rele_ext panic）。下一步：SpringBoard crash 原因（顯示器：MOBILE_DISPLAY／GPU 還沒接）、data-store 持久化、App cryptex、
  board 的內建 boot-args（DroidVMBootArgs.c 連進 27 的 kernel）。
- 遺留：emitter 把 native segment 對齊 64 KiB（拿掉 `use_contiguous_hint=0`）；ArmCpu fe98808 在 17 上量過後釘進 fork（現在只是
  Mac 本地覆寫）；剩下 24 個 stub 呼叫點與 IOHID 那個沒配對的旗標；上游 GPU userland 新版量過再換。

