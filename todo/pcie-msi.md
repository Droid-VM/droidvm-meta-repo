# PCIe／MSI-X／USB：每個 guest 自己偵測

使用者 11-16 問：「PCIe/MSI-x/USB 能做 guest os 自動偵測嗎？」答案是可以，做法是主機一律提供通用的 PCIe 與 MSI 幀，
每個 guest 依自己有沒有驅動決定用不用；主機程式碼不判斷 guest 是誰。唯一不能自動的是核心 virtio 裝置（區塊、網路、GPU…）
走 mmio 還是 PCI：crosvm 在 VM 啟動前就要決定每個裝置的傳輸，Gunyah 的 irqfd 也只在啟動時從 device tree 拿，guest 開機後沒得選。

四步：

| 步 | 內容 | 狀態 |
|---|---|---|
| 1 | App 對 Gunyah VM 預設開 crosvm 的 MBI 幀（`--mbi-spis 64`），每台可關 | ✅ 11-16（app 505b4a6） |
| 2 | DarwinBoot `--dynamic` 把 device tree 的 PCIe 主橋與 MBI 幀翻成 ADT 節點；macOS 一個 binary 兩種傳輸都能用 | ✅ 11-17（見下節） |
| 3 | macOS 的 USB 直通（Apple 的 PCIe 橋、xHCI、USB 家族） | ✅ 控制器與埠 11-18（device 8d1b84c）；裝置端沒實測（手機上沒插裝置） |
| 4 | iPadOS 的 USB（自寫通用 PCIe 主橋） | 未開始，最後再評估 |

## 11-18 下午：上次列的後續依序處理

使用者：「把這些修正按順序做完」（上次報告「還沒做的」那張清單）。結果：

| # | 項目 | 結果 |
|---|---|---|
| 1 | Windows 用新 crosvm | ✅ 開到桌面、有線網路、裝置管理員沒有資源衝突、系統內關機正常（見上節驗證表） |
| 2 | iPadOS 部署 ioreg 工具 | ✅ efde148 的 release 部署到 5566，1.2 秒拿到整棵樹 |
| 3 | macOS-DroidVM 的 ADT 要不要跟著改 | 不用：它的 VM 沒開電池，ADT 每次 prepare 從手機當下的 FDT 重做 |
| 4 | macOS 的 USB（xHCI）驅動 | ✅ 起來了（device 8d1b84c），見下 |
| 5 | 網卡走 PCI 時解鎖卡住 | 沒重現：PCI＋USB 設定下開機自動上鎖後解鎖 1 次、手動鎖定解鎖 4 次都正常 |
| 6 | MSI 沒分散到各 CPU | 其實有分散，是讀回值誤導（ArmCpu 652675b），見下 |
| 7 | 我們自己的驅動加 virtio-pci | 輸入驅動完成（device a615820），見下；GPU、media、音訊、Data 盤還沒做 |

### 4. USB：KC 連結工具把 IOUSBHostFamily 的 personality 拿掉了

- XnuPrelink 的 `fileset_emit.py` 只保留 **roots** 的 `IOKitPersonalities`：只當依賴被帶進 KC 的 kext，personality 一律刪掉
  （KC 紀錄 `kernel.json` 的 `personalities_dropped`）。IOUSBHostFamily 原本只是依賴，所以它的 `AppleUSBHostResources`
  （IOResources、`IOResourceMatch IOKit`）從來沒註冊，`AppleUSBXHCIPCI` 的 start 就一直等。
- 修法：macOS 的 prelink roots 加 IOUSBHostFamily、AppleUSBXHCIPCI、AppleUSBHostCompositeDevice、AppleUSBHub、
  IOUSBHostHIDDeviceSafeBoot、IOUSBMassStorageDriver、IOSCSIBlockCommandsDevice（macOS-DroidVM 的 MACOS_USB_PCI 那組加 hub）。
- 驗證：AppleUSBHostResources 註冊、AppleUSBXHCIPCI 起來，8 個 USB2、7 個 USB3 埠（「ports limit reached」：crosvm 給 16 個）；
  網卡、桌面、解鎖照常。
- 11-17 以為「xHCI 驅動卡住時把網卡也拖住」不對：網卡起不來是 crosvm 電池那個問題（上節）。
- 沒驗到：手機上沒插 USB 裝置，裝置端（HID、隨身碟）沒實測。USB2 埠 1–7 上電時 `AppleUSBXHCIPort::powerOn: deadline passed
  (PORTSC 0x00000000)`，USB3 埠沒有；crosvm 的 PORTSC 預設有 PP，原因沒查。

### 6. MSI 分散：Gunyah 讀 IROUTER 永遠是 0

- 每核心計數（ArmCpu `armcpu_core_spi`／`armcpu_core_mbi`，新加）：MSI 依 `armcpu_spi_distribute` 分到 CPU 1–3
  （開機碟 99 次在 CPU 1，網卡約 1 萬次各在 CPU 2、3）。
- 11-17 以為沒效，是因為 `DroidVMGicMsi` 印的 IROUTER 讀回值都是 0：Gunyah 讀每條 SPI 的 IROUTER 都回 0（確定有效的 SPI IPI
  那幾條也是），讀回值不能當證據。
- 實驗中改用兩次 32 位元寫入（低半、再寫高半 0）後線都回到 CPU 0：要一次 64 位元寫入。
- virtio-mmio 的線與我們 PCI 輸入裝置的線仍掛在 CPU 0（attach 時的路由）。

### 7. 輸入驅動接 PCI 上的 virtio-input

App 的 `virtio_transport` 設 pci、extra_options 不加 `--virtio-mmio-input` 時，輸入裝置都在 PCI 上，原本由 Apple 的
AppleVirtIOInput 當成一般鍵盤、滑鼠、觸控板接走（沒有觸控螢幕、筆、感測器、我們的觸控板）。

| 檔案 | 作用 |
|---|---|
| `DroidVMVirtioPci.c/.h` | virtio-pci（modern）傳輸。驅動照用 virtio-mmio 的暫存器位移，這裡翻成 common／notify／ISR／device config 的存取；設定空間走 ECAM（`/arm-io/pcie`），BAR 用 Apple 配好的位址；MSI-X 向量 0 由這裡寫，指到 MBI 範圍頂端一條空的 SPI（MSI 控制器從底部發） |
| `DroidVMVirtioPciNub.cpp` | `DroidVMVirtioPCI`，放在 DroidVMGicMsi kext：以 PCI id 佔住 virtio-input function、發布它的位址，不碰裝置 |
| `DroidVMVirtioPciWatch.cpp` | 輸入 kext：驅動啟動時掛配對通知，把佔住的 function 交給 `droidvm_input_add_pci` |
| `DroidVMVirtioInput.c` | PCI 裝置的暫存器存取走傳輸層；啟動後也能加裝置（同一把鎖、worker 隨第一個裝置啟動、中斷模式隨裝置數重算） |
| `HidInputProbe.cpp` | 筆、滑鼠、觸控板、感測器的 HID 服務改由 `native_hid_input_extras` 發布，每種一次，PCI 裝置加進來時再跑一次 |

陷阱（都在 5566 實際踩到）：

- **AppleVirtIOPCITransport 的 probe 把分數設成 10000**：我們的 personality 用 2000 時一個 function 都搶不到，也沒有任何訊息
  （io=0x16 看得出我們的 class 連 probe 都沒被叫）。改 20000。
- **佇列在 MSI-X 設好之前就啟用**：佇列向量被寫成 NO_VECTOR，裝置一次中斷都不發，輸入只靠 250 ms 保底輪詢在動。改成先設中斷
  再啟動裝置（reset 會清掉向量，status 每次寫入後補設設定向量，佇列啟用前設佇列向量）。
- **新 kext 放不進 KC 的 `__DATA`**：獨立的 DroidVMVirtioPCI kext 讓 fileset-add-kexts.py 報「past the chain table of __DATA」，
  所以放進 DroidVMGicMsi kext。
- 先前推論「輸入 kext 在早期配對時載不進來」是錯的，真正原因是上面的分數。

驗證（5566，macOS，開機碟、網卡、USB、7 個輸入裝置都在 PCI）：每個 function 拿到自己的 MBI SPI（INTID 121–127）；開機幾分鐘
中斷 30920 次，保底逾時 27 次、其中 1 次才有資料；Spotlight 打字、觸控點計算機按鈕、感測器資料約每秒 370 筆；鍵盤、筆、觸控
指標、滑鼠、觸控板、3 個感測器的 HID 服務都有。

### 回歸（最終版：fork f54247a、device 67e84ee、ArmCpu 652675b，gpumerge 樹乾淨建置）

| guest | 結果 |
|---|---|
| iPadOS 27 | 主畫面、GPU 13 clients 0 逾時、en0；6 種輸入裝置、鍵盤／觸控／筆、觸控板、3 個感測器的 HID 服務都在，滑動有事件 |
| macOS 27 原本的 MMIO 設定 | 桌面、網路、7 種輸入裝置與 HID 服務、觸控與按鍵事件 |
| macOS 27 PCI＋USB＋輸入在 PCI | 見上（最終版只差註解與 iPadOS 那邊的巨集） |

5566 結束時跑 macOS 27 原本的 MMIO 設定、最終版。rig 的工具：`m1118/pcicfg.py` 多了 `pci-input`（PCI＋USB，輸入也走 PCI）。


## 開了 xHCI 時 PCI 網卡起不來（11-18，已修）

### 原因

- crosvm（arm64）的 goldfish 電池跟 PCI 32 位元 BAR 從同一個位址池配置，排在 crosvm 放的最後一個 BAR 後面；FDT 卻把整個池
  （0x2000000+0x2000000）都宣告成 PCI 視窗。
- macOS 的 IOPCIConfigurator 會自己重排所有 BAR（Linux 保留韌體配好的，所以沒事）。多一個 xHCI（64 KiB BAR，排第一）時，
  排列變長，網卡的 BAR 落在 0x2018000+0x8000，蓋住電池（那次開機在 0x2019000）。沒開 xHCI 時排列只到 0x2018010，碰巧沒蓋到。
- crosvm 的 `PciRoot::config_space_write` 搬 BAR 時 `mmio_bus.insert` 因重疊失敗，錯誤被 `let _ =` 丟掉：網卡從此沒有映射，
  所有存取都是 `MMIO-UNMAPPED`（crosvm stderr），讀到 0。
- guest 端看到的樣子：AppleVirtIOPCITransport 有發布、MSI 也分到了（INTID 84–87），但 AppleVirtIONetwork 的 start 在等完
  IOBSD（IONetworkController::start 的 `waitForService("IOBSD")`，約 26 秒）之後失敗，沒有 en0 → IOTimeSync 沒介面 → 黑屏。
  11-17 以為的「MSI 向量不夠」不成立（`--mbi-spis 128` 一樣、ioreg 看得到向量）。

### 修法（crosvm da647254c，`wip/virtio-mmio` 與 `wip/hackintosh`）

| 改動 | 說明 |
|---|---|
| 電池移出 PCI 視窗 | arm64 固定在 0x8000（MBI 幀後一頁），不再隨 VM 的 PCI 裝置數量移動；`add_goldfish_battery` 多一個固定位址參數，x86 照舊配置 |
| 被拒的 BAR 搬移改成等待 | 重疊被拒的 BAR 記成 pending，之後任何裝置移走範圍就重試（真硬體上兩個裝置各解碼自己的 BAR，一次搬一個時本來就會短暫重疊） |
| 解碼關著的裝置不留舊映射 | crosvm 建 VM 時不管 COMMAND 有沒有開解碼都把 BAR 掛上 bus；解碼關著時 guest 改寫 BAR（沒有驅動的裝置），舊位址的映射原本會一直留著 |
| remove 只刪自己的 | `Bus::remove` 只比對位址，會刪到別的裝置；改用 `remove_owned`。裝置對自己已掛上的範圍再 insert 不算錯 |

我們的三條 board 都用 DarwinBoot `--dynamic`，電池位址從 FDT 讀，搬家不用改 guest。macOS-DroidVM 也不用改：它的 VM 沒開電池（CI 用的
`configs/k27-generated.dtb` 沒有 goldfish 節點，ADT 也不做電池節點），每次 prepare 都從手機當下的 FDT 重做 ADT，PCI 視窗與其他位址都沒變。

### 驗證（5566，新 crosvm）

| guest | 結果 |
|---|---|
| macOS 27，開機碟與網卡在 PCI、開 xHCI | AppleVirtIONetwork 掛上、en0、IPv4／IPv6、流量；沒有 `MMIO-UNMAPPED`；電池在新位址讀到 79% |
| macOS 27 原 MMIO 設定 | 開機、en0、GPU |
| iPadOS 27 | Data、SpringBoard、GPU 12 clients 0 逾時、en0；guest 裡 ioreg 讀到電池 79%、4077 mV |
| Ubuntu | 14 個 PCI 裝置、上網、crosvm 沒有 BAR 等待訊息（這台沒開電池） |
| Windows 11（開 USB） | 開到桌面、有線網路已連線、tap 雙向有流量；crosvm 沒有 BAR 等待或 `MMIO-UNMAPPED`；裝置管理員的「其他裝置」（PCI 裝置 0:10、0:12 與 4 個 ACPI 裝置）都是 Code 28 沒驅動，沒有資源衝突；在系統內 `shutdown /s /t 0` 關機，crosvm 正常結束、池子回滿 |

### 工具：kernel 檔案信箱的 IORegistry（device efde148）

- `export.py ioreg [FILTER] OUTPUT`：整棵 service plane，ioreg 的格式（class、id、registered／matched、busy、retain），FILTER 命中的
  節點與其子樹帶屬性（`*` 全部）。沒桌面、沒網路時也能用，1 秒內回來。
- 屬性用 `dictionaryWithProperties()` 複製，不走 `getProperty()`：IOPCIDevice 被讀 `IOInterruptSpecifiers` 時會順便把 MSI 向量
  定下來（IOPCIFamily 的 resolveInterrupts），會改變正在看的東西。
- iPadOS 27／macOS 27 的 board core 都有（kind 9）；iPadOS 17 的信箱沒有。iPadOS 27 已部署（5566，efde148 的 release，deploy27）：
  1.2 秒拿到整棵樹，電池 79%、4073 mV；部署後主畫面、GPU 13 clients 0 逾時、en0 正常。

### 方法與陷阱

- IOKit 的 `io=0x6`（probe／start）開機參數在 development kernel 裡有效：失敗的 probe 與超過 0.5 秒的 start 走 IOLog（序列埠
  sbsa1 看得到）；`::start(...) failed` 走 kprintf，這台看不到。這次靠「AppleVirtIONetwork start took 26514 ms」確定 start 跑完了。
- `unixnu.toml` 的 args 在開機碟（FAT）上，`mcopy` 改一份推上去就能加開機參數；還原推回原碟。
- Apple kext 的反組譯：KC 裡 AppleVirtIO 有 1721 個符號；scratchpad 的 `kdis.py`（stub 經 chained fixup 解析成目標）與 `vt.py`
  （vtable 槽位 → 方法名）。
- 要讓網卡走 PCI：`virtio_transport` 設 pci、extra_options 拿掉 `--virtio-mmio-net`（mmio 模式下 App 會自己補），rig 的
  `unixnu-vm.config.json` 與 daemon 兩邊都要改（scratchpad 的 `pcicfg.py orig|pci|pci-xhci` 一次改兩邊）。

## 第 2 步與「一個 binary」（11-17）

使用者問：macOS 現在 mmio 版和 pci 版要編譯期指定嗎？能不能做成一個 binary，bootloader 生成 ADT、XNU 自動偵測，偵測不到就由
bootloader 補開機參數，host 兩種都提供、guest 兩種都能用。

- macOS-DroidVM（另一位貢獻者的線）是開機前決定：`MACOS_PCIE`、`MACOS_NET_PCI`、`MACOS_DATA_PCI`、`MACOS_USB_PCI` 這組環境變數
  同時影響 `k27/try.sh` 的 KC 內容、`scripts/run-macos-vm.py` 離線做的 ADT（從抓下來的 FDT），以及 `scripts/droidvm-app.py` 的 VM 設定，
  三者要一致。它自己的文件記錄過同一個 KC 只換 ADT 就能改走 AppleVirtIO，所以真正逼它換 KC 的只有兩個替身驅動（佔住 en0 的
  DroidVMEthernet、頂替 IOUSBHostFamily 的 ARMPlatformStandIn）。
- host 本來就兩種都有：crosvm 每一類裝置都能放 MMIO 或 PCI（`--virtio-mmio-{block,input,net,gpu,snd,media,console}`），App 的
  `virtio_transport`（mmio／pci，整台 VM）在 MMIO 時自己加 input、net、gpu（有聲卡、console 時也加）這些開關；個別裝置要留在 MMIO
  就寫進 extra_options。這次 host 沒改。

### 改了什麼（全部已推 `wip/hackintosh`）

| repo | commit | 內容 |
|---|---|---|
| ArmCpu | afddd58 | SPI 槽 16 → 128，依 INTID 直接查槽；attach 加鎖並等 GIC 就緒；`armcpu_spi_set_enabled`、`armcpu_spi_distribute`（取自 macOS 線三個 ArmCpu 補丁） |
| DarwinBoot | ac57c33 | FDT 有 MBI 幀時生成 `/arm-io/pcie`（`pcie,vmapple1`，Apple 橋的契約：28 位元組小端 ranges、`device-interrupt-parent` 'MBIF'、`msi-frame-index` 0）與 `/arm-io/gic-mbi`；arm-io 的 ranges 拉長到涵蓋 64 位元 PCI 窗口（0x4_2000_0000）。沒有 MBI 幀時輸出逐位元不變 |
| fork | c0b97b2 | 兩個 gitlink |
| device | 5b41b7d | macOS KC 加 AppleVirtualPlatform、AppleVirtIO；新 kext DroidVMGicMsi（macOS 線的 MSI 控制器，掛在 `/arm-io/gic-mbi`，`AppleVirtualPlatformPCIE` 的 personality 改掛 IOPlatformDevice）；網路 kext 在沒有 MMIO 網卡時也發布 IOTimeSync 等的資源（等到任何 Ethernet 介面或 10 秒） |
| device | 6a93e50 | 虛擬 GPU 傳輸的 256 個 slot 表改從 heap 配（24 KiB）：多保留的 Apple kext 吃掉了板級 kext 的 `__DATA` 空洞，少一頁放不下 |
| device | c29df5c | xHCI 驅動先不放進 KC（見下面「沒解決的」） |

偵測全在執行期：IOKit 依 ADT 節點與 PCI 列舉配對，我們的 MMIO 驅動只在 DarwinBoot 生成的 MMIO 節點上啟動，Apple 的 AppleVirtIO 接
PCI 上的 virtio 裝置。iPadOS 也拿到這兩個節點，但它的 KC 沒有對應驅動，不受影響。沒用到開機參數。

### 驗證（5566，macOS 27 與 iPadOS 27，gpumerge 樹的乾淨 git 建置）

| 設定 | 結果 |
|---|---|
| macOS，`virtio_transport` mmio（原設定） | 照常開機、網路、GPU；PCI 匯流排上本來就有 crosvm 的 pvpanic 與一個 virtio 裝置（1af4:107c），Apple 橋列舉、AppleVirtIOPCITransport 接上 |
| macOS，pci（開機碟與網卡在 PCI，其餘用 extra_options 留在 MMIO） | 韌體與 DarwinBoot 從 virtio-pci 讀開機碟；AppleVirtIOBlockStorageDevice 接開機碟（FAT 由 FSKit msdos 唯讀掛上）；AppleVirtIONetwork 成為 en0（configd 依資料庫給 unit 0），IPv4／IPv6 對外 TCP 正常；MSI：INTID 64（碟）、84–87（網卡，1.2 萬／8 千次中斷）；桌面、鎖屏、解鎖 |
| macOS，pci 但網卡留 MMIO（只有開機碟在 PCI） | 鎖定再解鎖正常 |
| iPadOS 27（同一批 ArmCpu、DarwinBoot、GPU slot 改動） | 主畫面、GPU 15 clients 0 逾時、virtio-gpu 0 錯誤、網路、音訊 clients 2 0 延遲 |

測完 macOS VM 設定已還原（mmio、原 extra_options、沒有 xHCI），5566 跑 macOS 27 新版。

### 沒解決的

- ~~開了 xHCI 時 PCI 網卡起不來~~：11-18 修好，原因是 crosvm 的電池位址與 BAR 重排（見上節）。
- ~~**xHCI 驅動**~~（11-18 修好：IOUSBHostFamily 列為 KC root，見最上節）：`AppleUSBXHCIPCI` 的 start 卡在 `waitForMatchingService('AppleUSBHostResources')`（IOUSBHostFamily 的 IOResources
  personality，一直沒註冊）。macOS 線靠 ARMPlatformStandIn 頂替 AppleSMC 與多留幾個 USB kext 走通；我們的 KC 帶的是真的 AppleSMC。
  先從 KC 拿掉（c29df5c），VM 開了 xHCI 也只是沒人管。
- **網卡在 PCI 時解鎖卡過一次**：開機自動登入後自動上鎖的那個鎖屏，輸入密碼後畫面停住（WindowServer 不再送 GPU 工作，執行緒都在
  等訊息，kernel 沒卡）；之後同設定手動上鎖再解鎖正常，那個自動上鎖沒再出現，沒能重現。3 次解鎖 1 次。
- ~~**MSI 分散到各 CPU 沒效果**~~（11-18：其實有效，是 Gunyah 讀 IROUTER 永遠回 0，見最上節）：`armcpu_spi_distribute` 寫 IROUTER 後讀回都是 0，全部 MSI 仍由 CPU 0 處理（照樣能用）。
- **macOS 沒有任何網卡就開不到桌面**（原本就這樣）：IOTimeSync 要一個網路介面的位址當時鐘 ID。
- **我們自己的驅動還只有 MMIO**：GPU、media、音訊、Data 盤（擁有者鏈驗證）；輸入 11-18 兩種都行了（見最上節）。這些類別放
  PCI 時目前沒人接；要給這幾個驅動加一層 virtio-pci 傳輸（IOPCIDevice personality、modern capability、MSI-X），之後才算「兩種都能用」。
  Apple 有驅動的類別（block、net、console、entropy、基本鍵盤滑鼠、sound）已經兩種都行。
- App 的 `virtio_transport` 是整台 VM 一個選項；要逐類別選，現在只能靠 extra_options。

### 方法與陷阱

- macOS VM 沒有 ssh：`export.py`（檔案信箱）可以讀 guest 的檔、列行程、拿 stackshot；`peek.py __ZL4gSpi` 看 ArmCpu 每條 SPI 的
  INTID 與次數（MBI 是 64 以上）；unified log 用 `logarchive.py` 增量拉，再只硬連結開機後修改過的 tracev3 做成小 archive 給
  `unifiedlog_iterator`，訊息欄位用 python 過濾（整份 archive 直接 grep 會輸出幾十 GB）。
- rig 的 `vm.sh start` 先跑 `daemon-recover.sh`，以 rig 自己的 `unixnu-vm.config.json` 為準：改 VM 設定要兩邊一起改（daemon 用
  `vm_modify`，rig 改那個檔）。
- `deploy27.sh --keep-plugin` 留下的舊插件不在新 release 的信任裡時，iPadOS 的 GPU clients 會是 0；iPadOS 要讓 deploy 把插件推進去。
- 新增 kext 或多留 Apple kext 都會吃 `__DATA` 空洞：`fileset-add-kexts.py` 報「past the chain table of __DATA」就是不夠（root 的
  chain table 只涵蓋到原 KC 的頁數，最後 3 頁不能用）。

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
  11-17 再換成 ee11a29（PPTT、PR #5，標頭一樣是 `b 0x20000`，App 照常開 MSI；舊檔 `.bak-a7903f0`）。
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

## 第 2–4 步（11-16 寫的原計畫；第 2 步的實作見上）

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
