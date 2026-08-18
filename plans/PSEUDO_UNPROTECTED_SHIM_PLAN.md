# pseudo-unprotected VM:crosvm 新模式 + 開機 shim

2026-08-18。草案,尚未實作。承接同事 `Droid-VM/crosvm@unprotected` / `edk2-gunyah@unprotected`
的發現(runtime `MEM_SHARE` 帶 X 的 parcel,guest `MEM_ACCEPT` 後 Stage-2 是 RWX 且 host 可見),
把「整段 system RAM 走這條路」做成 crosvm 的一種 protection type,對 kernel 直開 / EDK2 / Windows 一視同仁。

---

## 0. 一句話

```
[LEND'd 小 boot region: shim @+0, DTB @+2M]  [SHARE'd RWX 視窗 = 真正的 guest RAM(kernel/EDK2 也放這裡)]  [pools]  [MMIO]
        ^ RM 只認得這一塊                          ^ 開機時無 Stage-2;shim 用 RM RPC accept 進來
```

shim 是唯一在 guest 端做事的人:accept 視窗 → 把 `/memory` 改成視窗 → `x0=DTB` 跳到 payload。
沒有 jmp 回來、沒有改 payload 開頭、沒有 swiotlb、沒有 RDMA0000。

---

## 1. 依據(哪些是查到的、哪些要量)

| # | 事實 | 來源 | 狀態 |
|---|---|---|---|
| F1 | RM 不檢查 `/memory reg`,VM_START 會用它認得的 parcel/demand-paged range 重寫 | RM `vm_config_parser.c:2377`, `vm_creation.c:1329` | 開源碼;裝置上以 shim 重寫為準,不依賴 |
| F2 | `/reserved-memory` 帶 `reg` 的子節點必須精確對到一顆已 accept 的 parcel,否則 DENIED | RM `vm_creation.c:1507-1545, 1674-1677`;8gen3 實測 ENODEV(crosvm `mod.rs:540-560`、lowmem fence 註解) | 8gen3 已證;8e/8e5 較寬 |
| F3 | RM 對 SHARE 沒有「不能 X」規則;accept 方權限 = 建立者 ACL;`MAP_OTHER` DENIED(host 不能代 accept) | RM `memparcel.c:666-757, 387-401, 2061` | 開源碼 |
| F4 | GKI 6.6 driver 把 SHARE binding 一律映成 R/RW;host_share 模組走 RM parcel 路徑,ACL X 會過 SCM assign | GKI `vm_mgr_mem.c:155-162`, `gunyah_qcom.c:15-45`;host_share `gunyah_share_mod.c:365-449` | 6.6 已證(同事);**8gen3 待驗(E1)** |
| F5 | PC = base-address(6.1);6.6 由 crosvm `SET_BOOT_CONTEXT` 指到 payload。x0 = DTB。DTB 必須在 image parcel 內 | RM `vm_firmware.c:765`;GKI `vm_mgr.c:717-722, 763-770`;crosvm `gunyah/aarch64.rs:296-350` | 已證 |
| F6 | GH_VM_START 之後、vCPU 跑之前可以 runtime SHARE(`share_probe()` 就是這個時序) | crosvm `mod.rs:791-800, 840` | 已證 |
| F7 | 視窗 IPA 必須在 `[base-address, base+size-max)`;上方 PCI 視窗的 BAR blob 三台都能 accept | crosvm `gunyah/aarch64.rs:80-145`;R5 驗收 gfxstream 三台 PASS | 已證 |
| F8 | host 寫進 memfd 的內容 SHARE/ACCEPT 後保留(driver 與模組都不帶 SANITIZE) | GKI `rsc_mgr_rpc.c:178,264`;host_share 不設 flags | 開源碼 |
| F9 | 一顆 parcel = 一次 RM 配額(1024/機,owner=HLOS,不 reclaim 不還);512 entries/RPC 由 driver 以 MEM_APPEND 分段 | RM `memparcel.c:106,781-787`;GKI 6.1/6.6 `rsc_mgr_rpc.c` | 開源碼 |
| F10 | RM 只在 owner 明確 `MEM_NOTIFY` 時才對 guest 發 `MEM_SHARED`;driver 不發 → 預先 share N 顆不會塞爆 rm-rpc msgq(depth 8) | RM `memparcel.c:2625-2650` | 開源碼 |
| F11 | edk2-gunyah FD 位置無關(`code0: adr x1,.` + PE 重定位);system memory 取 `/memory` **第一段**;UEFI region = FD 後 64 MiB;沒有 restricted-dma-pool 就不裝 IoMmu、不產 RDMA0000 | `GunyahKernel.fdf:52-53`, `ModuleEntryPoint.S:37-45,90-112`, `FdtParser.c:54-73`, `GunyahIoMmuDxe.c:302-340` | 已讀 |
| F12 | GB 級單顆 SHARE parcel 的 RM/hyp 行為 | — | **待量(E2)** |

---

## 2. 記憶體布局(新模式)

```
IPA
0x0000_0000 ┐ platform MMIO(RTC 0x2000 / WDT 0x3000 / GPIO 0x4000 / PCI CAM …)  → 不變,shim 不加裝置
0x0200_0000 │ 32-bit PCI MEM、pflash                                            → 不變
0x3FFD_0000 │ GIC
0x4000_0000 │ RM 捐的 low RAM(RW no-X)                                          → shim 寫 /memory 時自然排除,不再需要 fence 節點
0x8000_0000 ┼ boot region(LEND'd,GuestMemoryRegion,固定 4 MiB)
            │   +0x000000  shim.bin(<2 MiB,含 stack)
            │   +0x200000  DTB slot(AARCH64_FDT_MAX_SIZE = 2 MiB;RM 在這裡就地 patch)
0x8040_0000 ┼ handoff(新 purpose ShimHandoff,2 MiB,開機完整 SHARE + 自己的 no-map 節點)
            │   host 在 GH_VM_START 之後把 memparcel handle 寫進來(§5)
0x8060_0000 ┼ 視窗(新 purpose,例 SharedGuestRam;大小 = --mem;memfd,host 開機前 populate+collapse+mlock)
            │   +0          payload:kernel Image / edk2 FD(crosvm 直接寫進 memfd,F8)
            │   +align16M   initrd
            │   …           剩下 = guest 的 RAM
            │   (可切 N 顆 parcel:parcel-mb;預設整段一顆,視 E2 決定)
            ┼ gfx_host / gpu_guest / drm2kgsl / venus pool(不變,仍是 boot SHARE 的 data pool)
            ┼ platform-MMIO 8 MiB + 64-bit PCI 視窗(host-visible BAR)             → 隨 end_addr() 上移,不變
            └ size-max
```

- `--mem N` 語意改為「視窗大小」;boot region 是固定額外 4 MiB。
- 沒有 `--swiotlb`、沒有 simplefb 獨立 region(要 simplefb 就從視窗切,節點由 shim 事後加,見 §4.5)。
- 6.6 的 RM 把 image parcel 視為 DTB parcel(`mem_ipa_base` = DTB 位址),normal memory 只允許在它之上 → 視窗必須在 DTB 之上;上面的排法滿足。

---

## 3. 開機時序

```
crosvm                                   RM / hyp                       shim(guest vCPU0)
─────────────────────────────────────    ────────────────────────────   ─────────────────────────────
1 建 region:boot(LEND) + 視窗(memfd)
2 prepare 視窗:populate/collapse/mlock
3 載入:shim→boot+0;payload/initrd→視窗
   DTB→boot+2M(/memory=boot region;
   /droidvm,shim 節點;無 swiotlb/fence)
4 GH_VM_ANDROID_LEND(boot region)
   GH_VM_SET_DTB_CONFIG / SET_BOOT_PC=shim
5 GH_VM_START ───────────────────────►   VM_ALLOCATE…INIT(parse DT)
                                          VM_START:patch DTB、vcpu_poweron(pc=shim,x0=DTB)
6 share_blob(視窗 parcel i, RWX) ×N ─►   MEM_SHARE(ACL guest RWX, host RWX);SCM assign
   handles → handoff 區域,最後寫 ready
7 GH_VCPU_RUN ─────────────────────────────────────────────────────►    a 設 SP;讀 DTB:/droidvm,shim、
                                                                          gunyah-resource-manager(tx/rx cap)
                                                                        b handoff:等 ready,讀 N 與各 handle
                                                                        c 每顆:MSGQ_SEND MEM_ACCEPT
                                          MEM_ACCEPT → Stage-2 RWX ◄──     (CONTIGUOUS|DONE, sgl={base,size})
                                          reply ─────────────────────►     輪詢 MSGQ_RECV,丟棄非本 seq 的訊息
                                                                        d dc civac payload/initrd 範圍;ic iallu
                                                                        e /memory reg = 視窗;套 overlay(若有);
                                                                          刪 /droidvm,shim
                                                                        f handoff status=JUMPING
                                                                        g x0=DTB, x1..x3=0 → 跳 payload
8 輪詢 handoff status:JUMPING 才算成功;
   ERROR → 印 msg/error、結束 VM(不要靜默卡死)
… VM 結束:unshare_blob ×N(RM RECLAIM),否則吃配額(F9);crash 由 host_share reaper 兜底
```

---

## 4. shim 規格

### 4.1 進入 ABI
- EL1、MMU off、cache off、IRQ masked;`x0 = DTB`,其他暫存器不可信(SP=0)。第一件事設 SP(shim 區內)。
- 6.1:PC 由 RM 定為 image base;6.6:crosvm `SET_BOOT_CONTEXT` 指到同一位址。兩邊一致 → shim 永遠在 `0x8000_0000`。

### 4.2 輸入 —— header + handoff,不是 DT 節點

原本打算用一個 `/droidvm,shim` DT 節點傳參數。實際做下來不需要:靜態的東西(payload 位址、
handoff 位址、DTB 可成長上限、旗標)crosvm 在**開機前就能寫進 shim 映像自己的 header**
(`struct shim_header`,在入口分支之後的 offset 8),動態的東西(memparcel handle)本來就得走
handoff 區域。少一個節點,也少一次「RM 會不會嫌棄這個節點」的風險。

shim 唯一要從 DT 讀的是 RM 的 message queue capability:

```
/hypervisor/qcom,resource-mgr { compatible = "gunyah-resource-manager"; reg = <tx_capid rx_capid>; }
```

這個節點是 RM 自己產生的(crosvm 只宣告 `vdevice-type = "rm-rpc"`),`reg` 是兩個 u64 —— 和
guest 端 `gunyah_guest.c:762-773` 讀的是同一個東西。

### 4.3 步驟(對應 §3 的 a–g)
1. `fdt_check_header`;找 `/droidvm,shim`;找 `gunyah-resource-manager` 取 tx/rx capability。
2. handoff:等 `ready`(host 最後才寫),讀 `nparcels` 與每顆 `{handle, base, size}`。
3. 每顆送 RM `MEM_ACCEPT 0x51000011`:hdr(handle, type=NORMAL, trans=SHARE, flags=MAP_CONTIGUOUS|DONE, validate_label=0),acl n=0,sgl n=1 {base,size},attr n=0。
   收 reply:`MSGQ_RECV` 輪詢,只認 type=REPLY 且 seq 相符者,其他訊息丟棄(F10 說正常不會有,但要能吃)。錯誤碼非 0 → 失敗。
4. `dc civac` payload+initrd 範圍(host 用 cacheable 寫進來、guest 現在用 device 屬性讀 → 保險;成本 ~ms),`dsb sy; ic iallu; dsb; isb`。
5. DT:`fdt_open_into` 到 `dtb-max-size`;`/memory reg` = windows(排序、合併相鄰);有 `overlay` 就 `fdt_overlay_apply`;`fdt_del_node(/droidvm,shim)`;`fdt_pack`。
6. handoff `status = SHIM_STATUS_JUMPING`。
7. `x0 = DTB; x1=x2=x3=0; br payload`。不開 MMU 就不用關;若為了 memcpy 效能開了 MMU,跳前關掉並 clean。

### 4.4 錯誤處理
任何一步失敗:handoff `status = SHIM_STATUS_ERROR`、`error` 放 RM 錯誤碼、`msg` 放一行人話,然後
`wfi` 迴圈。crosvm 輪詢到就把 `msg` 印進 log 並結束 VM —— 不會變成一台安靜卡住的 VM。

### 4.5 不做的事(交給 crosvm 的 overlay)
simplefb-in-window、其他 `/reserved-memory` 節點、`/chosen` 額外屬性 … 一律由 crosvm 生成 dtbo 放在 `overlay` 屬性,
shim 只負責套。shim 保持「accept + memory reg + jump」三件事,穩定後不必再動。

### 4.6 實作選型
- **C + asm + vendored libfdt**(BSD/GPL-2.0+ 雙授權,和 DroidVM 的 GPL-2.0-or-later 相容),
  `clang --target=aarch64-none-elf -ffreestanding -fPIC -nostdlib`,linker script 出 flat `shim.bin`(< 64 KB)。
  理由:libfdt 現成、RM RPC 封包格式在 `gunyah_guest.c` / `GunyahPreloadDxe.c` 已有兩份可直接抄。
- 放哪:meta repo 新目錄 `droidvm-shim/`(獨立 Makefile);crosvm 以 `include_bytes!` 內嵌預設版,並提供
  `--protected-vm-pseudo-unprotected shim=PATH` 覆蓋,方便單獨迭代。
- 備選:Rust `no_std` `aarch64-unknown-none` — 少一條 C 工具鏈但要自己寫 fdt setprop/overlay,先不選。

---

## 5. handoff 區域(取代原本的 mailbox MMIO 裝置)

memparcel handle 只在 `GH_VM_START` 之後才存在,而 boot region 那時已經 LEND 出去、host 寫不進去 ——
所以 handle 必須經由一段 **host 仍可寫**的記憶體交給 shim。原本打算做一個 MMIO 裝置;後來發現
不需要:一個 **2 MiB、開機就完整 SHARE 的區域**就夠了,而那正是今天三個 GPU pool 的形狀,
crosvm 不必新增任何裝置。

* purpose `ShimHandoff`,2 MiB,完整 pre-share(`step = 0`)。
* 它有自己的 `/reserved-memory` 節點(`reg` 精確等於那顆 parcel,`no-map`)—— 8gen3 的 RM 因此
  接受它,而 RM 重新產生 `/memory` 時也會因為 `no-map` 把它排除,不會變成 Linux 的 RAM。
* shim 不必找節點:位址由 crosvm 在開機前寫進 shim 的 header。
* 內容就是 `struct shim_handoff`(`crosvm/hypervisor/src/gunyah/shim_abi.rs`):magic/version、`nparcels`、每顆
  `{handle, base, size}`、以及 host 最後才寫的 `ready`;回程是 `status`/`error`/`exec_probe`/`msg`,
  crosvm 輪詢它來決定 boot 成不成功、並把 `msg` 印進 log。

`ready` 是最後寫、最先讀的欄位:沒有它,一個比 host share 迴圈跑得快的 shim 會拿到還是 0 的 handle。

## 6. crosvm 變更清單

| 檔案 | 改什麼 |
|---|---|
| `hypervisor/src/lib.rs` | `ProtectionType` 新變體 `ProtectedPseudoUnprotected`(`isolates_memory()=true`、`runs_firmware()=false`),`Config` 加 shim 選項(parcel_mb、shim 路徑) |
| `src/crosvm/cmdline.rs` / `config.rs` | `--protected-vm-pseudo-unprotected [shim=PATH,parcel-mb=N]`;與 `--swiotlb`、`--protected-vm` 互斥;非 gunyah 拒絕 |
| `vm_memory/src/guest_memory.rs` | 新 `MemoryRegionPurpose::SharedGuestRam`;host 端視為 always-backed(裝置存取不擋);`is_guest_ram()` 類判斷要含它 |
| `aarch64/src/lib.rs` | `guest_memory_layout`:主 region 縮成 4 MiB boot region、視窗 region 疊在其後;`main_memory_size` 相關(initrd 上限、FDT 位置)改指視窗;`load_kernel`/`load_image` 目標改視窗;載入 shim 到 boot+0;`init_arch` 的 payload_entry = shim;pools 疊在視窗上方;`get_system_allocator_config` 不變(靠 end_addr) |
| `aarch64/src/fdt.rs` | `create_memory_node` 只放 boot region;新 `create_shim_node`;此模式不產 restricted-dma-pool / `/pci memory-region`;`chosen` initrd 指視窗;可選 overlay 生成(`cros_fdt` 建 fragment@0/target-path) |
| `hypervisor/src/gunyah/mod.rs` | `GunyahVm::new`:`SharedGuestRam` → 不 LEND、不 boot SHARE(`continue`),但做 `prepare_lend_region` 等級的 populate/collapse/mlock;`start()`:GH_VM_START 成功後對每顆 parcel `share_blob(…, exec=true)`,handle 存進 `Arc<Mutex<Vec<ShimParcel>>>`;`share_blob` 加 `allow_exec` 參數(**不要**全域改成 RWX,只有視窗給 X);Drop/teardown `unshare_blob` ×N |
| `hypervisor/src/gunyah/aarch64.rs` | `create_fdt`:`SharedGuestRam` 不建 shm vdevice;此模式不發 lowmem fence 節點;size-max 公式不變 |
| `devices/src/` | 不用動 —— handoff 走一段 SHARE'd 記憶體,不是新裝置(§5) |
| `src/crosvm/sys/linux.rs` / `arch` | shim 映像(內嵌 blob 或 `shim=PATH`)進 `VmComponents`;開機前 patch shim header;`GH_VM_START` 之後 share 窗口、填 handoff、寫 `ready`;輪詢 `status`,ERROR 就印 `msg` 並結束 VM |
| `hypervisor/src/geniezone`、kvm | `SharedGuestRam` 當普通 guest RAM(模式本身在非 gunyah 拒絕) |
| balloon | 此模式先不支援 inflate(`GH_VM_RECLAIM_REGION` 對 SHARE 無效);DroidVM 的 dynamic memory 之後改走 guest RELEASE + host RECLAIM(粒度 = parcel) |

---

## 7. 其他 repo 的影響

- **edk2-gunyah**:理論上零改動 —— FD 放視窗、`/memory` 第一段 = 視窗、UEFI region 落在視窗內、無 restricted-dma-pool → IoMmu/RDMA0000 自動略過(F11)。
  要盯:DTB 拷到 FD+0x40 的 32 KB slack(`FdtParser.c:78-86` 沒有大小檢查;crosvm DTB + RM patch + overlay 後要 < 32 KB,否則得改 edk2)。
- **guest kernel / guest-additions**:不用改。`/memory` 只有視窗;無 swiotlb;`gunyah_guest` 仍靠 RM 節點;pools 照舊。
- **DroidVM app**:VM 設定加第三種 protection 選項;此模式忽略 swiotlb 欄位;`--mem` 語意說明。
- **host_share 模組**:不用改(X 由 flags 帶入)。

---

## 8. 量到的東西(2026-08-19,8gen3 / OPD2404 / 6.1.118,除非另註)

裝置實測,不是讀碼推論。rig 在 `deploy/pseudo-unprotected/poolvm.sh`(無 GPU 的最小 VM + 可調 test pool),
guest 用 `droidvm-guest-additions/dynpool_test` 加 `accept` / `window` / `exec` 命令與
`tests/dynpool_exec.c`(EL0 探針)。crosvm 端三個診斷開關:`GH_SHARE_EXEC`、
`DROIDVM_POOL_HIDE=dt|shm|both`、`DROIDVM_TEST_POOL[_2]_GAP_MB`。

### E1 執行權限 —— 通過(EL0),EL1 待 shim

| 步驟 | 結果 |
|---|---|
| runtime `MEM_SHARE` ACL 帶 X(`flags=0x7`)| **RM 接受**,SCM assign 沒有拿走 host 的存取 |
| guest `MEM_ACCEPT` 到一個「crosvm 沒有 region、DT 沒節點、沒有 shm vdevice」的純空洞 | **成功**(rc=0)|
| 讀回 host 預先寫的圖樣 | **相符** —— 拿到的真的是 host 的頁 |
| EL0 執行(`/dev/dynpool` + `PAGE_SHARED_EXEC`,跑 `mov x0,#42; ret`)| **回傳 42** |
| **反面對照**:同一台、同一個池子、同一個位移、同一段程式碼,只把 `GH_SHARE_EXEC` 關掉 | **`NO-EXEC: signal 7`**(SIGBUS)在 CALL,而同一頁的讀寫照常 —— 所以可執行是 ACL 的 X 給的,不是本來就有 |
| EL1 執行 | **測不到,兩條路都被 stage-1 擋死** |

EL1 為什麼在 Linux 裡量不到,兩條路都試過:

1. **核心映射**:7.0 的 arm64 `ioremap_prot` 要求 `PTE_USER` 且只保留記憶體型別位元,底層的
   `ioremap_page_range()` 又一律套 `pgprot_nx` —— 沒有任何 ioremap 路徑能產生可執行的核心映射。
2. **使用者映射清掉 PXN,再從模組裡(同一個行程的 syscall 中)呼叫進去**:一樣被拒。ARMv8.7 的
   FEAT_PAN3/EPAN 會讓「使用者可執行」的頁對 EL1 自動變成 PXN,這條路在這代核心上本來就是死的。

兩次的 `ESR` 都是 `0x8600000f`(L3 指令權限錯誤)、位址都是**我們自己映的那個 VA**,也就是說
擋下來的是 stage-1,stage-2 完全沒有表態。第二條路的程式碼已經撤掉,留著只會誤導。

所以 EL1 的答案只能由 shim 給(MMU off → 沒有 stage-1 → 只剩 stage-2,正是真實情境),
`SHIM_FLAG_PROBE_EXEC` 就是為此存在。旁證仍然很強:Gunyah 的 `pgtable_access_t` 沒有
「只在 EL0 可執行」這種編碼,RM 把 ACL 的 RWX 映成 `PGTABLE_ACCESS_RWX` —— 和 guest 自己那塊
LEND'd RAM(guest kernel 每分每秒都在上面執行 EL1 程式碼)用的是同一個 access 值。

### E3 開機拒絕的真因 —— 是 `/reserved-memory` 節點,不是 region

一個宣告 512 MiB、開機零 SHARE 的池子,四個變體:

| 變體 | resmem 節點 | shm vdevice | 結果 |
|---|---|---|---|
| A | 有 | 有 | **拒絕**:`GH_VM_START failed` → `failed to initialize virtual machine No such device (os error 19)` |
| B | **無** | 有 | **開機成功** |
| C | 有 | **無** | 拒絕(同 A)|
| D | 無 | 無 | **開機成功** |

所以:
* **窗口可以是 crosvm 的 GuestMemory region**(宣告了卻不 SHARE,RM 不在意)—— 設計成立,
  memfd 預載 payload 與 `offset_from_base` 都保得住。
* shm vdevice 節點也無所謂(B 保留它仍能開機)。
* 唯一的地雷就是開源 RM `vm_creation.c:1507-1545` 那條:`/reserved-memory` 帶 `reg` 的子節點
  必須精確對到一顆已 accept 的 memparcel。窗口本來就不進 `/reserved-memory`,不會踩到。
* 附帶收穫:池子的 DT 節點其實不是必需品 —— host 端的池子表以 pool-id 為鍵,guest 只要知道
  base/size 就能驅動(`dynpool_test` 現在支援 `base=`/`size=` 模組參數)。這條讓 growable pool
  在 8gen3 上第一次可用。

### E2 單顆 parcel 的大小與成本 —— 卡在 host 的準備路徑,不是 RM

`--mem 1024`,池子整段一次 grant(一顆 memparcel):

| 窗口 | 結果 |
|---|---|
| 512 MiB | **成功**:folio 準備 751 ms + share/accept 1.20 s(其中 host share ioctl 1.148 s);`flags=0x7` 確認 ACL 帶 X;verify 通過;EL0 執行通過 |
| 1 / 2 / 4 GiB | **失敗 -ENOMEM**,而且失敗在 RM 之前 —— `prepare_folios` 就回錯 |

真因量到了:`folio_back_range()` 會**先 `fallocate` 整段**,那是普通 4 KiB shmem;
而這些手機把記憶體都停在大頁保留池裡(實測 8gen3:`MemAvailable` 1.05 GiB、`MemFree` 282 MiB,
對比 `pool_avail` 2816 頁 = 5.5 GiB)。4 KiB 配置拿不到保留池,於是 1 GiB 就撞牆;
更糟的是就算 fallocate 成功,後面的 `MADV_COLLAPSE` 還要再配一顆 2 MiB folio 並搬進去 —— 峰值雙倍。

**已修**(`hypervisor/src/gunyah/mthp.rs`):拿掉 fallocate,改成先 `MADV_HUGEPAGE` 再逐 2 MiB
`MADV_POPULATE_WRITE`,直接從保留池的 order-9 供給鉤子拿 folio —— 就是多 GiB guest RAM 的 LEND
一直在走的那條路(`prepare_lend_region`)。順手把錯誤處理分開:只有 `EINVAL/ENOSYS`(舊核心沒有
POPULATE_WRITE)才退回手動 write-fault,`ENOMEM` 直接往上回,否則手動 fault 遇到真的沒記憶體會
是 SIGBUS 打死 VMM,而不是一次 grant 失敗。

這順帶也是既有 growable pool 的一個真 bug:在保留池佔滿記憶體的機器上,大一點的 grow 從來不可能成功。

修完之後重跑,**一顆 parcel 涵蓋整段窗口在 8gen3 上是可行的**:

| 窗口 | folio 準備 | share + guest accept | 其中 host share ioctl | verify | EL0 執行 |
|---|---|---|---|---|---|
| 1 GiB | — | — | — | 通過 | 42 |
| 4 GiB | **257 ms** | **1.09 s** | 1.045 s | 通過 | 42 |

4 GiB 反而比修正前的 512 MiB(751 ms)還快,因為現在是直接從保留池拿 order-9 folio,
不再有「先配 4 KiB 再搬進 folio」那一輪。

**結論:`parcel-mb` 預設就整段一顆**,4 GiB 窗口在開機路徑上多花約 1.35 s。
切多顆只有兩個理由(RM 配額細粒度釋放、未來的動態記憶體),不是正確性需求。

### 順帶量到的三件事

* **`crosvm stop` 不是優雅關機**:guest 從不 flush,那一輪寫的檔案下次開機全是 0 bytes。
  要 `ssh … systemctl poweroff`(`poolvm.sh stop` 已改)。SETUP.md 早就寫了,我又踩一次。
* **pin probe 會擋 probe 用的 scratch 記憶體**:匿名頁落在 CMA → `GH-PIN … cannot be
  long-term pinned` → share 回 ENOMEM。`GUNYAH_PIN_POLICY=fix` 讓它遷移。真正的窗口走
  reserve pool + 2 MiB folio,不會遇到。
* **沒有任何一層擋得住「往任意 GPA accept」**:host 只要肯 share、guest 拿到 handle 就能
  accept 到任何位址(`pool_validate_share` 只驗 pool 相對位移,guest 端只驗 handle/size 非零)。
  窗口模式上線時 host 端要補一張「可被 share 的位址」白名單。

### 還沒做的

* E1 的 EL1(等 shim v0)。
* 8e5 只驗到「新的 pool DT 模型能開機」(firmware-only,`GH_VM_START` 無錯);完整的 grow/exec 沒跑。
* 8e 完全沒驗 —— 量測期間那台一直有使用者自己的 acc-test VM 在跑。

## 8b. 順帶解鎖:growable pool 在 8gen3 可用了(新的 DT 模型)

E3 的副產品。舊模型把整個窗口寫進 `/reserved-memory` 的 `reg`,而只有 floor 被 SHARE ——
8gen3 的 RM 找不到對應的 memparcel,VM 直接不啟動。新模型只換一件事:**`reg` 描述 floor,
窗口大小改用 `droidvm,pool-size`**。四個參數(總大小/預分配/步長/max-grants)一個都沒改,
crosvm 的 CLI 也沒動。

| 參數 | 舊 | 新 |
|---|---|---|
| 總大小 | `reg` 的 size | `droidvm,pool-size` |
| 預分配(floor)| `droidvm,pre-alloc-size` | `reg` 的 size(`pre-alloc-size` 同值保留)|
| 步長 | `droidvm,step-size` | 不變 |
| max-grants | 本來就只在 host 端 | 不變 |

三台通用,而且是同一條路徑:8gen3 的 RM 會檢查(新形狀正好滿足),6.6/6.12 那兩代的 driver
根本不替每個 region 建 parcel,它們的 RM 從來沒在比對 —— 這正是舊形狀在那兩台過得去的原因。

改動:
* `aarch64/src/fdt.rs`:`reg = <gpa floor>`;`floor != size` 時多一個 `droidvm,pool-size`。
  全預配的池子輸出**完全不變**(floor 就是窗口),所以既有三個 GPU pool 一個位元都沒動。
* `aarch64/src/fdt.rs` `create_memory_node`:growable pool 不再進 `/memory`。窗口的未 grant 部分
  被當成 RAM 會是「讀到零、寫下去 VM 死」,而 floor 由它自己的節點描述。非 growable 的池子維持原樣。
* `vm_memory/src/guest_memory.rs`:growable pool 的 floor 下限 **2 MiB**(`pool_param_error`)。
  floor = 0 就沒有 parcel 可對,節點也就沒地方掛屬性;要 floor=0 的只有窗口,而窗口不需要節點。
* guest `virtio_gpu/virtgpu_vram.c`、`dynpool_test`:有 `droidvm,pool-size` 就用它,沒有就退回
  `resource_size(reg)` —— 新舊 DT 都能跑。
* edk2 `GunyahPoolAcpiDxe`:同樣的讀法,Windows 那邊的 `_CRS` 才不會只看到 floor。

## 9. 風險與備案

- **vendor RM ≠ 開源 RM**:F1/F2/F10 是開源碼推論,裝置行為以實測為準;設計上已不依賴 F1(shim 自己重寫 `/memory`)。
- **cache 可見性**(host cacheable 寫、guest MMU-off 讀):今天 LEND 路徑同樣情境沒事;仍在 shim 加 `dc civac`,crosvm 端也可在寫完 payload 後 `dc cvac`(EL0 允許)。
- **配額**:每顆 parcel 佔 1024 配額之一且要在 teardown reclaim;crash 依賴 host_share reaper。parcel 數保持個位數到十幾。
- **記憶體全程 pin**:與今天 LEND 的 mTHP prepare 同量級,但少了 balloon 回收;先接受,後續用 parcel 粒度做動態記憶體。
- **DTB 32 KB slack(EDK2)**:超過就得改 edk2 PrePi;先量。
- **安全語意**:guest RAM 對 host 完全可見 —— 這是本模式的目的,文件要寫清楚,UI 上跟 protected 分開。

---

## 10. 里程碑

1. E1–E3(1 天,三台輪流)。
2. shim v0(零視窗直跳,E4)+ crosvm 版面/載入/handoff 骨架。
3. shim v1(accept + memory reg)+ crosvm share-after-start + teardown reclaim → 8e 上 kernel 直開通。
4. EDK2 路線(Ubuntu grub、Windows)驗證;overlay 機制視需要補。
5. 8gen3 全套;app 選項;三台驗收(沿用 R5 條件)。
