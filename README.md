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
| `EXTRA_PACKAGES` | 追加パッケージ（スペース区切り） | 空 |

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

## 📦 デフォルトで含まれる機能

`core-image-minimal` ベース:

| カテゴリ | 内容 |
|---------|------|
| システム | systemd, udev |
| SSH | OpenSSH サーバー（ENABLE_SSH=true の場合） |
| ネットワーク | systemd-networkd, DHCP または静的IP |
| タイムゾーン | Asia/Tokyo（.env で変更可能） |
| デバッグ | debug-tweaks（rootパスワードなしログイン可） |

> **本番環境向け**: `local.conf` の `EXTRA_IMAGE_FEATURES` から
> `debug-tweaks` を除去し、強いパスワードを設定してください。

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
