#!/usr/bin/env bash
# =============================================================================
# yocto_docker.sh  ―  Docker コンテナ内エントリーポイント
#
# 役割:
#   1. poky (Yocto参照ディストリビューション) を git clone
#   2. 追加レイヤー (meta-raspberrypi 等) を必要に応じて追加
#   3. local.conf / bblayers.conf をカスタマイズ
#   4. bitbake <IMAGE> でビルド
#   5. /build/yocto-image.wic.gz (またはimg.gz) を出力
#
# 設定は .env を編集してください。スクリプト本体は変更不要です。
#
# 進捗確認 (別ターミナルで):
#   docker logs -f Docker_Yocto
# =============================================================================

set -eo pipefail

# ─────────────────────────────────────────────
# .env → compose.yml environment → ここで受け取る
# ─────────────────────────────────────────────

# ── ビルド設定 ──
YOCTO_RELEASE="${YOCTO_RELEASE:-scarthgap}"
DEVICE_PROFILE="${DEVICE_PROFILE:-x86_64}"
CPU_CORE="${CPU_CORE:-4}"
WS="${WS:-build}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"

# ── ネットワーク設定 ──
NETWORK_PROTO="${NETWORK_PROTO:-dhcp}"
STATIC_IP="${STATIC_IP:-}"
STATIC_NETMASK="${STATIC_NETMASK:-255.255.255.0}"
STATIC_GATEWAY="${STATIC_GATEWAY:-}"
STATIC_DNS="${STATIC_DNS:-8.8.8.8}"

# ── ロケール・タイムゾーン ──
TIME_ZONE="${TIME_ZONE:-Asia/Tokyo}"
LOCALE="${LOCALE:-en_US.UTF-8}"

# ── SSH ──
ENABLE_SSH="${ENABLE_SSH:-true}"
SSH_PORT="${SSH_PORT:-22}"

# ── 認証 ──
ROOT_PASSWORD="${ROOT_PASSWORD:-password}"

# ─────────────────────────────────────────────
# ログ関数
# ─────────────────────────────────────────────
LOGFILE="/${WS}/build.log"
mkdir -p "/${WS}"
exec > >(tee -a "${LOGFILE}") 2>&1

log()  { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
warn() { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
err()  { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; exit 1; }
step() { echo ""; echo "========== $* =========="; }

echo "============================================"
log "yocto_docker.sh 開始"
echo "  YOCTO_RELEASE : ${YOCTO_RELEASE}"
echo "  DEVICE_PROFILE: ${DEVICE_PROFILE}"
echo "  CPU_CORE      : ${CPU_CORE}"
echo "============================================"

# ─────────────────────────────────────────────
# DEVICE_PROFILE → MACHINE / IMAGE / EXTRA_LAYER の解決
# ─────────────────────────────────────────────
_resolve_target() {
    case "${DEVICE_PROFILE}" in
        x86_64)
            MACHINE="${MACHINE:-genericx86-64}"
            IMAGE="${IMAGE:-core-image-minimal}"
            EXTRA_LAYER=""
            EXTRA_LAYER_REPO=""
            IMAGE_FSTYPES_EXTRA="wic.gz wic.bmap"
            ;;
        rpi4)
            MACHINE="${MACHINE:-raspberrypi4-64}"
            IMAGE="${IMAGE:-core-image-minimal}"
            EXTRA_LAYER="meta-raspberrypi"
            EXTRA_LAYER_REPO="https://git.yoctoproject.org/meta-raspberrypi"
            IMAGE_FSTYPES_EXTRA="wic.bz2 wic.bmap"
            ;;
        rpi3)
            MACHINE="${MACHINE:-raspberrypi3-64}"
            IMAGE="${IMAGE:-core-image-minimal}"
            EXTRA_LAYER="meta-raspberrypi"
            EXTRA_LAYER_REPO="https://git.yoctoproject.org/meta-raspberrypi"
            IMAGE_FSTYPES_EXTRA="wic.bz2 wic.bmap"
            ;;
        qemux86_64)
            MACHINE="${MACHINE:-qemux86-64}"
            IMAGE="${IMAGE:-core-image-minimal}"
            EXTRA_LAYER=""
            EXTRA_LAYER_REPO=""
            IMAGE_FSTYPES_EXTRA="ext4"
            ;;
        *)
            err "未知の DEVICE_PROFILE: '${DEVICE_PROFILE}'" \
                "  使用可能な値: x86_64 / rpi4 / rpi3 / qemux86_64"
            ;;
    esac
}
_resolve_target

log "MACHINE       : ${MACHINE}"
log "IMAGE         : ${IMAGE}"

# ─────────────────────────────────────────────
# ビルド完了フラグの確認
# ─────────────────────────────────────────────
FLAGS_DIR="/${WS}/FLAGS"
DONE_FLAG="${FLAGS_DIR}/.build_done"
mkdir -p "${FLAGS_DIR}"

if [[ -f "${DONE_FLAG}" ]]; then
    log "ビルド完了フラグが存在します。スキップします。"
    log "再ビルドするには: rm ${DONE_FLAG}"
    exit 0
fi

# ─────────────────────────────────────────────
# 1. poky のクローン / 更新
# ─────────────────────────────────────────────
step "1. poky クローン"

POKY_DIR="/${WS}/poky"

if [[ -d "${POKY_DIR}/.git" ]]; then
    log "poky が既に存在します。fetch してブランチを確認します。"
    cd "${POKY_DIR}"
    git fetch origin
    git checkout "${YOCTO_RELEASE}" 2>/dev/null || \
        git checkout "origin/${YOCTO_RELEASE}" -b "${YOCTO_RELEASE}" || \
        warn "ブランチ ${YOCTO_RELEASE} が見つかりません。現在のブランチを使用します。"
else
    log "poky を clone します (branch: ${YOCTO_RELEASE})"
    git clone --depth 1 \
        --branch "${YOCTO_RELEASE}" \
        https://git.yoctoproject.org/poky \
        "${POKY_DIR}"
fi

# ─────────────────────────────────────────────
# 2. 追加レイヤーのクローン
# ─────────────────────────────────────────────
step "2. 追加レイヤー取得"

if [[ -n "${EXTRA_LAYER}" && -n "${EXTRA_LAYER_REPO}" ]]; then
    LAYER_DIR="/${WS}/${EXTRA_LAYER}"
    if [[ -d "${LAYER_DIR}/.git" ]]; then
        log "${EXTRA_LAYER} が既に存在します。スキップします。"
    else
        log "${EXTRA_LAYER} を clone します"
        git clone --depth 1 \
            --branch "${YOCTO_RELEASE}" \
            "${EXTRA_LAYER_REPO}" \
            "${LAYER_DIR}" || \
        git clone --depth 1 \
            "${EXTRA_LAYER_REPO}" \
            "${LAYER_DIR}"
    fi
else
    log "追加レイヤーなし。スキップします。"
fi

# ─────────────────────────────────────────────
# 3. ビルドディレクトリの初期化
# ─────────────────────────────────────────────
step "3. ビルドディレクトリ初期化"

BUILD_DIR="/${WS}/build_yocto"
mkdir -p "${BUILD_DIR}"

# oe-init-build-env でビルド環境を初期化（初回のみ conf/を生成）
if [[ ! -f "${BUILD_DIR}/conf/local.conf" ]]; then
    log "oe-init-build-env を実行します"
    cd "${POKY_DIR}"
    # source はサブシェルでは効かないため bash -c で実行
    bash -c "source oe-init-build-env ${BUILD_DIR}" || true
fi

# ─────────────────────────────────────────────
# 4. local.conf のカスタマイズ
# ─────────────────────────────────────────────
step "4. local.conf カスタマイズ"

LOCAL_CONF="${BUILD_DIR}/conf/local.conf"

_patch_local_conf() {
    # MACHINEの設定
    sed -i "s/^MACHINE ?=.*/MACHINE ?= \"${MACHINE}\"/" "${LOCAL_CONF}"

    # 並列ビルド数
    if grep -q "^BB_NUMBER_THREADS" "${LOCAL_CONF}"; then
        sed -i "s/^BB_NUMBER_THREADS.*/BB_NUMBER_THREADS = \"${CPU_CORE}\"/" "${LOCAL_CONF}"
    else
        echo "BB_NUMBER_THREADS = \"${CPU_CORE}\"" >> "${LOCAL_CONF}"
    fi
    if grep -q "^PARALLEL_MAKE" "${LOCAL_CONF}"; then
        sed -i "s/^PARALLEL_MAKE.*/PARALLEL_MAKE = \"-j ${CPU_CORE}\"/" "${LOCAL_CONF}"
    else
        echo "PARALLEL_MAKE = \"-j ${CPU_CORE}\"" >> "${LOCAL_CONF}"
    fi

    # イメージ形式
    if grep -q "^IMAGE_FSTYPES" "${LOCAL_CONF}"; then
        sed -i "s|^IMAGE_FSTYPES.*|IMAGE_FSTYPES = \"${IMAGE_FSTYPES_EXTRA}\"|" "${LOCAL_CONF}"
    else
        echo "IMAGE_FSTYPES = \"${IMAGE_FSTYPES_EXTRA}\"" >> "${LOCAL_CONF}"
    fi

    # タイムゾーン
    if grep -q "^DEFAULT_TIMEZONE" "${LOCAL_CONF}"; then
        sed -i "s|^DEFAULT_TIMEZONE.*|DEFAULT_TIMEZONE = \"${TIME_ZONE}\"|" "${LOCAL_CONF}"
    else
        echo "DEFAULT_TIMEZONE = \"${TIME_ZONE}\"" >> "${LOCAL_CONF}"
    fi

    # ロケール
    if grep -q "^IMAGE_LINGUAS" "${LOCAL_CONF}"; then
        sed -i "s/^IMAGE_LINGUAS.*/IMAGE_LINGUAS = \"en-us\"/" "${LOCAL_CONF}"
    else
        echo "IMAGE_LINGUAS = \"en-us\"" >> "${LOCAL_CONF}"
    fi

    # SSH の有効化
    if [[ "${ENABLE_SSH}" == "true" ]]; then
        if ! grep -q "openssh" "${LOCAL_CONF}"; then
            cat >> "${LOCAL_CONF}" << 'SSHEOF'

# SSH サーバー有効化
IMAGE_INSTALL:append = " openssh openssh-sshd openssh-sftp-server"
SSHEOF
        fi
    fi

    # 追加パッケージ
    if [[ -n "${EXTRA_PACKAGES}" ]]; then
        PKGS=$(echo "${EXTRA_PACKAGES}" | tr ',' ' ')
        echo "IMAGE_INSTALL:append = \" ${PKGS}\"" >> "${LOCAL_CONF}"
    fi

    # rootパスワードを空にしない設定（デバッグ用）
    if ! grep -q "EXTRA_IMAGE_FEATURES.*debug-tweaks" "${LOCAL_CONF}"; then
        echo "" >> "${LOCAL_CONF}"
        echo "# 開発用設定: rootパスワードなしログインを許可" >> "${LOCAL_CONF}"
        echo "EXTRA_IMAGE_FEATURES += \"debug-tweaks\"" >> "${LOCAL_CONF}"
    fi

    # wic用: rootfs.tar.gz 出力
    echo "IMAGE_FSTYPES:append = \" tar.gz\"" >> "${LOCAL_CONF}"

    log "local.conf のカスタマイズ完了"
}
_patch_local_conf

# ─────────────────────────────────────────────
# 5. bblayers.conf への追加レイヤー登録
# ─────────────────────────────────────────────
step "5. bblayers.conf 更新"

BBLAYERS_CONF="${BUILD_DIR}/conf/bblayers.conf"

if [[ -n "${EXTRA_LAYER}" ]]; then
    LAYER_PATH="/${WS}/${EXTRA_LAYER}"
    if ! grep -q "${LAYER_PATH}" "${BBLAYERS_CONF}"; then
        log "bblayers.conf に ${EXTRA_LAYER} を追加します"
        # BBLAYERS += の末尾に追加
        sed -i "s|^\(BBLAYERS ?= \"\)|BBLAYERS ?= \"\\\n  ${LAYER_PATH} \\\\\n\"|" "${BBLAYERS_CONF}" || \
            echo "  ${LAYER_PATH} \\" >> "${BBLAYERS_CONF}"
    fi
fi

# ─────────────────────────────────────────────
# 6. rootfs カスタマイズ用スクリプトの準備
# ─────────────────────────────────────────────
step "6. rootfs カスタマイズ"

CUSTOM_RECIPE_DIR="${POKY_DIR}/meta/recipes-custom"
CUSTOM_INIT_SCRIPT="${BUILD_DIR}/conf/yocto-custom-init.sh"

# ネットワーク設定スクリプト（ビルド後に wic 内に配置）
cat > "${CUSTOM_INIT_SCRIPT}" << INITEOF
#!/bin/sh
# Yocto カスタム初期化スクリプト
# このスクリプトは直接 rootfs には注入されません。
# local.conf の IMAGE_ROOTFS_POSTPROCESS_COMMAND で呼び出すか、
# カスタムレイヤーのレシピ内で配置してください。
# 詳細は README.md を参照してください。

# rootパスワード設定
echo "root:${ROOT_PASSWORD}" | chpasswd 2>/dev/null || \
    echo "root:$(openssl passwd -6 '${ROOT_PASSWORD}')" | chpasswd -e 2>/dev/null || true

# タイムゾーン設定
echo "${TIME_ZONE}" > /etc/timezone
ln -sf /usr/share/zoneinfo/${TIME_ZONE} /etc/localtime 2>/dev/null || true

# ネットワーク設定(systemd-networkd想定)
NETCONF=/etc/systemd/network/10-eth0.network
mkdir -p /etc/systemd/network

if [ "${NETWORK_PROTO}" = "static" ]; then
    cat > "\${NETCONF}" << EOF
[Match]
Name=eth*

[Network]
Address=${STATIC_IP}/$(echo "${STATIC_NETMASK}" | awk -F. '{sum=0; for(i=1;i<=4;i++) {n=\$i; for(j=0;j<8;j++){sum+=and(n,1); n=rshift(n,1)}}; print sum}')
Gateway=${STATIC_GATEWAY}
DNS=${STATIC_DNS}
EOF
else
    cat > "\${NETCONF}" << EOF
[Match]
Name=eth*

[Network]
DHCP=yes
EOF
fi
INITEOF
chmod +x "${CUSTOM_INIT_SCRIPT}"
log "カスタム初期化スクリプトを生成: ${CUSTOM_INIT_SCRIPT}"

# ─────────────────────────────────────────────
# 7. bitbake ビルド
# ─────────────────────────────────────────────
step "7. bitbake ビルド開始"

log "ビルド対象: ${IMAGE} for ${MACHINE}"
log "並列数: ${CPU_CORE}"
log "ビルドには 1〜数時間かかります (初回はダウンロードを含む)"

cd "${POKY_DIR}"
source oe-init-build-env "${BUILD_DIR}"

# ダウンロードキャッシュ共有 (ホストの ./build/downloads を使い回す)
DL_DIR="/${WS}/downloads"
SSTATE_DIR="/${WS}/sstate-cache"
mkdir -p "${DL_DIR}" "${SSTATE_DIR}"
echo "DL_DIR = \"${DL_DIR}\""         >> "${LOCAL_CONF}"
echo "SSTATE_DIR = \"${SSTATE_DIR}\"" >> "${LOCAL_CONF}"

# ビルド実行
bitbake "${IMAGE}" 2>&1 | tee "/${WS}/bitbake.log"

# ─────────────────────────────────────────────
# 8. 成果物のコピーと整理
# ─────────────────────────────────────────────
step "8. 成果物コピー"

DEPLOY_DIR="${BUILD_DIR}/tmp/deploy/images/${MACHINE}"
OUTPUT_DIR="/${WS}/images"
mkdir -p "${OUTPUT_DIR}"

# wic.gz (x86_64) または wic.bz2 (rpi)
WIC_FILE=$(find "${DEPLOY_DIR}" -name "*.wic.gz" -o -name "*.wic.bz2" 2>/dev/null | head -1)
TAR_FILE=$(find "${DEPLOY_DIR}" -name "*rootfs*.tar.gz" 2>/dev/null | head -1)

if [[ -n "${WIC_FILE}" ]]; then
    cp -v "${WIC_FILE}" "/${WS}/yocto-image.wic.gz"
    log "WICイメージ → /${WS}/yocto-image.wic.gz"
else
    warn "WICイメージが見つかりません。"
fi

if [[ -n "${TAR_FILE}" ]]; then
    cp -v "${TAR_FILE}" "/${WS}/yocto-rootfs.tar.gz"
    log "rootfs → /${WS}/yocto-rootfs.tar.gz"
fi

# 全成果物をコピー
find "${DEPLOY_DIR}" -maxdepth 1 -type f \
    ! -name "*.manifest" \
    ! -name "*.json" \
    -exec cp -v {} "${OUTPUT_DIR}/" \; 2>/dev/null || true

log "成果物を ${OUTPUT_DIR} にコピーしました"

# ─────────────────────────────────────────────
# 9. 完了フラグ
# ─────────────────────────────────────────────
touch "${DONE_FLAG}"

echo ""
echo "============================================"
log "✅ ビルド完了！"
echo ""
echo "  成果物ディレクトリ: /${WS}/images/"
echo "  WICイメージ       : /${WS}/yocto-image.wic.gz"
echo "  rootfs            : /${WS}/yocto-rootfs.tar.gz"
echo ""
echo "  USB書き込み:"
echo "    gunzip -c yocto-image.wic.gz | sudo dd of=/dev/sdX bs=4M status=progress && sync"
echo ""
echo "  または:"
echo "    sudo bash morning.sh"
echo "============================================"
