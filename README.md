# Droidvm Build

DroidVM 的 meta repo：建置流程、跨 repo 文件、guest kernel 補丁。
每個元件都是獨立的 Droid-VM repo；這個資料夾是把它們串起來的工作區
（子 repo 的資料夾都在 .gitignore 裡）。

## 分支

分支分兩種。`lib_branch.sh` 對每個元件都沿著 **開發 → 穩定** 這條鏈解析：

| 分支 | 在哪 | 是什麼 |
|---|---|---|
| `<本 repo 的分支>` | 本 repo + 這項工作有動到的元件 | 開發線：元件要參與某項工作，就開一個和 meta repo 同名的分支 |
| `droidvm` | 每個 Droid-VM repo | 穩定分支，全 org 統一用這個名字 |
| `master` | 只有 `DroidVM`（app） | app 的穩定分支，唯一的例外，在 `6_build_apk_prepare.sh` 處理 |

這項工作沒動到的元件，自然就沒有同名分支，於是用它的穩定分支建置；
soong fork 兩者都沒有的話，維持 manifest 的 revision。
既有的 checkout 只會被回報，絕不會被悄悄切換（`REPO_SWITCH=1` 才會切）。

## 流程

1_.sh 一路跑到 9_.sh ，跑完就能拿到全部的元件，含 apk 和 linux 驅動等等

1_ 先跑
先等 1_ 跑完，2_ 3_ 4_ 5_ 可以同時跑
6_ 7_ 按順序跑
8_ 9_ 沒依賴，可以同時跑

| 步驟 | 腳本 | 做什麼 |
|---|---|---|
| 1 | `1_build_crosvm_prepare.sh` | 用 manifest repo-sync crosvm 的 soong tree，再把每個 Droid-VM fork 沿分支鏈 checkout（含 `mesa`、`mesa-cross`） |
| 2 | `2_build_crosvm.sh` | 為裝置編譯 crosvm（+ gfxstream/virglrenderer） |
| 2-1 | `2-1_collect_crosvm.sh` | 把 crosvm 和它連結的 .so 收進 `crosvm_out/`（步驟 2 會呼叫） |
| 2-2 | `2-2_crosvm_out_to_adb.sh` | 把 `crosvm_out/` 推到裝置上手動測試 |
| 2-3 | `2-3_crosvm_run_ubuntu.sh` | 在裝置上跑手動測試用的 VM |
| 3 | `3_build_edk2.sh` | 編譯 EDK2 韌體（`edk2-gunyah && ./build.sh -DPCI_CAM_MODE=FALSE`） |
| 4 | `4_build_gunyah_host.sh` | 針對每個 GKI KMI 編譯 host 模組（host-share、kvcalloc、gh_unmovable、udmabuf）→ `gunyah_host_mod/dist/` |
| 5 | `5_prepare_turnip.sh` | 編譯 host 端 turnip Vulkan 驅動（Droid-VM/Banners-Turnip：pin 住的上游 mesa + patch，走 KGSL）→ `turnip/libvulkan_freedreno.so` |
| 6 | `6_build_apk_prepare.sh` | clone app + prebuilt-root，把 crosvm/EDK2/gunyah/turnip 的產物疊進 `manual-build/` |
| 7 | `7_build_apk.sh` | 用本機 prebuilt 打包 DroidVM APK |
| 8 | `8_build_guest_mesa.sh` | 編譯 guest mesa：一個套件包含三條路線（在容器裡交叉編譯，recipe 來自 `mesa-cross/`） |
| 9 | `9_build_guest_addition.sh` | 把 guest kernel 模組打成 DKMS .deb |

請按 1 到 9 的順序跑：後面的腳本會吃前面的產物（步驟 6 把步驟 2 編出的
crosvm 拉進 app 專案，步驟 7 打包出去）。最終產物是 host 端 APK（步驟 7）
和兩個 guest 端 `.deb`（步驟 8、9，放在 `dist-guest/`）。

建置產物（crosvm 步驟 2、EDK2 步驟 3、gunyah 模組步驟 4、turnip 步驟 5）
各自留在自己的元件目錄

步驟 6 是唯一把它們全部收進 `manual-build/` ，覆蓋掉 prebuilt ，之後打包 APK。



## 裝置

手機透過 OpenWrt 路由器 `10.53.12.1` 用 adb 連線，每台手機轉發一個 port：

| 路由器 | 手機（host） |
|---|---|
| `10.53.12.1:5566` | `192.168.40.11:5566` |
| `10.53.12.1:5567` | `192.168.40.12:5567` |
| `10.53.12.1:5568` | `192.168.40.13:5568` |

app daemon 啟動時會載入 kernel 模組並拉起 `br-wifi`。橋接已經設定好；
若損毀就重設。它基於 pseudo-bridge-rs，所以跑起來的 VM 位址會出現在手機
自己的 `wlan0` 上，帶 `nodad` 旗標，靠這個旗標分辨代理上去的 VM 位址和手機
本身的位址（VM 沒開機時那裡就沒有）：

adb -s 10.53.12.1:5566 shell "ip addr show wlan0" nodad 就是 vm ipv6，ssh key 已經設定好，直接 ssh root 連線過去


