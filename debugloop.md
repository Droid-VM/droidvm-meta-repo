# gfx 路線的除錯迴圈

寫給下一次的自己。這份文件的一半是**陷阱**,因為這一輪裡讓我得出錯誤結論的次數,
比程式本身的 bug 還多。

---

## 1. 一輪迴圈長什麼樣

```bash
# 改 host(crosvm + gfxstream,兩者同一個建置)
./2_build_crosvm.sh                     # → crosvm_out/
scratchpad/devvm.sh push                # crosvm_out/ → dbg_pkg/ → 手機,逐檔 md5
scratchpad/devvm.sh start               # 起 VM,並開始串流 log 到 scratchpad/devvm.log
# ...量測...
scratchpad/devvm.sh stop                # 一定要用這個關,絕不 kill -9

# 改客體 mesa(gfxstream ICD / zink)
bash 8_build_guest_mesa_gfx.sh          # → dist-guest/mesa-guest-gfxstream_*.deb
# 改客體核心模組(virtio-gpu / gunyah_guest)
bash 9_build_guest_addition.sh          # → dist-guest/droidvm-guest-additions_*.deb
scp dist-guest/*.deb root@172.22.68.12:/root/
ssh root@172.22.68.12 'apt-get install -y --allow-downgrades ./<deb>'
```

**每一步都要驗證它真的發生了**,理由見第 3 節。

---

## 2. 手邊的工具

`scratchpad/` 底下(這一輪建立的):

| 工具 | 用途 |
|---|---|
| `devvm.sh` | push / start / stop / log。不經過 app,用 app 會用的 argv 直接起 crosvm |
| `gfxcheck.sh` | 對一個 session 給**一個判定**:desktop / no-compositor / no-shell / x-wedged / x-never-started / unreachable |
| `gfxrun.sh N` | 跑 N 次 session 重啟並統計。每輪在 golden image 的**拋棄式 overlay** 上,並有手機負載看門狗 |
| `rfb_grab.py` | VNC 截圖 + 亮點統計 |
| `grab2.py` | 同上,但可宣告 RichCursor 偽編碼,讓畫面裡**只剩 crosvm 合成的游標** |
| `curdiff.py` | 兩張截圖相減,把變動像素分群成 blob,回報各自的外框 |
| `mvonly.py` / `rfb_click.py` | VNC 移動指標(不按鍵) / 點擊 |
| `rfb_watch.py` | 保持一條 VNC 連線並連續回報畫面亮度 |
| `mclaunch.py` | 繞過 HMCL GUI 直接起 Minecraft(從 version JSON 組出命令列) |

手機上:

| 工具 | 用途 |
|---|---|
| `/data/local/tmp/sampler.sh` | **常駐**,每 5 秒記一行 busy/user/sys/irq/timer + crosvm 各執行緒 → `cpusample.log`。手機重開後要重新啟動 |

環境變數(都經由 `devvm.sh` 傳進 `run.sh`):

| 變數 | 作用 |
|---|---|
| `GFXSTREAM_DIAG=1` | 打開所有手加的診斷(封包追蹤、park 狀態、context 建立、池子配置、游標座標…) |
| `GFXSTREAM_ASG_SPIN_LEVELS` | host ring consumer 的退避階梯,`iters:sleep_us` 逗號分隔。**不給就用編譯預設** |
| `GFXSTREAM_SEQNO_FUTEX_AT` | seqno 等待改用 futex 的自旋門檻 |
| `GFXSTREAM_HANDOFF_BENCH=1` + `GFXSTREAM_HANDOFF_GAP_US` | 啟動時量 futex vs 自旋的交接延遲 |
| `GFXSTREAM_GUEST_BACKOFF_SPINS` | **客體端**的傳輸自旋門檻(設在客體行程的環境裡,不是 crosvm) |
| `/sys/module/virtio_gpu/parameters/droidvm_trace` | 客體核心模組的每次配置追蹤,預設關 |

---

## 3. 陷阱(照踩到的頻率排)

### 3.1 你以為在測新的二進位,其實不是

- **建置寫 `crosvm_out/`,push 讀 `dbg_pkg/`**,兩者一度沒接起來,而 push 的 md5 只比對
  `dbg_pkg ↔ 手機`,所以過期的套件會印出「all md5 verified」。**白測了四輪**。已修,但
  唯一可信的檢查是:**本機建置產物的 md5 vs 手機上的 md5**。
- **編輯失敗但建置成功**。把「改檔 + 建置」放進同一個背景命令、只檢查建置的錯誤數,
  一個 `AssertionError` 的編輯看起來就像一次乾淨的建置。**先驗證編輯落地(grep 新字串),
  再建置;建置完再驗證新字串進了二進位**(`grep -ac '新字串' crosvm_out/crosvm`)。
- 想確認某段程式碼有沒有進去:`grep -ac 'string' 檔案`。**不要**用
  `grep -c <(strings ...)`,它會靜默給空結果。

### 3.2 log 的計數是虛構的

`devvm.sh start` 每次都起一個 `tail -n +1 -F`,而**那會從第 1 行重播整個檔案**。
清理用的 `pkill` 模式一度寫成 `tail -F`(實際是 `tail -n +1 -F`)所以從沒殺到,
於是每 start 一次就多一份副本——**一個「只報一次」的守衛在 log 裡讀到 44 次**。

- 判讀方法:相鄰行的時間戳會**倒退**。
- **0 是可信的,任何大於 0 的計數都不可信**(重播只會增加)。這個不對稱很陰險。
- 取計數前先 `pgrep -cf 'tail .*crosvm.log'`。

### 3.3 不存在的輔助工具,加上被丟掉的 stderr

`python3 $SP/mv.py ... >/dev/null 2>&1` 連跑十幾次都「成功」——**那個檔案根本不在那個目錄**。
於是「移動指標」全是空操作,而我從中得出了一個很有說服力的錯誤結論
(「客體從不送 MOVE_CURSOR」);真相是那些移動從沒發生過。

- 輔助工具第一次用之前先讓它**印一行**,或至少別把 stderr 丟掉。
- 有預期副作用的步驟要有**正控制**:這裡就是「移動之後計數應該增加」。零增加要當成
  「這一步沒發生」的嫌疑,而不是「被測物沒反應」的結論。
- 想在客體端確認輸入有沒有進來,`cat /dev/input/eventN` 會讀到**零位元組**——
  `kwin_wayland` 對那些節點下了 `EVIOCGRAB`。要看輸入,去看它造成的下游效果
  (這裡是 crosvm 收到的 `MOVE_CURSOR`),別去讀被獨佔的裝置節點。

### 3.4 VNC 截圖裡有一顆不是你畫的游標

LibVNCServer 會替**不支援游標偽編碼**的客戶端把游標混進送出去的畫面。所以一般的截圖裡
同時有 crosvm 合成的那顆和它自己畫的那顆,疊在一起——想用截圖判斷「我們的游標畫對了沒」
會直接被它蓋掉。

反過來這也是免費的**參考實作**:它畫在 `cursorX - xhot`,和我們的路徑不共用 bug。
抓一張有宣告偽編碼的(只有我們的)、一張沒宣告的(我們的 + 它的),相減得 0 就是對齊。
再抓一張指標移開的當正控制,證明我們那顆真的在畫面上。

### 3.5 `pkill -f` 會匹配到自己

這一輪踩了**三次**:殺 sampler 時把整條 `su -c` 一起殺掉、殺測試腳本時殺到自己的 shell、
`until ! pgrep -f '2_build_crosvm.sh'` 的等待迴圈因為命令列裡有那個字串而**永遠不結束**
(好幾次「等建置」撞到 600 秒逾時,其實建置早就好了)。

用 pid 殺,或用 `[t]ail` 這種讓模式不匹配自己的寫法。

### 3.6 環境變數架空編譯預設

`devvm.sh` 一度無條件導出 `GFXSTREAM_ASG_SPIN_LEVELS` 的 fallback,於是 committed 的預設
根本不是實際在跑的值,而事後**無法從紀錄判斷當時跑的是哪個**——一段 40 分鐘的中斷風暴
因此無法歸因。已改成「呼叫端有給才導出」。任何「用環境變數覆蓋預設」的除錯設施都有這個風險。

### 3.7 效能數字

- **`vkmark -b :duration=2` 在冷 shader cache 上低估四倍**(615 vs duration=6 的 1920),
  而且連跑六次會「穩定」在錯的值上。跨映像比較一律 `duration>=6`。
- **GPU DVFS 是最大的雜訊源**:同一份建置同一顆碟,七輪可以從 2303 跑到 7847,
  第八輪 4723。**單次結果沒有意義**,要嘛交錯 A/B,要嘛鎖頻。
- 全新 overlay 的 `~/.cache/mesa_shader_cache` 是空的,前幾輪一定要丟掉。

### 3.8 判定「桌面好了沒」

- **只看行程存在不夠**。要等 `kwin` 和 `plasmashell` 兩個都在 D-Bus 上**註冊好名字**
  (`busctl --user --acquired list`)。
- **X11 探針少了 `XAUTHORITY` 看起來像掛住**。cookie 要從 **kwin 的命令列**讀
  (`/proc/<kwin>/cmdline` 裡的 `/run/user/1000/xauth_*`);`/run/user/1000` 底下會累積
  舊 session 的檔案,按名字排序取第一個會拿到幾小時前的。**只有 exit code 124 才算掛住**。
- **kwin 持有 X 的監聽 socket**,XWayland 是按需生出來的——所以「沒生出來」和「生出來但不回應」
  connect 起來一模一樣,要用 `pgrep -x Xwayland` 分開。而且 **kwin 約十次之後就不再重生它**,
  所以「反覆殺 XWayland」這個重現法每個 session 只能用約 10 次。
- **閒置熄屏會讓好的桌面看起來全黑**。X11 下 `xset -q` 會說 `Monitor is Off`,
  而**VNC 的滑鼠移動不會重設 DPMS 計時器**。測之前先 `xset s off -dpms`。

### 3.9 環境本身會壞掉

- **反覆重啟 session 會弄壞 overlay**(兩次 VM 失聯之後 plasmashell 就再也起不來),
  之後量到的一切都是關於那顆碟而不是關於程式碼。所以 `gfxrun.sh` 每次都從
  **golden image 開一個拋棄式 overlay**。
- **手機重開後 tap 不會自動接回 bridge**。桌面會好好地跑,但 ssh 不通,harness 判定
  「boot failed」——有一次那個 session 已經正常跑了六分鐘。`gfxrun.sh` 現在會先檢查
  `ip link show vm526795fd-0` 有沒有 `master br-wifi`。
- **絕不 `kill -9` crosvm**:洩漏的 memparcel 到手機重開才會回來,而且會偽裝成
  「並發上限」的假象。用 `devvm.sh stop`。

---

## 4. 怎麼判讀「手機在忙什麼」

`sampler.sh` 的每一行:

```
t=43528 busy=800 user=8   sys=453 irq=337 timer=627448 vm=0
t=75221 busy=716 user=297 sys=388 irq=25  timer=3126   vm=0
```

| 樣貌 | 判讀 |
|---|---|
| `user` 低、`sys`+`irq` 高、`timer` 遠超基準 | **空轉**。短 sleep 或自旋,每次 sleep 一個計時器中斷 |
| `user` 高、`timer` 接近基準 | **真工作** |
| `vm=` 後面同一個客戶端名字反覆出現 | 該客戶端的 render thread 在等,不是在解碼 |

基準:手機閒置無 VM ≈ `busy=144 timer=2400`;閒置桌面 ≈ `busy=170 timer=1800`。

實測過的極端:舊的 ring consumer 階梯讓**閒置桌面**變成 `user=8 sys=453 irq=337 timer=627448`
——手機滿載而**什麼都沒在算**。20 小時的取樣裡,手機飽和的 233 筆有 228 筆是這種。

---

## 5. 方法論(這一輪學到最貴的)

1. **先量它會不會被走到,再改它。** 我兩次改到不會執行的路徑上:seqno 的 100µs sleep 尾巴
   (1626 次等待全停在 4096 圈,尾巴永遠走不到)、以及客體的自旋門檻(vkmark 這種滿管線負載
   根本很少撞到)。兩次都是中性結果。
2. **在單行程負載上調出來的等待參數,不能套到多行程桌面。** ring consumer 的 sleep 階梯是
   在 Minecraft 上調的最佳解,套到 KDE(五個以上 Vulkan 客戶端各一條 render thread)
   就變成每秒 28.9 萬次中斷。
3. **判定函式要先對「已知好」和「已知壞」兩種狀態各驗一次。** 我的 X 探針第一版把
   「kwin 放棄重生 XWayland」誤判成「XWayland 卡住」,是 known-bad 測試抓出來的。
4. **守衛沉默有兩種可能**:它是保險,或 bug 還活著而它在遮。把防禦性補丁改成**開火時大聲回報**,
   才分得出來。
5. **不確定就別宣稱。** 有幾次我改完就說「修好了」,後來發現量的是過期二進位、或改到死碼。
   commit 訊息裡寫「measure that it changes nothing」比寫一個好聽但錯的因果好。
