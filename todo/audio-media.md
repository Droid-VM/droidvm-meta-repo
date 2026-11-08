# 音訊與媒體（VPU、VideoToolbox、相機）

VPU、VideoToolbox paravirt 與相機的待辦完整細節，從 `PROGRESS.md`「未解／待查」與「7. 下一步」移來（原文照錄）。

## 11-02 VideoToolbox 編碼器不吃 App 設定

VideoToolbox paravirt 編碼器還不吃 App 的設定：`esup` 沒列 AverageBitRate、MaxKeyFrameInterval、RealTime、ProfileLevel 等，VideoToolbox 直接拒絕、不送 `eset`，碼率與 GOP 用 MediaCodec 預設。要做：列進清單、`eset` 對到 V4L2 `V4L2_CID_MPEG_VIDEO_*`，且 codec 要延到第一幀才建立（App 在 session 建好後才設，`esta` 時已經 STREAMON）

## 10-28 TODO 4 VPU 與相機

**VPU（編碼器、解碼器）與相機（含對焦、閃光燈）。**

- **host＋Linux guest：已完成。**virtio-media 三個裝置（相機、解碼器、編碼器）、vhost-user helper（app uid）、`media_host`／`media_guest`
  池、Linux guest driver（DKMS）、libva-v4l2 都做完，Ubuntu 上出貨組態驗收（Firefox 硬解 H.264／VP9／AV1、ffmpeg 硬體編碼、相機）
  大部分已關；`wip/vpu` 已 rebase 進 `wip/hackintosh`。還開著的：**P-6**（畫面卡死、之後鎖定畫面全黑，blocker，未能重現）、**P-5**
  （硬體編碼 drain 偶發掉尾幀，非決定性）、P-2（low）、P-9 的 12.4 h 實機 soak 沒做。細節 `plans/VPU_DESIGN.md` §7.8。
- ✅ **iPadOS guest：傳輸層第一個里程碑完成（10-29）**：guest 自檢讀到解碼器格式（H264／HEVC／VP90／AV01 → NV12，9 個 command、0 timeout）；crosvm `--virtio-mmio-media`（d5c13c494）、guest 輪詢式 `package/DroidVMVirtioMedia.c`（e66a7b4）、動態 ADT（DarwinBoot b2ad902、device 3f3474d）。memory [[droidvm-dynamic-adt]]、[[droidvm-virtio-media-ios]]。
  - 陷阱：`VIDIOC_QUERYCAP` 由 driver 用 config space 自己回答，送給 device 會回 ENOTTY。
  - 解碼、編碼的往返已由下面的 VideoToolbox 路線做完；相機還沒接。
- **接 VideoToolbox：用 Apple 自己 VM 的 paravirtualization 通道（11-02 查明，從 24A446 shared cache 讀出）。**
  - iPadOS 27 的 VideoToolbox 本身帶完整的 paravirtualized 解碼器、編碼器、JPEG、motion estimation（`ParavirtualizedVideoDecoder_*`
    等；macOS host 那半邊 `VTParavirtualizationHost*` 也編在同一顆）。`VTParavirtualizationIsRunningInGuest` 只看
    `AppleVideoToolboxParavirtualizationDriver` 打不打得開（不看 `kern.hv_vmm_present`），打得開就讓合格的 codec 全走它。
    userland 原封不動，XNU 扮演 host，把 session 翻成 virtio-media 的 V4L2：符合「通用 host 裝置、XNU 翻譯、userland 原廠」。
  - 傳輸（`VideoToolboxParavirtualizationSupport.framework`，8 KB，`AppleParavirtGPU-1`）：IOServiceOpen type 0。
    selector 0 `{size}`→`{容量, 送出 buffer, 佇列}`（kernel 映射進行程，先 16 KiB）；1／2 註冊／註銷 guest UUID（16 bytes）；
    3 `{長度, 最多 5 個 IOSurface ID}`→`{status}`；4 佇列取空。host→guest 用 IODataQueue＋notification port（每則 ≤16 KiB）。
    sandbox 只放行 `AppleVideoToolboxParavirtualizationUserClient` 這個名字（kernel 的 profile 有這串）。
  - 訊息：48 bytes 的 FigAtom `'vtpv'`（類型 FourCC、flags、guest UUID、request ID），後接序列化 CF 型別與 sample buffer 的 atom。
    解碼器：guest→host `decs` 列表、`dcap` 能力、`+dec` 建立、`dsta` 開 session、`dcan`、`dfrm` 解一幀、`dfin`、`dcop`／`dset`／
    `dmul`／`dsup`／`dsav` 屬性、`dinv`、`-dec`、`Bye!`；host→guest `Dbuf` 請 guest 配 pixel buffer（IOSurface）、`Demt` 送出解好的幀、
    `Ddpa`／`Dpba`／`Drpa` 屬性、`Dfub`。編碼器對稱（`encs`…）。
  - ✅ **解碼、編碼都通（11-02）**：`package/DroidVMVTParavirt.cpp`（傳輸、Apple 名字的 driver／user client）＋`DroidVMVTHost.cpp`
    （host：session 依 UUID，V4L2 session、worker thread、IOSurface 查詢）＋`DroidVMVTWire.h`（訊息格式）。device 1479852（解碼）、
    9d5a0ce（編碼）、706338e（預設開啟）。開機就發布（關掉：命令列 `droidvm-vt-paravirt=0`）；執行中改 `kern.droidvm_vt_paravirt`
    只影響之後才啟動的行程（videocodecd 若已啟動就不會換）。
    測試：`gfxprobe vtdecode FILE N`、`gfxprobe vtencode [hevc] W H N`（輸出 `/private/var/ngpu/enc.h264|hevc`）、`gfxprobe imgdecode FILE N`。
  - 「在 guest 裡」除了 codec 還改了什麼（24A446 shared cache）：VideoToolbox 隱藏非 paravirt 的硬體 codec（AVD、AVE，這裡本來就沒有）；
    MediaToolbox 放寬防錄影檢查（外部保護不足時不遮畫面，FairPlay 這裡本來就沒有）；CMPhoto 問 paravirt JPEG（`jcap`），被拒後用軟體。
    實測開／關對照：HEIC、JPEG 像素相同、速度相同；4:2:2 H.264 兩邊都解不了（軟體也不支援）；不開時 H.264 編碼是軟體 `anon-1`（720p 32 fps）。
    VM 要有 `--virtio-media kind=decoder` 與 `kind=encoder`（＋`--virtio-mmio-media`、`media-host-mb=160`）。
  - 格式怎麼來的：Mac（macOS 27）上 `tools/vtpv-oracle`：`hostonly` 把 guest 錄到的訊息餵給 VideoToolbox 自己的 host session，
    錄 host 的回覆（`Efds` 要回真的 format description，host 才會吐 `Eemt`）；編碼器在 macOS 是 out-of-process，loopback 跑不起來。
  - 陷阱：
    - guest framework 在 selector 3 整段持鎖，host 不能在 guest 的 thread 上等 guest 回覆（輸入排隊、worker 做事）。
    - MediaCodec 會扣幀（單張 IDR 也扣），`dfin`／`ecfr` 要 drain（`*_CMD_STOP`→LAST→`*_CMD_START`），兩秒還沒交出的幀回錯誤。
    - 高通 AVC 解碼器 720p 要 21 個 CAPTURE buffer；c2.qti 解碼最小 96x96。
    - IOSurface 只能被「建立者 task」或「已持有它的 client」查：解碼的 surface 是 videocodecd 自己建的，核心另開一個 client 查即可；
      編碼的 surface 是 App 的（XPC 傳進來），要用行程自己的 client（`IOUserClientCreator` 找）建 port 再查。
      同一個 client 查第二次會被拒，所以依 ID 快取，session 結束 `clientClose` 一次還。
    - 關鍵幀不能帶 `NotSync`（WebRTC、gfxprobe 都只看有沒有這個 key）。
    - 解碼器、編碼器 session ID 會重複，媒體事件要依裝置＋session 分派。
    - VideoToolbox 只轉發 `dsup`／`esup` 支援清單裡有的屬性，清單外的它自己回 -12900、不問 host；目前清單只列
      `UsingHardwareAccelerated{Decoder,Encoder}`（回 true，device fab4fb1）。HEVC 編碼 session 會主動問
      `MVHEVCVideoLayerIDs`（多視角 HEVC），回不支援是對的。
  - 下一步：開機預設發布並測 Safari／AVPlayer 播放與錄影類 App；1080p；VP9／AV1 解碼（VideoToolbox 的 paravirt 清單能不能列）。
