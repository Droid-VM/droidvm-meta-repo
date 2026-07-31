# 動態池:宣告整段、開機只 share 一部分、其餘由 guest 請求

狀態:地基已實測(crosvm `188e44c78`),實作中。2026-07-31。

## 0. 這份 plan 的地基是量出來的,不是推論的

兩個 env-gated 鉤子(`DROIDVM_POOL_PREALLOC_MB` / `DROIDVM_POOL_GROW_TEST`)在真機上證實:

| # | 問題 | 結果 |
|---|---|---|
| 1 | RM 容不容忍「只 SHARE 一部分」的池 region | ✅ VM 開機正常,客體 DT 看到**完整**窗口,無 RM 錯誤 |
| 2 | runtime share + guest accept 能否落進未 backing 的洞 | ✅ `gpa=0x194000000` 成功 |
| 3 | grant 後的記憶體真的能用嗎 | ✅ /dev/mem 寫標記讀回一致 |
| 4 | 碰到「已宣告未 grant」會怎樣 | **不對稱,見 §6** |

先前靜態閱讀 RM 源碼預測「必須先祝福」「碰到會是不可恢復的 hyp fault」,**兩條都被實測推翻**。

### 為什麼 `ram_top` 的陷阱沒有發生

因為 region 是照**完整窗口**建立的(memfd 稀疏 → 只花 host VA,不花 host RAM),
只有開機的 share 被截斷。`region.size` 仍是完整窗口 → 餵進 `ram_top` → `size_max` 正確
→ RM 的 `vm_address_range_untag_above_mem_base()` untag 整個窗口。

**設計的關鍵一句話:先建滿尺寸 region、再只 share 一部分。**
不是「建小 region、之後擴充」——那條才會撞上 `RM_ERROR_MEM_INVALID (0xa)`。

---

## 1. 參數

`MemoryRegionOptions` 加兩個欄位,其餘不動:

```rust
/// 開機時 SHARE 的長度。== size 表示全預配。
pub pre_alloc_size: u64,
/// 成長粒度。**0 表示這個池不啟用 runtime-share,全部走開機前 share**。
/// 非 0 時必須 >= 2MiB 且為 2 的冪。
pub step_size: u64,
```

`step_size == 0` 是三個既有池的狀態,行為與今天**逐位元相同**(`pre_alloc_size == size`
→ 走 `share_chunks` 涵蓋整個 region 那條,一模一樣的程式碼路徑)。

約束(在 config parse 時擋掉,不要讓它跑到客體才炸):

- `step_size != 0` → 必須 `>= 2MiB`(folio)且 `is_power_of_two()`(`drm_buddy` 否則 `-EINVAL`)
- `pre_alloc_size <= size`,且兩者都對齊 `step_size`(當 `step_size != 0`)
- `step_size == 0` → 強制 `pre_alloc_size == size`

---

## 2. Host 端的池登記表

runtime-share 目前**完全無狀態**:回收的 label 是 `gpa >> 12` 算出來的,不是查表得到的
(`hypervisor/src/gunyah/mod.rs:948`)。所以「這個 GPA 現在有沒有東西」是 crosvm 今天問不出來的問題。

動態池必須補上這張表,而且它一次解決三件事:

1. **label 撞號**:同一 GPA 被 share 兩次 → `unshare_blob(label)` 收掉錯的那個
2. **請求驗證**(§3)
3. **能否安全釋放**:host 是唯一知道「這段還有沒有 udmabuf / GPU 映射掛著」的一方

```rust
struct PoolState {
    base: GuestAddress,
    size: u64,
    pre_alloc: u64,
    step: u64,
    /// step 為單位的 bitmap:第 i 位 = [base + pre_alloc + i*step, +step) 已 grant
    granted: BitVec,
    /// 每個 live grant 的 RM handle,用來 unshare
    handles: BTreeMap<u64 /*offset*/, u32>,
}
```

---

## 3. 請求驗證(host 端)

**方向由佇列決定,不是由欄位旗標決定** —— 請求從 guest→host 的新佇列進來,host 就天然知道
它是 guest 發起的,驗證掛在那條佇列的處理函式上,一處、不會漏。host 自己發起的
VkDeviceMemory share(走 BAR)完全不受影響。

收到 `REQ_SHARE{pool_id, offset, len}` 時,**全部條件都要成立**:

| 檢查 | 理由 |
|---|---|
| `pool_id` 存在且 `step != 0` | `step == 0` 的池不接受 runtime 請求 |
| `offset >= pre_alloc` | 開機前 share 的部分不歸 runtime 管(label 空間不同,見 §7) |
| `offset + len <= size` | 不能越過窗口 |
| `offset % step == 0 && len % step == 0` | 對齊池的 step |
| 該範圍**目前全部未 grant** | 防 label 撞號 |
| live grant 數 + `len/step` <= `max_grants` | memparcel 配額(§5) |

任何一條不過 → 回 `-EINVAL`,**不做任何副作用**。

`REQ_UNSHARE{pool_id, offset, len}` 額外要檢查:**該範圍沒有任何 host 端物件還掛著**
(udmabuf / GPU 映射 / scanout iovec)。這條**不能交給 guest 判斷** —— guest 的
`RESOURCE_UNREF` 是 fire-and-forget,它以為放掉了,host 那邊還握著。

---

## 4. 傳輸:擴充 `virtio-gunyah-accept`

現有兩條佇列不動(`VIRTIO_ID_GUNYAH_ACCEPT = 60`):

| 佇列 | 方向 | 現況 |
|---|---|---|
| 0 `requestq` | host → guest | `ACCEPT`(1) / `RELEASE`(2),32-byte req |
| 1 `completionq` | guest → host | 8-byte comp,`req_id` + `ret` |

新增第三條:

| 佇列 | 方向 | 新增 |
|---|---|---|
| 2 `poolq` | guest → host | `REQ_SHARE` / `REQ_UNSHARE` / `QUERY` |

comp 只有 8 bytes,塞不下 gpa/size,**所以不能借用佇列 1**;而且 `req_id` 是 host 指派的,
host 收到不認識的就丟(`gunyah_accept.rs:125`)。第三條佇列同時解決這兩件事。

```c
struct virtio_gunyah_pool_req {      /* guest -> host, 32 bytes, LE */
    __le32 req_id;      /* guest 指派,回應時原樣帶回 */
    __le32 op;          /* 1 = REQ_SHARE, 2 = REQ_UNSHARE, 3 = QUERY */
    __le32 pool_id;
    __le32 flags;       /* 保留, 0 */
    __le64 offset;      /* 相對 pool base */
    __le64 len;
};

struct virtio_gunyah_pool_resp {     /* host -> guest, 16 bytes, LE */
    __le32 req_id;
    __le32 ret;         /* 0 或負 errno */
    __le64 granted;     /* QUERY: live grant 的 bitmap 前 64 格;其餘 op: 實際處理長度 */
};
```

`REQ_SHARE` 的往返:

```
guest → poolq   : REQ_SHARE{pool_id, offset, len}
host            : 驗證(§3) → 配置 → runtime_share      ← 既有
host → requestq : ACCEPT{req_id, handle, gpa, size}     ← 既有,不動
guest           : gh_rm_mem_accept                      ← 既有,不動
guest → compq   : COMP{req_id, ret}                     ← 既有,不動
host → poolq    : RESP{req_id, ret}
```

**ACCEPT 已經把 gpa 告訴 guest 了**,所以 guest 在 accept 當下就知道拿到哪一段;
`RESP` 只是結案通知。新增的線格式只有 poolq 的兩個 struct。

`REQ_UNSHARE` 對稱:`REQ_UNSHARE` → host 驗證 → `RELEASE`(既有)→ guest release
→ comp → host unshare → `RESP`。

### 死結:必須避開的

對抗性審查找到一條真死結:guest 執行緒等 poolq 回應 ← 裝置 worker 等 vm_memory handler
執行緒 ← handler 卡在 `drive_guest_accept` 等 guest 的 accept workqueue。

**解法:poolq 用自己的 worker 執行緒**,不要跟現有的單執行緒 worker 共用。
guest 端也一樣:發請求的執行緒不能是處理 `requestq` 的那條。

---

## 5. memparcel 配額 —— 決定 step 大小的硬約束

`MAX_MEMPARCEL_PER_VM = 1024`,而且:

- **未 `MEM_RECLAIM` 的 parcel 永久佔用配額**,HLOS 從不 reset —— 這就是 SIGKILL crosvm
  之後要重開機才恢復的那個資源
- **Android 自己的 parcel 吃同一份配額**

每個 grant = 一個 memparcel。所以 `step = 2MiB` 長到 2GiB 就撞頂,**整台手機**跟著死。

- `step` 預設建議 **32–64 MiB**
- `max_grants` 必須**跨池預算**,不是每池各自算
- config parse 時算出 `Σ (size - pre_alloc) / step` 並拒絕超過保守上限(建議 256)

---

## 6. 客體端的存取閘門 —— 失敗模式是不對稱的

實測(§0 第 4 項):

```
讀未 grant 位址 → 回傳零。無錯誤、無 log、VM 存活。       ← 危險
寫未 grant 位址 → page fault ... attempt: -2 → VM 死亡
主機            → 兩種情況都存活
```

**讀那條更陰險**:配置器若在 grant 之前讀,拿到零而毫無跡象。

所以:

- guest 端配置器必須**嚴格 gating**,不能靠 fault 觸發成長(沒有可恢復的 fault 可用)
- host 端的 live-grant 驗證**必須擋讀,不能只擋寫**。今天 `guest_memory.rs:528` 對
  `GpuPoolGuest` 是無條件 `Ok(())`,動態池不能照抄
- 好消息:配置器的 bug 只弄死 VM,不弄死手機

---

## 7. 開機 share 與 runtime share 的 label 空間不同

```rust
mem_node.set_prop("label", index)              // 開機 shm 節點:region index
let label = (guest_addr.offset() >> 12) as u32; // runtime:gpa >> 12
```

實務上不會撞(真實 GPA 在 GB 級,`gpa>>12` 是百萬級,region index 是個位數),但推論是:
**開機 share 的部分收不回來**,`runtime_unshare` 的 label 對不上。

這正好是想要的:pre_alloc 那段是池子的**永久地板** —— 零冷啟延遲、不可縮。
`offset >= pre_alloc` 這條驗證就是在守它。

---

## 8. Teardown

**兩個不同的事件,不要混為一談**(原設計混了,被審查抓到):

| 事件 | accepted parcel 能否回收 |
|---|---|
| **VM teardown(fd 消失)** | **可以**。`gunyah_vm_stop()` 先跑且會等,之後 `gunyah_vm_reclaim_range(0, U64_MAX)`;driver 註解:*"because the VM is not running and RM will let us reclaim all the memory"* |
| `VirtioDevice::reset()` | **不行**。VM 還在跑,已 accept 的 parcel 收不回 |

所以:

- **不要**在 `reset()` 裡收回所有 grant —— 做不到,而且會把 RM RPC 放進 vCPU 可見路徑
- `reset()` 只標記池為 dead、拒絕新請求,把 grant 清單交給背景執行緒
- 真正的回收靠 VM fd 消失,那條路 SIGKILL 也涵蓋

---

## 9. 實作階段

每一階段都能獨立驗證,前一階段不通就不進下一階段。

### 階段 1:參數落地,零行為變更

- `MemoryRegionOptions` 加 `pre_alloc_size` / `step_size`
- 三個既有池填 `pre_alloc_size = size`, `step_size = 0`
- 開機 share 改用 `pre_alloc_size`(取代 §0 的 env 鉤子)
- config parse 加 §1 的約束檢查

**驗收:五模式跑分與 2026-07-31 基準一致**(見 [[five-mode-benchmark-2026-07-31]]),
任何差異都表示遷移不是零行為變更。

### 階段 2:host 端池登記表 + 驗證

- `PoolState`(§2),在 region 建立時填好
- `REQ_*` 的驗證函式(§3),此時還沒有呼叫者
- `check_host_access` / `get_slice_at_addr` 對 `step != 0` 的池改查 grant 表

**驗收:單元測試涵蓋 §3 的每一條拒絕理由。**

### 階段 3:poolq + guest 端

- 第三條佇列、兩個 struct(§4)、獨立 worker(§4 死結)
- guest 端:`virtio_gunyah_accept` 加 poolq、對內導出 `pool_grow()/pool_shrink()`

### 階段 4:測試池 + 測試驅動

- 一個獨立的測試池(例如 `--pre-alloc test-pool-mb=256,test-pool-prealloc-mb=64,test-pool-step-mb=32`)
- 一個 guest 測試模組:sysfs 觸發 grow/shrink,寫入標記、讀回、驗證
- **必須涵蓋 §6 的兩個失敗方向**:對未 grant 位址的讀(應被 host 擋下,而不是靜默回零)
  與寫(應被擋下,而不是弄死 VM)

---

## 10. 相關

- crosvm `188e44c78` —— 地基實驗的兩個 env 鉤子,留著給後續驗證
- [[sparse-pool-runtime-grant-proven]] —— 實驗結果與踩過的坑
- `plans/POOL_RECLAIM_PLAN.md` —— 池子回收(另一件事,但共用 memparcel 配額這條約束)
