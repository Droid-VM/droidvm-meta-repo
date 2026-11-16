# PCIe／MSI-X／USB：每個 guest 自己偵測

使用者 11-16 問：「PCIe/MSI-x/USB 能做 guest os 自動偵測嗎？」答案是可以，做法是主機一律提供通用的 PCIe 與 MSI 幀，
每個 guest 依自己有沒有驅動決定用不用；主機程式碼不判斷 guest 是誰。唯一不能自動的是核心 virtio 裝置（區塊、網路、GPU…）
走 mmio 還是 PCI：crosvm 在 VM 啟動前就要決定每個裝置的傳輸，Gunyah 的 irqfd 也只在啟動時從 device tree 拿，guest 開機後沒得選。

四步：

| 步 | 內容 | 狀態 |
|---|---|---|
| 1 | App 對 Gunyah VM 預設開 crosvm 的 MBI 幀（`--mbi-spis 64`），每台可關 | ✅ 11-16（app 505b4a6） |
| 2 | DarwinBoot `--dynamic` 把 device tree 的 PCIe 主橋與 MBI 幀翻成 ADT 節點 | 未開始 |
| 3 | macOS 的 USB 直通（Apple 的 PCIe 橋、xHCI、USB 家族） | 未開始 |
| 4 | iPadOS 的 USB（自寫通用 PCIe 主橋） | 未開始，最後再評估 |

## 第 1 步（11-16）

### App（505b4a6，`wip/hackintosh`）

- `CrosvmBackendInstance.appendMbiOptions`：Gunyah 才加（KVM／GenieZone 的 irq chip 不接受 MBI，VM 會起不來）；設定鍵 `pci_msi`，
  沒有這個鍵的舊設定視為開；`extra_options` 自己帶了 `--mbi-spis` 就照它的。
- 編輯器「基本」分頁多一個開關「PCI MSI 中斷 (Gunyah)」。
- 單元測試 `CrosvmMbiTest`（5 項），backend 與 store 的測試共 162 項全過。

### 韌體陷阱：舊 edk2-gunyah 只留 32 KB 給 device tree

- 64 條 MBI 線在 VM 啟動時就要在 device tree 裡，resource manager 再為每條加一個 doorbell 節點（`bell-NN`），tree 大約多 9 KB。
- edk2-gunyah 的 PrePi 把 tree 複製到映像開頭 64 位元組標頭之後的空間；a7903f0 之前那段只有 32 KB（標頭第二個指令 `b 0x8000`），
  tree 一超過就蓋到韌體自己的程式碼。
- 5566 上的樣子：shim 跳進 payload 後 `SHIM EXCEPTION 0x4 esr=0x2000000 elr=0x80609cdc`（EC 0：執行到的不是指令）。
  從主機讀那一頁，內容是 `bell-38`、`doorbell` 這些節點，不是韌體。
- a7903f0（11-13 從 macOS 線併來）把這段加大到 128 KB（`b 0x20000`）。
- App 讀韌體檔開頭 8 位元組：第一個字是 `adr x1, .`、第二個是往前的 `b`，且目標在 128 KB 以上才開 MSI；認不得的韌體也不開，
  寧可沒有 MSI 也不要開不了機。

### 5566 的部署

- App r335（從 `DroidVM-vpu-rebase` 工作樹直接 `./gradlew assembleDebug`；build.sh 會卡在子模組更新）。
  - 工作樹裡另一個 session 未提交的 GPU 即時優先權改動照舊一起建進去，沒有提交。
  - payload 沒重打包（跟手機上逐位元相同）：重打包會連帶把手機上 11-15 的 crosvm 換回 payload 裡的舊版。
- App 目錄的 `usr/share/droidvm/edk2-gunyah.fd` 直接換成 a7903f0 建的檔（舊檔留 `.bak-20261116`，擁有者與 SELinux 標籤不變）。
  下次完整打包 APK 時，`6_build_apk_prepare.sh` 會自己帶 `edk2-gunyah/edk2-gunyah.fd`。
- iPadOS 27 與 macOS 27 兩台 VM 的韌體改成 App 內建（設定裡 firmware 空字串），不再用 17 那台目錄裡的 `edk2-virtio-gpu.fd`。
- 沒動的：17 那台 VM 與 rig 的 template（`fresh-deploy.sh` 把 `EDK2_FD` 推成 `edk2-virtio-gpu.fd`）仍是舊韌體，App 會自己不開 MSI。
  5567／5568 的 App 與韌體都還是舊的。

### 驗證（5566，全部沒在 extra_options 手動加參數）

| guest | 韌體 | App 的判斷 | 結果 |
|---|---|---|---|
| Ubuntu | App 內建（新） | 加 `--mbi-spis 64` | `GICv3: MBI range [64:127]`，所有 virtio-pci 與 xHCI 走 `MBI-PCI-MSIX`（39 個向量），區塊裝置 4 個佇列分在 4 顆 CPU |
| macOS 27 | 舊 `edk2-virtio-gpu.fd` | 不加 | 照常開機 |
| iPadOS 27 | App 內建（新） | 加 | Data 掛上、SpringBoard、GPU 0 逾時、音訊 clients 2 |
| macOS 27 | App 內建（新） | 加 | 開到桌面（之前手動加參數時也登入、Terminal 恢復） |
| Windows 11 | 新（手動指定） | 手動加 | 開機、網路正常；但見下 |

- Linux 的 `irq: type mismatch, failed to map hwirq-47` 不開 MSI 時也有，是原本就有的。
- 1 GiB 順序讀 INTx 0.89 秒、MSI-X 0.96 秒，屬誤差；macOS 線量到的收益是小 I/O、多佇列，這次沒量。

### Windows 沒有用 MSI

- 開了 MBI、MADT 裡也有 GIC MSI Frame（a7903f0 的 GunyahMbiAcpiDxe），Windows 開機、連網都正常。
- 但 crosvm 的 `irq_handler_thread` 只切換 29 次，同時 `virtio_blk` 有 6.5 萬次。MSI 在 Gunyah 上要經這個執行緒轉送，
  所以 Windows 一個 MSI 都沒發，驅動仍走 INTx。
- 待查：Windows 對 GICv2m 幀還要什麼（PCI 主橋 `_OSC` 有沒有給 MSI 控制權、IORT、MADT 旗標）。
- Windows 照舊能用，App 預設開著不影響它。

### 量測方法（工具在 session 的 scratchpad，沒進 repo）

- 改 VM 設定：從 App 的 `files/vms.json` 讀那台 VM，改 `extra_options` 或 `boot.uefi.firmware`，`vm_modify`（VM 要停著），
  再用 rig 的 `vmpersist.py` 寫回。rig 自己那台另外更新 `unixnu-vm.config.json`（`vmdisk.py` 同一套）。
- 看 crosvm 實際參數：`/proc/<pid>/cmdline`。
- Windows 有沒有 MSI：比較 crosvm 各執行緒 `/proc/<pid>/task/*/status` 的 `voluntary_ctxt_switches`。

## 第 2–4 步（未開始）

參照 macOS-DroidVM 的 `docs/k27-vmapple-pcie-msi-plan.md` 與 `scripts/run-macos-vm.py`（`MACOS_PCIE=1` 的 make_adt）；它們已在自己的流程
驗過 AppleVirtIO 區塊與網路、xHCI 三組 interrupter、實體 USB 滑鼠直通。

- **2：DarwinBoot 翻譯。**
  - `/arm-io/pcie`：`pcie,vmapple1`，`#address-cells` 3、`#size-cells` 2，28 位元組一項的 `ranges`（小端，父位址減 ARMIO_BASE），
    `device-interrupt-parent` 'MBIF'，有 MBI 幀時 `msi-frame-index` 0。
  - `/arm-io/gic-mbi`：`droidvm,gic-mbi`，`reg` 取 intc 的 `mbi-alias`，加 `mbi-ranges`。
  - 不能把 MBI 幀接到 `/arm-io/intc` 的 `reg` 後面：ArmCpu 的 `mapGic` 要它剛好兩項。
- **3：macOS USB。**
  - KC 保留 AppleVirtualPlatform、AppleVirtIO、AppleUSBXHCIPCI、IOUSBHostFamily 與它們的依賴。
  - 收 DroidVMGicMsi kext、ArmCpu 的 MSI 補丁（128 個 SPI 槽、`armcpu_spi_set_enabled`、`armcpu_spi_distribute`）。
  - 收 IOServicePM 的 arm64e thunk 修正（macOS-DroidVM 9a274a2）與 ArmDTPlatform 的電源父設備（b0b8448）。
  - DroidVMInput 要能掛 IOPCIDevice。
- **4：iPadOS USB。**
  - iPadOS 27 的 kernelcache 有 IOPCIFamily、AppleUSBXHCIPCI、USB 隨身碟／HID／音訊／網卡驅動。
  - 但沒有通用 PCIe 主橋（只有 Apple 自家晶片的），也沒有 AppleVirtIO。
  - 要自寫 `IOPCIHostBridge` 與 MSI 控制器，大約是 macOS 線止損方案那份約 300 行的設計。

## 順帶看到的

- iPadOS 有一次開機後 audiomxd 沒打開音訊裝置（DroidVMAudio 的 user client 0 個、鈴聲試聽沒聲音）。
  - 回滾到前一版與再部署新版各開一次都正常（clients 2）。
  - 跟 11-16 的 ring 修正無關（那段只在開始播放之後才跑），原因未查。
