# 「管理增量分支」面板改版設計

日期：2026-09-02。狀態：已拍板，實作中。

拍板結果：1 保留三鍵、2 唯讀游標留原地、3 面板留在底下回來刷新、4 同 VM 其他列靜默跟移、5 daemon 冪等刪除、6 `-ov-yyMMdd-HHmmss`。另加 3.7 共用磁碟規則。

## 0. 現況盤點（讀碼結果）

### 元件對照

| 角色 | 檔案 | 現況重點 |
|---|---|---|
| 樹模型 | `ui/disk/tree/DiskTree.java` | 純邏輯，從 DiskStore 的 `parent` 欄位建 forest；壞連結/環會降級成 root |
| 樹畫面 | `ui/disk/tree/DiskTreeView.java` | RecyclerView；radio 單選、鎖頭(有子節點)、per-node 選單按鈕 |
| 面板 | `ui/disk/tree/DiskTreeDialog.java` | 靜態 `show()`；每個節點操作一律先 `treeDialog.dismiss()` 再做事 |
| 建增量 | `ui/disk/action/DiskOverlayCreateDialog.java` | 預設名 `-ov-yyyyMMdd-HHmm`；受影響 VM 從**已存檔**的 VMStore 掃；只有「改掛增量」有回呼給編輯器，「改為唯讀」沒有 |
| 刪/合併/攤平 | `ui/disk/action/DiskActionDialog.java` | 刪=整棵子樹；合併/攤平交給 `DiskOperationActivity` 跑 |
| 改 VM 槽位 | `ui/disk/action/DiskDependencyUpdater.java` | 以「路徑集合 → 目標路徑/null」改所有 VM 的 slot；不動 `readonly` |
| 編輯器列 | `ui/vm/edit/storage/disk/VMDiskEditAdapter.java` | `lockedPaths` 快取決定強制唯讀；`setPathAt` 用「舊路徑曾鎖定→清掉 readonly」的啟發式 |
| 刪 VM | `ui/vm/VMDeletion.java` + `daemon/ipc/vm/DeleteHandler.java` | 先 `vm_delete`，daemon 回失敗就整批 skip 並顯示「仍在使用/有相依」 |
| 在跑查詢 | `ui/vm/VmRunningQuery.java` | 只把 state==`running` 算在跑；suspended/starting/stopping 不算 |

### 三個痛點的根因

1. **同分鐘撞名**：`defaultName()` 只到分鐘；註冊表與檔案存在檢查在按 OK 之後才做，所以直接彈「已存在」。
2. **刪 VM 誤判相依**：VM 只有在第一次啟動時才會經 `vm_exists → vm_create` 進 daemon。沒開過機的 VM，`vm_delete` 在 daemon 端丟 `VM not found` → `onUnsuccessful` → `skipped.run()`，而 toast 文案把「daemon 不認識」「被別的 VM 用」「是增量基底」「rm 失敗」四種原因混成一句。開機一次後 daemon 認識了，就正常。
3. **面板一操作就關**：`showNodeMenu()` 第一行就 `dismiss()`。副作用鏈：
   - 從編輯器開面板 → 建增量：受影響 VM 是從已存檔 VMStore 掃的，編輯器裡還沒存的列看不到 → 不會問「改掛/唯讀」→ `onSwitchedToOverlay` 不會觸發 → 列仍指向基底、readonly=false、`lockedPaths` 沒重載 → 存檔後基底以可寫掛載（只剩開機前的 `guardLockedDisks` 兜底）。
   - 已存檔 VM 選「改為唯讀」：store 被改成 readonly=true，但編輯器 in-memory 列沒收到通知，之後存檔又把 false 蓋回去。
   - 從磁碟資訊頁開面板：`new DiskActionDialog(context, null, null)` 的 `onUpdate` 是 null，操作完主清單/資訊頁不刷新。
   - 刪子樹後 `redirectVmDisks` 把 slot 指到 parent，但 parent 若還有別的子節點（鎖定），slot 仍是可寫，沒補 readonly。

## 1. 檔名 suffix

- 格式改成 `<base>-ov-yyMMdd-HHmmss`（例：`disk-ov-260902-031718.qcow2`）。
- 剝舊 stamp 的 regex 同時接受新舊兩種：`-ov-(\d{8}-\d{4}|\d{6}-\d{6})$`，既有 `-ov-20260902-0317` 命名的磁碟再疊增量時不會長成兩層 stamp。
- 預設名產生時就對資料夾做 `File.exists()`，撞到就補 `-2`、`-3`（秒級之後幾乎不會用到，但零成本）。註冊表檢查維持在按 OK 時做。

## 2. 刪 VM 誤判相依

- daemon `DeleteHandler`：`vm_id` 不存在 → 視為冪等成功，回 `existed:false`。沒被 daemon 管過的 VM 不可能在跑，沒有東西要停。
- `VMDeletion.releaseDaemonAndMaybeDeleteDisks`：只有「daemon 回報停不掉」才 skip；其餘走 cleanup。
- `cleanupDisks` 結果改成分原因回報：被其他 VM 掛載 N、是增量基底 M、刪檔失敗 K；不再用一句混合文案。
- 順手：`VmRunningQuery` 改成「state != stopped 就算使用中」（suspended 的 crosvm 仍握著檔案）。

## 3. 面板不退出＋游標模型

### 3.1 名詞

- **Family**：目前磁碟所在的整棵樹（`DiskTree.buildFamily`）。
- **Cursor（游標）**：一個 VM 磁碟槽位在這棵樹上的落點。欄位：`vmId, vmName, slotIndex, nodeId(可為 null=已清空), readonly, kind`。
  - `kind = ACTIVE`：從編輯器某一列開面板，那一列就是 active，全面板只有一個。in-memory，關面板時才套回列。
  - `kind = EDITOR`：同一台 VM 編輯器裡其他還沒存檔、也指到這棵樹的列。in-memory，關面板時套回列，移動不提醒（使用者正在看這台 VM 的編輯畫面）。
  - `kind = PERSISTED`：VMStore 裡所有指到這棵樹的槽位（含正在編輯那台 VM 已存檔的版本）。移動一律**當下寫回 VMStore**，因為檔案已經沒了，不寫回就懸空；按取消離開編輯器也一樣會發生，所以動到它們**一定要提醒**。正在編輯那台 VM 的 PERSISTED 槽位例外：靜默改寫（編輯器存檔會蓋掉它，放棄編輯時它又必須是有效的）。
- **Pinned（不可移動）**：游標所屬 VM 的 daemon 狀態不是 stopped。節點上有任一 pinned 游標，該節點就是 pinned。會讓 pinned 游標移動或改寫其內容的操作一律拒絕，訊息列出 VM 名稱。
- 磁碟資訊頁進來的面板：沒有 ACTIVE/EDITOR，全部是 PERSISTED。

### 3.2 面板生命週期

1. **開啟**：`BackingChainLinker.repair` → 載入 DiskStore + VMStore → 建 family → 建游標集（PERSISTED 從 VMStore 以路徑 `findByPath` 解析；ACTIVE/EDITOR 由編輯器把 live rows 傳進來）→ 查 `vm_list` 標 pinned → 渲染。radio 初值 = ACTIVE 游標的節點。
2. **操作**：節點選單不再關面板。建增量/刪除是對話框＋非同步，完成回呼後刷新；合併/攤平交給 `DiskOperationActivity`，面板留在底下，等 activity 回來（面板 decor view 的 `onWindowFocusChanged(true)`，或改用 ActivityResultLauncher）就刷新。
3. **刷新**：重載兩個 store → 重建 family（以 ACTIVE 游標所在節點重新定根；沒有 ACTIVE 就用開面板的磁碟）→ 依 3.3 reconcile 游標 → 更新 pinned → 重畫。整棵樹都沒了就顯示空狀態，只剩「關閉/返回」，不自動關。
4. **關閉**：依 3.5 套用。

### 3.3 游標 reconcile 規則（每次刷新後對每個游標跑一次，純邏輯，可單元測試）

1. 節點還在 → 不動。（攤平、合併別的兄弟、在已有子節點的節點下再建增量，都落在這條。）
2. 節點不見了 → 沿**舊樹**的祖先鏈往上找第一個還在的節點，移過去。（刪子樹 → parent；合併 n 進 p → p。）都不在 → 清空。
3. 建增量特例：在節點 n 下建增量，且 n 原本沒有子節點，則 n 上的**可寫**游標移到新子節點；唯讀游標留在原地（基底鎖定對它沒影響）。n 原本就有子節點則不動。
4. 移動落點若有子節點（鎖定）→ 該游標 `readonly` 強制為 true；落點是葉子 → 保留原 readonly。
5. 共用磁碟（3.7）：reconcile 後同一節點上有兩個以上非 SHADOW 游標 → 全部強制 readonly。含「原本在不同子樹、刪掉後一起往上到同一個 parent」的情形。

心智模型：葉子=可寫；有子樹=強制唯讀；你正在用的那個節點長出第一個子節點時，你會跟著到子節點繼續可寫；已經是基底的節點再多一個子節點什麼都不變。

### 3.4 各操作的前置檢查與單一確認框

所有檢查在 pool 執行緒算完，產出一份 **Plan**（要刪的磁碟、每個游標的 from→to、readonly 變化），然後只彈**一個**確認框，內容照 plan 列出：「VM `X` 的磁碟 #2：`a.qcow2` → `b.qcow2`（改為唯讀）」。ACTIVE/EDITOR 游標的移動不列。

| 操作 | 拒絕條件 | Plan |
|---|---|---|
| 建增量於 n | n 上有 pinned 且可寫的游標 | 規則 3；PERSISTED 可寫游標沿用現有「改掛增量／改為唯讀」三鍵，只是文案列出 VM＋槽位 |
| 刪 n（子樹 S） | S 內任一節點 pinned | S 內游標 → parent(n) 或清空；清空的 PERSISTED 槽位移除（現有行為）；ACTIVE/EDITOR 清空的列在關面板時移除 |
| 合併 n → p | n 有兄弟（現有）；family 內任一 pinned（現有：全家 VM 要關） | n 上游標 → p；p 上游標不動但列「內容將被改寫」；n 的子節點改接 p（現有） |
| 攤平 n | n pinned（現有） | 游標不動；n 變成獨立 root，面板依 ACTIVE 游標重新定根 |

### 3.5 關閉時的套用

- **編輯器入口**
  - 「確定」：active 列 ← radio 目前選的節點；其他 EDITOR 列 ← 各自游標。
  - 「返回」（系統返回鍵／toolbar）或「關閉」：active 列 ← ACTIVE 游標；其他 EDITOR 列 ← 各自游標。
  - 游標已清空 → `removeItem` 把該列刪掉，避免懸空。
  - 套用後 `reloadLockedPaths` → 全部列重綁，強制唯讀重新推導。
- **磁碟資訊頁入口**：「關閉」與「返回」同義。資訊頁的主角磁碟若已不存在，關面板同時 `finish()` 資訊頁並刷新清單。
- **磁碟清單長按直接操作**：沒有面板，Plan＋確認框＋套用當下就跑（現有流程升級為同一套 Plan，多的是 VM 槽位列表與 readonly 補正）。

### 3.6 編輯器列的 readonly 兩層化

把「使用者自己勾的」和「因為有子樹被強制的」分開：`readonlyUser`（持久欄位 `readonly`）與 `readonlyForced`（每次 bind 由 `lockedPaths` 推導，不持久化）。開關顯示 `forced || user`，`forced` 時 disable；存檔寫 `forced || user`。這樣可以拿掉 `setPathAt` 裡「舊路徑曾鎖定就清掉 readonly」的啟發式，也讓「沒有觸發改 readonly 事件」這類問題在關面板後一次由重綁解決。

### 3.7 共用磁碟強制唯讀

同一個磁碟被兩個以上游標指到（兩台 VM、或同一台 VM 的兩個槽位）就全部強制唯讀，兩個寫入者會互相毀掉 qcow2。三個地方同一條規則 `forced = hasChildren(node) || cursorsOn(node) >= 2`：

- **Plan**（面板操作、清單長按）：reconcile 後套用；PERSISTED 游標寫回時帶 readonly=true 並列在確認框；ACTIVE/EDITOR 關面板時由編輯器重綁強制。
- **編輯器**：鎖定資訊從「有子節點的路徑」擴成「有子節點的路徑 ∪ 其他 VM 掛載的路徑（排除正在編輯那台的已存檔槽位）」，再加同一編輯器裡其他列相同路徑。
- **開機前守衛**（`VMActions.guardLockedParents`）：可寫槽位的路徑若也被別台 VM 掛載 → 與基底鎖定同一個「改唯讀並啟動？」提示。另一台 VM 已存檔的可寫槽位不在編輯時改動，等它開機時由守衛處理。

強制只會把 readonly 加上去，不會自動拿掉；鎖定解除後使用者可以自己關掉。

## 4. 實作對照（2026-09-02）

純邏輯（JVM 單元測試 `CursorPlanTest`、`DiskDependencyUpdaterTest`）：
- `ui/disk/tree/TreeShape.java`：註冊表 parent 連結快照；`without / withMerged / withChild / withDetached` 產生操作後的預測形狀。
- `ui/disk/tree/AttachmentCursor.java`：游標（kind = ACTIVE / EDITOR / SHADOW / PERSISTED、pinned）。
- `ui/disk/tree/CursorPlan.java`：`reconcile(moving, fixed, before, after)`，規則 1–5；`refused` 非空即拒絕。
- `ui/disk/tree/AttachmentCursors.java`：從兩個 store（＋編輯器 live rows）收集游標。

Android 端：
- `ui/disk/tree/DiskBranchPanel.java`（取代 `DiskTreeDialog`）：面板不關；刷新＝重載 store → reconcile live 游標 → 以 ACTIVE 重新定根；merge/flatten 回來時靠 window focus 刷新；關閉回傳 `Result{confirmed, rows, subjectGone}`。
- `ui/disk/tree/DiskTreeView.java`：`updateRoots`（保留摺疊）、`setCursorLabels`（「掛載：vm (#n)」）、`setCurrentId/ setSelectedId`。
- `ui/disk/tree/CursorPlanText.java`：確認框文案。
- `ui/disk/action/DiskActionDialog.java`：`confirmDelete / tryMerge(config, live, onConfirmed)`、`tryFlatten(config, onConfirmed)`；`Family` 一次載入 store＋游標＋in-use。
- `ui/disk/action/DiskOverlayCreateDialog.java`：`-ov-yyMMdd-HHmmss`＋`-N` 碰撞遞增；受影響槽位改由 Plan 決定；三鍵保留（「改為唯讀」= announced 游標留原地 readonly=true）。
- `ui/disk/action/DiskDependencyUpdater.java`：`applyPlan(context, plan)`，依 (vmId, slot) 寫回，路徑不符就跳過，readonly 只加不減。
- `ui/disk/operation/DiskOperationActivity.finishCommit`：改走 Plan。
- `ui/vm/edit/storage/disk/VMDiskEditAdapter.java`：`userReadonly`（identity map）＋ forced（基底 ∪ 其他 VM 掛載 ∪ 同編輯器其他列）；`commitReadonly()` 存檔前重算；面板關閉 `applyPanelResult`。
- `ui/vm/edit/storage/VMEditStorageTab.java`：`setEditingVm`、存檔前 `commitReadonly`。
- `ui/vm/VMActions.guardLockedParents`：加共用磁碟檢查。
- `ui/vm/VMDeletion.java` + `daemon/ipc/vm/DeleteHandler.java`：冪等刪除；結果分四種原因。
- `ui/vm/VmRunningQuery.inUseAmong`：非 stopped 即使用中。
- `ui/disk/info/info/DiskInfoInfoTab.java`：接面板；主角磁碟消失就 finish。
- strings（en / zh-rTW / zh-rCN）：新增 `disk_tree_change_*`、`disk_tree_pinned`、`disk_tree_attached_by`、`disk_tree_in_use`、`disk_tree_empty`、`disk_manage_branches_back`、`edit_vm_disk_shared_readonly`、`vm_shared_disk_*`；`vm_delete_disks_result` 改四參數；移除 `disk_tree_attachment_*`。

## 4.1 實機驗收（2026-09-02，PLK110 / 10.53.12.1:5566，r324 debug）

夾具：`/storage/emulated/0/DroidVM/bt/` 下 64M 的 bt-base / bt-other，VM bt-vm1（掛 bt-base rw）、bt-vm2（掛 bt-other rw），皆直接寫進 json、從未開機。操作用 uiautomator dump + 依文字點擊；狀態用 root 讀 disks.json / vms.json。

| # | 情境 | 結果 |
|---|---|---|
| 1 | 預設名格式 | `bt-base-ov-260902-042202`（yyMMdd-HHmmss）✅；同秒碰撞未實測（`-N` 遞增只靠程式碼） |
| 2 | 從未開機的 bt-vm2 刪 VM 勾刪磁碟 | toast「已刪除 1 個磁碟檔案；保留 0…」，檔案與註冊表都清掉 ✅ |
| 3 | 編輯頁面板建增量 → 返回 | 面板不關、子節點標「目前掛載」、shadow 槽位靜默改掛；返回後列=子節點、可寫 ✅；再開選基底按確定 → 列=基底、強制唯讀 ✅ |
| 4 | 面板刪子樹 / 刪整樹 | 確認框列出「bt-vm2 磁碟 #1：… → bt-base」；刪整樹列出「將從該虛擬機器移除」；空狀態；返回後列被移除、bt-vm2 槽位移除 ✅ |
| 5 | 共用磁碟 | bt-vm1 選 bt-vm2 掛的葉子 → 強制唯讀 ✅（toast 文字沒截到，鎖定判定正確） |
| 6 | bt-vm1 執行中 | 清單長按刪 bt-base → 「尚未關機…bt-vm1」拒絕 ✅；建增量 → 「正在使用基底磁碟」拒絕 ✅ |
| 7 | 資訊頁面板刪主角 | 第一版資訊頁在面板還開著時就自動關（onRegistryChanged 觸發 finish）→ 改成只在關閉時 finish；重建後重驗：面板留在空狀態，按關閉才退出資訊頁 ✅ |
| 8 | 面板合併 | 三鍵選「改掛增量」後 bt-vm1 → 子節點；合併回來面板自動刷新、子節點消失、bt-vm1 → 基底 rw ✅ |

發現並修正的 bug：`VMDiskEditAdapter.onBindViewHolder` 的 `setChecked` 會觸發上一次 bind 留下的 listener，把強制值記成使用者選擇（換回自由葉子後仍是唯讀）；修法=bind 前先 `setOnCheckedChangeListener(null)`；重建後重驗通過（選回自由葉子時開關恢復可寫）。

## 5. 拍板紀錄（已決）

1. 建增量時，PERSISTED 可寫游標保留「改掛增量／改為唯讀」的選擇（建議保留），還是一律改掛只提醒？
2. 唯讀游標在建增量時留在原地（建議），還是也跟去子節點？
3. 合併/攤平期間面板留在 `DiskOperationActivity` 底下、回來刷新（建議），還是維持現在關掉？
4. 同一台 VM 編輯器裡非 active 的列：靜默跟著移（建議），還是也提醒？
5. 痛點 2 修在 daemon（冪等刪除，建議）還是只在 app 端先問 `vm_exists`？
6. suffix 確認為 `-ov-yyMMdd-HHmmss`（你寫的 `260912` 我理解為 yyMMdd）。

## 6. 追加（2026-09-02 下午）

1. **新增磁碟成功自動退出**：`DiskCreateActivity` 帶 `EXTRA_AUTOFINISH`，`DiskOperationActivity` 成功即 `finish()`，失敗仍停在錯誤畫面。實測從 VM 列建 1 GiB qcow2，1 秒內回到編輯頁、列已填好路徑 ✅
2. **面板 radio 跟隨 active**：`DiskBranchPanel.render` 記 `lastActiveNode`，radio 若還在上一次的 active 節點就跟著移，否則不動。實測：radio 在 active 上建增量 → 跟到子節點；radio 移到基底再建 → 留在基底 ✅
3. **長按拖拽排序**：`CardItemListView` 新增 `app:reorderable` 屬性（storage 的磁碟／共享目錄、network 的網卡開啟），`ItemTouchHelper` 長按抬起、放下後 `notifyDataSetChanged`；`CardItemAdapter.moveItem` + `onItemMoved` hook。磁碟排序會通知啟動分頁 `VMEditBootTab.onDiskMoved` 讓「掃描磁碟索引」跟著同一顆磁碟。實測磁碟 [0→2]、網卡 [0→1] 存檔順序正確，image.disk 由 1 變 0 仍指同一顆 ✅。注意：陣列順序＝crosvm 參數順序＝客體 vda/vdb、eth0/eth1。

## 7. 追加（首頁與文案）

1. **首頁「建立嚮導」**：原本 toast「功能未實現」，改開與 VM 頁 + 相同的選單（Linux VM / Windows VM / 從 .vmpkg 匯入 / 自訂）。選單抽成 `ui/vm/VMCreateMenu.show(context)`，`MainVMFragment.onFabClick` 與 `MainHomeFragment.openWizard` 共用。實機點卡片看到四個選項 ✅
2. **VPU 與相機文案**：`create_vm_vpu_note`（圖形分頁）與 `edit_vm_peripheral_unavailable`（外設卡片，相機類型顯示）三語系改成「功能待實現」措辭。圖形分頁與外設頁的相機卡片實機都看到新文案 ✅

## 8. 追加：大頁預檢多算 guest pool（5568 的 5 GB VM 被說要 6 GB）

根因：daemon（`CrosvmBackendInstance`）在 host 看得到客體 RAM 的兩種模式（protected_normal、pseudo_unprotected）會把 `gpu_guest_pool_mb` 歸零不傳；`PoolPreflight.neededPages` 沒套同一條規則，仍加 1024 → 5120+1024=6144。另一處漂移：gfxstream 的 udmabuf 預設 daemon=true、預檢=false。

修法：新增 `lib/store/vm/GuestPoolSizing`（`hostVisibleRam / bootGuestPoolMb / bootGuestPreallocMb`），daemon 三條路線與預檢都改呼叫它。單元測試 `PoolPreflightTest` 6 例（pseudo_unprotected=5120、protected=6144、gfxstream udmabuf 開關、無 GPU、prealloc 512）。

部署注意：預檢在 app 程序跑（前景啟動），裝 APK 即生效；daemon 的 `waitForPool`（背景/自動啟動）同一段碼，要重啟 daemon 才換新。5568 當時有 VM 在跑，未主動安裝。

## 9. 追加：清空增量（reset overlay）

qemu-img 沒有「丟棄增量內容」的指令，做法是重建：在旁邊 `qemu-img create` 一個同 backing、同虛擬大小、同 cluster_size / compression_type 的空 header 檔（`<path>.reset.tmp`），再 rename 蓋回原路徑（原子交換，失敗時原檔不動）。路徑不變所以 VM 槽位與註冊表都不用動，確認框只列「內容將被改寫為基底目前狀態」。

限制：只有可寫葉子可做（有 parent、無 child）；加密磁碟拒絕（沒金鑰重建不了）；掛著它的 VM 必須停止（pinned 游標拒絕）。

入口：面板節點選單、磁碟清單長按（overlay 選單）、資訊頁併入「管理增量分支」。`DiskActionDialog.tryReset(config, live, onConfirmed)`。非葉子（根或有子節點）不顯示這個選項而不是按了才拒絕：面板用 `MaterialMenu.setItemVisible`，清單走 `MainListFragment.onPrepareItemMenu` hook（MainDiskFragment 覆寫）；tryReset 內的檢查保留作防呆。

實機（5566）：4.3 MB 髒增量 rs-ov → 清空後 196616 bytes，backing / virtual size 不變，rs-vm 槽位不動，面板不關 ✅；根節點與有子節點的節點被拒絕 ✅。
