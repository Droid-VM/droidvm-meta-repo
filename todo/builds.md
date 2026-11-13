# 構建線：iPadOS 17／27 與機型（iPad／iPhone）

2026-11-13 盤點。使用者問：目前成果怎麼整理、17 和 27 的構建怎麼管、具體要建哪一個（iPad 還是 iPhone）；
答覆後使用者說「先能重現」，同一天做完：**27 現在從 git 一條指令建出 release，5566 上跑的就是那一版**（第 3 節）。
第 1–2 節是現況，第 3 節是 27 現在怎麼建、怎麼部署，第 4 節是重現過程查到的事，第 5 節是還沒做的，第 6 節是要使用者決定的事。

## 1. 兩條 OS 線

| | iPadOS 17.7.11（21H461） | iPadOS 27.0.1（24A446） |
|---|---|---|
| 機型身分 | iPad7,1／J120AP（iPad Pro 12.9" 第 2 代，A10X） | iPad17,3／J820AP（iPad Pro 13" M5） |
| 使用者空間 | arm64 | arm64e（guest 要有 PAC；三支手機都驗過可用） |
| XNU | xnu-10063，傳統 prelink | xnu-12377 加 Darwin 26 的 syscall 補丁（Darwin 26 原始碼未公開），`MH_FILESET` |
| 裝置 repo 裡的位置 | 根目錄的 `board.toml`、`scripts/`、`configs/` | `ipados27/`（schema 2，自己的 `board.toml`、`scripts/`、`patches/`） |
| 共用 | `package/`（`ipados27/package` 是指回去的連結）、fork 的 GPU userland（plugin 與 Turnip 用 `--target ios27` 分） | 同左 |
| 最後一次建置 | 10-29（kernel） | 11-13（從 git 完整建置） |
| 從零建置 | `scripts/build-droidvm-all.py` 一條指令到 `release/`，rig `fresh-deploy.sh` 部署；10-29 驗過 | `ipados27/scripts/build-droidvm-all.py` 到 `release/`，rig `deploy27.sh` 部署；11-13 在 5566 驗過（第 3 節） |
| 在跑的手機 | 沒有。5566 上留著 10-29 的 VM 目錄；5568 搬到一半 | 5566（8 Elite Gen 5）、5567（8 Gen 3） |
| 10-30 之後的開發 | 沒有 | 全部（VPU 編解碼、WebGPU／WebGL 2、第三方 App 的 3D、Apple Pencil、觸控板、序列埠、IOSurface 同步、GPU 優先權、這週的閃爍與 hang） |

10-29 的計畫（`plans/IPADOS27_BUMP.md`）寫「17 在移植期間保持可建置」。實際上 10-29 之後 17 沒有再建過；
同一段時間共用的 `package/` 有 55 個 commit、38 個檔案、約 9000 行新增。**17 現在還能不能建、能不能開機，沒有驗過。**

## 2. 來源在哪裡

### git（本機 clone → 推送處）

| 元件 | 本機 clone（分支） | 推送到 | head（11-13） | 備註 |
|---|---|---|---|---|
| UniXNU fork | `UniXNU/orgrepos/UniXNU-m1101`（`merge-up-1101`） | Droid-VM/UniXNU `wip/hackintosh`（11-13 起；舊名 `wip/droidvm` 停在 0f7b62a） | 0f7b62a | 上次合併上游是 11-01（407db1a）；上游 main 之後又多了 282 個 commit |
| 裝置 repo | `UniXNU/UniXNU-droidvm-main`（`main`） | `wip/hackintosh` | 見 git | 兩個 board 都在這裡 |
| AdrenoMetal（Droid-VM/NativeMetal） | `orgrepos/NativeMetal-rebase` | `wip/hackintosh` | 312cde5 | fork 的 pin 相同（11-13 跟上） |
| DarwinBoot | `orgrepos/DarwinBoot-rebase` | `wip/hackintosh`（11-13 起；舊名 `wip/droidvm-virtio-gpu` 停在 eb4a095） | eb4a095 | fork 的 pin 相同（11-13 跟上，並修了一個問題，見第 4 節） |
| Adreno740（NativeAdreno） | — | — | pin 627836d | 刻意不跟上游（改寫過的驅動會打壞裝置 repo 的 text patch） |
| ArmCpu、GopFramebuffer | — | — | 5265ef1、ed08bd4 | pin 與 head 相同 |
| ownervisor、applebox（除錯 shell） | — | Droid-VM/ownervisor、applebox `main` | c6c8b2a、6e3b471 | 27 的 pin 在 `ipados27/feeds.toml`（11-13 加） |

其他本機 clone 是別的工作階段或舊流程留下的，**不是現在的來源**：`UniXNU-droidvm`（`wip/toybox-fold`）、
`UniXNU-droidvm-audio`（`wip/audio`，有未提交的檔案）、`UniXNU-droidvm-land`（`wip/peripherals`）、`orgrepos/UniXNU`、
`orgrepos/UniXNU-rebase`。

### build Mac 上的樹（`/Volumes/DATA/UniXNU/`）

| 目錄 | 用途 | 規則 |
|---|---|---|
| `ipados27/` | **27 的正式樹**（11-13 從 GitHub clone）。`UniXNU/` 加 `UniXNU-droidvm/`，release 在 `UniXNU/out/droidvm/ipados-27.0.1-24A446/droidvm_ipados27/release/` | 內容只靠 `git pull`／`git submodule update` 改變。建置腳本遇到有本機修改的 checkout 會拒絕 |
| `ipados27-dev/` | 實驗用的樹（同樣的 clone） | 可以 scp、改檔，建置加 `--allow-dirty`；它的 release 會標成不乾淨，部署腳本預設不收 |
| `generations/24A446-2EE158B3/` | 現有 27 VM 用的那份 Data seed（volume UUID 2EE158B3…）、它的紀錄、Data 裡現有程式的信任紀錄（`trust/*.json`） | 現有 VM 的每次建置都讀它。在 guest 裡另外裝了 App，要把它的信任紀錄放進 `trust/` |
| `fresh27/` | 11-13 以前的 27 手動建置樹（50 GB） | 退役：不再建置。已核對內容與 git 一致（第 4 節）。刪除要使用者同意 |
| `fresh/`、`orgrepos/`、`audio/` | 17 的樹（最後建置 10-29）、21H461 的 IPSW 快取 | 不動 |
| `fresh2/`、`fresh3/`、`fresh4/` | 10-29 驗證 17「從零建置」的三次試跑（86 GB，乾淨、已推送） | 刪除要使用者同意 |

### rig 與手機

- 在用：`UniXNU/droidvm-5566-27`、`droidvm-5567-27`（27）。5566 的 `rig.env` 已指向正式樹與現在的 clone；5567 的還沒改
  （它上面的部署還等使用者決定）。
- 17 留下的：`droidvm-5566`、`droidvm-5568`、`droidvm-fresh`、`droidvm`（最後這個指向已刪除的 VM）。
- 手機上 VM 目錄裡的 `release.json` 就是「這支手機跑的是哪一版」：fork、裝置 repo、每個 submodule 的 commit，Mesa 與
  metal2vulkan 的 pin，seed，plugin 與各檔案的雜湊。
- 5566 上 27 的 VM 用的韌體檔在 **17 的 VM 目錄**裡（`DroidVM/UniXNU/edk2-virtio-gpu.fd`）：那個目錄不能整個刪。

## 3. 27 現在怎麼建、怎麼部署

在 Mac 的正式樹：

```
cd /Volumes/DATA/UniXNU/ipados27
git -C UniXNU pull && git -C UniXNU submodule update --init --recursive && git -C UniXNU-droidvm pull
cd UniXNU-droidvm
python3 ipados27/scripts/build-droidvm-all.py --unique-chip-id <rig 的 chip id> \
    --generation /Volumes/DATA/UniXNU/generations/24A446-2EE158B3
```

或者在 rig 裡一條指令（建置加部署）：`./deploy27.sh --build`。

- **步驟**：setup（defconfig、fetch、IPSW 成員、解密）→ policies（owner 金鑰、OS／SystemOS 原始磁碟與簽過的 root policy）
  → package（UniXNU.efi、DarwinBoot.efi）→ tools（arm64e 的除錯 shell 與工具）→ plugin（Turnip、metal2vulkan、AdrenoMetal）
  → data（seed）→ kernel（含 fileset 的人工配對，再 prelink）→ trust → payload（開機碟）→ release。
  從空的 clone 到 release 約 15 分鐘（IPSW 用 `--ipsw-cache` 從舊樹複製時）。
- **每一步記下它是用什麼建的**（各 checkout 的 commit、本機修改的摘要、seed、chip id）；`git pull` 之後跑同一條指令，
  只有輸入變了的步驟會重跑。setup、policies、新的 Data seed 只跑一次。
- **兩種建置**：kernel 用 seed 的 volume UUID 掛 Data，手機上的 Data store 存的是相對於 seed 的變更。所以
  - 現有的 VM：`--generation DIR`，沿用它當初的 seed；
  - 全新的 VM：不加，腳本會做一份新的 seed（新的 UUID，裡面是這次建的 plugin 與工具），要配新的 Data store。
    rig 端是 `deploy27.sh --new-vm 來源rig 名稱`，在一個新的 rig 目錄裡跑：手機上開新目錄（開機碟、`release.json`、
    空的 Data store），VM 透過 daemon 的 IPC 建立，設定抄自現有 27 VM 的 rig（新的 id、名稱、目錄、網卡）；
    不動其他 VM，也不改 App 的 `vms.json`。唯讀的 OS／SystemOS 磁碟預設共用現有 VM 的（先在手機上對雜湊）。
- **部署**（`tools/rig/deploy27.sh`）：先拿 `release.json`，不乾淨、chip id 不對、seed 不對就拒絕；每個檔案對雜湊；
  把 release 的 plugin 推進執行中 guest 的 Data（先留下被換掉的檔案）；檢查 hugepage 池再停機；把手機上原本的開機碟
  留在 `out/previous27`；推新的開機碟和 `release.json`；更新符號；開機、印健康狀態。`--rollback` 把上一張開機碟和
  plugin 放回去。
- **11-13 的驗證，全新 VM**（5566）：實驗樹回到已推送的 head 後不加 `--generation` 完整建置（新 seed 53067C2A…、
  新的 chip id），`deploy27.sh --new-vm` 開出新 VM：Data 掛上新的 store、SpringBoard 連同 widget 與桌布正常顯示
  （Metal plugin 在運作）、網路正常、ssh 可用（seed 裡的 dropbear）、guest 裡 plugin 的雜湊等於 release 的。
  測完已關機並從 daemon 移除，主要的 VM 開回來；它的目錄（3.4 GB）還在手機上。
- **11-13 的驗證，現有 VM**（5566）：正式樹建的 release（fork 0f7b62a、裝置 repo 634d2e2）用 `deploy27.sh` 部署，開機正常、
  網路與 ssh 正常、guest 裡的 plugin 雜湊等於 release 的、Metal Check 通過（0 failures）、合成器重啟 30 次 0 次 host GPU hang。

舊的手動流程（scp 進 `fresh27`、暫存腳本）不再使用；那 22 支暫存腳本的副本還在 rig 的 `droidvm-5566-27/build27/`，只當參考。

## 4. 重現過程查到的事

**舊樹的原始碼等於 git。** 逐項比對 `fresh27` 的內容與已推送的 commit：

- fork 的工作樹等於 5143df6（當時的 head）；裝置 repo 的 `package/` 與 `ipados27/` 等於 77bb46b
  （只有 Data seed 腳本少一個偏好設定、信任腳本的註解不同、rig 工具較舊）。
- ArmCpu 是 Mac 上一個本機目錄（`local.toml` 覆寫），內容等於 pin 5265ef1；DarwinBoot 的建置目錄等於 c3ff6e4；
  打過補丁的 Mesa 原始碼兩棵樹完全相同。
- 新舊 kernel：`__TEXT_EXEC`、`__DATA`、`__DATA_CONST` 大小相同，符號數相同（91017），fileset 配對數相同
  （16847 個函式、1371 個資料、18 個 stub）；只有字串段差 1230 bytes（路徑長度）。
- 新舊 Turnip：565 個編譯指令相同，只有一個目的檔不同——Mesa 產生的 ir3 編碼器，敘述順序跟著 Python 的雜湊種子變。
  建置腳本現在固定種子。

**但「照 git 建」有四個地方本來走不通，舊樹因為留著舊產物所以沒發現：**

1. **host 版 Turnip 建不起來**（11-06 加的 Mach-O 後處理也套到 host 版，而 host 版沒有那個結構）。已修（fork 299058d）。
2. **host 模擬編不過**：fork 把 Adreno740 刻意停在舊 commit，SMMU kit 的 pin 卻往前走了，兩邊介面對不上。
   plugin 建置原本一定要 host 模擬錄一段「重播」資料，舊樹一直在用 10 月的舊目的檔。那段重播測的是 NativeAdreno
   自己的 GPU 核心，DroidVM 的 guest（virtio GPU）用不到，27 的 plugin 現在不帶它（fork 299058d，預設行為沒變）。
3. **除錯 shell 的來源沒有 pin**：ownervisor、applebox 在 Mac 上是沒有 git 的目錄。現在 pin 在 `ipados27/feeds.toml`。
4. **git 上的 DarwinBoot 在 5566 開不了機。** c3ff6e4 的 CPU 叢集規則（「由高到低標成 P，直到超過一半」）只在 5567
   （8 Gen 3）跑過；5566（8 Elite Gen 5）一直用 11-03 的舊二進位檔，部署腳本每次都把它「放回去」。照 git 建出來的
   開機碟在 5566 上把六顆 vCPU 全標成 P，kernel 在 launchd 啟動時停 20 秒，然後 launchd 死掉。換回舊規則就正常，
   確認是這一條。已修：最低一級 capacity 永遠留作 E（DarwinBoot eb4a095，5566 驗過；8 Gen 3 的分法不變）。
   **還沒查的**：vCPU 的 capacity 全部相同時 DarwinBoot 仍然全標 P，這個 kernel 很可能一樣開不了；沒試。

另外兩個小發現：27 開機碟裡的 UniXNU.efi 一直是 17 那棵樹 10-29 建的（現在每次從 fork 建）；
Data seed 的紀錄把 OS 映像檔名寫成 `lsdiag`（變數被迴圈蓋掉，已修）。

**還沒解決的（原第 4 節的其餘各點）：**

- **17 的狀態不明。** 10-29 之後沒建過，共用的 `package/` 多了 55 個 commit。見 5.1。
- **跟機型／build 綁定的資料散在多處**：`fileset-reviewed.json`、`legacy-display-24A446.json`、`hid-device-24A446.json`、
  profile 的 `original-classes.json`、QuartzCore 的 text fixup、trust、root policy、Data seed 都對著「24A446 的 iPad17,3」。
  換 OS 版本或換機型，每一樣都要重做。
- **二進位不是逐位元可重現**：路徑會寫進去（兩棵樹建出的 plugin 雜湊不同）。驗證靠 `release.json` 的 commit 與上機測試。
- **PROGRESS 的第 1、3、4 節還是 17 時代的內容**（本機路徑、建置表）。

## 5. 建議

### 5.1 一條主線，一條凍結

- **主線＝iPadOS 27（iPad17,3，24A446）。** 開發、測試、之後要給人用的版本都只有它。
- **17 凍結，不再維護。** 在 fork 和裝置 repo 給 10-29 最後驗過的那組 commit 打 tag，Mac 留 `fresh/` 當成品，
  文件寫明「17 停在這裡」。理由：
  - 我們手上能跑 DroidVM 的三支手機都有 PAC，沒有「只能跑 17」的機器。
  - 27 上 arm64（非 arm64e）的程式也能跑（裝置 repo 8ea1e33、d85806a），17 沒有獨有的相容性。
  - 記憶體需求一樣：5567 的 27 VM 是 5120 MB、1024×1366 @1x，跟 17 的設定相同（池子不夠那次 4608 MB 也開過）。
  - 留著的代價是每個 kernel 端改動要建兩次、開兩次機，Data seed 和 trust 也各一套。
- 如果想保留回到 17 的可能，折衷是「只檢查能不能建」：獨立一棵 Mac 樹，每次推送階段編 17 的 kernel 和 plugin，
  不上機。先要花一次工把現在的 HEAD 修到能建（工作量未知，見第 1 節）。

### 5.2 讓 27 能從 git 重現——11-13 做完

fork 的 pin 跟上、Mac 開了只用 git 的正式樹、流程收進裝置 repo、部署留紀錄、實驗另開一棵樹、全新 VM 的路：
都做了也上機驗過，見第 2、3 節。剩下的：

1. 5567 的 `rig.env` 與部署（等使用者決定要不要把這幾天的修正裝上 5567／5568）。
2. Metal Check 這類測試 App 不在 seed 裡（要另外推進 guest）；新 VM 上還沒跑過它。
3. 舊樹與測試留下的東西的清理（5.4）。

### 5.3 機型：留在 iPad

**建議只建 iPad，而且就是現在的 iPad17,3／24A446。**

- **上游主線只有 iPadOS 的 profile。** UniXNU main 的 27 只有 `ipados-27.0.1-24A446`（iPad17,3），登記的 365 個裝置裡
  47 個用它，我們是其中之一：上游對這個 kernelcache 做的 fileset、prelink、補丁我們直接受益。
  iPhone 的 profile（24A446 的 iPhone17,1／17,2／17,4）只在社群的裝置 repo 裡（登記了 7 個），各養各的。
- **我們做的東西是 iPad 的用法。** 系統游標加觸控板、Apple Pencil、實體鍵盤、視窗化 App、外接螢幕、橫向，
  iPhone 上沒有系統游標、沒有 Pencil、沒有多視窗。DroidVM 的操作介面（外接螢幕、鍵盤、滑鼠）對的是 iPad。
- **畫面尺寸。** iPadOS 接受我們給的 1024×1366、1032×1376 @1x 和 2048×2732 @2x（都驗過）。iPhone 的版面綁特定機型的
  screen class：上游 aston 的紀錄裡，面板換算成 421×927 點、對不上 iPhone17,2 的 440×956，第一次開機就報
  「unsupported screen class」。VM 可以把虛擬面板設成剛好那個尺寸，但那是 @3x（iPhone 16 Pro 是 1206×2622），
  像素是我們 @1x iPad 的 2.2 倍；能不能像 iPad 一樣降到 @1x，沒試過。
- **iPhone 多出電信堆疊。** 沒有基頻時 CommCenter 那一串怎麼反應，我們沒試過，是風險。

iPhone 在同一個 build 上**做得起來**，這點上游已有證據：aston（OnePlus Ace 3，SM8550 原生）以 iPhone17,2 的身分跑 iOS 27，
紀錄寫到開得了設定、GPU 在動；它還記了一件省工的事：iPhone17,2 的 dyld shared cache 裡 QuartzCore 的程式碼與 iPad 24A446
那份位址相同。其他幾個（shennong、cupid、asteroids 的 iPhone 目標）還在開機或設定階段。

iPhone 能給的：

- **填滿手機螢幕。** 5566 的面板是 1272×2772，iPad 的 3:4 畫面直放橫放都只佔 61%；最瘦長的 iPad（mini）也只到 70%。
- 不必換身分就有 GNSS；有震動（iPad 沒有）；手機版 App 是原生版面。

成本：同一個 build（24A446），XNU 原始碼與補丁可共用；上游 asteroids 的紀錄顯示 iPhone17,4 的 kernelcache 裡比對過的
32 個 kext 版本與 iPad17,3 相同，class 的 fixture 可以用腳本重映射。但第 4 節第 4 點的資料大多要重做或重映射，ADT 要從
iPhone 的 DeviceTree 重套我們全部的修改，Data seed 重做，然後整張功能表重驗一次；之後是永久的第二條線。

所以：**iPad 是主線；iPhone 現在不開。** 先完成 5.2，讓「加一個機型」變成加一個 profile 目錄加一組資料，而不是再手養一棵樹。
之後如果手機當 host 的體驗重要，iPhone 值得一個限時的試作：在 5566 以 iPhone17,x 開到 SpringBoard，看卡在哪、
@3x 的負擔多大，再決定要不要變成第二條線。

iPad 之內的兩個小選項，都還沒驗：

- **蜂巢版身分（iPad17,4／J821AP）**：iPadOS 的 locationd 只對蜂巢機型啟動 GNSS（17 上已查明），TODO 5 的 iPadOS 那一半要靠它。
  同一個 IPSW；要不要換 kernelcache 沒查。
- **OS 版本**：留在 24A446，上游換 pin 時再跟。每換一版，第 4 節第 4 點的資料全部重做。

### 5.4 清理（刪東西，要使用者點頭）

- Mac：`fresh27/`（50 GB，已退役，內容與 git 核對過）、`fresh2/`、`fresh3/`、`fresh4/`（86 GB，乾淨、已推送）。
  `audio/` 有未提交的檔案，先確認。
- 手機 5566：17 的 VM 目錄（27 的韌體檔在裡面，不能整個刪）、27 目錄裡 11-02 的舊 Data 備份與兩個舊開機碟、
  11-13 測試用新 VM 的目錄 `DroidVM/UniXNU27fresh`（3.4 GB；VM 已從 daemon 移除）。
- 本機：舊 rig 與舊 clone 先不動（`UniXNU-droidvm-audio` 有未提交、未追蹤的檔案，不是這個工作階段的）。
  rig `droidvm-5566-27/out/` 裡這次留下的測試用開機碟（`droidvm-disk.*.img`）、測試新 VM 用的 rig 目錄
  `droidvm-5566-27f` 可以刪。

## 6. 要使用者決定

1. 17：凍結（建議）／只檢查能不能建／繼續完整維護。
2. iPhone：現在不做（建議）／限時試作／現在就開一條線。
3. 5.4 的清理做不做。
4. 5567／5568 要不要裝這一版（release 的部署腳本已經有了；5567 目前是 11-11 的開機碟加較舊的 plugin）。

## 7. `macOS` 分支併入 `wip/hackintosh`（11-13 盤點）

使用者要把目前的工作都收進 `wip/hackintosh`；`macOS` 分支是另一位開發者平行做的 macOS 27 guest。

**分支名。** 11-13 起 UniXNU fork 與 DarwinBoot 也推 `wip/hackintosh`（舊名 `wip/droidvm`、`wip/droidvm-virtio-gpu` 停在當天的
commit，沒刪）；Mac 兩棵建置樹的 fork 已改追這個分支。其餘 repo 本來就是。

**macOS 27 與 iPadOS 27 的 kernel。** 同一份原始碼（xnu-12377.121.6，`ac9718f`，arm64e，同一個機型設定），不是同一個 kernel：
macOS 編譯時加 `-DXNU_TARGET_OS_OSX`（macOS kext 的 vtable 排法）、補丁是另一套、連結的是 macOS 自己的 Apple kext
（kernel collection）。二進位不共用；可共用的是大部分補丁與全部驅動原始碼。

**各 repo 的 `macOS` 分支對 `wip/hackintosh`：**

| repo | macOS 多 | hackintosh 多 | 內容與試合併結果 |
|---|---|---|---|
| crosvm | 27 | 6 | msm_vidc 直通解碼（`vidc=true`）、KMS 接管面板、WebRTC 顯示輸出（帶進 `third_party/libdatachannel`）、AAudio 改成 callback、PCI MSI（`--mbi-spis`）、`--virtio-mmio-edge-irq`、xHCI MSI-X、half-float scanout。1 處衝突（`cmdline.rs`，兩邊各加一個選項），已解；本機分支 `merge/macos-into-hackintosh`（266818b7c），**未建置、未推** |
| virtio-media | 1 | 0 | 解碼器 buffer 走 dma-buf、display delay；crosvm 的 vidc 後端要它，兩個要一起動 |
| virglrenderer | 10 | 5 | `drm2kgsl_renderer.c` 6 處衝突（兩邊都改了 timestamp、power constraint、fault count），未解 |
| edk2-gunyah | 1 | 0 | MADT 的 GIC MSI Frame（只有 DT 帶 MBI 屬性時才有作用） |
| NativeMetal | 5 | 4 | 雙平面 YCbCr surface 轉換等，只動 `NativeBridgeMetalFrontend.mm`，合併無衝突 |
| UniXNU-droidvm | 2 | 255 | `DroidVMGpu.cpp` 的 macOS 版（削到只剩 NativeAdreno 的 publish），和我們的版本衝突，不能直接合 |
| NativeAdreno | 6 | 50 | 6 個都已在 `wip/hackintosh`（patch 相同） |
| UniXNU | 17 | 635 | 10-31 的舊分支；macOS 線的 GPU 用戶空間後來改釘我們 fork 的 `ef4486d` |
| DarwinBoot、ArmCpu、NativeMobileDisplay、mesa | 0 | — | 分支上沒有東西，改動以 patch 檔放在 `macOS-DroidVM` |

**guest 的主體在 `Droid-VM/macOS-DroidVM`**（`macOS` 分支比 `main` 新 37 個 commit，已改走 PCIe virtio 加 MSI-X）。它不走 UniXNU
流程（自己的 `k27/` 與 KC 連結器、`overlay/kext/` 自己的板級 kext、kernel 補丁 49 個），並且是「釘住我們某個 commit 再疊補丁」
來用我們的原始碼：音訊（e29d087 + 3）、VideoToolbox（706338e + 11）、virtio-gpu 顯示（59ec0a8 + 1）、DroidVMGpu／NativeAdreno（+ 8）、
ArmCpu 3、DarwinBoot 2、Mesa 2、metal2vulkan 1。併進 iPadOS 27 這邊 = 把這些補丁變成 `wip/hackintosh` 上的 commit，
macOS 只留它專屬的部分（kernel 補丁、KC、seed）。

**crosvm 合進來後不是 opt-in 的改動**（會影響現有的 iPadOS／Linux／Windows guest，推之前要回歸測試）：virtio-snd 的 AAudio 輸出、
MediaCodec 解碼器的像素預算與單一 buffer 映射、virtio-pci 的 MSI-X 向量時機、xHCI、游標 surface 大小、half-float scanout。

**卡住的地方：**
1. crosvm 只有一棵建置樹，裡面有別的工作階段 11-04 留下的未提交音訊修改（2 檔 48 行），和 macOS 的 AAudio 改寫是同兩個檔。
   三方合併套得上，但合起來沒有人測過；要不要把它帶過去由使用者決定。
2. 這邊的手機上沒有 macOS VM，macOS 端的結果無法在這裡驗證，要 macOS 線的人重建。
