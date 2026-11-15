# macOS 27 on DroidVM through our pipeline (11-14 起)

使用者 11-14：「都做完」「OK繼續做完」，磁碟佈局照上游 UniXNU（OS 映像＋SystemOS 疊合根、Data 分開、保留驗證），
不走 macOS-DroidVM 的單一容器。

## 為什麼不照 macOS-DroidVM 的流程

子代理通讀 macOS-DroidVM（58359aa）的結論：腳本齊全，但缺原作者本機的東西，無法重現——
`../ios/tools/droidvm-app.py`（VM 註冊）、kernel 建置環境（KDK、Darling 工具鏈、`out/x12377/*`）、`UniXNU.efi`／
`edk2-macos.fd`、27.2 kernelcache 的來源 IPSW（AMFI GOT 槽位與 KC 版面綁死它）；還要求 UniXNU-droidvm bf7fc44、
DarwinBoot 85332b3。可借用的知識：

- 開機必要：磁碟（RAM block＋Data store）、NativeAES（沒有它 AppleImage4 panic）。
- 登入畫面必要：顯示、輸入、ARMPlatformStandIn（取代 AppleARMPlatform／AppleIISController／AppleAudioClockLibs／
  IOUSBHostFamily）、Ethernet（WindowServer 等 en0）、GPU＋Data 上的 Metal 外掛（沒有 Metal，WindowServer 每 30 s 崩潰）。
- AMFI 的 PAGE_SHIFT_CONST GOT 槽位改綁 kernel 的 `_k27_amfi_page_shift`（27.0.1 vma2：0xfffffe0007b439c8）。
- 開機參數（731 B）、`MACOS_BOOT_MANIFEST_HASH=1`（否則 Image4 panic）、ADT 的 `/chosen/asmb`、5120 MiB／8 vCPU。

## 輸入

- IPSW：UniversalMac_27.0.1_26A434（VirtualMac2,1 = vma2macosap，0xFE00／0x20），Mac `out/ipsw/26A434`：
  kernelcache（解壓 81 MB）、DeviceTree、三份 trust cache；OS（10.5 GB AEA）、SystemOS（2.3 GB AEA）、AppOS 下載解密中
  （log：Mac `/Volumes/DATA/UniXNU/logs/macos-members-26A434.log`）。
- fork profile `macos-27.0.1-26A434`（e4c8f28 補了身分與 trust cache）。

## 階段

| # | 內容 | 狀態 |
|---|---|---|
| 1 | 上游 macOS 的 kernel patch 挑選移植（疊合根佈局要的那些） | ✅ 11-14 fork 4672760：26 個上游 patch（firmlink、疊合根、唯讀系統、擁有者根已驗證開啟、Hardware／VM volume、App cryptex、GPU bundle、addon、apfs boot shim、文字主控台＋設定與診斷）；不收 payload／window／memwired（sheng 的記憶體視窗）與我們另有做法的；142 個 patch 依序套得上 |
| 2 | KC：XnuPrelink 的 macOS 支援、profile `[kernel.prelink]`（vma2 roots、AMFI early init、GOT 改綁） | ✅ 11-14 fork 37ceb37（XnuPrelink 440589b，按名字配對 3213＋280／3544）、device b476450（roots、`fileset-sites/fileset-26A434-symbols.json` 由 `fileset-add-kexts.py --sites` 套用）；collection 搬到 0xfffffff007004000（slide 0x1f000000000） |
| 3 | macOS kernel 連結（defconfig、archives、owner UUID） | ✅ 11-14 device b476450：`droidvm_macos27_defconfig`（`__TEXT,__cstring` 移進 `__TEXT_EXEC` 才放得進 Apple kernel 的 0x11c000）、board core 拆出、儲存 kext 兩個 OS 共用（kernel `__DATA` 槽 0x164000 放不下內建儲存）、Data store 緩衝動態配置；根 UUID 還是佔位 |
| 4 | 根映像（OS＋SystemOS，owner 簽章 policy）、Data 種子、trust bundle、ADT／payload | ✅ 11-14：`root-image-identity.py`（[root] 值，fork 655ab48）、policy 驗證 346 萬＋70 萬區塊；Data 種子不用 sudo：`make-droidvm-macos-seed.py` 在 lima VM 裡以 root 寫入（`make-macos-data-linux.py`，device 9cc425e）；ADT：vma2 身分、`--adt-table`（boot-uuid、asmb）、root-matching（c920aaa）；`build-droidvm-all.py --os`（2cca425） |
| 5 | macOS 的 kext：儲存、網路、顯示、GPU、輸入（device 814d788、06c78e6）；AES、平台替身用不到（沒有它們也開得起來） | ✅ 11-14；11-15 輸入在 app 上驗過（鍵盤、觸控點按與拖曳），加電池、cpufreq、音效、console（device d325d0f） |
| 6 | macOS 版 Metal 外掛 | ✅ 11-14：fork 013aa8c／820eb5c（`macos27` 目標，上游 e7c359c、d434fc2）、8641129（NativeMetal af958ac：上游 bd09ede 的 macOS 入口，IOGPUMetalDevice 子類別、WindowServer 是 render server）、35d4beb（Turnip 的 virtio-gpu 路徑照 `TU_DARWIN_SERVICE` 找加速器）；經 payload 的 GPU addon（`GPUBundles/`，`gpu-addon=1`）放到 /Library/GPUBundles |
| 7 | 5566 上建 VM、開機、除錯到登入畫面 | ✅ 11-14 第 13 次：自動登入到 Finder 桌面（Dock、選單列、小工具、桌布），WindowServer 用 Metal 合成，480 s 沒 panic。第 5-7 次：en0、IOTimeSync 註冊；WindowServer 打開 IOMobileFramebuffer 後每約 33 s 重啟（缺 Metal，同 macOS-DroidVM run 18）；Metal 加速器已發布（stage 5）。rig `droidvm-5566-macos`，VM `UniXNU-macOS27`：第 4 次開機到使用者空間——根（已驗證）、SystemOS、Data 掛上，launchd「Early boot complete」，140 個行程；還沒有顯示／輸入／網路（沒有 WindowServer）。修過：storage vtable（handleStart 的 reportRemovability 驗證失敗）、等 boot-uuid-media（改 root-matching）、mount-phase-1 的 apfs_boot_util EROFS（上游替身，c920aaa） |

### 開機記錄

1. panic 於 IOBlockStorageDriver::handleStart：我們的 IOBlockStorageDevice 少了 TARGET_OS_OSX 的 3 個槽（`-UTARGET_OS_OSX -DTARGET_OS_OSX=1`）。
2. 等 `boot-uuid-media` 到天荒地老：APFS 拿不到 iBoot 轉交的根雜湊就不發布；加 root-matching（IOMedia UUID）。
3. launchd 的 mount-phase-1 中止（apfs_boot_util 想寫唯讀的根 container）：上游 `apfs_boot_util` 替身放在 Data 種子，`apfs-boot-shim=1`。
4. 到使用者空間。
5. 網路 kext（Apple 的 IONetworkingFamily）：en0、clocksyncd 不再卡。
6. 顯示 kext（macOS-DroidVM 的 DroidVMDisplay，26A434 ABI）：WindowServer 打開 IOMFB、`map_display_type`，30 s 後找不到 Metal 裝置就退出。
7. GPU 核心端（AGXAccelerator : IOAccelerator）：`droidvm_metal_publish` 0／5／0。
8. 外掛裝上（/Library/GPUBundles），WindowServer 仍每 30 s 重啟：Turnip 的 virtio-gpu 路徑寫死找 `IOAcceleratorES`（只有 iPadOS 有），退回 KGSL proxy 被拒（`VK_ERROR_INITIALIZATION_FAILED`，外掛的文字列在 kernel 的 `native_adreno_metal_rows`）。
9. Turnip 修好：virtio GPU 開始有命令，WindowServer 不再崩；但第一個畫面後 4 s「MACH Reboot」，VM 卡死（平台沒設 `PE_halt_restart`）。
10-12. 加 PSCI 重設（DroidVMReset.c，會自己重開了）、`droidvm-reset-hold=1` 保留現場、印呼叫者與回溯：是 WindowServer 裡的 panic——IOMFB 交出主控台給 serial，寫到 arm64 唯讀的 `cons_ops_index`（`serial=3` 才會走這條）。
13. `droidvm-macos-console-switch.patch`：到桌面。

### kext 連結器的 macOS 能力（device 814d788）

- 依 libraries 解析 Apple kext 的符號（外部，找不到再用唯一的本地符號）。
- `vtables`：自有類別對原始類別逐槽比 PAC diversity；原始類別重新宣告為純虛擬的槽，用祖先的 diversity 放行。
- `patch_personalities`：改 collection 裡 Apple kext 的 personality（IOTimeSyncRootService 等 DroidVMNetwork）。
- spec 可帶自己的 `personalities`、可以沒有 `attach`；macOS kext 一律 `TARGET_OS_OSX=1`。
- kext 的 `__DATA` 空間很小（storage＋network＋graphics 用到幾乎滿）：大的靜態表要改動態配置。

### 除錯工具（macOS）

- `dmesg.py`（msgbuf）、`console.py PORT TOKEN VM sbsa1`（kernel 主控台在 sbsa1，不是 serial1）。
- `guestcpus.py`（`TH_THREAD_ID=1528`）：各 CPU 的執行緒與中斷狀態；`kext-syms.py out/kernel.macho 0 out/kexts-apple.nm`：Apple kext 符號（XnuPrelink 已換算成搬家後的位址）。
- panic 時 `debugger_current_op` 0、entry 1、沒有 panic 字串：panic 路徑自己又出例外（在 SP1 上），看 cpu 的 kernel 堆疊。
- `health.py`／`deploy27.sh` 的判斷是 iPadOS 的（backboardd、SpringBoard、外掛），macOS 會報 exit 1。
- 畫面：這台 VM 不在 app 的清單裡（deploy27 經 daemon 建的），手機看不到；`scanout-grab-phone.sh /data/local/tmp/sg <2048*2732*8>` 抓 virtio-gpu 掃描輸出的 udmabuf（`RGhA` 半浮點，每像素 8 bytes），numpy 轉 PNG。`fbgrab.sh` 是開機 framebuffer（只看得到文字主控台）。
- 外掛的進度文字：`peek.py native_adreno_metal_rows 6144`（取可印字串）；`native_adreno_open_log` 看誰開了加速器。
- panic：`panic.py`（11-14 起會找 4 KiB 頁內的位移）；`droidvm-reset:` 一行列出重開／panic 的類型、行程與回溯。

## 輸入、手機畫面與其他 kext（11-15）

結果（device d325d0f、Virtualization c8c132c55、crosvm 4c267a2e 部署在 5566）：macOS 在 app 的畫面上看得到也能操作——鎖定畫面
打密碼登入、桌面（桌布、Dock、選單列）、點按與拖曳、鍵盤辨識精靈走完；app 的 VM 清單也列出這台（vms.json 加入，備份
`vms.json.bak-20261115-macos`）。沒驗：app 的滑鼠模式（相對滑鼠）、雙指捲動／右鍵（adb 沒有多指）、音效出聲。

- **HID 探測沒跑**：`HidInputProbe.cpp` 要 `offline-hid-input=1`、`offline-hid-home=1`，macOS 的 kernel_args 原本沒有（board.toml
  補上）；macOS 的 IOHIDDevice 也是 0xd0 bytes，大小檢查照過。**不要** `sheng-touch-hid`：它讓鍵盤裝置帶 iPadOS 的觸控 collection，
  探測再把它的 service 改成 Built-In／DisplayIntegrated／Digitizer，macOS 的 dext 於是把每筆按鍵報告送進 digitizer 路徑丟掉
  （`createEventForDigitizerCollection generates null event`），WindowServer 也把它當內建觸控螢幕——密碼打不進去。
- **鍵盤辨識精靈**：鍵盤宣告 HID country code 33 仍會跳一次（VendorID／ProductID 為 0，macOS 不認得）；走完後存在 Data 的
  `/Library/Preferences/com.apple.keyboardtype.plist`（`0-0-33` → 40 ANSI）。新的 Data 種子會再跳一次，要省掉就把這個 plist 放進種子。
- **macOS kext 的 vtable 有保留槽**（`APPLE_KEXT_VTABLE_PADDING`）：IOHIDDevice 334 槽，iPadOS 207。NativeHidInput 寫死的 iPadOS 槽號
  （觸控邊緣標記包 `dispatchEvent` 的第 198 槽）在 macOS 是 `IOService::terminate`；ShengHidInput 24f1f3f 換槽前比對 PAC diversity，
  所以在 macOS 自動略過（邊緣標記與筆的傾角不作用，不會掛錯函式）。
- **macOS 不把觸控 digitizer 當指標**：`DroidVMPointerHid.inc`（只在 `DROIDVM_INPUT_MOUSE`，macOS 的輸入 kext）把觸控螢幕做成 QEMU
  式的絕對座標指標（單指停 80 ms 或移動才按下，點按＝左鍵、拖曳；雙指捲動；雙指輕點＝右鍵），app 的「滑鼠」模式（REL_X/Y）
  做成五鍵滑鼠，`DroidVMVirtioInput.c` 多認一種 `KIND_MOUSE`。iPadOS 不變。
- **手機上黑屏**：WindowServer 的主圖層是 `RGhA`（FP16），45 MB 的 surface 在 4 KiB 頁最多 10928 段，DroidVMDisplay 用 MaxCommand
  算的上限只有 8188 段，零拷貝掃描輸出每幀都失敗（kIOReturnNoResources），退回的 CPU 轉換（約 140 ms）只寫開機 framebuffer
  ——app 的顯示不看那塊。改用板子的 `MaxEntries`（16384，走 transport 的 huge request），`droidvm_display_scanout_why` 記失敗原因。
  零拷貝之後 host 端還得認 FP16：app 顯示端的 Vulkan 匯入只認 32-bit fourcc（`Failed to import display dmabuf ... 0x48344241`），
  Virtualization c8c132c55 加 AB4H／XB4H → `R16G16B16A16_SFLOAT`，blit 進 8-bit 時夾到 [0,1]（同 guest 自己的 CPU 轉換）。
  另外 macOS 閒置會關顯示器（`DroidVMDisplay: display off`）並鎖螢幕；叫醒它的是任何 HID 活動（log 裡看到的是動作感測器的方向事件）。
- **其他 kext 開給 macOS**：電池（IOPMPowerSource，選單列有充電中的電池）、cpufreq（6 個 vCPU 窗口）、音效（IOAudio2Family 也在
  macOS 的 collection；兩個裝置發布、coreaudiod 開了，出聲沒驗）起來了；virtio-console 是 0 個埠（這台 VM 沒設，iPadOS 那台也沒有）。
- **查 macOS 輸入的方法**：`logarchive.py` 拉 unified log（434 MB 約 17 分鐘，uuidtext 是上千個小檔），`unifiedlog_iterator` 轉
  JSONL（17 GB）後 grep 時間窗；`com.apple.iohid` 的「Service added」列出每個 HID 服務的用途與 transport，dext 的
  `IOUserHIDEventDriver.cpp` 行說明報告怎麼解析，「HID activity」說明哪個服務在送事件。
- rig：`input.py` 在 VM surface 還沒有 buffer 時改用它的背景圖層換算（之前退回全螢幕、點到螢幕外）；`vm.sh attach` 改看
  `droidvm_input_published`（動作感測器讓 `droidvm_input_events` 一直增加，判斷形同虛設）。

## Safari、游標、捲動（11-15 下午）

結果（device ec40561、50e48ec、be96aa2、683a9cd，fork 0c7637f，5566）：Safari 從 Dock 開得起來，apple.com（圖片、影片）、
example.com 正常顯示；app 的滑鼠模式看得到游標；雙指捲動方向對、距離和手指一樣；雙指輕點是右鍵（連結選單）。

- **App cryptex**：Safari 在 `Cryptex1,AppOS`（IPSW 成員 043-70637-690.dmg，54 MB 的 raw 映像）。fork 的
  `macos-app-cryptex.patch` 是 `#ifdef XNU_OWNER_APP_VOLUME_UUID`，之前沒定義，所以根本沒編進去（Dock 上的 Safari 是問號）。
  profile 的 `[root] app_volume_uuid`／`app_image_sha256` → kernel.py → owner-data-volume.h；root policy 多一條 App（依映像大小
  對磁碟）；release 多 `app.img`，deploy27.sh 推上手機並用 `tools/rig/vmdisk.py` 加到 VM（rig config、daemon、app 的 vms.json
  三份一起改，只改一份會被另一份蓋回去）。開機後 `native_owner_app_cryptex_stage` = 5。
- **掛好的 App cryptex 又被 DiskArbitration 拿走**：登入畫面時 configd 報「沒有 console user」，DA 把沒有
  `Physical Interconnect Location` 的磁碟都當外接（DeferExternal 預設 true），印出「console user is not logged in. unmounting
  disk」把 AppCryptex 卸下，登入後再掛到 /Volumes/AppCryptex——/Applications/Safari.app 指向空目錄。修法：storage kext 的
  NativeVirtioBlock／NativeRamBlock personality 帶 `Protocol Characteristics` = {Virtual Interface, Internal}（跟一般 storage kext
  的 Info.plist 一樣，personality 會成為 driver 的 property table）。附帶：桌面上的卷宗圖示不見了（Finder 預設不顯示內建磁碟）。
  不需要 macOS-DroidVM 的 `GIGACAGE_ENABLED=no`：WebContent 照常跑。
- **App cryptex 裡的代理程式被 AMFI 擋**：SafariBookmarksSyncAgent、SafariNotificationAgent、SafariLaunchAgent、
  PasswordBreachAgent、com.apple.Safari.History 在 `/System/Volumes/Preboot/Cryptexes/App/usr/libexec` 啟動時
  「Launch Constraint Violation」——真機的 cryptex 是 graft 上去的，這裡是另一個 APFS 卷宗，限制條件不成立。Safari 本身與
  WebKit 行程不受影響；書籤同步、通知等功能沒有。未處理。
- **雙指捲動方向反了、量太大**：macOS 的自然捲動也會反轉滑鼠滾輪，所以手指往上要送「朝使用者」的滾輪；HID 事件系統又把
  滾輪當滑鼠加速（IOHIDPointerScrollFilter），700 px 的手勢捲過整頁 Wikipedia。觸控螢幕的裝置現在帶
  `HIDSupportsScrollAcceleration` = false，每格是 `droidvm_pointer_scroll_px`（poke.py，預設 80）的手指位移：實測手指 400 px、
  頁面 400 px。滑鼠模式保留滑鼠的加速。
- **游標看不到**：登入過場後 WindowServer 把游標當獨立圖層（swap 的 layer 1，128x128 BGRA）送出，DroidVMDisplay 只顯示最大的
  surface。移植 macOS-DroidVM b29557d：DroidVMDisplay 宣告 `CursorPlane`，layer 1 的影像裁成 64x64 進 cursor resource，
  私有參數 -1（set_parameter：時間、x、y、可見）移動；transport 加 `cursor()`（virtio-gpu 的 cursor queue，UPDATE／MOVE_CURSOR）。
  app 原本就會把 virtio-gpu 的游標畫在畫面上。
- **測雙指的方法**：adb `input` 只有單指。`/data/local/tmp/mt`（靜態 aarch64，uinput 建一個 BUS_VIRTUAL、INPUT_PROP_DIRECT 的
  多點觸控螢幕，Android 當內建觸控螢幕送給 app），stdin 讀 `d/m/u/w` 指令；`gesture.py scroll|tap2` 用 input.py 的換算產生。
  滑鼠模式從 app 的選單（`fab_menu` → `mode_mouse`）切，crosvm 的滑鼠 socket 是 app 開的，外面注入不了。
- **音效**：系統設定 → 聲音選提示音，手機的 AudioFlinger 多一條 DroidVM app（vhost-user AAudio）的播放軌，輸出執行緒從
  standby 轉成播放、frames 一直寫；但那條軌是 -inf dB、PortMuted，因為手機的媒體音量（喇叭）是 0——路徑通了，要聽到得把手機
  音量調上來（沒有替使用者調）。macOS 的「輸出音量」滑桿一開始是灰的，打開選單後才出現在最大。
- **iPadOS 回歸**：這輪共用的改動（storage personality 的 Internal、transport 的 `cursor()`）以 dev 樹建的 iPadOS 27 在 5566
  開機：Data 掛上、325 個行程、SpringBoard 起來、12 個 GPU client、561 次 fenced submission 0 逾時 0 拒絕、0 個新崩潰；
  MetalCheck 42/42。
- **還沒解**：記憶體壓力——Safari 開著 apple.com 一陣子後 free 只剩約 14 MB、wired 約 2.25 GB（6 GiB 的 VM），Dock／
  SystemUIServer 被重啟、kernelmanagerd 重啟，app 轉圈，畫面停在桌布＋Dock（WindowServer 仍每秒 34 個 swap）。這次開機連
  Wikipedia 也一直轉不出內容（apple.com 正常，上一次開機 Wikipedia 正常），原因未查。cryptexd 從每 10 秒崩一次變成約 640 秒一次。

## iPadOS 回歸（11-14 晚）

macOS 這輪動到的共用部分（DroidVMGpu.cpp 的發布順序、DroidVMVirtioGpu3D.cpp 的表改動態配置、DroidVMReset.c、HidInputProbe.cpp、
NativeMetal af958ac、Turnip 的 service 名 patch）以 dev 樹建的 iPadOS 27 在 5566 上回歸：資料掛上、330 個行程、SpringBoard 起來、
411 幀、12 個 GPU client、570 次 fenced submission 0 拒絕；MetalCheck 42/42、GPU 錯誤／逾時 0。

## 陷阱（11-14）

- `unixnu defconfig --os macos…` 會改掉 unixnu 記住的選擇：之後的 iPadOS 建置要先 `unixnu defconfig droidvm_ipados27_defconfig`。
- unixnu 建置會把子模組同步回 fork 記錄的版本：試新的 XnuPrelink 要 `git update-index --cacheinfo` 先記進 index。
- tree 的 `scripts/` 是組 tree 時的複本，改了 device repo 的腳本要用 dev checkout 那份跑（或重組 tree）。
- `ipados27/scripts/build-droidvm-gpu.py` 等 4 支是指向 `../../scripts/` 的符號連結：`git add` 要加上層那個（8f3b25c 漏了，d48a512 補）。
- Mac 沒有免密碼 sudo：macOS Data 種子要保留 root／服務帳號的擁有者，得由使用者在 Mac 上 sudo 跑一次。
