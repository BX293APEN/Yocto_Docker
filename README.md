# Yocto Linux ビルド on Docker

Docker 上で Yocto Linux をビルドし、
カスタム設定済みのイメージを生成して USB に焼けるプロジェクトです。

---

## 📁 ファイル構成

```
.
├── compose.yml             # Docker Compose 設定
├── Dockerfile              # Ubuntu 22.04 ベースのビルド環境
├── .env                    # 環境変数（バージョン・デバイス等）← ここを編集
├── yocto_docker.sh         # コンテナ内ビルドスクリプト（エントリーポイント）
├── tar2img.sh              # rootfs.tar.gz → .img 変換スクリプト（任意）
├── morning.sh              # USB書き込みスクリプト（ホストで実行）
└── build/                  # ビルド成果物（gitignore 推奨）
    ├── poky/               # Yocto poky リポジトリ
    ├── meta-raspberrypi/   # RPi レイヤー（rpi系デバイスのみ）
    ├── build_yocto/        # Yocto ビルドディレクトリ
    │   └── tmp/deploy/     # ビルド成果物（bitbake 出力）
    ├── downloads/          # ソースキャッシュ（再ビルド高速化）
    ├── sstate-cache/       # ビルドキャッシュ（再ビルド高速化）
    ├── images/             # コピーされた全成果物
    ├── yocto-image.wic.gz  # USB書き込み用イメージ（メイン成果物）
    ├── yocto-rootfs.tar.gz # rootfs アーカイブ
    ├── build.log           # ビルドログ
    ├── bitbake.log         # bitbake 詳細ログ
    └── FLAGS/.build_done   # ビルド完了フラグ
```

---

## ⚙️ カスタマイズ（`.env` を編集）

| 変数 | 説明 | デフォルト |
|------|------|-----------|
| `DEVICE_PROFILE` | **ターゲットデバイス**（下表参照） | `x86_64` |
| `YOCTO_RELEASE` | Yocto リリース名 | `scarthgap` |
| `CPU_CORE` | ビルド並列数 | `4` |
| `NETWORK_PROTO` | ネットワーク設定 (`dhcp`/`static`) | `dhcp` |
| `TIME_ZONE` | タイムゾーン | `Asia/Tokyo` |
| `ENABLE_SSH` | SSH サーバー有効化 | `true` |
| `ROOT_PASSWORD` | root パスワード | `password` |
| `EXTRA_PACKAGES` | 追加パッケージ（スペース区切り） | `nano` |

### DEVICE_PROFILE の選択肢

| 値 | 対象デバイス | MACHINE | 書き込み先 |
|----|-------------|---------|-----------|
| `x86_64` | PC / VM / x86 USB | genericx86-64 | USB / SSD |
| `rpi4` | Raspberry Pi 4 | raspberrypi4-64 | microSD / USB |
| `rpi3` | Raspberry Pi 3 | raspberrypi3-64 | microSD / USB |
| `qemux86_64` | QEMU 仮想マシン（動作確認用） | qemux86-64 | — |

> **MACHINE / IMAGE を直接指定したい場合**は、
> `.env` の `MACHINE=` / `IMAGE=` に直接記入すると `DEVICE_PROFILE` より優先されます。

### Yocto リリース一覧

| ブランチ名 | バージョン | サポート期間 |
|-----------|-----------|------------|
| `scarthgap` | 5.0 LTS | 2024〜2026 ← **推奨** |
| `nanbield` | 4.3 | 短期 |
| `mickledore` | 4.2 | 短期 |
| `kirkstone` | 4.0 LTS | 2022〜2024 |

---

## 🌙 ビルド手順

### 1. `.env` を編集

```bash
nano .env
```

最低限変更すべき設定:
- `DEVICE_PROFILE` — ターゲットデバイス
- `ROOT_PASSWORD` — root パスワード

### 2. ビルド開始

```bash
docker compose up --build -d
```

### 3. 進捗確認

```bash
docker logs -f Docker_Yocto
```

ビルドには **1〜数時間** かかります（初回はソースのダウンロードを含む）。

> **ヒント**: `downloads/` と `sstate-cache/` は自動的に再利用されるため、
> 2回目以降のビルドは大幅に短縮されます（数分〜30分程度）。

---

## ☀️ USB に書き込む

### 方法 A：WICイメージ（推奨）

```bash
# /dev/sdX を実際のUSBデバイスに置き換えること
gunzip -c ./build/yocto-image.wic.gz | sudo dd of=/dev/sdX bs=4M status=progress && sync
```

### 方法 B：morning.sh（対話型スクリプト）

```bash
sudo bash morning.sh
# オプション: --size <MB> でパーティションサイズを制限
```

### 方法 C：tar2img.sh でカスタムイメージ作成

```bash
sudo bash tar2img.sh
# オプション: -o 出力パス -s サイズ(MB)
```

---

## 🖥️ 動作確認（QEMU）

`DEVICE_PROFILE=qemux86_64` でビルドした場合:

```bash
# Yocto 環境でそのまま runqemu を使う方法
cd ./build/poky
source oe-init-build-env ../build_yocto
runqemu qemux86-64 nographic

# または ext4 イメージを直接起動
qemu-system-x86_64 \
    -m 512M \
    -drive file=./build/images/*rootfs.ext4,format=raw \
    -netdev user,id=net0 \
    -device e1000,netdev=net0 \
    -nographic
```

---

## 🔁 再ビルドしたい場合

```bash
rm ./build/FLAGS/.build_done
docker compose up --build -d
```

ダウンロードキャッシュも消したい場合:

```bash
rm -rf ./build/
docker compose up --build -d
```

---

## 📦 インストールされるパッケージ

3種類のベースイメージは**上位互換**です。  
`core-image-base` は `core-image-minimal` の全パッケージを含み、  
`core-image-full-cmdline` はさらにその全パッケージを含みます。

```
core-image-minimal
  └─ core-image-base（minimal の全パッケージ ＋ ハードウェアサポート）
       └─ core-image-full-cmdline（base の全パッケージ ＋ 実用CLIツール群）← デフォルト
```

---

### 🔵 core-image-minimal のパッケージ

ブートに必要な最小限のみ（`packagegroup-core-boot`）。

| パッケージ | 説明 |
|-----------|------|
| base-files | /etc, /tmp 等の基本ディレクトリ構造 |
| base-passwd | /etc/passwd, /etc/group の基本エントリ |
| busybox | ls, cat, sh, mount 等 100以上のコマンドを1バイナリに統合 |
| netbase | /etc/protocols, /etc/services 等のネットワーク設定ファイル |
| systemd | init / サービスマネージャー |
| udev | デバイスマネージャー |
| grub-efi | EFI ブートローダー（x86_64 の場合） |

> `bash` も `ip` コマンドも SSH も含まれません。本当に「起動するだけ」のイメージです。

---

### 🟡 core-image-base のパッケージ

**minimal の全パッケージ（上記すべて）＋** 以下が追加されます。

| パッケージ | 説明 |
|-----------|------|
| psplash | 起動スプラッシュスクリーン |
| kernel-modules | 該当 MACHINE のカーネルモジュール一式 |
| wpa-supplicant | WiFi 接続管理（WiFi 対応ハードウェアの場合） |
| bluez5 | Bluetooth スタック（BT 対応ハードウェアの場合） |
| setserial | シリアルポート設定（シリアル対応ハードウェアの場合） |

> `bash` や `ip` コマンドはここでも含まれません。

---

### 🟢 core-image-full-cmdline のパッケージ ← **デフォルト・推奨**

**base の全パッケージ（上記すべて）＋** 以下が追加されます。  
poky 公式ソース `packagegroup-core-full-cmdline.bb` に基づく正確な一覧です。

**基本コマンド群:**

| パッケージ | 説明 |
|-----------|------|
| bash | GNU Bash シェル（busybox の sh とは別に追加） |
| acl | アクセス制御リスト (getfacl / setfacl) |
| attr | 拡張属性 (getattr / setattr) |
| bc | 精度指定可能な電卓 |
| coreutils | ls, cp, mv, cat, chmod 等 GNU 版コアコマンド（busybox より高機能） |
| cpio | アーカイブツール |
| e2fsprogs | ext2/3/4 ファイルシステムツール (mkfs.ext4, fsck 等) |
| ed | GNU ラインエディタ |
| file | ファイル種別判定コマンド |
| findutils | find, xargs |
| gawk | GNU awk |
| grep | GNU grep |
| less | ページャー |
| makedevs | デバイスファイル作成ツール |
| mc | Midnight Commander (CUI ファイラー) |
| ncurses | ターミナル制御ライブラリ / tput 等 |
| net-tools | ifconfig, route, netstat（旧来ツール） |
| procps | ps, top, free, kill, vmstat 等 |
| psmisc | killall, fuser, pstree |
| sed | GNU sed |
| tar | GNU tar |
| time | コマンド実行時間計測 |
| util-linux | fdisk, lsblk, mount, blkid, dmesg, su 等 |

**ネットワーク・セキュリティ:**

| パッケージ | 説明 |
|-----------|------|
| iproute2 | ip コマンド（ifconfig の現代版） |
| iputils | ping, ping6, tracepath |
| iptables | ファイアウォール設定 |
| module-init-tools | modprobe, lsmod, rmmod 等 |
| openssl | SSL/TLS ライブラリ・コマンド |

**開発ツール:**

| パッケージ | 説明 |
|-----------|------|
| diffutils | diff, cmp |
| m4 | マクロプロセッサ |
| make | GNU make |
| patch | パッチ適用ツール |

**マルチユーザー管理:**

| パッケージ | 説明 |
|-----------|------|
| bzip2 | bzip2 圧縮・展開 |
| cracklib | パスワード強度チェックライブラリ |
| gzip | gzip 圧縮・展開 |
| shadow | useradd, passwd 等ユーザー管理コマンド |
| sudo | sudo コマンド |

**初期化スクリプト・システムサービス:**

| パッケージ | 説明 |
|-----------|------|
| ethtool | NIC 情報表示・設定 |
| sysklogd | syslog デーモン |
| at | ジョブスケジューラ (at コマンド) |
| cronie | cron デーモン |
| logrotate | ログローテーション |

---

### ENABLE_SSH=true のとき自動追加（エントリーポイントで自動追加）

| パッケージ | 説明 | 追加方法 |
|-----------|------|---------|
| openssh | SSH 共通ライブラリ | `IMAGE_INSTALL:append` |
| openssh-sshd | SSH サーバーデーモン | `IMAGE_INSTALL:append` |
| openssh-sftp-server | SFTP サブシステム | `IMAGE_INSTALL:append` |
| openssh-ssh | SSH クライアント | `IMAGE_INSTALL:append` |

---

### このプロジェクトで追加（EXTRA_PACKAGES）

| パッケージ | 説明 | 追加方法 |
|-----------|------|---------|
| nano | テキストエディタ | `IMAGE_INSTALL:append` |
| opkg | パッケージマネージャー（起動後の `opkg install` に必要） | `IMAGE_INSTALL:append` |
| opkg-collateral | opkg の設定ファイル群 | `IMAGE_INSTALL:append` |

> **本番環境向け**: `local.conf` の `EXTRA_IMAGE_FEATURES` から
> `debug-tweaks` を除去し、強いパスワードを設定してください。

---

## 📥 起動後に追加パッケージをインストールする

Yocto は `opkg` パッケージマネージャーを使用します。
`opkg` は `EXTRA_PACKAGES` に含まれているため、デフォルトのビルドで利用可能です。

### 基本的な使い方

```bash
# パッケージリストを更新
opkg update

# パッケージをインストール
opkg install vim
opkg install curl
opkg install python3
opkg install htop

# 複数まとめてインストール
opkg install vim curl htop

# パッケージを削除
opkg remove vim

# インストール済みパッケージ一覧
opkg list-installed

# パッケージを検索
opkg list | grep python
```

### ⚠️ 注意点

opkg はビルド時に生成されたパッケージフィードに依存します。
フィードが設定されていない場合は `opkg update` が失敗します。

その場合は **ビルド時に組み込む**のが確実です。`.env` の `EXTRA_PACKAGES` に追加して再ビルドしてください。

```bash
# .env に追加してから再ビルド
EXTRA_PACKAGES=nano vim curl htop python3
```

```bash
# 再ビルド
rm ./build/FLAGS/.build_done
docker compose up --build -d
```

---

## 🐛 トラブルシューティング

**ビルドが失敗する（パッケージが見つからない）**

```bash
# ビルドログを確認
docker logs Docker_Yocto
cat ./build/bitbake.log | tail -100
```

**YOCTO_RELEASE と MACHINE の組み合わせを確認**

```
https://wiki.yoctoproject.org/wiki/Releases
```

**ビルドが途中で止まった**

```bash
docker compose down
rm ./build/FLAGS/.build_done
docker compose up -d   # sstate-cache が再利用される
```

**RPi 向けレイヤーのブランチが見つからない**

meta-raspberrypi は Yocto のブランチ名に合わせてブランチが存在します。
`scarthgap` ブランチが存在しない場合は `.env` の `YOCTO_RELEASE` を
`kirkstone` などに変更してください。

**メモリ不足エラー**

Yocto は大量のメモリを使用します。最低 8GB 以上のRAM を推奨します。
```bash
# .env で並列数を減らす
CPU_CORE=2
```

---

## 📝 カスタムレイヤーの追加

`yocto_docker.sh` 内の以下の箇所にカスタムレイヤーを追加できます:

```bash
# yocto_docker.sh の "2. 追加レイヤー取得" セクション付近に追記
git clone --branch ${YOCTO_RELEASE} <YOUR_LAYER_REPO> /${WS}/meta-custom
```

`bblayers.conf` への登録も `_patch_bblayers` 関数で自動化されます。
