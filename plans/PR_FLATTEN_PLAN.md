# pr/3d-accel 扁平化計畫（2026-08-30 修訂，當日第三版）

一項功能一個 commit，順序 **L**(licensing) → **M**(GPU 無關) → **G**(路線共用 GPU 基礎) → **D**(drm2kgsl) → **X**(gfxstream) → **V**(venus)。
他人 commit 併入功能 commit，作者掛 `Co-authored-by:`。

**08-29 之後又進來 21 個 commit（全部在 08-30 當天），但只長出一個新的 commit 位。** 其餘都是既有功能的修正或重構
（ASCII/fmt 收尾、legacy key 清除、共用終端機面板、大頁進階畫面、Linux VM 密碼路徑、顏色邊界落地），
格子本來就亮著。唯一的新格是 **R**（nproc 救援模組）。

**「app 開不起來要重開機」找到根因了。** 我們在每次 VM 執行時反覆切換執行緒的*真實* uid，而
`setuid()` 的 `set_user()`（更新 `cred->user`，也就是 `commit_creds()` 判斷要不要移轉 NPROC 記帳的欄位）
被 CAP_SETUID 分支蓋著；走到 saved-uid 路徑就只更新 `cred->ucounts` 不更新 `cred->user`，
於是這個 process 的 NPROC charge 沒加卻在結束時被減。計數器一旦為負，
`is_rlimit_overlimit()` 讓該 uid 的每一次 fork 都失敗，Zygote 再也拉不起 app。
修正是 crosvm/probe 兩處改用 `setresuid()`（**算 fix，不加格子**），救援是新模組 `nproc_guard`（**算新格 R**）。

## 0. 總表

| repo | 縮寫 | base | head | 範圍內 commits |
|---|---|---|---|--:|
| droidvm-3d-accel（meta） | meta | 空樹 | abaac00 | 304 |
| mesa-cross | cross | 空樹 | 2586325 | 19 |
| DroidVM（app） | app | `origin/master` | 892bc02 | 130 |
| edk2-gunyah | edk2 | `origin/master` | 4fb0b84 | 8 |
| gunyah_host_mod | hmod | 空樹 | e1280d8 | 38 |
| droidvm-guest-additions | gmod | 空樹 | d7e6713 | 40 |
| crosvm | crosvm | `droidvm/droidvm` | f690a3c40 | 151 |
| Virtualization | virt | `droidvm/android16-qpr2-release-local` | 3278ede | 13 |
| gfxstream | gfxs | `aosp/emu-main-dev` c00cd03a3（08-21 換基準） | 6a9d4dd2c | 62 |
| virglrenderer | virgl | `8220efec`（AOSP snapshot） | 3dbfe7b5 | 44 |
| mesa | mesa | mesa main `74d4e41b2bb` | 6ad3bcbcfca | 76 |
| crosvm-minimal-manifest | mfst | 空樹 | 29de119 | 11 |
| gunyah-guest-drivers-windows | win | 上游 virtio-win | 8d12ff0e（`master-squash`） | 18 |

**`gh-hugepage-reserve`（舊 `hp` 欄）已經退出這張表。** 它自己走上游流程，v12（`bdf9062`）已推去
Droid-VM/gh-hugepage-reserve，不進 `pr/3d-accel`。它帶進來的兩位額外作者（samfor12、BigfootACA）
也跟著離開署名表。

**但「退出表格」不等於「沒有牽連」。有三條，全部是 fail-open 的可選整合，沒有一條是硬相依：**

1. **`/dev/gh_pinprobe`**（見註⁷與 §3.10）——crosvm 只需要在節點缺席時不當機。最輕。
2. **M5 的大頁面板**——`HugePageModel` 讀寫那個專案 Magisk 模組的
   `settings.prop` / `module.prop` / `disable` / `load.sh` / `kapi_check`，`rmmod` 它，
   並且**按它的 v6/v7 sysfs 差異分支**；`KernelModuleListController` 與 `HugePageActivity`
   還寫死了 `https://github.com/Droid-VM/gh-hugepage-reserve/releases` 當下載連結。
   （M5 不是「整個都是 hp 的面板」——同一列也管我們自己的四個模組，hmod 那格就是為此而亮。）
3. **`PoolPreflight` 在 VM 啟動前看一眼池子**——不在 M5，在啟動路徑上（`VMActions:113` 前景、
   `VMInstance:570` guest reboot 後重啟、`VMInstanceStore:157` 開機自啟）。它讀
   `/sys/module/gh_hugepage_reserve/parameters` 的 `pool_avail`，不夠就等（背景啟動）或說一聲（前景啟動）。

   **這是純新增的功能，不是新的相依。** 池子夠用時所有配置都由模組 serve，那條壞路徑根本走不到；
   池子不夠時的下場（整機停頓後 OOM-kill crosvm、`qcom_scm ... -22` 重置）是**舊版本一樣會有**的
   既有行為，PoolPreflight 只是先看一眼、能等就等。模組不在時 `readPages` 回 −1 →
   `applicable=false` → `isEnough()` 回 true → 照常啟動，也就是退回舊版本的行為。

所以三條都不是必要相依，`pr/3d-accel` 不會因為缺少那個專案而不能用。真正要在 PR 裡交代的
只有一件事：這些程式碼會去讀一個外部專案的 sysfs／settings.prop 介面，而且 M5 那條是版本
相依的（v6/v7 分支）。見 §8。

`win` 形狀與其他欄不同：base 是上游 virtio-win、上游目標也是 virtio-win，
而且**它已經自己扁平過了**（153 → 18 commits 在 `master-squash`）。

**上一輪（08-30）推送時，以上 head 都在 org 的 `wip/3d-accel` 上；之後 meta 與 app 各自又多了 commit**
（meta `abaac00`、app `892bc02`），要跟著這份修訂一起推。meta 這一列永遠會落後一步——這份文件就住在
它描述的 repo 裡，每次更新它自己就多一個 commit。
所有 repo 的工作區都是乾淨的，只剩 DroidVM 的
`assets/prebuilts` submodule 髒著——那是本機重編的 payload（已含 `nproc-guard-gki-*.ko`），
要推回 Droid-VM/DroidVM-Prebuilts 才輪得到指標 bump，而且它比目前的 crosvm HEAD 舊，下一次建 APK 會重生。

`mfst` 的 commit 數從 1 更正為 11：那一欄先前寫的是扁平後的數量，不是範圍內的數量，欄位定義不符。
整個 repo 都是我們的（無上游），11 個 commit 裡 7 個是 lateautumn233 的。

## 1. 表一：L / M / 新功能列

`o` = 扁平後這個 repo 會有這個 commit　`-` = 不涉及

| # | commit（功能） | meta | cross | app | edk2 | hmod | gmod | crosvm | virt | gfxs | virgl | mesa | mfst | win |
|---|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| **L** | Licensing | o | o | o | -¹ | o | o | o | - | o | o | o | - | - |
| **M1** | 建置管線與打包 | o | o | o | - | o | o | o | - | o | - | o | o | o |
| **M2** | DisplayFramework 重構 | - | - | o | - | - | - | o | o | - | - | - | - | - |
| **M3** | 磁碟與儲存² | - | - | o | - | - | - | o | - | - | - | - | o | - |
| **M4** | VM 平台雜項³ | - | - | o | o | o | - | o | - | - | - | - | - | - |
| **M5** | 核心模組管理與大頁（含 settings.prop 進階畫面） | - | - | o | - | o | - | - | - | - | - | - | - | - |
| **R** | nproc 救援模組（`nproc_guard`）⁵ | - | - | o | - | o | - | - | - | - | - | - | - | - |
| **N** | 網路預設與設定精靈步驟 | - | - | o | - | - | - | - | - | - | - | - | - | - |
| **AG** | 客體代理操作（無頭 agent VM）⁴ | - | - | o | - | - | - | - | - | - | - | - | - | - |
| **C** | vCPU 放置（affinity / capacity / cluster）¹¹ | - | - | o | - | - | - | - | - | - | - | - | - | - |
| **S** | 序列埠：SBSA UART / pty / USB ACM / PM reset | - | - | o | o | - | - | o | - | - | - | - | - | - |
| **A** | 虛擬音效卡（virtio-snd + AAudio 端點）ᴬ | o | - | o | - | - | - | o | - | - | - | - | - | o |
| **MED** | virtio-media：相機 / VPU⁶ᴬ | o | - | o | - | - | - | o | - | - | - | - | o | - |
| **P** | pseudo-unprotected VM + boot shim¹² | o | - | o | o | - | o | o | - | - | - | - | - | - |
| **W** | Windows guest 支援（pVM 驅動移植） | o | - | - | o | - | - | - | - | - | - | - | - | o |

**N** 與 **AG** 來自同一個 mega-commit `ca184f0`（61 檔 +4213/−882），連同 M3 的擴充，扁平時要按三列拆開。

**R 是 08-30 唯一的新列。** 它只有兩格，而且兩格本來就亮著——如果你認為救援模組只是 `setresuid`
修正的附屬品，把 R 併進 **M5** 即可（兩列亮的都是 app＋hmod），總數變成 127，其他什麼都不用動。分開列的理由是它是一個
自帶 sysfs 介面與 insmod 參數的獨立模組，扁平後 hmod 那半沒辦法誠實地塞進「核心模組管理」那一筆。

## 2. 表二：G + 路線列

| # | commit（功能） | meta | cross | app | edk2 | hmod | gmod | crosvm | virt | gfxs | virgl | mesa | mfst | win |
|---|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| **G1** | Gunyah 記憶體共享⁷ | - | - | o | - | o | o | o | - | - | - | - | - | - |
| **G2a** | 開機期 blessed pool | - | - | o | o | - | o | o | - | - | - | - | - | - |
| **G2b** | guest-alloc pool | - | - | o | - | - | o | o | - | - | - | - | - | - |
| **G2c** | 可成長 pool（`droidvm,pool-size`） | - | - | o | o | o | o | o | - | - | - | - | - | - |
| **G2d** | udmabuf 模組與界限（三邊 65536） | - | - | o | - | o | o | o | - | - | - | - | - | - |
| **G6** | 執行期 parcel 直接匯入 DMA-BUF⁸ | - | - | - | - | o | - | o | - | - | - | - | - | - |
| **G7** | `gh_unmovable`：一開始就不可移動的記憶體，讓小 blob 也能 share | - | - | - | - | o | - | - | - | - | - | - | - | - |
| **G3** | Scanout 與 blit 路徑（含每個 sink 自報 fourcc） | - | - | o | - | - | o | o | o | - | o | - | - | - |
| **DP** | 顯示管線解耦（Screen / Frame / Exporter、多螢幕、per-binding 輸入） | o | - | o | - | - | o | o | o | - | - | - | - | - |
| **H** | VNC 硬體 H.264（RFB encoding 50 + `DVH1`） | o | - | o | - | - | - | o | o | - | - | - | o | - |
| **G4** | GPU 排程（cpuset / RT，**依賴 C**） | - | - | o | - | - | - | o | - | - | - | - | - | - |
| **G5** | zink / wsi / GL 共用修正 | - | - | - | - | - | - | - | - | - | - | o | - | - |
| **Q** | virglrenderer QEMU resource-info 相容 API | - | - | - | - | - | - | - | - | - | o | - | - | - |
| **D** | drm2kgsl 路線 | o | - | o | - | - | o | o | - | - | o | o | - | - |
| **X1** | gfxstream 路線接線⁹ | o | - | o | - | - | o | o | - | - | - | o | - | - |
| **X2** | fd 外部記憶體模式 + HMI HAL（取代舊 AHB 適配） | - | - | - | - | - | - | - | - | o | - | o | - | - |
| **X3** | host-visible 後端、ring blob 池與 folio 政策¹⁰ | - | - | - | - | - | - | o | - | o | - | - | - | - |
| **X4** | Vulkan decoder 強化與生命週期 | - | - | - | - | - | - | - | - | o | - | - | - | - |
| **X5** | ASG 傳輸（consumer / framing / seqno） | - | - | - | - | - | - | - | - | o | - | o | - | - |
| **X6** | guest blob 匯入與 teardown | - | - | - | - | - | - | - | - | o | - | - | - | - |
| **X7** | cereal 相容閘（建置期腳本） | - | - | - | - | - | - | - | - | o | - | - | - | - |
| **X8** | guest ICD 擴充與配置 | - | - | - | - | - | - | - | - | - | - | o | - | - |
| **X9** | gfxstream 診斷（建議丟） | - | - | - | - | - | - | - | - | o | - | o | - | - |
| **X10** | 臨時壓抑（modifier 隱藏、`GFXSTREAM_NO_CB_EXPORT`） | - | - | - | - | - | - | - | - | o | - | - | - | - |
| **V** | venus 路線 | o | - | o | - | - | o | o | - | - | o | o | - | - |

08-29 新增 **G6**（hmod + crosvm）與 **Q**（virgl），並補三格：**G2d/gmod**、**X2/mesa**、**G1/hp**。
其中 **G1/hp** 已隨 hp 欄一起消失。

### 欄總計

| meta | cross | app | edk2 | hmod | gmod | crosvm | virt | gfxs | virgl | mesa | mfst | win | 合計 |
|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| 11 | 2 | 26 | 6 | 10 | 13 | 23 | 4 | 10 | 5 | 10 | 4 | 3 | **127** |

（歷次總數：08-26 **122** → 08-29 **130** → 08-30 加入 R 後 **132** → hp 欄退出後 **129**
→ 實作扁平化時發現**三格是空的**（edk2/L、crosvm/C、hmod/P）後 **127**
（hmod/P 空出來的位置由新列 **G7** 補上，所以總數持平）。）

**那三格是實作時才發現的，不是重新判斷的結果。** builder 做不出那些 commit，因為範圍內根本沒有
對應內容：edk2 的 licensing 加了又 revert（§4）、crosvm 完全沒有 vCPU 放置的碼（註¹¹）、
hmod 沒有 pseudo-unprotected 的碼（註¹²）。矩陣先前把「不變」「上游本來就有」「放錯格的模組」
都畫成了一格 commit。**這是紙上推演看不出來、真的去建分支才會撞到的一類錯誤。**

¹ edk2 保持 BSD-2-Clause-Patent，唯一不轉 GPL——而且「保持」是字面意思：範圍內**沒有任何 licensing 檔案被動過**。
　`fe353d3` 加過一版又被 `f8fa47a` 整個 revert（拿它動過的 7 個檔案 diff `fe353d3~1..f8fa47a`，0 行），
　所以這格是 `-`：沒有 commit 可產出
² LXC 映像匯入與建立 Linux VM、磁碟維護（resize / 相依更新 / 自動擴容）、VM 刪除、qcow2 zstd 與 zero-cluster、
　匯入後才可開機的規則
³ SMBIOS 身分、pflash、ACPI 電源、致命訊號、IRQ 衝突、kvcalloc >2GB、per-VM 環境變數、game mode、
　BootPlan 分成 UEFI / 直接開機兩型
⁴ `agent_mode`：QEMU 後端多開一條 `agent0` chardev，跑無頭 VM 做改密碼與自動擴容；動作佇列有單元測試。
　共用終端機面板（console / agent / disk 三個畫面同一個 `TerminalPanelView`）也記在這裡——真正改變行為的是
　agent 那個畫面，救援 shell 從「看得到」變成「打得進去」，另外兩個是重構的連帶
⁵ hmod 的 `nproc_guard.ko`（KMI 無關，6.1/6.6/6.12 一份原始碼，`uid=` 必填否則不動作）＋ app 兩處接線
　（`KernelModuleManager` 帶 uid insmod、`VMInstance` 在 VM 結束後 nudge reset）。**沒有強綁定**：
　模組沒載入時 sysfs 節點不存在，app 那半就是 no-op。診斷模組 `nproc_probe` 明寫 temporary，見 §8
⁶ 地基已落地：crosvm 的 `android_camera` Camera2 後端（`camera_probe` 實測 29.45 fps NV21），
　app 只有設定 schema 與權限；**virtio-media 裝置三個都還沒寫**
⁷ host_share 模組、runtime SHARE / UNSHARE、VmAccept::Sync、`/dev/gh_pinprobe` **的用戶端**、liveness GC、pin 釋放。
　節點本身由 `gh-hugepage-reserve` 提供（ABI 與 `gh_unmovable.ko` 舊版逐位元組相同），那個專案不在本表內，
　所以這一列只能假設節點「可能不存在」
⁸ hmod `gunyah_share` 收 DMA-BUF fd 當 parcel 來源，不改它的 backing；crosvm 端把 GPU 驅動匯出的 dma-buf
　直接送去 SHARE。這條路是 host folio 政策在 crosvm 側的替代品（見 §4）
⁹ capset / context-types / `GFXSTREAM_*` env（含 `GFXSTREAM_VRAM_*` 四個）/ pool 節點名 / UI / 啟動器
¹² hmod 範圍內**沒有 pseudo-unprotected 的碼**：整棵樹搜 `pseudo` 只有 `udmabuf.c:141` 一句註解。
　原本佔著 P 那格的 `gh_unmovable` 是獨立模組（非 Gunyah SHARE 本體），改列成 **G7**——
　跟 R（`nproc_guard`）同樣的處理：一個模組一列。hmod 的 commit 數不變

¹¹ crosvm 範圍內**沒有 vCPU 放置的碼**：整個 `droidvm/droidvm..wip` 的 diff 裡，`cpu_affinity` /
　`cpu_capacity` / `cpu_cluster` / `sched_setaffinity` / `cpuset` / `gpu_cgroup` 一行增刪都沒有，
　`--gpu-cgroup-path` 在 base 與 wip 的 `cmdline.rs` 裡都存在且相同——那是上游本來就有的。
　C 因此只剩 app 一格（lateautumn233 的 affinity picker）

¹⁰ folio 政策現在整條在 gfxstream（`host/vulkan/host_visible_folio.h`）；crosvm 只從 `--gpu vram-folio-threshold-kb=`
　轉成 env 傳過去，`STREAM_HANDLE_TYPE_MEM_POOL` 與 ring blob 池仍在 crosvm 側

ᴬ 這兩列的 crosvm 半邊各含一處 `setuid()` → `setresuid()`：A 是 vhost-user snd 後端降權到 app uid，
　MED 是 `camera_probe` 的同一個動作。**這是修正不是新功能**，格子本來就亮，見 §4 與 R 的說明

## 3. 排序限制與強綁定

1. ~~**G4 必須排在 C 之後。**~~ **這條作廢。** 它的前提是「`--gpu-cgroup-path` 由 lateautumn233 的
   vCPU affinity commit 引進」——實查 `cmdline.rs`，那個旗標在 base 與 wip 都在且相同，是上游本來就有的，
   不在我們的範圍內。crosvm 沒有 C 列（註¹¹），所以兩列之間沒有順序關係。G4 在 crosvm 是獨立的一筆。
2. **H 是一個七函式 C ABI**：`android_h264_enc_{create,destroy,request_sync_frame,encode_frame,poll_output,codec_config,frame_counts}`
   加 `media_codec_abi.h`。crosvm 宣告 `extern "C"`、virt 提供實作。兩邊必須同時上。
3. **X3 是第二個跨 repo ABI**：`stream_renderer_handle` 欄位、`STREAM_HANDLE_TYPE_MEM_POOL`、init params 2048/2049。
   gfxs 與 crosvm 各寫一半，FFI struct 大小必須一致。
4. **G2a/G2b/G2c 在 app、gmod、crosvm 三欄同時亮**：同一機制在三層各改一次（UI 傳參 → guest 驅動 → VMM）。
   三個 repo 的相對順序要一致，否則中間狀態的 guest 會拿到 host 還不認得的 wire。
5. **G2d 的 65536 是三邊數字**：hmod 的 udmabuf `list_limit`、crosvm 的 `MAX_UDMABUF_ENTRIES`、
   gmod 的 `guest_pool_max_nents`。最低的那個說了算，所以三個 repo 必須同一輪一起上。
6. **G3 的顏色邊界跨 crosvm 與 virt**（08-30 兩邊都已提交）：crosvm 端讓每個 sink 自報 fourcc、
   在 CPU 邊界做至多一次轉換；virt 端才能刪掉整幀 NEON 的 `swapRedBlueInPlace`。
   扁平後這兩個 commit 之間不能插進任何會被人 bisect 到的東西——只上一半就是整片紅藍互換。
7. **G6 與 X3 是同一個問題的兩個答案**：crosvm 的 per-blob folio 政策（`--runtime-share`）被 G6 取代，
   同一個政策的另一半搬進 gfxstream。扁平時 crosvm 不該出現 `--runtime-share`（見 §4）。
8. **X1（app 端去掉 virgl2）↔ crosvm 的 vrend 保持初始化**：只上 app 那半，每台 drm2kgsl/venus VM 都沒畫面。
9. **MED 是配對佔位**：app 半邊只有設定 schema 與權限，crosvm 半邊只有 `android_camera` 後端（沒有任何
   crosvm 程式碼引用它），virtio-media 裝置三個都沒寫。app 半邊單獨上線會是死 UI。
10. **G1 的 pinprobe 已經搬到表外**：`gh_unmovable.ko` 不再註冊 `/dev/gh_pinprobe`，節點改由
    `gh-hugepage-reserve` 提供，而那個專案走自己的上游流程。本表內只剩兩個半邊，必須一起上——
    hmod 拿掉註冊、crosvm 容忍缺席；只上前者的話，舊 crosvm 會把「節點不見了」當成「不可 pin」。
    因為提供者在表外，crosvm 那半不能寫成「節點一定在」，這是硬需求不是防禦性寫法。

## 4. 扁平時不該出現的東西

- **crosvm 的 per-blob host folio 政策**：`--runtime-share` / `RuntimeShareConfig` / `prepare_blob_backing` /
  `hypervisor/src/gunyah/mthp.rs` / rutabaga `register_blob_backing_handlers`，`713d71e64` 一次全刪（−449 行）。
  淨值是「crosvm 沒有這個旗標」，政策活在 gfxstream。**這是本輪最大的一組加了又刪。**
- **edk2 的 licensing commit `fe353d3`**：加了又被 `f8fa47a` 整個 revert，逐字淨零，所以 edk2 的
  L 格是 `-`（註¹）。
- **crosvm 的 pflash cherry-pick `f7838af1d`**：原始 commit `604aad262` 已經在 base 裡，
  兩邊內容逐字相同，`git diff` 對 pflash 是空的。扁平後不會有這個 commit（見 §5）。
- **`/dev/gh_pinprobe` 在 `gh_unmovable.ko` 的那一版**：hmod 建了又搬走（`588e583`），加了又刪，淨零。
  扁平後 hmod 不該有它，而接手的專案不在這張表上。
- **udmabuf 的 16384**：三個 repo 先後訂 16384 再一起改 65536，扁平後直接 65536，不留中間值。
- **`external_scanout` 仲裁**：08-20 加入，`b3fe7cf5e` 被新的 Screen 模型整個刪除。加了又刪，淨零。
- **CPU 顯示管線的「正規 BGRX」約定**：這個約定從來只寫在註解裡，而它讓一幀被改寫兩次——
  crosvm 的 `swap_red_blue_in_place`（依 guest 宣告的 fourcc 決定要不要換）＋ virt 的
  `swapRedBlueInPlace`（整幀 NEON，換回 RGBA_8888）。兩支函式都刪了，改由每個 sink 自報 fourcc、
  在 `copy_from_frame()` 這唯一的邊界做至多一次轉換。扁平後不該有任何一支「全幀 swizzle」存在。
- **`gunyah_hugepage_threshold_kb` / `gunyah_dynamic_share` 的遷移碼**：改名後又留了一份
  `migrateLegacySettings`，每次建構 VMConfig 都跑，讀一個沒人寫的 key。扁平後直接用新 key。
- **DVH2 第二 TCP 埠 side channel**（`h264-port=`）：`e15b27a0a`+`77c685775` 加入，`038abbaa3`+`6a35ebf8b` 端到端刪除。
- **gfxstream `188286372` ↔ `f5b4557e2`**：一對字面 revert，`git diff` 為空。
- **gfxstream seqno ladder 的自我抵銷**：`3bcb7b855`（加回第二三階）↔ `a2fa1750c`（拿掉 futex 階），
  兩者淨值 +31 行卻花了 875 行 churn。四個 commit 應併成一個。
- **mesa 的 first-transfers hex dump**：`3cecae67059` 已經自己刪掉了（X9 的一部分先行落地）。
- **mesa `c08fd270f69` ↔ `6634f48977c`**：extension 隱藏加了又拿掉。這個是**真正的上游取代**——
  新 gfxstream host base 212 個 pNext struct 全部能解，經 `check-cereal-compat.py` 驗證。
- **mesa `8c7d7ccc8ed` → revert → reapply**：那兩個 revert 是 A/B 量測不是否決，淨狀態是「已套用」。

## 5. 署名

### 規則

扁平化**只對照上游與本地最終狀態**，按功能切分，不參照 wip 的 commit 邊界。所以一個 commit 的
「作者」不再由歷史決定，而是由**這個功能的最終狀態裡有誰的碼**決定：

1. 一個功能有幾位作者，`pr/3d-accel` 那一個 commit 就掛幾個 `Co-authored-by:`。
2. **wip 分支裡的作者欄不必修。** 那裡有 `Your Name <you@example.com>`、有空 email、有同一個人四種寫法，
   全部不管——`wip/3d-accel` 是工作歷史，只要 `pr/3d-accel` 是對的就好。
3. `pr/3d-accel` 的 trailer **不掛 AI**。現在 wip 裡的 `Co-Authored-By: Claude ...` 與
   `Claude-Session:` 兩種 trailer 在扁平時一律刪掉（見 §8）。
4. 作者身分以人為單位，不是以 email 為單位。HuJK 的四種寫法
   （`gh@hujk.oeg`、`gh@hujk.org`、`s920361@gmail.com`、`Your Name <you@example.com>`）是同一個人，
   統一成一個。

### 目前的作者

**寫 commit 時就用這幾行**（前三個位址都實測過 GitHub 會連到本人的帳號，用
`gh api repos/<r>/commits/<sha> --jq .author.login` 驗的）：

```
Author: HuJK <gh@hujk.org>
Co-authored-by: lateautumn233 <lateautumn233@foxmail.com>
Co-authored-by: sunflower2333 <sunflower2333@outlook.com>
Co-authored-by: chunxu Liu <17998140+317764920@users.noreply.github.com>
```

⚠️ **`gh@hujk.oeg` 是錯字（oeg / org），而且 GitHub 認不得**——實測那個位址的 commit 回
`UNLINKED`，`gh@hujk.org` 才回 `HuJK`。範圍內最多的作者欄剛好就是那個認不得的錯字，
所以「四種 email 統一」不是美觀問題，是**不統一的話大半 commit 不會算在本人頭上**。

| 人 | 出現在 | 待辦 |
|---|---|---|
| **HuJK** | 全部 13 個 repo | 四種寫法統一成 `gh@hujk.org`（見上） |
| **lateautumn233（L233）** | app, hmod, gmod, crosvm, virt, virgl, mesa, mfst；**gfxs 的署名被弄丟了** | 見下方每列對照 |
| **Kancy Joe**（GitHub `sunflower2333`） | win `3b005d67`（`rdmapool/` 基礎）→ **W** | 用他自己 commit 的 `sunflower2333 <sunflower2333@outlook.com>`（實測會連到帳號） |
| **chunxu Liu** | win 的 viosnd → **A** | trailer 已經在 wip `41c2521b` 的 body 裡，照抄 |

**是四個人，不是三個。** 第四位 **chunxu Liu** 是實作扁平化時才浮出來的：win 的 viosnd 驅動
vendored 自 `github.com/317764920/viosnd`，wip `41c2521b` 的 body 本來就掛著他的 `Co-Authored-By:`。
那不是 AI trailer，不能跟 Claude 那些一起刪。**只掃 `%an` 掃不到他，要讀 commit body 才看得見**
——署名不能只看作者欄。

`Kancy Joe` 與 `sunflower2333` 是同一個人（GitHub id 54024877，
帳號顯示名就是 Kancy Joe），先前被當成兩位是我看錯。email 也不是問題：他在 DroidVM 與 edk2-gunyah 的
commit 一直用 `54024877+sunflower2333@users.noreply.github.com`，直接抄那個。
（crosvm 那個空 email 不是 cherry-pick 弄掉的——base 裡的原始 commit `604aad262` 本來就是空的。）

**BigfootACA 仍然出現在範圍內**：`win` 的 `3b005d67~1..master-squash` 裡有他 5 個 commit，
全部是把 HuJK 自己的 PR 併進 master 的 merge。merge 不帶內容，所以不掛 trailer——這跟
`gh-hugepage-reserve` 裡那兩個 merge 是同一個判準，不是因為那個 repo 退出了。samfor12 則是真的
隨 hp 一起離開。

⚠️ **但他的 crosvm pflash 不進 `pr/3d-accel`。** 見下一段。

### 每一列要掛誰

只列出 HuJK 以外還有人的列。沒列到的 21 列——**L**、**M5**、**N**、**AG**、**R**、**S**、**A**、**MED**、
**P**、**G2c**、**G2d**、**G6**、**H**、**Q**、**X1**、**X4**–**X7**、**X9**、**X10**——就是 HuJK 一個人。
**L**（Licensing）值得特別點名：hp 還在欄裡時它的非 HuJK 署名（samfor12＋L233）全部來自 hp，
hp 退出後它變成 HuJK 獨有，很容易在清單裡被漏掉。

| 列 | 追加 co-author | 依據（wip 的 commit） |
|---|---|---|
| **M1** 建置管線與打包 | L233 | mesa `40eccc6e9db` `34c69c5813d` `0c92ee40414` `11a4b43c40b` `f5faa901c85`；mfst 全部 7 個 |
| **M2** DisplayFramework | L233 | app `02377c0`（DisplayChromeController tests） |
| **M3** 磁碟與儲存 | L233 | app `540a601`（zstd worker count） |
| **M4** VM 平台雜項 | L233 | app `d3dfe75`（per-VM 環境變數）。~~crosvm `f7838af1d`（pflash）~~ 見下 |
| **C** vCPU 放置 | L233 | app `7e5459c`（affinity picker） |
| **W** Windows guest | **Kancy Joe** | win `3b005d67` |
| **G1** Gunyah 記憶體共享 | L233 | hmod `0a9d951`；crosvm `78ca3b50b` `d01bdef7f` |
| **G2a** 開機期 blessed pool | L233 | crosvm `bb171f312`（pci_bar_size 2GB→256MB） |
| **G2b** guest-alloc pool | L233 | app `15c8286`；gmod `ce7e962`；crosvm `83ffa9d8f` |
| **G3** Scanout 與 blit | L233 | gmod `075d260`；crosvm `ddf70b61b` `cff5722ee` `00ec650d0`；virgl `fd611e67` `24ce0a62`；virt `f413ae8` `4a4581e` |
| **DP** 顯示管線解耦 | L233 | virt `466354b`（surface change handling） |
| **G4** GPU 排程 | L233 | crosvm `2444da33c`（RT scheduling） |
| **G5** zink / wsi / GL | L233 | wsi `24df2ad76b2` `24d85e4494e`；GL `4501696cbcd`（`src/mesa/main/getstring.c`，所以列名含 GL） |
| **D** drm2kgsl | L233 | virgl：範圍內 19 個 `drm/kgsl:` 中他的 **10** 個（另外 9 個是 HuJK 的）；mesa：`tu/virtio:` 4 個、`tu/a750` `91be6906972`、`50450cbcc75`、`945635003d3`、`12b907f5a52`、freedreno/virtio 側 4 個。**`b9881a0c` 不算在內**——它改的是 `src/vrend_renderer.c`，host GL 路線，不是 kgsl（見 §8） |
| **X2** fd 外部記憶體 | L233（**補回**） | 舊分支 `1c6e27ef3` + `e1d0472b5`；被 `7bccebab2` 重寫——見下 |
| **X3** host-visible 後端 | L233（**補回**） | 舊分支 `f038bd111`（lazy mLinear）；被 `402ea1771` 重寫——見下 |
| **X8** guest ICD 擴充 | L233 | mesa `44df9764052`（cerealgenerator + gfxstream_vk_device + ResourceTracker） |
| **V** venus | L233 | crosvm `0091d85be`（forward virgl log levels）；virgl `336c5aed` |

### pflash 已經在 base 裡，所以它不產生 commit

`f7838af1d`（Kancy Joe，aarch64 pflash for UEFI variables）在 `droidvm/droidvm..HEAD` 的範圍內，
所以按 commit 數它是「我們的」。但扁平化比的是**上游與最終狀態**，而這個功能兩邊都有：

- 原始 commit `604aad262` 在 base（`droidvm/droidvm`）裡，`f7838af1d` 是它的 cherry-pick。
  我們的分支從 `3126586d1` 分出去，那時 `604aad262` 還沒進 base，後來兩邊各自有了它。
- `git diff droidvm/droidvm HEAD` 在 `devices/src/pflash.rs` 上**完全沒有輸出**，
  `aarch64/src/fdt.rs` 與 `aarch64/src/lib.rs` 的 diff 裡**沒有任何一行碰到 pflash**
  （`fdt.rs` / `lib.rs` / `pflash.rs` 三個檔的 pflash 出現次數 base 與 HEAD 一模一樣：10 / 38 / 93）。

所以扁平後 M4 不會包含任何 pflash 內容，也就沒有東西要掛他的名字。他在 `pr/3d-accel` 的
唯一貢獻是 **W** 的 `rdmapool/` 基礎。**這不是把人漏掉，是那段碼已經在上游了**——這正是
「只對照上游與最終狀態」這條規則要處理的情況，也是 §4 那一節的同類。

### gfxstream 的署名要用手補

08-21 那次不是 rebase，是**從 `aosp/emu-main-dev` 全新建立分支**再手工重寫，103 個舊 commit 變成 25 個，
lateautumn233 在舊分支上的 12 個 commit 一個都沒帶過來——現在 62 個 commit 裡沒有一行**人類的**
`Co-authored-by`（AI trailer 有 61 個，那些扁平時本來就要刪）。12 個裡有 9 個是設計取代
（`ff1557881` 改用 fd/dma-buf 取代整條 AHB 路線）合理消失，剩下 3 個是**他的碼被重寫**，
最終狀態裡還看得到：

| 舊分支（他的） | 新分支（HuJK 重寫） | 要補的列 |
|---|---|---|
| `f038bd111` gfxstream: lazy-allocate mLinear for blob-backed resource transfers | `402ea1771` | **X3** |
| `1c6e27ef3` gfxstream: always apply memoryTypeBits host-to-guest mapping | `7bccebab2` | **X2** |
| `e1d0472b5` gfxstream: zero out Vk13Features instead of removing from chain | `7bccebab2`（同一個） | **X2** |

⚠️ 這張表在 08-31 之前寫反了：當時把**新分支上 HuJK 的重寫 hash** 當成「舊分支的證據」，
照著查會查到 HuJK 自己，`Co-authored-by` 一行都生不出來。舊分支保留在
`backup/pre-upstream-20260821`，比對用 `git log backup/pre-upstream-20260821 --author=lateautumn233`。

### 其他

- crosvm `d9000bb43` 作者 `Your Name <you@example.com>` 是本機早期未設 identity 的產物，是 HuJK 自己的，
  不是另一個人。
- **meta 不掛 lateautumn233。** 他在 meta 唯一的痕跡是 `guest-patches/linux/0001-...patch` 這種
  vendored patch 檔（patch 內文的 `From:` 是他），而那整個目錄已經從 `pr/3d-accel` 拿掉（§7）。
  真正 ship 的是 gmod 的 `virtio_gpu/` 驅動，gmod 的 `bf00f88`（accept host-SHARE'd memparcels）
  已經掛了他的 trailer。**署名跟著實際 ship 的碼走，不跟著鏡像走。**
- L233 的兩個 `tmp` / `wip` 標題（crosvm `d01bdef7f`、mesa `44df9764052`）內容都是真的：
  前者是 Gunyah + GPU blob（G1），後者是 gfxstream guest ICD（X8）。標題爛不代表可以丟。

## 6. 換基準帶來的反向問題

新的 gfxstream 上游不是「我們的補丁縮水」，而是**重新移植時默默掉了行為，後面得補回來**：

- `7104586b3`：上游把寫死常數改成 `VulkanMaxSafeHeapSize` 且預設不設，重新移植繼承新預設值卻沒注意行為變了。
- `1f6560815`：上游 `74f179774` 讓 `ExportBlob` 能回答 non-blob COLOR_BUFFER，**但 crosvm 沒有對應的 rutabaga 半邊**。
  08-28/29 的 `dad773942`（gfxs 按 handle type 選匯入路徑）＋ `6ad3bcbcfca`（mesa 保留 dedicated image type）
  是這件事的續集，都掛在 X2。

## 7. 無家可歸的產物

- `crosvm_build/external/aaudiotone/`（08-23）：AAudio 測音程式，在被 gitignore 的 `crosvm_build/` 裡，
  不是自己的 git repo，也不在 manifest 裡。
- DroidVM `app/src/main/assets/prebuilts` submodule 指標在 `ca184f0`、`d2c994c` 各動一次，但本機重編的
  crosvm payload 沒推回 Droid-VM/DroidVM-Prebuilts。扁平後這些 bump 是噪音，除非 prebuilts repo 自己有一列。
- **Q 的 consumer 不在這張表上**：`virgl_renderer_resource_get_info_ext` 是給 QEMU 用的，而
  `qemu-gunyah/qemu-android-gunyah` 是別的 org、最後一個 commit 停在 2026-04-03。app 的 QEMU 後端選項是上游本來就有的。
- **`prebuilts` submodule 是髒的但指標沒動**：本機重編的 payload 已含 `nproc-guard-gki-{6.1,6.6,6.12}.ko`，
  但沒推回 Droid-VM/DroidVM-Prebuilts，而且它比 crosvm HEAD 舊（少 `setresuid` 與顏色邊界）。
  下次建 APK 會重生，所以沒有必要為了扁平先提交它。
- **`guest-patches/`（23 個檔）已從 meta 的 `pr/3d-accel` 拿掉。** 它是鏡像不是產物：
  `linux/*.patch` 的實體是 gmod 的 `virtio_gpu/` DKMS 驅動；`mesa-26.0.3/` 與 `l233-mesa/` 是
  mesa fork 還推不出去時留的快照（README 自己寫「Canonical full tree: … snapshot the load-bearing
  files here」），那些檔案 mesa repo 裡都有。**沒有任何 `1~9*.sh` 引用它**（實查 0 次），
  `droidvm-gpu-modules.service` 也是 DKMS 打包前的手動 insmod unit。
- **`info.txt` 留著但做過去識別化**（空的 `CLAUDE.md` 拿掉）。而且不只 info.txt——同一批本機資料
  散在 **26 個檔案**裡（`deploy/` 的 bench 腳本 `PHONE=${PHONE:-…}` 預設值、`plans/` 的多份文件），
  只洗 info.txt 等於沒洗。`pr/3d-accel` 上一律換成：
  路由器 `10.53.12.1`、手機 `192.168.40.11/.12/.13`、MAC `02:00:5e:11:22:33`、
  IPv6 改用文件用途的 `2001:db8::/32`（原本是真實的 ISP 前綴，比內網 IP 更能識別）、
  路徑一律 `/root/Documents/DroidVM_meta`。驗證方式是整支分支 grep 原值，0 個檔案命中。

## 8. 待決

1. **`nproc_probe` 要不要在 PR 前刪掉。** 它自己的標頭就寫著 TEMPORARY，不在 `build.sh` 的模組清單、
   也不在 `match.json`，所以不會被打包；留著的唯一理由是 `setresuid` 修正還沒在三台上跑滿一輪，
   而 `leaked` 這個數字是唯一能分辨「修好了」與「剛好沒漂」的東西。確認之後就刪。
2. **X9 / meta 的 evidence pack / virgl D5 等診斷列要不要整包丟。** 全丟大約再少 15–20 個 commit。
3. **X10 兩個臨時壓抑**（commit body 自述「保持獨立以便隨時拿掉」）在 PR 前該不該先解決掉。
4. **mesa 的 6 個 Blumenkrantz upstream cherry-pick**：rebase 到 main 後原版已在 base 裡，實測會靜默重複插入
   （`zink_context.c` 的 partial-resolve 區塊出現兩次且無衝突警告），所以必須**明確 drop**，不能靠 patch-id 偵測。
5. **Q 要不要進 PR。** 它是 virglrenderer 的公開 ABI 增補，但這棵樹裡沒有 consumer（§7）。
6. **`win` 的 base 要在 `dev/viosnd-endpoint-per-stream` 合併前釘住。**
7. **預設 renderer 翻成 virglrenderer（app `6025be0`）沒有寫下理由**，body 只有機制面的事實。
   要嘛補上「virglrenderer 是目前能用的路線、gfxstream 還在實驗」，要嘛在扁平前退掉。
8. **對 `gh-hugepage-reserve` 的介面相依怎麼在 PR 裡交代**（§0 那三條）。三條都 fail-open，
   缺了那個專案一樣能跑，所以這是措辭問題不是設計問題。commit body 照實寫「對外部模組的可選整合」
   即可，不必渲染缺席時的後果——那是既有行為，不是這批改動造成的。
   唯一實質待辦是 **M5 面板的 v6/v7 版本分支**：那是唯一一處我們對外部專案的介面做了版本判斷，
   要嘛收斂成單一支援版本，要嘛在 body 說明為什麼兩版都要支援。
9. **純 virglrenderer GL 路線在矩陣裡沒有列。** 三條路線 D / X / V 都是 Vulkan，但 app 還提供
   `virglrenderer`（vrend GL），而且 `6025be0` 把它設成新 VM 的預設（見第 7 項）。virgl 的
   `b9881a0c`（Adreno GLES dual-source blend）就無處可歸。要嘛補一列，要嘛連同第 7 項一起
   決定這條路線在 PR 裡的定位。
10. **PR 目標分支名**：org 預設是 `wip-3d-accel`（連字號）。meta / hmod / gmod 整個 repo 都是 3d-accel 工作，
   建議 `pr/3d-accel` 直接以新歷史取代。

### 已從待決移除

- ~~Kancy Joe 的 email 是空的，寫不出 trailer~~ —— 他就是 GitHub 的 `sunflower2333`（id 54024877），
  自己的 commit 一直用 `54024877+sunflower2333@users.noreply.github.com`。而且他唯一進得了
  `pr/3d-accel` 的是 W，crosvm 的 pflash 已經在 base 裡（§5）。
- ~~hp 要不要併進 `pr/3d-accel`~~ —— 不併。它已推去自己的上游（Droid-VM/gh-hugepage-reserve，`bdf9062`），
  已從總表與兩張矩陣移除，帶走 L / M5 / G1 三格與 samfor12、BigfootACA 兩位署名。
  留下的唯一牽連是 `/dev/gh_pinprobe` 的執行期相依（§3.10）。
- ~~未提交的 G3 顏色邊界工作要先落地~~ —— 08-30 已提交，crosvm `f690a3c40` ＋ virt `3278ede`。
  §3.6 從「必須先落地」降級成「扁平時兩者不能拆開」。
- ~~A（音訊）的 crosvm 半邊未完成~~ —— `c15fcab2e`（08-26 09:35）已經把 VM 的 protection 透過
  `params.access_platform` 帶進 vhost-user 後端，`VIRTIO_F_ACCESS_PLATFORM` 會依 VM 型態宣告。
  08-26 的修訂寫這條時它已經修好了。

---

`plans/pr-flatten/*.md` 是 08-17/08-18 產出的逐 commit 明細（hunk 歸屬、coverage check）。
**那些檔案只涵蓋 08-18 之前的範圍**，本文第 1、2 節的表才是最新決定。
