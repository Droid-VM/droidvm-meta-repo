# 構建線：iPadOS 17／27 與機型（iPad／iPhone）

2026-11-13 盤點。使用者問：目前成果怎麼整理、17 和 27 的構建怎麼管、具體要建哪一個（iPad 還是 iPhone）。
第 1–4 節是查到的事實，第 5 節是建議，第 6 節是要使用者決定的事。

## 1. 兩條 OS 線

| | iPadOS 17.7.11（21H461） | iPadOS 27.0.1（24A446） |
|---|---|---|
| 機型身分 | iPad7,1／J120AP（iPad Pro 12.9" 第 2 代，A10X） | iPad17,3／J820AP（iPad Pro 13" M5） |
| 使用者空間 | arm64 | arm64e（guest 要有 PAC；三支手機都驗過可用） |
| XNU | xnu-10063，傳統 prelink | xnu-12377 加 Darwin 26 的 syscall 補丁（Darwin 26 原始碼未公開），`MH_FILESET` |
| 裝置 repo 裡的位置 | 根目錄的 `board.toml`、`scripts/`、`configs/` | `ipados27/`（schema 2，自己的 `board.toml`、`scripts/`、`patches/`） |
| 共用 | `package/`（`ipados27/package` 是指回去的連結）、fork 的 GPU userland（plugin 與 Turnip 用 `--target ios27` 分） | 同左 |
| 最後一次建置 | 10-29（kernel） | kernel 11-11，plugin／開機碟 11-13 |
| 從零建置 | `scripts/build-droidvm-all.py` 一條指令到 `release/`，rig `fresh-deploy.sh` 部署；10-29 驗過 | 沒有；手動流程（第 3 節） |
| 在跑的手機 | 沒有。5566 上留著 10-29 的 VM 目錄；5568 搬到一半 | 5566（8 Elite Gen 5）、5567（8 Gen 3） |
| 10-30 之後的開發 | 沒有 | 全部（VPU 編解碼、WebGPU／WebGL 2、第三方 App 的 3D、Apple Pencil、觸控板、序列埠、IOSurface 同步、GPU 優先權、這週的閃爍與 hang） |

10-29 的計畫（`plans/IPADOS27_BUMP.md`）寫「17 在移植期間保持可建置」。實際上 10-29 之後 17 沒有再建過；
同一段時間共用的 `package/` 有 55 個 commit、38 個檔案、約 9000 行新增。**17 現在還能不能建、能不能開機，沒有驗過。**

## 2. 哪裡才是真的來源

### git（本機 clone → 推送處）

| 元件 | 本機 clone（分支） | 推送到 | head | 備註 |
|---|---|---|---|---|
| UniXNU fork | `UniXNU/orgrepos/UniXNU-m1101`（`merge-up-1101`） | Droid-VM/UniXNU `wip/droidvm` | 5143df6 | 上次合併上游是 11-01（407db1a）；上游 main 之後又多了 282 個 commit |
| 裝置 repo | `UniXNU/UniXNU-droidvm-main`（`main`） | `wip/hackintosh` | 77bb46b | 兩個 board 都在這裡 |
| AdrenoMetal（Droid-VM/NativeMetal） | `orgrepos/NativeMetal-rebase` | `wip/hackintosh` | 312cde5 | **fork 的 pin 還是 b0d6a07，落後 8 個 commit** |
| DarwinBoot | `orgrepos/DarwinBoot-rebase` | `wip/droidvm-virtio-gpu` | c3ff6e4 | **fork 的 pin 還是 c936dc6，落後 2 個** |
| Adreno740（NativeAdreno） | — | — | pin 627836d | 刻意不跟上游（改寫過的驅動會打壞裝置 repo 的 text patch） |
| ArmCpu、GopFramebuffer | — | — | 5265ef1、ed08bd4 | pin 與 head 相同 |

其他本機 clone 是別的工作階段或舊流程留下的，**不是現在的來源**：`UniXNU-droidvm`（`wip/toybox-fold`，比 main 多 1、少 15 個
commit）、`UniXNU-droidvm-audio`（`wip/audio`，有未提交的檔案）、`UniXNU-droidvm-land`（`wip/peripherals`）、`orgrepos/UniXNU`、
`orgrepos/UniXNU-rebase`。27 兩個 rig 的 `rig.env` 裡 `REPO`／`FORK` 還指著其中兩個舊 clone。

### build Mac 上的樹（`/Volumes/DATA/UniXNU/`）

| 目錄 | 用途 | git 狀態 | 大小 |
|---|---|---|---|
| `fresh27/` | **27 唯一的建置樹** | fork 停在 b4fca4d（11-01）加 53 個未提交的檔案；裝置 repo 停在 b1fe948（10-29）加 78 個。內容是用 scp 和 bundle 搬過去的，**Mac 的 git HEAD 不代表樹裡的內容** | 50 GB |
| `fresh/` | 17 最後一次建置（10-29，合併後的 fork；分支 `ipados27` 上一個 bisect 用的 commit） | 有未提交 | 31 GB |
| `orgrepos/` | 17 原本的主樹（kernel 10-28）＋ 21H461 的 IPSW 快取 | 接近乾淨 | 59 GB |
| `audio/` | 17 音訊工作的隔離樹（10-29） | 7 個未提交 | 9 GB |
| `fresh2/`、`fresh3/`、`fresh4/` | 10-29 驗證「從零建置」腳本的三次試跑 | 乾淨，內容都已推送 | 86 GB |

磁碟還有 1.3 TB，空間不急。

### rig 與手機

- 在用：`UniXNU/droidvm-5566-27`、`droidvm-5567-27`（27）。
- 17 留下的：`droidvm-5566`、`droidvm-5568`、`droidvm-fresh`、`droidvm`（最後這個指向已刪除的 VM）。
- 5566 手機上：17 的 VM 目錄 11 GB（10-29 的開機碟）；27 的目錄 34 GB，裡面有 11-02 的舊 Data 備份和兩個舊開機碟。

## 3. 27 現在實際怎麼建

全部手動，在 Mac 的 `fresh27` 樹裡（`D`＝裝置 repo 的 `ipados27`）：

1. **同步**：把本機改過的檔案 scp 過去，或用 git bundle 搬 commit；沒有「Mac 等於某個 commit」的檢查。
2. **kernel**：`./unixnu build kernel -D $D` → `apply-fileset-reviewed.py`（`ipados27/fileset-reviewed.json`）→ `./unixnu build prelink -D $D`。
3. **plugin**：`link-droidvm-gpu-sources.py` → `build-turnip-darwin.py --target ios27` → `build-adreno-metal-plugin.py --target ios27`。
   AdrenoMetal 的做法是 Mac 上 checkout 舊的 3f8d44a，再把本機 5 個檔案蓋上去（內容等於 312cde5，但不是 checkout 出來的）。
4. **trust＋payload＋開機碟**：`build-droidvm-trust.py` → `./unixnu build payload -D $D … --data-ramdisk data-12g-27-gpu.dbr
   --trust-cache owner.bundle` → `make-droidvm-disk.sh`。這支會放進舊的 DarwinBoot，要再手動換成新的。
5. **部署**：rig 的 `deploy27.sh`／`deploy-boot.sh`、`fileset-syms.py`；plugin 的檔案經 ssh 推進 guest 的 Data。

這些步驟的腳本原本只在工作階段的暫存區。11-13 原樣複製到 rig 的 `droidvm-5566-27/build27/`（22 支，路徑寫死，只當參考）。

## 4. 問題

1. **27 不能從 git 重現。** 手機上跑的東西來自一棵 git HEAD 是兩週前、上面疊了一百多個未提交檔案的樹；
   fork 的 AdrenoMetal 和 DarwinBoot pin 也落後。照 git 上的 commit 從頭建，得不到手機上那一版。
2. **流程不在 repo 裡。** 27 的建置與部署步驟是暫存腳本加記憶筆記；17 有的 `build-droidvm-all.py` 沒有 27 的版本
   （計畫的 P6 最後一項）。
3. **17 的狀態不明。** 兩週沒建，共用程式碼大改，文件卻還把它寫成目標。
4. **跟機型／build 綁定的資料散在多處。** `fileset-reviewed.json`、`legacy-display-24A446.json`、`hid-device-24A446.json`、
   profile 的 `original-classes.json`、QuartzCore 的 text fixup、trust、root policy 的 UUID 與 digest、Data seed
   都對著「24A446 的 iPad17,3」。換 OS 版本或換機型，每一樣都要重做。
5. **實驗和正式建置共用一棵樹。** 這週 Mesa 的 A/B 補丁直接改 `fresh27` 的 `mesa-work`，漏記一個就建置失敗，
   也曾把實驗版留在手機上。
6. **PROGRESS 的開頭和第 1、3、4 節還是 17 時代的內容**（目標、本機路徑、建置表）。

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

### 5.2 讓 27 能從 git 重現（建議的順序）

1. fork 的 pin 跟上：AdrenoMetal → 312cde5、DarwinBoot → c3ff6e4。
2. Mac 開一棵**只用 git 取得內容**的新樹（推送的分支＋submodule 照 pin），建 kernel、plugin、開機碟，
   跟手機上那版比對（plugin 的雜湊、kernel）。對得上，`fresh27` 才退役。
3. 把第 3 節的流程收進裝置 repo：`build-droidvm-all.py` 加 27 的 board（或 `ipados27/` 自己一支），
   部署腳本進 `tools/rig`，路徑走 `rig.env`；順手解掉 DarwinBoot 要手動換的那一步。
4. 規則：正式的 Mac 樹只接受 `git fetch`；每次部署在開機碟旁留一份紀錄（fork、裝置 repo、各 submodule 的 commit、
   plugin 雜湊），手機上跑的是哪一版隨時查得到。17 的流程已經有 `release.json`，沿用。
5. 實驗在第二棵樹做（APFS 的 `cp -c` 複製不佔空間），正式樹保持乾淨。

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

- Mac：`fresh2/`、`fresh3/`、`fresh4/`（86 GB，乾淨、已推送）。`audio/` 有未提交的檔案，先確認。
- 手機 5566：17 的 VM 目錄（決定凍結後留或刪）、27 目錄裡 11-02 的舊 Data 備份與兩個舊開機碟。
- 本機：舊 rig 與舊 clone 先不動（`UniXNU-droidvm-audio` 有未提交、未追蹤的檔案，不是這個工作階段的）。

## 6. 要使用者決定

1. 17：凍結（建議）／只檢查能不能建／繼續完整維護。
2. iPhone：現在不做（建議）／5.2 做完後限時試作／現在就開一條線。
3. 5.4 的清理做不做。

5.2 不論上面怎麼選都要做，可以直接開始。
