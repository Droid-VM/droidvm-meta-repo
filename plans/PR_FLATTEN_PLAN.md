# pr/3d-accel 扁平化計畫（2026-08-26 修訂）

一項功能一個 commit，順序 **L**(licensing) → **M**(GPU 無關) → **G**(路線共用 GPU 基礎) → **D**(drm2kgsl) → **X**(gfxstream) → **V**(venus)。
他人 commit 併入功能 commit，作者掛 `Co-authored-by:`。

**這份文件在 08-18 到 08-26 之間停更，期間七個新功能列誕生。** 本次修訂把它們補上，並修正三個
已經不成立的結構假設（gfxstream 換基準、mesa 合併成單一分支、manifest 改走分支鏈）。

## 0. 總表

| repo | 縮寫 | base | head | 範圍內 commits |
|---|---|---|---|--:|
| droidvm-3d-accel（meta） | meta | 空樹 | b7a7753 | 297 |
| mesa-cross | cross | 空樹 | 2586325 | 19 |
| DroidVM（app） | app | `origin/master` | 6a5f283 | 103 |
| edk2-gunyah | edk2 | `origin/master` | 4fb0b84 | 8 |
| gunyah_host_mod | hmod | 空樹 | bee2864 | 33 |
| droidvm-guest-additions | gmod | 空樹 | 893d059 | 39 |
| crosvm | crosvm | `droidvm/droidvm` | 6a35ebf8b | 144 |
| Virtualization | virt | `android16-qpr2-release-local` | a05556f | 12 |
| gfxstream | gfxs | **`aosp/emu-main-dev` c00cd03a3**（08-21 換基準） | a2fa1750c | 60 |
| virglrenderer | virgl | `8220efec`（AOSP snapshot） | cf202c3c | 42 |
| mesa | mesa | mesa main `74d4e41b2bb` | 1ea6646e66b | 74 |
| crosvm-minimal-manifest | mfst | 分支鏈（不再釘 `main`） | 29de119 | 1 |
| **gunyah-guest-drivers-windows** | **win** | **上游 virtio-win** | 8d12ff0e（`master-squash`） | 18 |
| **gh-hugepage-reserve** | **hp** | `upstream/master` | 9681328 | 29 |

`win` 與 `hp` 是本次新增的欄。`win` 形狀與其他欄不同：base 是上游 virtio-win、上游目標也是 virtio-win，
而且**它已經自己扁平過了**（153 → 17 commits 在 `master-squash`）。`hp` 持有 `POOL_DESIGN.md` 與大頁模組本體。

## 1. 表一：L / M / 新功能列

`o` = 扁平後這個 repo 會有這個 commit　`-` = 不涉及

| # | commit（功能） | meta | cross | app | edk2 | hmod | gmod | crosvm | virt | gfxs | virgl | mesa | mfst | win | hp |
|---|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| **L** | Licensing | o | o | o | o¹ | o | o | o | - | o | o | o | - | - | o |
| **M1** | 建置管線與打包 | o | o | o | - | o | o | o | - | o | - | o | o | o | - |
| **M2** | DisplayFramework 重構 | - | - | o | - | - | - | o | o | - | - | - | - | - | - |
| **M3** | 磁碟與儲存 | - | - | o | - | - | - | o | - | - | - | - | o | - | - |
| **M4** | VM 平台雜項² | - | - | o | o | o | - | o | - | - | - | - | - | - | - |
| **M5** | 核心模組管理與大頁 | - | - | o | - | o | - | - | - | - | - | - | - | - | o |
| **C** | vCPU 放置（affinity / capacity / cluster） | - | - | o | - | - | - | o | - | - | - | - | - | - | - |
| **S** | 序列埠：SBSA UART / pty / USB ACM / PM reset | - | - | o | o | - | - | o | - | - | - | - | - | - | - |
| **A** | 虛擬音效卡（virtio-snd + AAudio 端點） | o | - | o | - | - | - | o | - | - | - | - | - | o | - |
| **MED** | virtio-media：相機 / VPU（**地基，裝置未實作**） | o | - | o | - | - | - | o | - | - | - | - | o | - | - |
| **P** | pseudo-unprotected VM + boot shim | o | - | o | o | o | o | o | - | - | - | - | - | - | - |
| **W** | Windows guest 支援（pVM 驅動移植） | o | - | - | o | - | - | - | - | - | - | - | - | o | - |

## 2. 表二：G + 路線列

| # | commit（功能） | meta | cross | app | edk2 | hmod | gmod | crosvm | virt | gfxs | virgl | mesa | mfst | win | hp |
|---|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| **G1** | Gunyah 記憶體共享³ | - | - | o | - | o | o | o | - | - | - | - | - | - | - |
| **G2a** | 開機期 blessed pool | - | - | o | o | - | o | o | - | - | - | - | - | - | - |
| **G2b** | guest-alloc pool | - | - | o | - | - | o | o | - | - | - | - | - | - | - |
| **G2c** | 可成長 pool（`droidvm,pool-size`） | - | - | o | o | o | o | o | - | - | - | - | - | - | - |
| **G2d** | udmabuf 模組與界限 | - | - | o | - | o | - | o | - | - | - | - | - | - | - |
| **G3** | Scanout 與 blit 路徑 | - | - | o | - | - | o | o | o | - | o | - | - | - | - |
| **DP** | 顯示管線解耦（Screen / Frame / Exporter、多螢幕、per-binding 輸入） | o | - | o | - | - | o | o | o | - | - | - | - | - | - |
| **H** | VNC 硬體 H.264（RFB encoding 50 + `DVH1`） | o | - | o | - | - | - | o | o | - | - | - | o | - | - |
| **G4** | GPU 排程（cpuset / RT，**依賴 C**） | - | - | o | - | - | - | o | - | - | - | - | - | - | - |
| **G5** | zink 與 wsi 共用修正 | - | - | - | - | - | - | - | - | - | - | o | - | - | - |
| **D** | drm2kgsl 路線 | o | - | o | - | - | o | o | - | - | o | o | - | - | - |
| **X1** | gfxstream 路線接線⁴ | o | - | o | - | - | o | o | - | - | - | o | - | - | - |
| **X2** | fd 外部記憶體模式 + HMI HAL（取代舊 AHB 適配） | - | - | - | - | - | - | - | - | o | - | - | - | - | - |
| **X3** | host-visible 後端與 ring blob 池 | - | - | - | - | - | - | o | - | o | - | - | - | - | - |
| **X4** | Vulkan decoder 強化與生命週期 | - | - | - | - | - | - | - | - | o | - | - | - | - | - |
| **X5** | ASG 傳輸（consumer / framing / seqno） | - | - | - | - | - | - | - | - | o | - | o | - | - | - |
| **X6** | guest blob 匯入與 teardown | - | - | - | - | - | - | - | - | o | - | - | - | - | - |
| **X7** | cereal 相容閘（建置期腳本） | - | - | - | - | - | - | - | - | o | - | - | - | - | - |
| **X8** | guest ICD 擴充與配置 | - | - | - | - | - | - | - | - | - | - | o | - | - | - |
| **X9** | gfxstream 診斷（建議丟） | - | - | - | - | - | - | - | - | o | - | o | - | - | - |
| **X10** | 臨時壓抑（modifier 隱藏、`GFXSTREAM_NO_CB_EXPORT`） | - | - | - | - | - | - | - | - | o | - | - | - | - | - |
| **V** | venus 路線 | o | - | o | - | - | o | o | - | - | o | o | - | - | - |

¹ edk2 保持 BSD-2-Clause-Patent，唯一不轉 GPL
² SMBIOS 身分、pflash、ACPI 電源、致命訊號、IRQ 衝突、kvcalloc >2GB、per-VM 環境變數、game mode
³ host_share 模組、runtime SHARE/UNSHARE、VmAccept::Sync、`/dev/gh_pinprobe`、liveness GC、pin 釋放
⁴ capset / context-types / `GFXSTREAM_*` env / pool 節點名 / UI / 啟動器

## 3. 排序限制與強綁定

1. **G4 必須排在 C 之後。** `--gpu-cgroup-path` 由 lateautumn233 的 vCPU affinity commit 引進，G4 的 RT 開關又 gate
   在 cpuset 存在上。反序會產生編不起來的樹。
2. **H 是一個七函式 C ABI**：`android_h264_enc_{create,destroy,request_sync_frame,encode_frame,poll_output,codec_config,frame_counts}`
   加 `media_codec_abi.h`。crosvm 宣告 `extern "C"`、virt 提供實作。兩邊必須同時上。
3. **X3 是第二個跨 repo ABI**：`stream_renderer_handle` 欄位、`STREAM_HANDLE_TYPE_MEM_POOL`、init params 2048/2049。
   gfxs 與 crosvm 各寫一半，FFI struct 大小必須一致。
4. **G2a/G2b/G2c 在 app、gmod、crosvm 三欄同時亮**：同一機制在三層各改一次（UI 傳參 → guest 驅動 → VMM）。
   三個 repo 的相對順序要一致，否則中間狀態的 guest 會拿到 host 還不認得的 wire。
5. **X1（app 端去掉 virgl2）↔ crosvm 的 vrend 保持初始化**：只上 app 那半，每台 drm2kgsl/venus VM 都沒畫面。
6. **MED 是配對佔位**：app 半邊只有設定 schema 與權限，crosvm 半邊只有 `android_camera` 相機後端，
   virtio-media 裝置三個都沒寫。app 半邊單獨上線會是死 UI。
7. **A（音訊）的 crosvm 半邊未完成**：protected VM 下 virtio-snd 仍無法 activate，根因在
   `devices/src/virtio/vhost/user/device/snd.rs:95` 寫死 `ProtectionType::Unprotected` 導致不提供
   `VIRTIO_F_ACCESS_PLATFORM`。app 與 win 半邊已完整。

## 4. 扁平時不該出現的東西

- **`external_scanout` 仲裁**：08-20 加入，`b3fe7cf5e` 被新的 Screen 模型整個刪除。加了又刪，淨零。
- **DVH2 第二 TCP 埠 side channel**（`h264-port=`）：`e15b27a0a`+`77c685775` 加入，`038abbaa3`+`6a35ebf8b` 端到端刪除。
- **gfxstream `188286372` ↔ `f5b4557e2`**：一對字面 revert，`git diff` 為空。
- **gfxstream seqno ladder 的自我抵銷**：`3bcb7b855`（加回第二三階）↔ `a2fa1750c`（拿掉 futex 階），
  兩者淨值 +31 行卻花了 875 行 churn。四個 commit 應併成一個。
- **mesa `c08fd270f69` ↔ `6634f48977c`**：extension 隱藏加了又拿掉。這個是**真正的上游取代**——
  新 gfxstream host base 212 個 pNext struct 全部能解，經 `check-cereal-compat.py` 驗證。
- **mesa `8c7d7ccc8ed` → revert → reapply**：那兩個 revert 是 A/B 量測不是否決，淨狀態是「已套用」。

## 5. 署名

- **gfxstream 換基準時掉了 lateautumn233 的署名。** 08-21 分支是從 `aosp/emu-main-dev` **全新建立**（不是 rebase），
  103 個舊 commit 手工重寫成 25 個，他的 12 個 commit 一個都沒帶過來，60 個 commit 沒有任何
  `Co-authored-by: lateautumn233`。其中 10 個是設計取代（`ff1557881` 改用 fd/dma-buf 取代整條 AHB 路線）合理消失，
  但 **`402ea1771`（lazy mLinear）與 `7bccebab2`（memoryTypeBits + Vk13Features）是他的碼被重寫**，這兩列要補署名。
  舊分支保留在 `backup/pre-upstream-20260821`。
- **`win` 的 `rdmapool/` 基礎 commit `3b005d67` 作者是 `sunflower2333`**，不是 HuJK。
- app 的 lateautumn233 commit 5 個：guest memory allocation options（G2b）、環境變數（M4）、
  zstd worker count（M3）、DisplayChromeController tests（M2）、vCPU affinity picker（C）。
- crosvm `d9000bb43` 作者 `Your Name <you@example.com>` 是本機早期未設 identity 的產物，是 HuJK 自己的。

## 6. 換基準帶來的反向問題

新的 gfxstream 上游不是「我們的補丁縮水」，而是**重新移植時默默掉了行為，後面得補回來**：

- `7104586b3`：上游把寫死常數改成 `VulkanMaxSafeHeapSize` 且預設不設，重新移植繼承新預設值卻沒注意行為變了。
- `1f6560815`：上游 `74f179774` 讓 `ExportBlob` 能回答 non-blob COLOR_BUFFER，**但 crosvm 沒有對應的 rutabaga 半邊**，
  等於這個上游改動只套用了一半——目前是黑畫面/色彩交換的活嫌疑犯。

## 7. 無家可歸的產物

- `crosvm_build/external/aaudiotone/`（08-23）：AAudio 測音程式，在被 gitignore 的 `crosvm_build/` 裡，
  不是自己的 git repo，也不在 manifest 裡。
- DroidVM `app/src/main/assets/prebuilts` submodule 髒了但指標沒動：本機重編的 crosvm payload 沒推回
  Droid-VM/DroidVM-Prebuilts。表上的 prebuilts 指標 bump（`3b1072d`、`32e2cb3`）在扁平後是噪音，
  除非 prebuilts repo 自己有一列。
- meta 的 `CLAUDE.md`（空）與 `info.txt`（手機 IP/adb 埠）看起來是本機筆記。

## 8. 待決

1. **X9 / meta 的 evidence pack / virgl D5 等診斷列要不要整包丟。** 全丟大約再少 15–20 個 commit。
2. **X10 兩個臨時壓抑**（commit body 自述「保持獨立以便隨時拿掉」）在 PR 前該不該先解決掉。
3. **mesa 的 6 個 Blumenkrantz upstream cherry-pick**：rebase 到 main 後原版已在 base 裡，實測會靜默重複插入
   （`zink_context.c` 的 partial-resolve 區塊出現兩次且無衝突警告），所以必須**明確 drop**，不能靠 patch-id 偵測。
4. **`win` 的 base 要在 `dev/viosnd-endpoint-per-stream` 合併前釘住。**
5. **Claude-Session trailer** 全部拿掉；HuJK 三種 email（`gh@hujk.oeg` / `gh@hujk.org` / `s920361@gmail.com`）統一。
6. **PR 目標分支名**：org 預設是 `wip-3d-accel`（連字號）。meta / hmod / gmod 整個 repo 都是 3d-accel 工作，
   建議 `pr/3d-accel` 直接以新歷史取代。

---

`plans/pr-flatten/*.md` 是 08-17/08-18 產出的逐 commit 明細（hunk 歸屬、coverage check）。
**那些檔案只涵蓋 08-18 之前的範圍**，本文第 1、2 節的表才是最新決定。
