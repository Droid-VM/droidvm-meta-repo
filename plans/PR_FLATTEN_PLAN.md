# pr/3d-accel 扁平化計畫（2026-08-29 修訂）

一項功能一個 commit，順序 **L**(licensing) → **M**(GPU 無關) → **G**(路線共用 GPU 基礎) → **D**(drm2kgsl) → **X**(gfxstream) → **V**(venus)。
他人 commit 併入功能 commit，作者掛 `Co-authored-by:`。

**08-26 修訂之後又長出八個 commit 位。** 本次把它們補上，並修正四個已經不成立的敘述：
crosvm 的 host folio 政策整條搬去 gfxstream、`/dev/gh_pinprobe` 搬去 gh_hugepage_reserve、
udmabuf 界限三邊一起改成 65536、virtio-snd 的 protected VM 半邊其實在 08-26 當天就修好了。

## 0. 總表

| repo | 縮寫 | base | head | 範圍內 commits |
|---|---|---|---|--:|
| droidvm-3d-accel（meta） | meta | 空樹 | af1454a | 300 |
| mesa-cross | cross | 空樹 | 2586325 | 19 |
| DroidVM（app） | app | `origin/master` | 51c13cb | 117 |
| edk2-gunyah | edk2 | `origin/master` | 4fb0b84 | 8 |
| gunyah_host_mod | hmod | 空樹 | b7920bb | 36 |
| droidvm-guest-additions | gmod | 空樹 | d7e6713 | 40 |
| crosvm | crosvm | `droidvm/droidvm` | 1607efb11 | 149 |
| Virtualization | virt | `droidvm/android16-qpr2-release-local` | a05556f | 12 |
| gfxstream | gfxs | `aosp/emu-main-dev` c00cd03a3（08-21 換基準） | 6a9d4dd2c | 62 |
| virglrenderer | virgl | `8220efec`（AOSP snapshot） | 3dbfe7b5 | 44 |
| mesa | mesa | mesa main `74d4e41b2bb` | 6ad3bcbcfca | 76 |
| crosvm-minimal-manifest | mfst | 分支鏈（不再釘 `main`） | 29de119 | 1 |
| gunyah-guest-drivers-windows | win | 上游 virtio-win | 8d12ff0e（`master-squash`） | 18 |
| gh-hugepage-reserve | hp | `upstream/master` | 9805ea9 | 23 |

`hp` 從 29 掉到 23，是 v12（`9805ea9`）把 v9/v11 疊出來的補丁路徑整包重寫成 SOLID 結構的結果，
不是有東西被丟掉。`win` 形狀與其他欄不同：base 是上游 virtio-win、上游目標也是 virtio-win，
而且**它已經自己扁平過了**（153 → 18 commits 在 `master-squash`）。

**尚未提交（扁平前必須先落地）**：crosvm 8 個檔（`gpu_display/` 的 per-sink fourcc 與單一轉換邊界）、
virt 1 個檔（刪掉 `swapRedBlueInPlace`）、meta 2 個檔（打包壓縮等級）。前兩者是 **G3** 的同一件事，
分屬兩個 repo，必須同時上。

## 1. 表一：L / M / 新功能列

`o` = 扁平後這個 repo 會有這個 commit　`-` = 不涉及

| # | commit（功能） | meta | cross | app | edk2 | hmod | gmod | crosvm | virt | gfxs | virgl | mesa | mfst | win | hp |
|---|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| **L** | Licensing | o | o | o | o¹ | o | o | o | - | o | o | o | - | - | o |
| **M1** | 建置管線與打包 | o | o | o | - | o | o | o | - | o | - | o | o | o | - |
| **M2** | DisplayFramework 重構 | - | - | o | - | - | - | o | o | - | - | - | - | - | - |
| **M3** | 磁碟與儲存² | - | - | o | - | - | - | o | - | - | - | - | o | - | - |
| **M4** | VM 平台雜項³ | - | - | o | o | o | - | o | - | - | - | - | - | - | - |
| **M5** | 核心模組管理與大頁 | - | - | o | - | o | - | - | - | - | - | - | - | - | o |
| **N** | 網路預設與設定精靈步驟 | - | - | o | - | - | - | - | - | - | - | - | - | - | - |
| **AG** | 客體代理操作（無頭 agent VM）⁴ | - | - | o | - | - | - | - | - | - | - | - | - | - | - |
| **C** | vCPU 放置（affinity / capacity / cluster） | - | - | o | - | - | - | o | - | - | - | - | - | - | - |
| **S** | 序列埠：SBSA UART / pty / USB ACM / PM reset | - | - | o | o | - | - | o | - | - | - | - | - | - | - |
| **A** | 虛擬音效卡（virtio-snd + AAudio 端點） | o | - | o | - | - | - | o | - | - | - | - | - | o | - |
| **MED** | virtio-media：相機 / VPU⁵ | o | - | o | - | - | - | o | - | - | - | - | o | - | - |
| **P** | pseudo-unprotected VM + boot shim | o | - | o | o | o | o | o | - | - | - | - | - | - | - |
| **W** | Windows guest 支援（pVM 驅動移植） | o | - | - | o | - | - | - | - | - | - | - | - | o | - |

**N** 與 **AG** 是本次新增的列，都只在 app。兩者連同 M3 的擴充來自同一個 mega-commit
`ca184f0`（61 檔 +4213/−882），扁平時要按這三列拆開。

## 2. 表二：G + 路線列

| # | commit（功能） | meta | cross | app | edk2 | hmod | gmod | crosvm | virt | gfxs | virgl | mesa | mfst | win | hp |
|---|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| **G1** | Gunyah 記憶體共享⁶ | - | - | o | - | o | o | o | - | - | - | - | - | - | o |
| **G2a** | 開機期 blessed pool | - | - | o | o | - | o | o | - | - | - | - | - | - | - |
| **G2b** | guest-alloc pool | - | - | o | - | - | o | o | - | - | - | - | - | - | - |
| **G2c** | 可成長 pool（`droidvm,pool-size`） | - | - | o | o | o | o | o | - | - | - | - | - | - | - |
| **G2d** | udmabuf 模組與界限（三邊 65536） | - | - | o | - | o | o | o | - | - | - | - | - | - | - |
| **G6** | 執行期 parcel 直接匯入 DMA-BUF⁷ | - | - | - | - | o | - | o | - | - | - | - | - | - | - |
| **G3** | Scanout 與 blit 路徑（含每個 sink 自報 fourcc） | - | - | o | - | - | o | o | o | - | o | - | - | - | - |
| **DP** | 顯示管線解耦（Screen / Frame / Exporter、多螢幕、per-binding 輸入） | o | - | o | - | - | o | o | o | - | - | - | - | - | - |
| **H** | VNC 硬體 H.264（RFB encoding 50 + `DVH1`） | o | - | o | - | - | - | o | o | - | - | - | o | - | - |
| **G4** | GPU 排程（cpuset / RT，**依賴 C**） | - | - | o | - | - | - | o | - | - | - | - | - | - | - |
| **G5** | zink 與 wsi 共用修正 | - | - | - | - | - | - | - | - | - | - | o | - | - | - |
| **Q** | virglrenderer QEMU resource-info 相容 API | - | - | - | - | - | - | - | - | - | o | - | - | - | - |
| **D** | drm2kgsl 路線 | o | - | o | - | - | o | o | - | - | o | o | - | - | - |
| **X1** | gfxstream 路線接線⁸ | o | - | o | - | - | o | o | - | - | - | o | - | - | - |
| **X2** | fd 外部記憶體模式 + HMI HAL（取代舊 AHB 適配） | - | - | - | - | - | - | - | - | o | - | o | - | - | - |
| **X3** | host-visible 後端、ring blob 池與 folio 政策⁹ | - | - | - | - | - | - | o | - | o | - | - | - | - | - |
| **X4** | Vulkan decoder 強化與生命週期 | - | - | - | - | - | - | - | - | o | - | - | - | - | - |
| **X5** | ASG 傳輸（consumer / framing / seqno） | - | - | - | - | - | - | - | - | o | - | o | - | - | - |
| **X6** | guest blob 匯入與 teardown | - | - | - | - | - | - | - | - | o | - | - | - | - | - |
| **X7** | cereal 相容閘（建置期腳本） | - | - | - | - | - | - | - | - | o | - | - | - | - | - |
| **X8** | guest ICD 擴充與配置 | - | - | - | - | - | - | - | - | - | - | o | - | - | - |
| **X9** | gfxstream 診斷（建議丟） | - | - | - | - | - | - | - | - | o | - | o | - | - | - |
| **X10** | 臨時壓抑（modifier 隱藏、`GFXSTREAM_NO_CB_EXPORT`） | - | - | - | - | - | - | - | - | o | - | - | - | - | - |
| **V** | venus 路線 | o | - | o | - | - | o | o | - | - | o | o | - | - | - |

本次新增 **G6**（hmod + crosvm）與 **Q**（virgl），並補三格：**G2d/gmod**、**X2/mesa**、**G1/hp**。

### 欄總計

| meta | cross | app | edk2 | hmod | gmod | crosvm | virt | gfxs | virgl | mesa | mfst | win | hp | 合計 |
|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| 11 | 2 | 25 | 7 | 9 | 13 | 24 | 4 | 10 | 5 | 10 | 4 | 3 | 3 | **130** |

（08-26 的版本是 122。+8 = N、AG、G2d/gmod、G6/hmod、G6/crosvm、Q/virgl、X2/mesa、G1/hp。）

¹ edk2 保持 BSD-2-Clause-Patent，唯一不轉 GPL
² LXC 映像匯入與建立 Linux VM、磁碟維護（resize / 相依更新 / 自動擴容）、VM 刪除、qcow2 zstd 與 zero-cluster、
　匯入後才可開機的規則
³ SMBIOS 身分、pflash、ACPI 電源、致命訊號、IRQ 衝突、kvcalloc >2GB、per-VM 環境變數、game mode、
　BootPlan 分成 UEFI / 直接開機兩型
⁴ `agent_mode`：QEMU 後端多開一條 `agent0` chardev，跑無頭 VM 做改密碼與自動擴容；動作佇列有單元測試
⁵ 地基已落地：crosvm 的 `android_camera` Camera2 後端（`camera_probe` 實測 29.45 fps NV21），
　app 只有設定 schema 與權限；**virtio-media 裝置三個都還沒寫**
⁶ host_share 模組、runtime SHARE / UNSHARE、VmAccept::Sync、`/dev/gh_pinprobe`（現由 hp 提供，ABI 逐位元組不變）、
　liveness GC、pin 釋放
⁷ hmod `gunyah_share` 收 DMA-BUF fd 當 parcel 來源，不改它的 backing；crosvm 端把 GPU 驅動匯出的 dma-buf
　直接送去 SHARE。這條路是 host folio 政策在 crosvm 側的替代品（見 §4）
⁸ capset / context-types / `GFXSTREAM_*` env（含 `GFXSTREAM_VRAM_*` 四個）/ pool 節點名 / UI / 啟動器
⁹ folio 政策現在整條在 gfxstream（`host/vulkan/host_visible_folio.h`）；crosvm 只從 `--gpu vram-folio-threshold-kb=`
　轉成 env 傳過去，`STREAM_HANDLE_TYPE_MEM_POOL` 與 ring blob 池仍在 crosvm 側

## 3. 排序限制與強綁定

1. **G4 必須排在 C 之後。** `--gpu-cgroup-path` 由 lateautumn233 的 vCPU affinity commit 引進，G4 的 RT 開關又 gate
   在 cpuset 存在上。反序會產生編不起來的樹。
2. **H 是一個七函式 C ABI**：`android_h264_enc_{create,destroy,request_sync_frame,encode_frame,poll_output,codec_config,frame_counts}`
   加 `media_codec_abi.h`。crosvm 宣告 `extern "C"`、virt 提供實作。兩邊必須同時上。
3. **X3 是第二個跨 repo ABI**：`stream_renderer_handle` 欄位、`STREAM_HANDLE_TYPE_MEM_POOL`、init params 2048/2049。
   gfxs 與 crosvm 各寫一半，FFI struct 大小必須一致。
4. **G2a/G2b/G2c 在 app、gmod、crosvm 三欄同時亮**：同一機制在三層各改一次（UI 傳參 → guest 驅動 → VMM）。
   三個 repo 的相對順序要一致，否則中間狀態的 guest 會拿到 host 還不認得的 wire。
5. **G2d 的 65536 是三邊數字**：hmod 的 udmabuf `list_limit`、crosvm 的 `MAX_UDMABUF_ENTRIES`、
   gmod 的 `guest_pool_max_nents`。最低的那個說了算，所以三個 repo 必須同一輪一起上。
6. **G3 的顏色邊界跨 crosvm 與 virt**：crosvm 端讓每個 sink 自報 fourcc、在 CPU 邊界做至多一次轉換；
   virt 端才能刪掉整幀 NEON 的 `swapRedBlueInPlace`。只上一半 = 紅藍互換。
7. **G6 與 X3 是同一個問題的兩個答案**：crosvm 的 per-blob folio 政策（`--runtime-share`）被 G6 取代，
   同一個政策的另一半搬進 gfxstream。扁平時 crosvm 不該出現 `--runtime-share`（見 §4）。
8. **X1（app 端去掉 virgl2）↔ crosvm 的 vrend 保持初始化**：只上 app 那半，每台 drm2kgsl/venus VM 都沒畫面。
9. **MED 是配對佔位**：app 半邊只有設定 schema 與權限，crosvm 半邊只有 `android_camera` 後端（沒有任何
   crosvm 程式碼引用它），virtio-media 裝置三個都沒寫。app 半邊單獨上線會是死 UI。
10. **G1 的 pinprobe 現在由 hp 提供**：`gh_unmovable.ko` 不再註冊 `/dev/gh_pinprobe`，crosvm 端在節點不存在時
    直接跳過探測。三個 repo（hmod 拿掉、hp 加入、crosvm 容忍缺席）必須一起上，否則舊 crosvm 配新模組會
    在缺節點時當成不可 pin。

## 4. 扁平時不該出現的東西

- **crosvm 的 per-blob host folio 政策**：`--runtime-share` / `RuntimeShareConfig` / `prepare_blob_backing` /
  `hypervisor/src/gunyah/mthp.rs` / rutabaga `register_blob_backing_handlers`，`713d71e64` 一次全刪（−449 行）。
  淨值是「crosvm 沒有這個旗標」，政策活在 gfxstream。**這是本輪最大的一組加了又刪。**
- **`/dev/gh_pinprobe` 在 `gh_unmovable.ko` 的那一版**：hmod 建了又搬走（`588e583`），扁平後只該出現在 hp。
- **udmabuf 的 16384**：三個 repo 先後訂 16384 再一起改 65536，扁平後直接 65536，不留中間值。
- **`external_scanout` 仲裁**：08-20 加入，`b3fe7cf5e` 被新的 Screen 模型整個刪除。加了又刪，淨零。
- **`swapRedBlueInPlace`**（virt，含 aarch64 NEON 版本）：整段刪除，換成 crosvm CPU 邊界的一次轉換。
- **DVH2 第二 TCP 埠 side channel**（`h264-port=`）：`e15b27a0a`+`77c685775` 加入，`038abbaa3`+`6a35ebf8b` 端到端刪除。
- **gfxstream `188286372` ↔ `f5b4557e2`**：一對字面 revert，`git diff` 為空。
- **gfxstream seqno ladder 的自我抵銷**：`3bcb7b855`（加回第二三階）↔ `a2fa1750c`（拿掉 futex 階），
  兩者淨值 +31 行卻花了 875 行 churn。四個 commit 應併成一個。
- **mesa 的 first-transfers hex dump**：`3cecae67059` 已經自己刪掉了（X9 的一部分先行落地）。
- **mesa `c08fd270f69` ↔ `6634f48977c`**：extension 隱藏加了又拿掉。這個是**真正的上游取代**——
  新 gfxstream host base 212 個 pNext struct 全部能解，經 `check-cereal-compat.py` 驗證。
- **mesa `8c7d7ccc8ed` → revert → reapply**：那兩個 revert 是 A/B 量測不是否決，淨狀態是「已套用」。

## 5. 署名

- **gfxstream 換基準時掉了 lateautumn233 的署名。** 08-21 分支是從 `aosp/emu-main-dev` **全新建立**（不是 rebase），
  103 個舊 commit 手工重寫成 25 個，他的 12 個 commit 一個都沒帶過來，62 個 commit 沒有任何
  `Co-authored-by: lateautumn233`。其中 10 個是設計取代（`ff1557881` 改用 fd/dma-buf 取代整條 AHB 路線）合理消失，
  但 **`402ea1771`（lazy mLinear）與 `7bccebab2`（memoryTypeBits + Vk13Features）是他的碼被重寫**，這兩列要補署名。
  舊分支保留在 `backup/pre-upstream-20260821`。
- **`win` 的 `rdmapool/` 基礎 commit `3b005d67` 作者是 `sunflower2333`**，不是 HuJK。
- **`hp` 有兩個外部作者**：`lateautumn233`（fork 起點）與 `samfor12`（PR #7，五個 commit：immediate reclaim、
  reconcile 對 vm_count=0、PCP drain）。v12 重寫把他們的碼吸收進新結構，扁平後那一列要掛兩個 co-author。
- app 的 lateautumn233 commit 5 個：guest memory allocation options（G2b）、環境變數（M4）、
  zstd worker count（M3）、DisplayChromeController tests（M2）、vCPU affinity picker（C）。
- crosvm `d9000bb43` 作者 `Your Name <you@example.com>` 是本機早期未設 identity 的產物，是 HuJK 自己的。

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
- meta 的 `CLAUDE.md`（空）與 `info.txt`（手機 IP/adb 埠）看起來是本機筆記。

## 8. 待決

1. **未提交的 G3 顏色邊界工作要先落地。** crosvm 8 檔 + virt 1 檔，兩邊同時上（§3.6）。
2. **X9 / meta 的 evidence pack / virgl D5 等診斷列要不要整包丟。** 全丟大約再少 15–20 個 commit。
3. **X10 兩個臨時壓抑**（commit body 自述「保持獨立以便隨時拿掉」）在 PR 前該不該先解決掉。
4. **mesa 的 6 個 Blumenkrantz upstream cherry-pick**：rebase 到 main 後原版已在 base 裡，實測會靜默重複插入
   （`zink_context.c` 的 partial-resolve 區塊出現兩次且無衝突警告），所以必須**明確 drop**，不能靠 patch-id 偵測。
5. **Q 要不要進 PR。** 它是 virglrenderer 的公開 ABI 增補，但這棵樹裡沒有 consumer（§7）。
6. **`win` 的 base 要在 `dev/viosnd-endpoint-per-stream` 合併前釘住。**
7. **預設 renderer 翻成 virglrenderer（app `6025be0`）沒有寫下理由**，body 只有機制面的事實。
   要嘛補上「virglrenderer 是目前能用的路線、gfxstream 還在實驗」，要嘛在扁平前退掉。
8. **Claude-Session trailer** 全部拿掉；HuJK 三種 email（`gh@hujk.oeg` / `gh@hujk.org` / `s920361@gmail.com`）統一。
9. **PR 目標分支名**：org 預設是 `wip-3d-accel`（連字號）。meta / hmod / gmod 整個 repo 都是 3d-accel 工作，
   建議 `pr/3d-accel` 直接以新歷史取代。

### 已從待決移除

- ~~A（音訊）的 crosvm 半邊未完成~~ —— `c15fcab2e`（08-26 09:35）已經把 VM 的 protection 透過
  `params.access_platform` 帶進 vhost-user 後端，`VIRTIO_F_ACCESS_PLATFORM` 會依 VM 型態宣告。
  08-26 的修訂寫這條時它已經修好了。

---

`plans/pr-flatten/*.md` 是 08-17/08-18 產出的逐 commit 明細（hunk 歸屬、coverage check）。
**那些檔案只涵蓋 08-18 之前的範圍**，本文第 1、2 節的表才是最新決定。
