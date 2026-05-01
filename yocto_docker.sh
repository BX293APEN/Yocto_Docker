#!/usr/bin/env bash
# =============================================================================
# yocto_docker.sh  ―  Docker コンテナ内エントリーポイント
#
# 役割:
#   1. poky (Yocto参照ディストリビューション) を git clone
#   2. 追加レイヤー (meta-raspberrypi 等) を必要に応じて追加
#   3. local.conf / bblayers.conf をカスタマイズ
#   4. bitbake <IMAGE> でビルド
#   5. /build/yocto-rootfs.tar.gz を出力
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
# "name,url[,branch] name,url[,branch] ..." 形式
EXTRA_LAYERS="${EXTRA_LAYERS:-}"

# ── systemd ──
USE_SYSTEMD="${USE_SYSTEMD:-false}"

# ── ソースミラー ──
# スペース区切りで "元URL_パターン ミラーURL 元URL_パターン2 ミラーURL2 ..." と指定
PREMIRRORS="${PREMIRRORS:-}"
MIRRORS="${MIRRORS:-}"

# ── フェッチリトライ回数 ──
FETCH_RETRIES="${FETCH_RETRIES:-5}"

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
sudo mkdir -p "/${WS}"
sudo chmod 777 "/${WS}"
sudo chown yocto:yocto "/${WS}"

cd /${WS}
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
            IMAGE="${IMAGE:-core-image-full-cmdline}"
            EXTRA_LAYER=""
            EXTRA_LAYER_REPO=""
            IMAGE_FSTYPES_EXTRA="wic wic.bmap tar.gz"   # wic=USB直書き用, tar.gz=応用・フォールバック用
            ;;
        rpi4)
            MACHINE="${MACHINE:-raspberrypi4-64}"
            IMAGE="${IMAGE:-core-image-full-cmdline}"
            EXTRA_LAYER="meta-raspberrypi"
            EXTRA_LAYER_REPO="https://git.yoctoproject.org/meta-raspberrypi"
            IMAGE_FSTYPES_EXTRA="wic.bz2 wic.bmap tar.gz"
            ;;
        rpi3)
            MACHINE="${MACHINE:-raspberrypi3-64}"
            IMAGE="${IMAGE:-core-image-full-cmdline}"
            EXTRA_LAYER="meta-raspberrypi"
            EXTRA_LAYER_REPO="https://git.yoctoproject.org/meta-raspberrypi"
            IMAGE_FSTYPES_EXTRA="wic.bz2 wic.bmap tar.gz"
            ;;
        qemux86_64)
            MACHINE="${MACHINE:-qemux86-64}"
            IMAGE="${IMAGE:-core-image-full-cmdline}"
            EXTRA_LAYER=""
            EXTRA_LAYER_REPO=""
            IMAGE_FSTYPES_EXTRA="ext4 tar.gz"
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
sudo mkdir -p "${FLAGS_DIR}"
sudo chmod 777 "/${FLAGS_DIR}"

if [[ -f "${DONE_FLAG}" ]]; then
    log "ビルド完了フラグが存在します。ビルドをスキップします。"
    log "再ビルドするには: rm ${DONE_FLAG}"
    # 成果物が既に /build/images に存在するか確認し、なければコピーだけ実行する
    OUTPUT_DIR="/${WS}/images"
    sudo mkdir -p "${OUTPUT_DIR}"
    sudo chmod 777 "${OUTPUT_DIR}"
    _resolve_target  # MACHINE を確定させる
    # DEPLOY_DIR を動的に解決（tmp-glibc 等サフィックスに依存しない）
    BUILD_DIR_SKIP="/${WS}/build_yocto"
    DEPLOY_DIR=$(find "${BUILD_DIR_SKIP}" -type d \
        -path "*/deploy/images/${MACHINE}" 2>/dev/null | head -1 || true)
    if [[ -n "${DEPLOY_DIR}" ]]; then
        log "DEPLOY_DIR = ${DEPLOY_DIR}"
        TAR_FILE=$(find "${DEPLOY_DIR}" -name "*rootfs*.tar.gz" 2>/dev/null | head -1 || true)
        if [[ -n "${TAR_FILE}" ]]; then
            cp -v "${TAR_FILE}" "/${WS}/yocto-rootfs.tar.gz"
            log "rootfs → /${WS}/yocto-rootfs.tar.gz"
        else
            warn "rootfs.tar.gz が見つかりません。"
        fi
        find "${DEPLOY_DIR}" -maxdepth 1 -type f \
            ! -name "*.manifest" ! -name "*.json" \
            -exec cp -v {} "${OUTPUT_DIR}/" \; 2>/dev/null || true
        log "成果物を ${OUTPUT_DIR} にコピーしました"
    else
        warn "DEPLOY_DIR が見つかりません (MACHINE=${MACHINE}, BUILD_DIR=${BUILD_DIR_SKIP})"
    fi
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

# DEVICE_PROFILE 由来のレイヤーと .env の EXTRA_LAYERS を統合する
# _LAYERS_TO_CLONE は "name,url[,branch]" のスペース区切りリスト
_LAYERS_TO_CLONE=""

# DEVICE_PROFILE 由来 (例: meta-raspberrypi)
if [[ -n "${EXTRA_LAYER}" && -n "${EXTRA_LAYER_REPO}" ]]; then
    _LAYERS_TO_CLONE="${EXTRA_LAYER},${EXTRA_LAYER_REPO}"
fi

# .env の EXTRA_LAYERS を追記
if [[ -n "${EXTRA_LAYERS}" ]]; then
    _LAYERS_TO_CLONE="${_LAYERS_TO_CLONE} ${EXTRA_LAYERS}"
fi

# 重複除去しつつクローン
_SEEN_LAYERS=""
if [[ -z "${_LAYERS_TO_CLONE// /}" ]]; then
    log "追加レイヤーなし。スキップします。"
else
    for _LAYER_ENTRY in ${_LAYERS_TO_CLONE}; do
        # "name,url[,branch[,subpath]]" に分解
        _LAYER_NAME=$(  echo "${_LAYER_ENTRY}" | cut -d',' -f1)
        _LAYER_URL=$(   echo "${_LAYER_ENTRY}" | cut -d',' -f2)
        _LAYER_BRANCH=$(echo "${_LAYER_ENTRY}" | cut -d',' -f3)
        _LAYER_SUBPATH=$(echo "${_LAYER_ENTRY}" | cut -d',' -f4)
        _LAYER_BRANCH="${_LAYER_BRANCH:-${YOCTO_RELEASE}}"

        # 空エントリのスキップ
        [[ -z "${_LAYER_NAME}" || -z "${_LAYER_URL}" ]] && continue

        # 重複スキップ
        if echo "${_SEEN_LAYERS}" | grep -qw "${_LAYER_NAME}"; then
            log "${_LAYER_NAME} は既にキュー済みです。スキップします。"
            continue
        fi
        _SEEN_LAYERS="${_SEEN_LAYERS} ${_LAYER_NAME}"

        LAYER_DIR="/${WS}/${_LAYER_NAME}"
        if [[ -d "${LAYER_DIR}/.git" ]]; then
            log "${_LAYER_NAME} が既に存在します。スキップします。"
        else
            log "${_LAYER_NAME} を clone します (branch: ${_LAYER_BRANCH})"
            git clone --depth 1 \
                --branch "${_LAYER_BRANCH}" \
                "${_LAYER_URL}" \
                "${LAYER_DIR}" || \
            git clone --depth 1 \
                "${_LAYER_URL}" \
                "${LAYER_DIR}"
        fi
    done
fi

# ─────────────────────────────────────────────
# 3. ビルドディレクトリの初期化
# ─────────────────────────────────────────────
step "3. ビルドディレクトリ初期化"

BUILD_DIR="/${WS}/build_yocto"
sudo mkdir -p "${BUILD_DIR}"
sudo chmod 777 "${BUILD_DIR}"

# oe-init-build-env でビルド環境を初期化し、local.conf をクリーン生成する。
#
# 【設計方針】local.conf は毎回テンプレートから再生成して _patch_local_conf で上書きする。
#   - 再実行時の重複追記を防ぎ、完全に冪等な状態を保つ。
#   - sstate-cache / downloads はボリュームに残るのでビルドは高速に再開できる。
#   - bblayers.conf は残す（レイヤー登録が消えないように）。
log "local.conf を初期化します（oe-init-build-env）"
cd "${POKY_DIR}"
# local.conf だけ削除して oe-init-build-env に再生成させる
# source はサブシェルでは効かないため bash -c で実行
rm -f "${BUILD_DIR}/conf/local.conf"
bash -c "source oe-init-build-env ${BUILD_DIR}" || true

# ─────────────────────────────────────────────
# 4. local.conf のカスタマイズ
# ─────────────────────────────────────────────
step "4. local.conf カスタマイズ"

LOCAL_CONF="${BUILD_DIR}/conf/local.conf"

_patch_local_conf() {
    # local.conf は呼び出し前に oe-init-build-env で毎回クリーン生成済み。
    # そのためガード不要 — 全設定をシンプルに echo >> で追記する。

    # ── 基本設定 ──────────────────────────────────────────────────────────────
    sed -i "s/^MACHINE ?=.*/MACHINE ?= \"${MACHINE}\"/" "${LOCAL_CONF}"
    echo "BB_NUMBER_THREADS = \"${CPU_CORE}\""      >> "${LOCAL_CONF}"
    echo "PARALLEL_MAKE = \"-j ${CPU_CORE}\""       >> "${LOCAL_CONF}"
    echo "IMAGE_FSTYPES = \"${IMAGE_FSTYPES_EXTRA}\"" >> "${LOCAL_CONF}"
    echo "DEFAULT_TIMEZONE = \"${TIME_ZONE}\""      >> "${LOCAL_CONF}"
    echo "IMAGE_LINGUAS = \"en-us\""                >> "${LOCAL_CONF}"

    # ── grub (x86_64 のみ: grub-mkconfig 実行に必要) ─────────────────────────
    # morning.sh は chroot 内で grub-mkconfig を呼ぶため、
    # grub / grub-efi が rootfs に含まれている必要がある。
    if [[ "${MACHINE}" == "genericx86-64" ]]; then
        cat >> "${LOCAL_CONF}" << 'GRUBEOF'

# x86_64: grub-mkconfig 実行のため grub / grub-efi を組み込む
IMAGE_INSTALL:append = " grub grub-efi grub-efi-x86-64"
GRUBEOF
        log "x86_64: grub / grub-efi を IMAGE_INSTALL に追加しました"
    fi

    # ── SSH ───────────────────────────────────────────────────────────────────
    if [[ "${ENABLE_SSH}" == "true" ]]; then
        cat >> "${LOCAL_CONF}" << 'SSHEOF'

# SSH サーバー有効化
IMAGE_INSTALL:append = " openssh openssh-sshd openssh-sftp-server"
SSHEOF
    fi

    # ── 追加パッケージ ────────────────────────────────────────────────────────
    if [[ -n "${EXTRA_PACKAGES}" ]]; then
        local PKGS
        PKGS=$(echo "${EXTRA_PACKAGES}" | tr ',' ' ')
        echo "IMAGE_INSTALL:append = \" ${PKGS}\"" >> "${LOCAL_CONF}"
    fi

    # ── root パスワード (.bbclass 経由) ──────────────────────────────────────
    # BitBake の conf パーサーはシェル関数構文を解釈できないため
    # 関数定義を .bbclass に分離し、local.conf からは inherit のみ行う。
    local BBCLASS_DIR="${BUILD_DIR}/classes"
    local CUSTOM_BBCLASS="${BBCLASS_DIR}/yocto-docker-custom.bbclass"
    sudo mkdir -p "${BBCLASS_DIR}"
    sudo chmod 777 "${BBCLASS_DIR}"

    # ヒアドキュメントは '' で変数展開を抑止し、sed でプレースホルダーを置換する
    cat > "${CUSTOM_BBCLASS}" << 'BBCLASSEOF'
# yocto-docker-custom.bbclass — Docker ビルド時に自動生成

set_root_password () {
    echo "root:__ROOT_PASSWORD__" | chpasswd -R ${IMAGE_ROOTFS} 2>/dev/null || \
        sed -i "s|^root:[^:]*:|root:$(openssl passwd -6 '__ROOT_PASSWORD__'):|" \
            ${IMAGE_ROOTFS}/etc/shadow || true
}

ROOTFS_POSTPROCESS_COMMAND:append = " set_root_password;"
BBCLASSEOF
    sed -i "s|__ROOT_PASSWORD__|${ROOT_PASSWORD}|g" "${CUSTOM_BBCLASS}"

    cat >> "${LOCAL_CONF}" << EOF

# カスタマイズクラス (root パスワード / ネットワーク設定)
INHERIT += "yocto-docker-custom"
BBPATH:prepend := "${BUILD_DIR}:"
EOF

    # ── NetworkManager 検出 ───────────────────────────────────────────────────
    local _pkgs_lower
    _pkgs_lower=$(echo "${EXTRA_PACKAGES}" | tr '[:upper:]' '[:lower:]')
    local _use_nm=false
    echo "${_pkgs_lower}" | grep -qw 'networkmanager' && _use_nm=true

    # ── systemd (NM 使用時は自動有効化) ──────────────────────────────────────
    if [[ "${USE_SYSTEMD}" == "true" || "${_use_nm}" == "true" ]]; then
        cat >> "${LOCAL_CONF}" << 'SYSTEMDEOF'

# systemd を init manager として使用
DISTRO_FEATURES:append = " systemd"
VIRTUAL-RUNTIME_init_manager = "systemd"
VIRTUAL-RUNTIME_initscripts = ""
SYSTEMDEOF
    fi

    # ── NetworkManager 設定 ───────────────────────────────────────────────────
    if [[ "${_use_nm}" == "true" ]]; then
        log "NetworkManager を検出。connman 除外・NM 統合設定を追加します。"
        cat >> "${LOCAL_CONF}" << 'NMEOF'

# NetworkManager 統合設定
PACKAGE_EXCLUDE += "connman connman-client connman-gnome connman-conf"
IMAGE_INSTALL:remove = " connman connman-client connman-gnome connman-conf"
DISTRO_FEATURES:append = " networkmanager"
VIRTUAL-RUNTIME_net_manager = "networkmanager"
SYSTEMD_AUTO_ENABLE = "disable"
SYSTEMD_AUTO_ENABLE:pn-networkmanager = "enable"
NMEOF
    fi

    # ── ネットワーク設定 (static / dhcp) ─────────────────────────────────────
    if [[ "${_use_nm}" == "true" && "${NETWORK_PROTO}" == "static" ]]; then
        local PREFIX
        PREFIX=$(echo "${STATIC_NETMASK}" | awk -F. '{s=0;for(i=1;i<=4;i++){n=$i;for(j=0;j<8;j++){s+=and(n,1);n=rshift(n,1)}};print s}')
        log "NetworkManager static IP (${STATIC_IP}/${PREFIX}) をキーファイルで生成します。"
        cat >> "${CUSTOM_BBCLASS}" << 'NETEOF'

configure_network () {
    mkdir -p ${IMAGE_ROOTFS}/etc/NetworkManager/system-connections
    chmod 777 ${IMAGE_ROOTFS}/etc/NetworkManager/system-connections
    cat > ${IMAGE_ROOTFS}/etc/NetworkManager/system-connections/eth0.nmconnection << EOF
[connection]
id=eth0
type=ethernet
interface-name=eth0
autoconnect=true

[ethernet]

[ipv4]
method=manual
addresses=__STATIC_IP__/__PREFIX__
gateway=__STATIC_GATEWAY__
dns=__STATIC_DNS__

[ipv6]
method=ignore
EOF
    chmod 600 ${IMAGE_ROOTFS}/etc/NetworkManager/system-connections/eth0.nmconnection
}

ROOTFS_POSTPROCESS_COMMAND:append = " configure_network;"
NETEOF
        sed -i \
            -e "s|__STATIC_IP__|${STATIC_IP}|g" \
            -e "s|__PREFIX__|${PREFIX}|g" \
            -e "s|__STATIC_GATEWAY__|${STATIC_GATEWAY}|g" \
            -e "s|__STATIC_DNS__|${STATIC_DNS}|g" \
            "${CUSTOM_BBCLASS}"

    elif [[ "${_use_nm}" == "true" ]]; then
        log "NetworkManager DHCP 設定。キーファイルは不要です (NM デフォルト動作)。"

    elif [[ "${NETWORK_PROTO}" == "static" ]]; then
        local PREFIX
        PREFIX=$(echo "${STATIC_NETMASK}" | awk -F. '{s=0;for(i=1;i<=4;i++){n=$i;for(j=0;j<8;j++){s+=and(n,1);n=rshift(n,1)}};print s}')
        cat >> "${CUSTOM_BBCLASS}" << 'NETEOF'

configure_network () {
    mkdir -p ${IMAGE_ROOTFS}/etc/systemd/network
    chmod 777 ${IMAGE_ROOTFS}/etc/systemd/network
    cat > ${IMAGE_ROOTFS}/etc/systemd/network/10-eth0.network << EOF
[Match]
Name=eth*

[Network]
Address=__STATIC_IP__/__PREFIX__
Gateway=__STATIC_GATEWAY__
DNS=__STATIC_DNS__
EOF
    ln -sf /lib/systemd/system/systemd-networkd.service \
        ${IMAGE_ROOTFS}/etc/systemd/system/multi-user.target.wants/systemd-networkd.service 2>/dev/null || true
}

ROOTFS_POSTPROCESS_COMMAND:append = " configure_network;"
NETEOF
        sed -i \
            -e "s|__STATIC_IP__|${STATIC_IP}|g" \
            -e "s|__PREFIX__|${PREFIX}|g" \
            -e "s|__STATIC_GATEWAY__|${STATIC_GATEWAY}|g" \
            -e "s|__STATIC_DNS__|${STATIC_DNS}|g" \
            "${CUSTOM_BBCLASS}"
    else
        cat >> "${CUSTOM_BBCLASS}" << 'NETEOF'

configure_network () {
    mkdir -p ${IMAGE_ROOTFS}/etc/systemd/network
    chmod 777 ${IMAGE_ROOTFS}/etc/systemd/network
    cat > ${IMAGE_ROOTFS}/etc/systemd/network/10-eth0.network << EOF
[Match]
Name=eth*

[Network]
DHCP=yes
EOF
    ln -sf /lib/systemd/system/systemd-networkd.service \
        ${IMAGE_ROOTFS}/etc/systemd/system/multi-user.target.wants/systemd-networkd.service 2>/dev/null || true
}

ROOTFS_POSTPROCESS_COMMAND:append = " configure_network;"
NETEOF
    fi

    # ── systemd-networkd/resolved の誤指定ガード ──────────────────────────────
    if echo "${_pkgs_lower}" | grep -qE 'systemd-networkd|systemd-resolved'; then
        warn "EXTRA_PACKAGES に systemd-networkd/systemd-resolved が含まれています。USE_SYSTEMD=true を推奨します。"
        cat >> "${LOCAL_CONF}" << 'SYSTEMDEOF'

# systemd-networkd/resolved を EXTRA_PACKAGES で指定したため自動有効化
DISTRO_FEATURES:append = " systemd"
VIRTUAL-RUNTIME_init_manager = "systemd"
VIRTUAL-RUNTIME_initscripts = ""
SYSTEMDEOF
    fi

    # ── 開発用設定 ────────────────────────────────────────────────────────────
    # debug-tweaks は無効化する。
    # 有効にすると /etc/shadow の root エントリを空パスワードに強制上書きし、
    # set_root_password で設定したパスワードが消えてログイン不能になるため。
    # パスワードは set_root_password (ROOTFS_POSTPROCESS_COMMAND) で設定済み。

    # ── ソースミラー ──────────────────────────────────────────────────────────
    # .env の PREMIRRORS / MIRRORS をスペース区切りペアで指定する。
    # URL 内の特殊文字 (/ . *) がシェル展開でバグらないよう
    # ヒアドキュメント '' + sed 置換で安全に書き込む。
    _write_mirror_conf() {
        local raw="$1"       # "パターン1 URL1 パターン2 URL2 ..."
        local conf_key="$2"  # PREMIRRORS または MIRRORS

        [[ -z "${raw// /}" ]] && return

        local entries="" token_arr=()
        read -r -a token_arr <<< "${raw}"
        local i=0
        while [[ $i -lt ${#token_arr[@]} ]]; do
            local pattern="${token_arr[$i]}"
            local url="${token_arr[$((i+1))]}"
            if [[ -z "${pattern}" || -z "${url}" ]]; then
                warn "ミラー設定のペアが不完全です。スキップします: ${raw}"
                return
            fi
            entries="${entries}${pattern} ${url} \\\n"
            i=$((i+2))
        done
        log "${conf_key} を $((${#token_arr[@]}/2)) 件設定します。"

        local tmpfile; tmpfile=$(mktemp)
        cat > "${tmpfile}" << 'MIRROREOF'

# __CONF_KEY__ (.env で設定)
__CONF_KEY__ += "__ENTRIES__"
MIRROREOF
        local entries_expanded entries_escaped
        entries_expanded=$(printf '%b' "${entries}")
        entries_escaped=$(printf '%s' "${entries_expanded}" | sed 's/[&\]/\\&/g')
        sed -e "s|__CONF_KEY__|${conf_key}|g" \
            -e "s|__ENTRIES__|${entries_escaped}|g" \
            "${tmpfile}" >> "${LOCAL_CONF}"
        rm -f "${tmpfile}"
    }

    _write_mirror_conf "${PREMIRRORS}" "PREMIRRORS"
    _write_mirror_conf "${MIRRORS}"    "MIRRORS"

    # ── フェッチリトライ回数 ──────────────────────────────────────────────────
    echo "BB_FETCH_RETRIES = \"${FETCH_RETRIES}\"" >> "${LOCAL_CONF}"
    log "BB_FETCH_RETRIES = ${FETCH_RETRIES}"

    # ── ダウンロード・sstate キャッシュ ──────────────────────────────────────
    # Step7(oe-init-build-env 後)ではなくここで設定することで、
    # local.conf への追記を1箇所に集約し再実行時の重複を防ぐ。
    #
    # 【TMPDIR について】
    #   TMPDIR は local.conf に設定しない。
    #   Yocto の openembedded-core ディストロは TCLIBCAPPEND="-glibc" を持ち、
    #   TMPDIR に自動でサフィックスを付加する仕様になっている。
    #   local.conf の TCLIBCAPPEND="" で上書きしようとしても、
    #   distro の設定ファイルが後から再上書きするため効果がなく、
    #   結果として常に BUILD_DIR/tmp-glibc に出力される。
    #   そのため TMPDIR は Yocto デフォルト (BUILD_DIR/tmp-glibc) に任せ、
    #   成果物コピー(Step8)側でパスを動的に解決する設計にしている。
    local DL_DIR_CFG="/${WS}/downloads"
    local SSTATE_DIR_CFG="/${WS}/sstate-cache"
    sudo mkdir -p "${DL_DIR_CFG}" "${SSTATE_DIR_CFG}"
    sudo chmod 777 "${DL_DIR_CFG}" "${SSTATE_DIR_CFG}"
    echo "DL_DIR = \"${DL_DIR_CFG}\""         >> "${LOCAL_CONF}"
    echo "SSTATE_DIR = \"${SSTATE_DIR_CFG}\""  >> "${LOCAL_CONF}"
    log "DL_DIR    = ${DL_DIR_CFG}"
    log "SSTATE_DIR= ${SSTATE_DIR_CFG}"
    log "TMPDIR    = Yocto デフォルト (BUILD_DIR/tmp-glibc) に委譲"

    log "local.conf のカスタマイズ完了"
}
_patch_local_conf

# ─────────────────────────────────────────────
# 5. bblayers.conf への追加レイヤー登録
# ─────────────────────────────────────────────
step "5. bblayers.conf 更新"

BBLAYERS_CONF="${BUILD_DIR}/conf/bblayers.conf"

_register_layer_to_bblayers() {
    local layer_name="$1"
    local subpath="$2"   # 省略可。指定時は /{WS}/{layer_name}/{subpath} で登録
    local layer_path

    [[ -z "${layer_name}" ]] && return

    if [[ -n "${subpath}" ]]; then
        layer_path="/${WS}/${layer_name}/${subpath}"
    else
        layer_path="/${WS}/${layer_name}"
    fi

    if [[ ! -d "${layer_path}" ]]; then
        warn "レイヤーディレクトリが存在しません: ${layer_path} (スキップ)"
        return
    fi

    if grep -q "${layer_path}" "${BBLAYERS_CONF}"; then
        log "${layer_name}${subpath:+/$subpath} は既に bblayers.conf に登録済みです。"
        return
    fi

    log "bblayers.conf に ${layer_name}${subpath:+/$subpath} を追加します"
    sed -i "s|\"$|  ${layer_path} \\\\\n\"|" "${BBLAYERS_CONF}"
}

# DEVICE_PROFILE 由来のレイヤーを登録
[[ -n "${EXTRA_LAYER}" ]] && _register_layer_to_bblayers "${EXTRA_LAYER}"

# EXTRA_LAYERS を登録 (サブパスも考慮)
for _LAYER_ENTRY in ${EXTRA_LAYERS}; do
    _LAYER_NAME=$(   echo "${_LAYER_ENTRY}" | cut -d',' -f1)
    _LAYER_SUBPATH=$(echo "${_LAYER_ENTRY}" | cut -d',' -f4)
    [[ -n "${_LAYER_NAME}" ]] && _register_layer_to_bblayers "${_LAYER_NAME}" "${_LAYER_SUBPATH}"
done

# ─────────────────────────────────────────────
# 6. rootfs カスタマイズの確認ログ
# ─────────────────────────────────────────────
step "6. rootfs カスタマイズ確認"

log "ROOT_PASSWORD  : (設定済み → IMAGE_ROOTFS_POSTPROCESS_COMMAND で反映)"
log "NETWORK_PROTO  : ${NETWORK_PROTO}"
if [[ "${NETWORK_PROTO}" == "static" ]]; then
    log "STATIC_IP      : ${STATIC_IP}"
    log "STATIC_GATEWAY : ${STATIC_GATEWAY}"
    log "STATIC_DNS     : ${STATIC_DNS}"
fi
log "TIME_ZONE      : ${TIME_ZONE}"

# ─────────────────────────────────────────────
# 7. bitbake ビルド
# ─────────────────────────────────────────────
step "7. bitbake ビルド開始"

log "ビルド対象: ${IMAGE} for ${MACHINE}"
log "並列数: ${CPU_CORE}"
log "ビルドには 1〜数時間かかります (初回はダウンロードを含む)"

cd "${POKY_DIR}"
source oe-init-build-env "${BUILD_DIR}"

# ビルド実行
# 問題: set -eo pipefail 環境では "bitbake | tee" のパイプ失敗で bash が即 abort し、
#       PIPESTATUS の代入行に到達できない。
#       tee が SIGPIPE (exit 141) を返すだけでもビルド成功なのに落ちる。
# 対策: パイプ実行中だけ set +e で -e を無効化し、PIPESTATUS[0] で
#       bitbake 自身の終了コードを正確に取得してから判定する。
set +e
bitbake "${IMAGE}" 2>&1 | tee "/${WS}/bitbake.log"
BITBAKE_EXIT=${PIPESTATUS[0]}
set -e
if [[ ${BITBAKE_EXIT} -ne 0 ]]; then
    err "bitbake が失敗しました (exit ${BITBAKE_EXIT})。/${WS}/bitbake.log を確認してください。"
fi

# ─────────────────────────────────────────────
# 8. 成果物のコピーと整理
# ─────────────────────────────────────────────
step "8. 成果物コピー"

# DEPLOY_DIR の動的解決
# Yocto は TCLIBCAPPEND="-glibc" により BUILD_DIR/tmp-glibc に出力する。
# distro 設定が local.conf より優先されるため TMPDIR の固定は不可能。
# そのため find で実際に生成されたパスを探索して解決する。
DEPLOY_DIR=$(find "${BUILD_DIR}" -type d \
    -path "*/deploy/images/${MACHINE}" 2>/dev/null | head -1 || true)

if [[ -z "${DEPLOY_DIR}" ]]; then
    warn "DEPLOY_DIR が見つかりません (MACHINE=${MACHINE}, BUILD_DIR=${BUILD_DIR})"
else
    log "DEPLOY_DIR = ${DEPLOY_DIR}"
fi

OUTPUT_DIR="/${WS}/images"
sudo mkdir -p "${OUTPUT_DIR}"
sudo chmod 777 "${OUTPUT_DIR}"

# rootfs.tar.gz を /build/yocto-rootfs.tar.gz として配置 (morning.sh / tar2img.sh が参照)
TAR_FILE=$(find "${DEPLOY_DIR}" -name "*rootfs*.tar.gz" 2>/dev/null | head -1 || true)

if [[ -n "${TAR_FILE}" ]]; then
    cp -v "${TAR_FILE}" "/${WS}/yocto-rootfs.tar.gz"
    log "rootfs → /${WS}/yocto-rootfs.tar.gz"
else
    # ── フォールバック: wic を losetup + mount で tar.gz に変換 ───────────────
    # IMAGE_FSTYPES に tar.gz を指定済みだが、キャッシュヒット等で生成されなかった場合の保険。
    # ※ 旧実装の debugfs rdump はシンボリックリンクや特殊ファイルをスキップし
    #    etc/ 以下が欠落する問題があったため、losetup + mount 方式に変更。
    # ※ --partscan はコンテナ内カーネルが /dev/loopNpX を作らない場合があるため、
    #    オフセット直接指定方式（losetup --offset）を採用。udevd/partprobe 不要。
    warn "tar.gz が見つかりません。wic から tar.gz を生成します（losetup + mount）。"
    WIC_FILE=$(find "${DEPLOY_DIR}" -name "*rootfs*.wic" ! -name "*.bmap" 2>/dev/null | head -1 || true)
    if [[ -z "${WIC_FILE}" ]]; then
        err "rootfs.tar.gz も .wic も見つかりません。ビルドログを確認してください。"
    fi

    log "対象 wic: ${WIC_FILE}"

    # ── パーティションオフセットを python3 で解析（GPT / MBR 両対応）─────────
    # x86_64 wic は GPT フォーマット。python3 で GPT ヘッダを直接読み
    # 2番目のパーティション（rootfs）のバイトオフセットとサイズを取得する。
    _WIC_PARSE_SCRIPT=$(mktemp /tmp/wic_parse_XXXXXX.py)
    cat > "${_WIC_PARSE_SCRIPT}" << 'PYEOF'
import sys, struct

SECTOR = 512

with open(sys.argv[1], "rb") as f:
    f.seek(SECTOR)
    gpt_header = f.read(92)
    if gpt_header[:8] == b"EFI PART":
        part_entry_lba = struct.unpack_from("<Q", gpt_header, 72)[0]
        num_entries    = struct.unpack_from("<I", gpt_header, 80)[0]
        entry_size     = struct.unpack_from("<I", gpt_header, 84)[0]
        f.seek(part_entry_lba * SECTOR)
        entries = []
        for _ in range(num_entries):
            entry = f.read(entry_size)
            if entry[:16] == b"\x00" * 16:
                continue
            s = struct.unpack_from("<Q", entry, 32)[0]
            e = struct.unpack_from("<Q", entry, 40)[0]
            if s > 0:
                entries.append((s, e))
        entries.sort(key=lambda x: x[0])
        # 2番目=rootfs (1番目はEFI/boot)
        s, e = entries[1] if len(entries) >= 2 else entries[0] if entries else (0, 0)
        print(s * SECTOR, (e - s + 1) * SECTOR)
    else:
        f.seek(0)
        mbr = f.read(SECTOR)
        parts = []
        for i in range(4):
            e = mbr[446 + i*16: 446 + i*16 + 16]
            start = struct.unpack_from("<I", e, 8)[0]
            size  = struct.unpack_from("<I", e, 12)[0]
            if start > 0 and size > 0:
                parts.append((start, size))
        parts.sort(key=lambda x: x[0])
        s, sz = parts[1] if len(parts) >= 2 else parts[0] if parts else (0, 0)
        print(s * SECTOR, sz * SECTOR)
PYEOF

    read -r ROOTFS_OFFSET_BYTES ROOTFS_SIZE_BYTES < <(python3 "${_WIC_PARSE_SCRIPT}" "${WIC_FILE}")
    rm -f "${_WIC_PARSE_SCRIPT}"

    if [[ -z "${ROOTFS_OFFSET_BYTES}" || "${ROOTFS_OFFSET_BYTES}" == "0" ]]; then
        err "wic のパーティション情報を取得できませんでした。wic ファイルが壊れていないか確認してください。"
    fi
    log "rootfs パーティション: offset=${ROOTFS_OFFSET_BYTES} bytes, size=${ROOTFS_SIZE_BYTES} bytes"

    # ── losetup でオフセット直接指定してマウント ─────────────────────────────
    # rootfs パーティションだけを単一ループデバイスとして見せることで
    # /dev/loopNpX に依存せず Docker コンテナ内でも確実に動作する。
    LOOP_DEV=$(sudo losetup --find --show \
        --offset "${ROOTFS_OFFSET_BYTES}" \
        --sizelimit "${ROOTFS_SIZE_BYTES}" \
        "${WIC_FILE}")
    log "ループデバイス: ${LOOP_DEV} (rootfs パーティション直接マウント)"

    ROOTFS_TMP=$(mktemp -d /tmp/rootfs_extract_XXXXXX)
    sudo mount -o ro "${LOOP_DEV}" "${ROOTFS_TMP}"

    # etc/ が存在するか事前確認（マウント成功・オフセット正常の確認）
    if [[ ! -d "${ROOTFS_TMP}/etc" ]]; then
        sudo umount "${ROOTFS_TMP}"
        sudo losetup -d "${LOOP_DEV}"
        rm -rf "${ROOTFS_TMP}"
        err "マウントした rootfs に etc/ が存在しません。パーティションオフセットを確認してください。"
    fi

    log "tar.gz 生成中 (${ROOTFS_TMP} → /${WS}/yocto-rootfs.tar.gz) ..."
    # --numeric-owner: morning.sh 側の展開オプションと合わせる
    # sudo: rootfs 内に root 所有ファイルが存在するため権限昇格が必要
    sudo tar -czf "/${WS}/yocto-rootfs.tar.gz" \
        -C "${ROOTFS_TMP}" \
        --numeric-owner \
        --xattrs \
        --xattrs-include='*.*' \
        .

    # クリーンアップ
    sudo umount "${ROOTFS_TMP}"
    sudo losetup -d "${LOOP_DEV}"
    rm -rf "${ROOTFS_TMP}"

    # 所有者を yocto に戻す（後続処理や compose volume のアクセス権のため）
    sudo chown yocto:yocto "/${WS}/yocto-rootfs.tar.gz"

    log "rootfs → /${WS}/yocto-rootfs.tar.gz (wic から生成)"
fi

# 全成果物をコピー (.manifest / .json を除く)
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
echo "  rootfs            : /${WS}/yocto-rootfs.tar.gz"
echo ""
echo "  USB書き込み:"
echo "    sudo bash morning.sh"
echo "============================================"
