# UniXNUSetting：iPadOS 內的管理介面（細節）

狀態：2026-10-28。大方向見 `PROGRESS.md` 的「TODO 2」與 10-28 下午續報；本文件放細節。
定位決策（10-28 晚修訂）：UniXNUSetting 是 **ownervisor 的 in-app GUI**——staged 系統 app（不可刪）、以 mobile 跑；要 root 的操作經本機
socket 交 kernel 以 root spawn 的 ownervisor 執行。**不做特權 app**（persona 提權不通，§3）。存取控制與防刪見 §3.1。

本輪（10-28）主要把「能簽哪些 entitlement、簽多大、怎麼挑」這件事實測清楚，產物都在 `plans/unixnusetting/`。

## 1. debug shell（applebox）

debug shell 是 UniXNUSetting 的除錯子系統，也是 ownervisor 以外、未來要收斂掉的 owner 工具的接班人。

### 1.1 組成

- **applebox** = 單一 multicall binary：
  - **Apple OSS 的 `_cmds`**（file/text/shell/adv/network…）為主；
  - **toybox** 只補 Apple OSS 沒有的缺口（xz、timeout、watch、od…）；**兩邊都有的一律用 Apple OSS 版**；
  - 以 `ld -r` + exported-symbols-list 把符號 localize 併成一顆（一個 cdhash、一組 entitlement）。
  - 研究報告：scratchpad `applebox-research.md`、`libimobiledevice-path-research.md`（前一輪）。
- **dropbear**：ssh；login shell exec applebox-zsh → 滿權限 shell。
- **libimobiledevice**（靜態 OpenSSL）：**研究用**，待機內配對通了才接上線（配對是獨立 track，見 §4）。
- **lldb server（debugserver）**：建議加入，見 §1.4。
- （舊 `gfxprobe` → `debugutil`：改用 §1.2 的 curated debug 集，收掉它殘留的配對實驗 entitlement。）

每個工具都 ad-hoc 4K 簽名、帶 §1.2 的 entitlement、cdhash 進 owner trust bundle（`build/owner-trust-extra/*.json`，
category 3）。簽名/信任流程照 `scripts/build-droidvm-gfxprobe.py` 的樣子。

### 1.2 entitlement 策略——實測結論

**沒有單一「萬能」entitlement，也不能把全集簽上去。** 實測（captest 探針，見 §1.3）：

- **AMFI 有 blob 大小上限。** stock 全集聯集（3430 key，XML ~338 KB / DER ~233 KB）簽上去，exec 時被 AMFI 殺，
  kernel log：`mac_vnode_check_signature: ... AMFI could not load its entitlements for validation: entitlements too large`。
  - XML **168 KB 可過、338 KB 被拒** → 上限約落在 **256 KB XML** 一帶（未精確逼近；要時可再 bracket）。
  - 最大的 stock binary 是 `/Applications/Preferences.app`：XML 58.6 KB / DER 40.3 KB，全數通過 → 「設定」級的量一定安全。
- **所以做法是 curate，不是全簽。** 範圍內盡量塞除錯/管理能力即可，空間很寬（我們目前的集才 17 KB）。
- 之後若要縮更小／搬進 kernel（`cap.sys_admin` 一個 key、kernel 內展開全集）是另一條路，見 `PROGRESS.md`；**kernel 路線先擱置**。

**目前的 curated 集（`plans/unixnusetting/debug-entitlements.plist`，由 `gen-debug-ents.py` 產生）**：
**109 個 key、plist 18 KB / 簽入 binary 約 17 KB**，離上限還很遠。組成三塊：

1. **gdb 級 process 除錯原語**（抄自 stock 的 `debugserver` + instruments `dtsecurity` + `taskinfo`/`spindump`/`ReportCrash`）：
   - `com.apple.private.cs.debugger`（當 debugger：繞過 CS、attach、讀寫目標記憶體、下軟體中斷點）
   - `com.apple.private.thread-set-state`（設目標 thread 暫存器 → 硬體中斷點、單步、改 PC）
   - `com.apple.private.set-exception-port` + `com.apple.private.host-exception-port-override`（接中斷點的 Mach exception）
   - `com.apple.system-task-ports`(+`.control`/`.read`/`.inspect`/`.name.safe`/`.token.corpse`)（拿任意 process 的 task port，== task_for_pid）
   - `com.apple.private.stackshot`、`com.apple.private.memorystatus`、`com.apple.private.kernel.override-cpumon`、`com.apple.private.pac.exception`、`com.apple.private.crash-reporter`
   - `com.apple.{backboardd,frontboard,springboard}.debugapplications` + `.launchapplications`（以 debug 模式啟 app 再 attach）
   - `com.apple.security.network.client`/`.server`（debugserver 的 TCP endpoint）
   - 註：iOS **沒有 macOS 的 `task_for_pid-allow`**，對應能力是 `com.apple.system-task-ports.*`。
2. **lockdownd 全套**（目標：debug shell 能**代替 lockdownd 操作 iOS**）——把 stock `/usr/libexec/lockdownd` 的 entitlement 整包併入，
   只排除 3 個會「改身分／反而受限」的（見下）。代表性能力：`mobileactivationd.spi`（activation）、`mobileinstall.allowedSPI`、
   `mobile_storage.allowedSPI=[CopyDevices]`、`managedconfiguration.profiled-access`、`private.system-keychain`、
   `security.storage.Lockdown`（寫 `/var/db/lockdown`）、`securityd.ae.lockdown`、`PairingManager.Read/.Write/.RemovePeer`、
   `dt.remotepairing.pairingmanagement/.tunnelmanagement`、`private.iamlockdown`、`tcc.allow=[FaceID,Photos]`、
   `keychain-access-groups=[com.apple.mobile.lockdownd, lockdown-identities]`、NFC/SMC/gasgauge/camera-iokit、`wifi.manager-access` 等。
   還有 client gate 的 `lockdown.finegrained-get/-set/-remove`（取 stock **完整 union**：66/43/32 個 `NULL/<Key>` 值）+ `mobile.ldpair` + `lockdownd.allow-save-value`。
3. **周邊 debug**：no-sandbox、no-container、logging.diagnostic/admin/stream、diagnostics、kernel.get-kext-info、
   DiagnosticReports.read-write、AppDataContainers、MobileGestalt.AllowedProtectedKeys（18 個裝置識別）、
   iokit-user-client-class（GPU/display/report/HID/storage 共 ~24 個，含 lockdownd 的 7 個）、powerd/reboot 便利鍵。

**排除（不能照抄，否則有害）**：
- `application-identifier`、`seatbelt-profiles`：會把工具**標記成 lockdownd 的身分、或塞進 lockdownd 的 sandbox profile**（我們要 no-sandbox）。
- `fairplay-client`：固定 FairPlay client id，是身分不是能力。

**未在 stock、保留但未證實**（AMFI 對未知 key 只忽略不拒，無害）：`com.apple.PairingManager`（裸）、`com.apple.mobile.ldpair`、
我們自家的 `com.apple.backboardd.setDeviceOrientation`。

### 1.3 驗證探針 captest

`plans/unixnusetting/captest.c`：ad-hoc 簽上要測的 entitlement、cdhash 進 trust、staged 到 `/private/var/ngpu/bin`，over ssh 跑。
- `captest ents`：用 `csops(CS_OPS_ENTITLEMENTS_BLOB)` 把 kernel 實際授予的 entitlement blob 讀回來，列出每個 key 名 → 一眼看出 AMFI 有沒有 strip 掉哪個。
- `captest persona`：persona 提權測試（§3）。
- 結論：**curated 集（25-key 版）與 109-key 全 lockdownd 集實測皆 100% 授予、工具正常啟動**（109/109，blob 17018 bytes，遠低於 ~256KB 上限；見 §5）。

### 1.4 lldb server（debugserver）——可以放，entitlement 已備齊

iOS 的 lldb remote server 就是 **`debugserver`**（Xcode / DeveloperDiskImage 內）。要跑它需要的 entitlement
（`cs.debugger`、`thread-set-state`、`set-exception-port`、`system-task-ports*`、`*.debugapplications`+`.launchapplications`、
`network.client/.server`、`memorystatus`）**§1.2 的 debug 集已經全部涵蓋**。所以放 lldb server 完全可行：
- 來源選項：(a) 取 Apple 的 `debugserver`（DeveloperDiskImage），ad-hoc 重簽 + cdhash-trust，最省；(b) 自 build llvm `lldb-server`（較大、要處理靜態連結）。
- 形態：`debugserver` 是獨立 binary（非 multicall），當 applebox 旁邊的獨立 trusted binary，或由 applebox 一個 `exec` 入口帶起。
- 用法：guest 內 `debugserver *:PORT --attach=PID`，host/PC 端 lldb `platform/gdb-remote` 連上（走 §1.2 的 network.server）。
- 建議採 (a)，列為 applebox 之外的第 5 個 debug 工具。

### 1.5 ipatool（.ipa 安裝器）—— 已實作並實機驗證（2026-10-28）

`package/ipatool/ipatool.m`、`scripts/build-droidvm-ipatool.py`（device repo，未 commit）。debug shell 的 .ipa 安裝工具——lsdiag 只有 owner-install/owner-register 兩半，ipatool 補成完整的「解壓→檢查→安裝→移除」。動詞：

- `ipatool scan IPA`：解壓到暫存，列出每個 Mach-O（主程式、Frameworks/*、PlugIns/*.appex 及巢狀 bundle）的 CDHash（SHA-256 取前 20 bytes，trust-cache 格式）與是否 FairPlay 加密（`LC_ENCRYPTION_INFO(_64)` cryptid≠0）。
- `ipatool install [-f] IPA`：scan + 若有加密 binary 則拒裝（`-f` 強制）；把 `Payload/<app>` 搬進 MCM bundle container、建 data container、向 LaunchServices 註冊成 User / ad-hoc。印出要信任的 CDHash。register 那步建議以 mobile（-u 501）跑。
- `ipatool remove BUNDLE_ID...`：先解析 proxy 取真 bundle URL 做 `unregisterApplication:`，失敗退回對稱的 `unregisterContainerizedApplicationWithBundleIdentifier:…`（**都在 destroy 之前**），再 `MCMContainer destroyContainerWithCompletion:` 砍 bundle 與 data container。
- `ipatool unpack IPA DEST`、`ipatool sels CLASS [SUBSTR]`（內省：列類別的實例＋類別方法，用來查私有 selector）。

實作要點：
- **解 zip 用 libz 自解**（iphoneos SDK 有 `libz.tbd`、裝置 shared cache 一定有 libz；`zlib.h` 從 macOS SDK 當 shim，`-framework MobileCoreServices` 讓 `LSApplicationWorkspace` 可用）。不用 libarchive：兩個 SDK 都沒出 `archive.h`。
- zip 解壓防穿越：擋絕對路徑與 `..` component。**不要用 `stringByStandardizingPath` 做前綴比對**——iOS 上它把 `/private/var`↔`/var` 改寫，會讓比對失準（踩過兩次）；路徑前綴一律同時接受兩種拼法。
- **entitlement 走 lsdiag 那組最小集**（no-container、canmaplsdatabase、rebuildappdatabases、mobileinstall allowedSPI、can-register-install-results、MobileContainerManager.allowed、storage.AppBundles/AppDataContainers），**不是** §1.2 的 109-key debug 全集：ipatool 是聚焦的安裝器，不是 debugger；全集留給 applebox／debugserver。
- 私有 selector 實機確認：MCM 砍 container 是 `MCMContainer destroyContainerWithCompletion:`；LS 反註冊是 `unregisterApplication:`（吃 URL）或 `unregisterContainerizedApplicationWithBundleIdentifier:operationUUID:unregistrationOperation:requestContext:saveObserver:unregistrationError:`；proxy 查找是 `+[LSApplicationProxy applicationProxyForIdentifier:]`（類別方法）。

**實機驗證**（用 Mac build 的 `IpaTest.ipa`，cdhash `af42fc0b…` 已加進開機 trust）：scan 算出的 cdhash 與 Mac codesign 一致、未誤判加密；install→`lsdiag -u 501 app` 顯示 `installed=YES valid=YES typeForInstallMachinery=User`、bundle 落在 `…/Bundle/Application/<UUID>/`；remove→`unregister OK`、兩個 MCM container `destroy OK`、`lsdiag` 回 `no record`、bundle 目錄消失。完整 install/remove 循環可重複。

**限制**：任意第三方 IPA 要能*執行*，仍需其每個 Mach-O 的 cdhash 被信任（開機 trust，或計畫中的 runtime-trust SPI＝kernel 第 2 步，目前擋住）。ipatool 只負責安裝/註冊並印出待信任的 cdhash，本身不授予信任。主機端 build、cdhash 已進開機 trust 的 IPA 可完整跑通（如上測試）。部署同 §3.2 gotcha：Mac 的 build tree 尚無 ipatool 原始碼與 `owner-trust-extra/ipatool.json`，payload-redeploy 前必須先同步原始碼到 Mac，否則重建的 trust bundle 會少掉 ipatool（與 app.sock ownervisor）的 cdhash。

### 1.6 applebox v1（已實作並實機驗證，2026-10-28）

`package/applebox/`（`debug-entitlements.plist` 從 meta repo 複製進 device repo）+ `scripts/build-droidvm-applebox.py`（device repo，未 commit）。

**定位**：applebox 是 Apple 自家 OSS 指令的 multicall binary（busybox/toybox 式，argv[0] 或 `applebox CMD …` 選指令）＝debug shell 的 coreutils。**shell 由 zsh 擔當（已建、Apple OSS），所以 applebox 不含 `sh`**（shell_cmds 的 sh 是 25 檔、要 yacc/產生器，最難建的部分直接免掉）；dropbear 當 ssh。三者分工乾淨。

**合併機制**（plan §1.1 的 `ld -r` + 符號 localize，已跑通）：
- 每個指令的 `*.c` 用 `-Dmain=<cmd>_main` 編譯（只有含 main() 的那檔受影響），產生物件檔。
- 每個指令再用 `ld -r -exported_symbols_list`（清單只有 `_<cmd>_main`）partial-link 成一顆 `<cmd>.cmd.o`：指令內部的 `usage`/旗標/helper 等全域符號變成該物件私有，跨指令不會撞名。
- 產生 dispatcher（`basename(argv[0])` 查表），把所有 `<cmd>.cmd.o` 連成一顆 `applebox`。
- 以 4 KiB 頁 ad-hoc 簽 **§1.2 的 109-key debug 集**（applebox 是滿權限 debug 工具，與 ipatool 的最小集不同），cdhash 進 owner module（category 3）。

**v1 指令集（33 個，shell_cmds 216.60.1 中 libc-only 的那批）**：apply basename chroot dirname echo env false getopt hexdump hostname jot kill logname mktemp nice path_helper printenv printf pwd renice seq shlock sleep tee test(＋`[`) true uname users what whereis which xargs yes。單一 binary ~160 KB。

**v1 捨棄（v2 用 shim/yacc 補；toybox 暫代）**：date（`protocols/timed.h`）、id（OpenDirectory.framework）、killall（`sys/user.h`）、nohup（`vproc.h`）、systime（`libproc.h`）、expr＋find（yacc `.y` 文法 + getdate）、who＋lastcomm（utmp/acct，iOS 無）。

**實機驗證**：binary 能跑（＝109-key debug 集在全新 binary 上被 AMFI 接受，再次確認 §1.2）；`--list` 列 34 項；echo/uname（真 `Darwin iPad7,1`）/pwd/printf/basename/dirname/env/test/`[`/mktemp/`kill -l`/which 正常；對 33 個指令名建了 symlink → applebox，`PATH=/private/var/ngpu/bin` 下裸名可用（`uname -s -m` → `Darwin iPad7,1`）。部署同 §3.2 gotcha（Mac build tree 尚無 applebox 原始碼與 trust json）。

**v2 方向**：併入 Apple OSS **file_cmds**（ls/cp/mv/rm/mkdir/stat/ln/chmod/chown/du/df/pax…）與 **text_cmds**（cat/head/tail/cut/tr/sort/sed/…），兩邊與 toybox 都有的用 Apple 版；為 date/id/expr/find 加 shim 或 yacc 步驟；debugserver（lldb server）當 applebox 旁邊的第 5 個獨立 trusted binary（§1.4）。

### 1.7 實作進度（2026-10-28 晚）：6-binary debug shell

使用者定案：debug shell ＝ **6 個 trusted binary**（applebox、dropbear、ipatool、ownervisor、libimobiledevice、lldb-server），**ownervisor 拉起 ssh + serial-shell**（mesa 已收回，圖形走原廠 kernel+plugin）。GUI（UniXNUSetting app）是唯一延後的部分。

| binary | 狀態 |
|---|---|
| applebox | ✅ v1（§1.6） |
| dropbear | ✅ 既有，ownervisor enabled 服務 |
| ipatool | ✅（§1.5，原 ipautil 改名） |
| ownervisor | ✅ app.sock（§3.2） |
| libimobiledevice | ✅ **已建**：Mac 交叉編 iOS arm64 —— libplist 2.6.0 + glue 1.3.1 + libusbmuxd 2.1.0 + OpenSSL 3.0.15（靜態）+ libimobiledevice 1.3.0，21 個工具（ideviceinfo/idevicepair/idevicesyslog/idevice_id/plistutil/idevicedebug/idevicedebugserverproxy…），no-container+network 簽、全數信任+staged+實機可跑。plistutil 完全可用；連裝置的工具乾淨回報 No device found（無 usbmuxd/配對＝§4 擱置 track）。build tree 在 Mac 的 /tmp/libimd-1028，尚未寫成 device-repo build script。 |
| lldb-server | 🔧 **路線定案、待建**：建 llvm-project 的 `lldb/tools/debugserver`(＝Apple debugserver 源碼,自足、不連 llvm/clang、有 arm64)。build＝`mig` dbgnub-mig.defs 產 mach_exc glue + 編 source/*.cpp + MacOSX/*.{cpp,mm} + arm64/*.cpp,連 Foundation/CoreFoundation/Security,用 109-key 集簽。第一關障礙(照 toybox/zsh 從 macOS SDK shim):mig 需 `mach/mach_exc.defs`(指向 macOS SDK)、`libproc.h`(iphoneos SDK 無,從 macOS SDK 複製),預期要逐一補標頭。尚未寫成 build-droidvm-debugserver.py。stub 到位後 applebox 的除錯 entitlement 讓 `debugserver 127.0.0.1:PORT --attach=PID` + host lldb 即可用,目標 app 不需 get-task-allow。 |

**serial-shell（更正:尚未可用,2026-10-28)**：原判「已做」有誤。截圖+marker 實測:App 的 **serial1 是 DarwinBoot loader 的 log**,凍結在交棒給 kernel;交棒後 **XNU 沒有把 console 接到任何 App 可見的 UART**(與既有 silent-panics 一致),`/dev/console` 是一條 sink —— 寫入被丟棄、讀不到輸入。所以掛在 `/dev/console` 的 serial-shell **不能用**(service 已定義但設為不自動啟動)。
- **serial 驅動診斷(2026-10-28)**:XNU 這塊板是 BCM2837 config,`pe_serial.c` 只編了 **PI3_UART = BCM2837 mini-UART(AUX)+ GPIO**,crosvm 不模擬 → 必然靜默。XNU **沒有 16550 驅動**(serial 列舉:APPLE/PI3/VMAPPLE/DCC),所以 serial1/NS16550 用不了。crosvm 硬體裡唯一對得上的是 **PL011**(pl011@6000,SBSA,console=true),而 XNU 的 **`VMAPPLE_UART` 就是 PL011 驅動**,但只在 `VMAPPLE.h` 定義,BCM2837 build **沒編進去**。
- **修法(兩個改動,要 kernel rebuild 才能部署測試)**:
  1. **kernel**:在 BCM2837 build 定義 `VMAPPLE_UART`。patch(等 Mac 的 kernel rebuild 解封再套,避免干擾正在進行的 build;**尚未**寫進 fork):
     ```
     --- a/pexpert/pexpert/arm64/BCM2837.h
     +++ b/pexpert/pexpert/arm64/BCM2837.h
      #define PI3_UART
     +#define VMAPPLE_UART   /* crosvm 有 PL011 但無 BCM2837 mini-UART;用 VMAPPLE 的 PL011 驅動 */
     ```
     PL011_* 常數與 vmapple_uart_* 全在 `#ifdef VMAPPLE_UART` 內,自足。PI3 仍會編但因 ADT 無 gpio/aux 節點而不註冊;VMAPPLE 因有 uart0 節點而註冊。
  2. **ADT**（`make-droidvm-adt.py`,**已改**）:自動從 FDT 的 `arm,pl011` 節點加 `/arm-io/uart0`,`reg = <pl011_gpa - ARMIO_BASE(0x1000), size>`;serial_init 做 `ml_io_map(soc_base(0x1000) + reg[0])` = 0x6000 = crosvm pl011。沒 VMAPPLE_UART 時此節點惰性無害。可用 `swap-adt.sh` 重生 ADT。
- **輸出落點**:PL011 = crosvm 的 **SBSA**（console=true,app_console backend）→ 顯示在 App 的 **SBSA tab**(目前空的),可輸入。所以修好後 serial console 在 **SBSA tab**(不是 serial1;serial1 是 XNU 無法驅動的 16550)。之後重新 enable serial-shell 即可。
- 讀 console 正確方式:`console.py PORT TOKEN VM serialN`,PORT=手機 `$RUN/droidvmd-port.txt`、TOKEN=`$RUN/droidvmd-token.txt`。
- **讀 console 的正確方式**:`dvmipc` argv1 是 **daemon IPC port**(手機 `$RUN/droidvmd-port.txt`),不是 adb serial;token 在 `$RUN/droidvmd-token.txt`。App 的 serialN=NS16550、SBSA=PL011(FDT stdout-path,edk2/DarwinBoot 路徑用)。
- 雙 serial(人+腳本)仍成立,但前提是先把上面的 console 接線做好。

**libimobiledevice 交叉編筆記**：用 **release tarball**(自帶 configure；Mac 無 autoreconf/pkg-config)；以 `<module>_CFLAGS/_LIBS` 環境變數繞過 pkg-config；libplist 2.6.0 與 libimobiledevice 1.3.0 在 `common/utils.h` 的 `PLIST_FORMAT_XML/BINARY` 列舉撞名 → 把 imd 自己那組改名。

## 2. entitlement harvest 與產生器（怎麼重建）

- **harvest**：`plans/unixnusetting/entdump.py` 掃一棵已掛載的檔案樹，把每個 Mach-O 的 entitlement 輸出成 JSON lines。
  21H461 的來源是 build Mac 上已掛載的 stock rootfs（`044-76040-038.dmg`）+ cryptex（`044-76034-038.dmg`）。
  產出 `ents-21H461.jsonl`（rootfs）+ `ents-21H461-cryptex.jsonl`（cryptex），共 2505 簽章 binary、1595 帶 entitlement、3658 個不同 key。
  （jsonl 含 Apple 的 entitlement 資料，**不進 repo**；需要時用 entdump.py 重建。）
- **產生器**：`plans/unixnusetting/gen-debug-ents.py` 讀 harvest jsonl，組出 `debug-entitlements.plist`。
  每個 scalar key 都對過 harvest（不發明），lockdownd 整包 merge、finegrained 取 union、MG/IOKit 取 union。
  改清單就改這支，re-sign 即可（輕量）；不必動 kernel。

## 3. persona 提權（已否決的 root helper 候選路線）

目標：mobile 身分的 app 要做需要 root 的操作。測了「用 `persona-mgmt` + `posix_spawn` persona override 取得 root 子行程」（TrollStore 式）。

- kernel 有完整 persona 支援（kernelcache 76 個 persona 符號、`kern_persona.c`、`POSIX_SPAWN_PERSONA_FLAGS`）。
- 這個 guest **沒有任何既有 persona**（`kpersona_pidinfo(self)` ESRCH、`find_by_type` 全空）——單使用者 iPad + 精簡 userland 不會建。
- 用授予的 `persona-mgmt` **`kpersona_alloc(DEFAULT, uid 0)` 成功**（拿到 id）。
- **root → adopt 該 persona override uid 0 → spawn 成功**（子行程 uid=0）。
- **euid 降 501 後再 spawn root persona → EPERM**（ruid 仍 0 的半吊子降權）。
- **純 mobile（fork 後 setgid/setuid 501，ruid=euid=svuid=501）→ spawn root persona → EPERM**（2026-10-28 實測，§5）。
- **結論**：persona override 要 spawn root 子行程，**呼叫者本身必須已是 root**；非 root（半降權或純 mobile 皆然）一律 EPERM。所以 **SpringBoard 啟動的 mobile app 無法靠 persona 自力提權到 root**——persona 不是 app 的提權途徑。
- **實務建議**：app 的 root 操作交給 **kernel 已以 root spawn 的 ownervisor root helper service**（app 經 ownerctl/socket 呼叫），這是唯一穩的路。persona 僅在「已是 root 的 owner daemon 要以特定 uid 跑子行程」時有用（root→任意 uid），不解決 mobile→root。

### 3.1 定案：root 操作交 ownervisor；存取控制與防刪（10-28 晚）

使用者定案：UniXNUSetting 本質是 ownervisor 的 in-app GUI，走 root helper（＝ownervisor）不違反「ownervisor 只除錯」；特權 app 不需要。
要守的是兩件事：

**(a) 未經使用者授權的第三方 app 碰不到 ownervisor 和 debug 工具**
- 現況（`package/ownervisor/ownervisor.m`）：兩個控制入口 `run/ctl.sock`（line-JSON）與 `control/<id>.req` spool，**都沒有對端驗證**，靠檔案權限
  （root、預設 umask）擋。`add` 動詞收 `{exec:[...], uid}`，能以 root 跑任何 trusted binary（`zsh -c …` 等於任意 root 指令）。
  → 這兩個入口**維持 root-only**（給 ssh 進來的 root shell 和 host 的 export.py 用），不開給 app。
- app 專用入口：新增 `run/app.sock`，權限開給 mobile（`0660 root:mobile` 或 `0666`），**關卡放在對端驗證**：
  accept 後 `getsockopt(LOCAL_PEERTOKEN)` 取 audit token → `csops_audittoken(CS_OPS_CDHASH)` 取對端 cdhash（用 token 而非 pid，避免 pid 重用競態），
  比對**payload 建置時寫進 ownervisor 設定的 UniXNUSetting cdhash**（它也在開機 owner trust bundle 裡）。不符就斷線。
  - **不能只看 entitlement**：AMFI 把任何 entitlement 授予任何 cdhash-trusted binary（§1.2 實測），之後 runtime 信任的使用者 IPA 也一樣，
    自稱帶 `org.droidvm.ownervisor.client` 擋不住。也不能只看路徑（路徑可換、可競態；cdhash 綁內容）。
  - 「經使用者授權」的那條路（可選、之後做）：ownervisor 存一份使用者核准的 client cdhash 清單，由 UniXNUSetting 介面讓使用者明確授權其他 app。
  - app socket 的動詞集可比 ctl.sock 窄（例如 `add` 只收預先定義的服務範本），降低「冒充成功＝任意 root」的衝擊。
- debug 工具（applebox／dropbear／debugutil／debugserver）所在目錄設 **root-only（`0700 root`）**：以 mobile 跑的 app 即使無 sandbox 也 exec 不到；
  它們只由 ownervisor（root）或 ssh 登入後的 root shell 執行。
- 第三方 app 預設在 sandbox 內，本來就碰不到 `/private/var/ngpu`；上面的關卡擋的是**無 sandbox 的 app**（日後的特權 IPA）和**冒充 UniXNUSetting 的 app**。
- UniXNUSetting 自己要連得到 `/private/var/ngpu/ownervisor/run/app.sock`：給一條 sandbox 檔案路徑 exception，或只給 `no-sandbox`（不帶大 entitlement 集）。

**(b) 使用中不會不小心刪掉**
- UniXNUSetting 當 **staged 系統 app** 放在唯讀 os.img（同 `staged_system_apps` 機制），不在可刪除系統 app 清單 → SpringBoard 長按不出「刪除」；
  檔案在唯讀卷上，誤刪也刪不掉。
- ownervisor 自身與 ssh、serial-shell 服務用 TODO 2 (4) 的 `protected` 旗標（可停不可刪）。

**待驗**：
1. ~~ownervisor 端 `LOCAL_PEERTOKEN` + `csops_audittoken(CS_OPS_CDHASH)` 取得對端 cdhash~~ → 已實作並實機驗證（下面「第 1 步」）。
2. sandboxed staged app 連 ownervisor 的 unix socket 需要哪條 exception（或直接 `no-sandbox`）。
3. staged app 長按確實沒有「刪除」。

### 3.2 ownervisor 端第 1 步：權限收緊 + `app.sock`（2026-10-28 完成，實機驗證）

不改 kernel，只改 `package/ownervisor/ownervisor.m`（加 `ownerctl --app`）。路徑暫時還在 `/private/var/ngpu/ownervisor`，第 2 步才搬。

- **權限**（ownervisor 每次啟動重設）：根目錄與 `run/` 為 `0711 root`（app 摸得到 `run/app.sock`，但列不出任何東西）；`tmp/` 為 `01770 root:mobile`；
  其餘子目錄 `0700 root`。`ctl.sock` 為 `0600`，`app.sock` 為 `0660 root:mobile`。seed 用 `hdiutil -owners off` 寫入的檔案擁有者是 `_unknown`(99)，所以也一併 chown。
  host 的 `export.py` 走 kernel，不受這些 mode 影響。
- **`tmp/`**（使用者要求）：client 可寫的交件目錄，例如 app 交給 ownervisor 的 IPA。內容由 client 控制，所以 ownervisor 讀裡面的檔一律 `O_NOFOLLOW` 並檢查擁有者，而且不往裡面寫。
- **`app.sock` 對端驗證**：`getsockopt(LOCAL_PEERTOKEN)` 取 audit token，再用 `csops_audittoken` 取 `CS_OPS_STATUS`（要有 `CS_VALID`）和 `CS_OPS_CDHASH`。
  kernel 會比對 token 的 pid 與 pid version，所以 pid 重用過不了關。cdhash 比對 `auth/app-clients`（每行 40 位 hex，`#` 之後是註解）。
  每次連線都重讀這個檔，改了不用重啟；沒有這個檔就全部拒絕（目前的狀態）。
- **`app.sock` 動詞**：只服務 `list/status/start/stop/restart/enable/disable`；`add/remove/reload/run` 回 `cmd not served on app.sock`，只留在 `ctl.sock` 和 spool。
- **防卡死**：ownervisor 是單執行緒迴圈，每個連線加 2 s 收發逾時，單一請求上限 64 KiB。
- **實測**（root 透過 ownervisor 起一次性的 uid 501 服務，所以 ruid=euid=501）：
  mobile 連 `ctl.sock` 得到 Permission denied；連 `app.sock` 未列名時回 `not an authorized client`；把 ownerctl 的 cdhash（`709bc416…`）列進去後 `status` 正常，`run`/`add` 被拒；
  mobile 能寫 `tmp/`，但列不出 ownervisor 根目錄、讀不到 `services.d/`；root 也一樣要列名才能用 `app.sock`；一個連上卻不送資料的 client 佔住 `ctl.sock` 時，下一個 client 2 s 後就被服務。
- **部署方式**（Mac 的 sync-check 還卡在 `build-arm-driver.py` 的 WIP，`payload-redeploy.sh` 走不了）：在 Mac 的暫存目錄 build（不碰共用 checkout），
  在本機把新的 cdhash（ownervisor `b36e13b1…`、ownerctl `709bc416…`）以 category 3 加進現有 owner trust bundle 的 owner module，保留舊的 hash 當退路，
  再用 `mcopy` 換掉開機磁碟上的 `kernel.macho.trustcache`。DarwinBoot 只驗結構，`board.toml` 的 pin 只在 build payload 時比對。pin 已改成 `5fe27b72…`。
  guest 端用 rename 換 binary（舊的留在 `bin/ownervisor.prev`、`bin/ownerctl.prev`）；換之前的磁碟留在 rig 的 `out/droidvm-disk.pre-appsock.img`。
- **注意**：Mac 的 build tree 還是舊的 ownervisor 原始碼和舊的 `owner-trust-extra/ownervisor.json`。如果在原始碼同步到 Mac 之前跑 `payload-redeploy.sh`，
  新的 trust bundle 會少掉 `b36e13b1…`，guest 的新 ownervisor 開機時會被 AMFI 殺掉，ssh 也跟著沒了。救法：用 `export.py put` 把 `ownervisor.prev` 的內容放回 `bin/ownervisor` 再重開機。

**第 2 步**（跟下一次 kernel rebuild 一起做）：owner 和 debug 的東西搬到 `/private/var/ownervisor`；GPU addon（上游的東西）留在 `ngpu`。
kernel 要改的有 `DroidVMLaunchPolicy.c` 的 spawn 路徑，以及 `DroidVMFileExport.c` 的寫入白名單（要加上 `/private/var/ownervisor/`）。板子 repo 其餘寫死的路徑約 26 個檔案。

## 4. 配對（獨立 track，擱置）

機內 lockdownd 配對：`GetValue/SetValue` 開、`QueryType/StartSession/Pair` 關（value-only），TCP 62078 要 TLS/密碼。見 `PROGRESS.md`。
未來研究 **免 USB 配對** 的鑰匙不是 client gate，而是 server/pair-record 側：`security.storage.Lockdown`（寫 `/var/db/lockdown`）+
`private.system-keychain` + keychain group `lockdown-identities`（pair record 的 host key/cert）+ `securityd.ae.lockdown`。
這些已全部進 §1.2 的集（debug shell 可代替 lockdownd），待逆向 pair record 格式 + crypto。

## 5. 驗證結果（2026-10-28 完成）

兩項在乾淨 kernel（f9514c7b + owner-trust bundle dd0c52b4，含 captest cdhash c362e879）上實測，captest 原始輸出存
`plans/unixnusetting/captest-ents.txt`、`captest-persona.txt`。

1. **109-key 全 lockdownd 集被 AMFI 全數授予 ✓**
   `captest ents`：`csops(CS_OPS_ENTITLEMENTS_BLOB) r=0`、`magic=0xfade7171`、`blob_len=17018`、**granted keys = 109**。
   點名要查的 key **全在、無一被 strip**：`private.security.storage.Lockdown`、`private.system-keychain`、`private.securityd.ae.lockdown`、
   `managedconfiguration.profiled-access`、`mobileactivationd.spi`、`private.lockdown.finegrained-get/set/remove`（三個都在）、
   `mobile.ldpair`、`iamlockdown`、`PairingManager(.Read/.Write/.RemovePeer)`、`dt.remotepairing.*`、`system-task-ports(.control/.read/.inspect/.name.safe/.token.corpse)`、
   `cs.debugger`、`thread-set-state`、`set-exception-port`、`host-exception-port-override`、`stackshot`、`memorystatus`、`persona-mgmt/.read/.write`。
   → **109/109 全授予，17KB blob 遠低於 ~256KB 上限**。curated 不設限、整包簽 lockdownd 完全可行。
2. **純 mobile 子行程 persona 提權到 root → 不行（EPERM）✓**
   `captest persona`：root→root persona override spawn 成功（子 uid=0）；**euid 降 501 → spawn root persona = EPERM**；
   **fork 後 setgid/setuid 501（ruid=euid=svuid=501）→ spawn root persona = EPERM**。
   → §3 的 EPERM 不是半吊子降權的假象：**非 root 一律不能靠 persona override 取得 root 子行程**。mobile app 自力提權此路不通，走 ownervisor root helper（§3）。

> 部署踩雷備忘：`deploy.sh --kernel-only` 推整顆 boot disk 但只換 kernel.macho、**保留手機既有 trustcache**；且 staged owner 工具（captest）
> 不隨 kernel 重推。本次 captest 被 AMFI `CT policy 0`（cdhash 不在 trustcache）kill，根因是手機上 staged 的是**舊版 captest 二進位**（cdhash≠c362e879），
> 非 trustcache 問題——重推對應 cdhash 的 binary 到 `/private/var/ngpu/bin/` 即修好，免重建/重啟。换 entitlement 集時務必 kernel/trustcache 與 staged binary 同步。

## 6. kext 載入（為什麼沒有）

iOS **沒有執行期載入 kext 的機制**：stock rootfs 上 `kextd`/`kernelmanagerd`/`kmutil`/`kextload`/`kextutil`/`kextcache` **全不存在**，
kernelcache 是 prelinked。所以**沒有對應 entitlement**（harvest 裡 kext 相關只有 DriverKit 的 `developer.driverkit.*`＝userspace dext、
以及 `kernel.get-kext-info`＝列舉已載入的 kext）。XNU 核心本身有 `kext_request`/`OSKext::loadFromMemory`，但 iOS 把 userspace 路徑拿掉+鎖死。
我們自己的 kernel 驅動是 build 時編進 kernelcache（`kits/droidvm`）。要 in-guest 可載入核心模組＝在 XNU fork 自己開這條路，屬 **kernel 路線（擱置）**。

## 7. 產物索引（`plans/unixnusetting/`）

- `gen-debug-ents.py`：curated debug/管理 entitlement 集的產生器（讀 harvest jsonl）。
- `debug-entitlements.plist`：目前成品（109 key / 17 KB）。
- `entdump.py`：從掛載的檔案樹 dump 每個 Mach-O 的 entitlement（harvest 工具）。
- `captest.c`：entitlement 授予 + persona 提權驗證探針。
