# App 與系統（IPA 安裝器、UniXNUSetting）

TODO 2（iPadOS 內的 IPA 安裝器與 UniXNUSetting）的完整內容，從 `PROGRESS.md`「7. 下一步」移來（原文照錄）。

## 10-28 TODO 2 IPA 安裝器與 UniXNUSetting

**iPadOS 內的 IPA 安裝器 / UniXNUSetting（進行中）。** 見最上面「TODO 2 續報」：runtime 信任快取已證實可行、entitlement 可任意授予。配對先擱著。範圍與動工順序：

- **(1) shell 環境（先做）＝ 4 個工具，全部簽上 entitlement 全集 + owner-trust，每個 applet/行程都帶滿權限**（AMFI 對 cdhash-trusted binary 授予任意 entitlement，已驗）：
  **applebox**（單一 multicall：Apple OSS `_cmds`（file/text/shell/adv/network…）+ toybox 補缺口（xz/timeout/od…）+ zsh，用 `ld -r` + exported-symbols-list 併一顆）、**dropbear**（ssh，login shell exec applebox-zsh → 滿權限 zsh）、**debugutil**（原 gfxprobe）、**libimobiledevice**（備著，待配對通了才用）。entsh 暫不做（這幾顆滿權限的就是它）。
  `build-applebox.py`：table-driven、per-tool `-Dmain=<t>_main` + `ld -r` localize + 聚合一個 `applebox.json` trust。研究報告見 scratchpad `applebox-research.md`。
  待辦子項：entitlement 全集要盤一份 curated 清單（多數 boolean、少數陣列值如 iokit-user-client-class/finegrained-*；逐步加、個別 restricted AMFI 可能拒要一加一驗）；terminfo db 要一起 stage（less/vim/top/zsh 互動要）；scp/sftp 用 OpenSSH sftp-server。
  **entitlement 全集 → 日後搬進 kernel（`cap.sys_admin` 計畫）**：現在「簽滿」是為了快速把全集盤穩；穩了之後定義一個自定義 entitlement **`cap.sys_admin`**（非 apple 前綴，不受 AMFI restriction 檢查，就是個 dict key），工具只簽它，**patch AMFI 在 exec 附掛 entitlement 時、看到 `cap.sys_admin` 就注入 kernel 內 curate 的全集 dictionary**。這個附掛點**一處同蓋 kernel 端（`IOTaskHasEntitlement`／sandbox／MACF）與 userspace （`SecTask`/`csops` → lockdownd 等）**，因兩層都讀 task 附掛的 entitlements；value 型 entitlement（finegrained-*、iokit-user-client-class）要給值/萬用。`cap.*` 命名留擴充空間（日後 `cap.net_admin`、`cap.pairing`… 各映射 entitlement 子集，做成 capability 風格）。取捨：改全集內容「簽滿」是 re-sign（輕）、`cap.sys_admin` 要重建 kernel（重），所以迭代用前者、穩定用後者。
- **(2) trust-cache user client（唯一要改 kernel 的一塊）**：讓 userspace 呼叫已驗證的 `load_legacy_trust_cache`（owner-gated）。+ 機內 cdhash 抽取 → **普通 IPA 安裝端到端**（抽 cdhash → runtime 信任 → staged + LaunchServices 登記 → 上主畫面；移除走 SpringBoard 長按）。
- **(3) 持久化 trust 清單**：裝好的 cdhash 存到 Data；**開機早期由 kernel（`DroidVMTrustCache.c`）在 Data 掛上時直接讀已存清單重載**（不經 ownervisor 服務——見上方 10-28 下午續報的決定；撐過重開機、不用主機、不重建 kernel）。+ **特權 IPA 安裝/移除**（同 (2) + 全集只簽在 helper；移除：刪 bundle + 從清單移除）。
- **(4) serial-shell 服務**（zsh 掛到指定 serial，getty 式）+ **ownervisor `protected` 旗標**（ssh、serial-shell 可停不可刪）+ **服務管理**（新增/刪除/列表/狀態，GUI 由 (5) 經 app socket 交 ownervisor 執行）。
- **(5) UniXNUSetting＝ownervisor 的 in-app GUI（10-28 晚修訂，取代「特權 app」與更早的「GUI＋unixnusettingd」）**：staged 系統 app（唯讀 os.img、不可刪）、以 mobile 跑、不簽大 entitlement；要 root 的操作經 app 專用 socket 交 ownervisor 執行，ownervisor 以對端 cdhash 只認 payload 內建的 UniXNUSetting，擋未經授權的第三方 app；debug 工具目錄 root-only。細節 `plans/UNIXNUSETTING.md` §3.1。
- **配對（獨立 track，擱置）**：USB-mux 模擬 / 無線（設密碼）/ 直接寫 `/var/db/lockdown` 的 pair record（吃 kernel 控制，待逆向格式）。
