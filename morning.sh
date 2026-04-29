#!/usr/bin/env bash
# =============================================================================
# morning.sh  ―  朝起きたら実行(ホストUbuntu上で sudo bash morning.sh)
# 役割: Yocto のビルド成果物を USB / microSD に書き込む
#
# 実行前にやること:
#   1. USB または microSD を挿す
#   2. lsblk でデバイス名を確認する
#   3. sudo bash morning.sh [オプション]
#
# オプション:
#   --size <MB>   書き込み後の rootfs パーティション上限サイズ(MB単位)
#                 例: --size 8192  → 8 GB に制限
#                 例: --size 0     → デバイス全容量を使う(デフォルト)
#                 .env の USB_SIZE_MB でも指定可能(コマンドライン引数が優先)
#
# 警告: 選択したデバイスは完全消去されます！
#
# DEVICE_PROFILE に応じて書き込み方法が自動で変わります:
#   x86_64    … yocto-image.wic.gz を dd で直接書き込み
#   rpi4/rpi3 … yocto-image.wic.bz2 を dd で直接書き込み
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────
# コマンドライン引数パース
# ─────────────────────────────────────────────
_CLI_SIZE_MB=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --size)
            [[ -n "${2:-}" ]] || { echo "[ERROR] --size にはMB数を指定してください" >&2; exit 1; }
            _CLI_SIZE_MB="$2"
            shift 2
            ;;
        --size=*)
            _CLI_SIZE_MB="${1#--size=}"
            shift
            ;;
        *)
            echo "[ERROR] 不明なオプション: $1" >&2
            echo "使い方: sudo bash morning.sh [--size <MB>]" >&2
            exit 1
            ;;
    esac
done

# ─────────────────────────────────────────────
# .env の読み込み
# ─────────────────────────────────────────────
ENV_FILE="$(dirname "$0")/.env"
DEVICE_PROFILE="x86_64"
USB_SIZE_MB=0

if [[ -f "${ENV_FILE}" ]]; then
    _dp=$(grep -E '^DEVICE_PROFILE=' "${ENV_FILE}" | tail -1 | cut -d= -f2 | tr -d '"'"'" | xargs 2>/dev/null || true)
    [[ -n "${_dp}" ]] && DEVICE_PROFILE="${_dp}"

    _sz=$(grep -E '^USB_SIZE_MB=' "${ENV_FILE}" | tail -1 | cut -d= -f2 | tr -d '"'"'" | xargs 2>/dev/null || true)
    [[ -n "${_sz}" ]] && USB_SIZE_MB="${_sz}"
fi

[[ -n "${_CLI_SIZE_MB}" ]] && USB_SIZE_MB="${_CLI_SIZE_MB}"

if ! [[ "${USB_SIZE_MB}" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] USB_SIZE_MB は 0 以上の整数で指定してください: ${USB_SIZE_MB}" >&2
    exit 1
fi

# ─────────────────────────────────────────────
# パス設定
# ─────────────────────────────────────────────
BUILD_DIR="./build"
DONE_FLAG="${BUILD_DIR}/FLAGS/.build_done"
LOGFILE="${BUILD_DIR}/morning.log"
MOUNT_ROOT="/mnt/yocto"

# 成果物ファイルを検索
IMG_FILE=""
_find_image() {
    # 1. build/ 直下の yocto-image.wic.gz (x86_64)
    [[ -f "${BUILD_DIR}/yocto-image.wic.gz" ]]  && { IMG_FILE="${BUILD_DIR}/yocto-image.wic.gz";  return; }
    [[ -f "${BUILD_DIR}/yocto-image.wic.bz2" ]] && { IMG_FILE="${BUILD_DIR}/yocto-image.wic.bz2"; return; }
    # 2. build/images/ 以下を検索
    case "${DEVICE_PROFILE}" in
        x86_64)
            IMG_FILE=$(find "${BUILD_DIR}/images" -name "*.wic.gz" 2>/dev/null | head -1)
            ;;
        rpi4|rpi3)
            IMG_FILE=$(find "${BUILD_DIR}/images" -name "*.wic.bz2" 2>/dev/null | head -1)
            IMG_FILE="${IMG_FILE:-$(find "${BUILD_DIR}/images" -name "*.wic.gz" 2>/dev/null | head -1)}"
            ;;
        *)
            IMG_FILE=$(find "${BUILD_DIR}/images" \( -name "*.wic.gz" -o -name "*.wic.bz2" \) 2>/dev/null | head -1)
            ;;
    esac
}
_find_image

# ─────────────────────────────────────────────
# ログ設定
# ─────────────────────────────────────────────
mkdir -p "${BUILD_DIR}"
exec > >(tee -a "$LOGFILE") 2>&1

log()  { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
warn() { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
err()  { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; exit 1; }

echo "============================================"
log "morning.sh 開始"
echo "  DEVICE_PROFILE: ${DEVICE_PROFILE}"
echo "  イメージ      : ${IMG_FILE:-(未検出)}"
if [[ "${USB_SIZE_MB}" -eq 0 ]]; then
    echo "  容量制限      : なし(デバイス全容量を使用)"
else
    echo "  容量制限      : ${USB_SIZE_MB} MB"
fi
echo "============================================"

# ─────────────────────────────────────────────
# 0. 事前確認
# ─────────────────────────────────────────────
[[ "$EUID" -eq 0 ]] || err "root権限が必要です: sudo bash morning.sh"

if [[ ! -f "$DONE_FLAG" ]]; then
    warn "ビルド完了フラグ (${DONE_FLAG}) がありません。"
    warn "ビルドが中途半端かもしれません。"
    read -rp "  続行しますか？ (yes/no): " _c
    [[ "${_c}" == "yes" ]] || { echo "中止しました。"; exit 0; }
fi

if [[ -z "${IMG_FILE}" ]] || [[ ! -f "${IMG_FILE}" ]]; then
    err "書き込むイメージが見つかりません。\n  ${BUILD_DIR}/images/ を確認してください。\n  tar2img.sh を使用してイメージを作成することもできます。"
fi

# ─────────────────────────────────────────────
# 1. デバイス選択
# ─────────────────────────────────────────────
echo ""
echo "接続済みデバイス一覧:"
lsblk -po NAME,SIZE,LABEL,MOUNTPOINT | head -n1
lsblk -po NAME,SIZE,LABEL,MOUNTPOINT | grep -E '^(/dev/sd|/dev/nvme|/dev/mmcblk)|^[├└]' || \
    lsblk -po NAME,SIZE,LABEL,MOUNTPOINT | grep -v "^NAME"

echo ""
read -rp "書き込み先デバイスを入力してください (例: /dev/sdb): " TARGET_DEV

# 入力確認
[[ "${TARGET_DEV}" =~ ^/dev/ ]] || err "デバイスパスは /dev/ から始まる必要があります"
[[ -b "${TARGET_DEV}" ]] || err "ブロックデバイスが見つかりません: ${TARGET_DEV}"

# ルートデバイスへの書き込みを防止
ROOT_DEV=$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null | head -1 || true)
if [[ -n "${ROOT_DEV}" && "${TARGET_DEV}" == *"${ROOT_DEV}"* ]]; then
    err "危険！ルートデバイスへの書き込みは禁止されています: ${TARGET_DEV}"
fi

DEVICE_SIZE=$(lsblk -dno SIZE "${TARGET_DEV}" 2>/dev/null || echo "不明")

echo ""
echo "========================================================"
echo "  ⚠️  警告: ${TARGET_DEV} の全データが消去されます！"
echo "  デバイス : ${TARGET_DEV}"
echo "  サイズ   : ${DEVICE_SIZE}"
echo "  イメージ : ${IMG_FILE}"
echo "========================================================"
read -rp "本当に続行しますか？ (yes と入力して Enter): " FINAL_CONFIRM
[[ "${FINAL_CONFIRM}" == "yes" ]] || { echo "中止しました。"; exit 0; }

# ─────────────────────────────────────────────
# 2. デバイスのアンマウント
# ─────────────────────────────────────────────
log "マウント済みパーティションをアンマウントします"
while IFS= read -r part; do
    if mountpoint -q "${part}" 2>/dev/null; then
        log "アンマウント: ${part}"
        umount "${part}" || warn "アンマウントに失敗: ${part}"
    fi
done < <(lsblk -lnpo NAME "${TARGET_DEV}" | tail -n +2)

# ─────────────────────────────────────────────
# 3. dd で書き込み
# ─────────────────────────────────────────────
log "イメージを書き込み中..."
log "  イメージ: ${IMG_FILE}"
log "  デバイス: ${TARGET_DEV}"

case "${IMG_FILE}" in
    *.wic.gz|*.img.gz)
        gunzip -c "${IMG_FILE}" | \
            dd of="${TARGET_DEV}" bs=4M status=progress
        ;;
    *.wic.bz2|*.img.bz2)
        bunzip2 -c "${IMG_FILE}" | \
            dd of="${TARGET_DEV}" bs=4M status=progress
        ;;
    *.wic|*.img)
        dd if="${IMG_FILE}" of="${TARGET_DEV}" bs=4M status=progress
        ;;
    *)
        err "サポートされていないイメージ形式: ${IMG_FILE}"
        ;;
esac

sync
log "書き込み完了"

# ─────────────────────────────────────────────
# 4. パーティション拡張 (オプション)
# ─────────────────────────────────────────────
if [[ "${USB_SIZE_MB}" -gt 0 ]]; then
    log "rootfs パーティションを ${USB_SIZE_MB} MB に拡張します"
    partprobe "${TARGET_DEV}" 2>/dev/null || true
    sleep 1

    # 最後のパーティション番号を取得
    LAST_PART_NUM=$(parted -s "${TARGET_DEV}" print | awk '/^ [0-9]/{last=$1} END{print last}')
    if [[ -n "${LAST_PART_NUM}" ]]; then
        END_SECTOR=$(( USB_SIZE_MB * 1024 * 2 ))  # MBをセクタに変換(512byte/sector)
        parted -s "${TARGET_DEV}" resizepart "${LAST_PART_NUM}" "${USB_SIZE_MB}MiB" 2>/dev/null || \
            warn "パーティション拡張に失敗しました。手動で拡張してください。"

        # ext4 ファイルシステムの拡張
        LAST_PART_DEV="${TARGET_DEV}${LAST_PART_NUM}"
        [[ ! -b "${LAST_PART_DEV}" ]] && LAST_PART_DEV="${TARGET_DEV}p${LAST_PART_NUM}"
        if [[ -b "${LAST_PART_DEV}" ]]; then
            e2fsck -f -y "${LAST_PART_DEV}" 2>/dev/null || true
            resize2fs "${LAST_PART_DEV}" 2>/dev/null || \
                warn "ファイルシステム拡張に失敗しました。手動で resize2fs を実行してください。"
        fi
    fi
fi

# ─────────────────────────────────────────────
# 5. 完了
# ─────────────────────────────────────────────
echo ""
echo "============================================"
log "✅ USB書き込み完了！"
echo ""
echo "  デバイス: ${TARGET_DEV}"
echo "  イメージ: ${IMG_FILE}"
echo ""
echo "  USB を安全に取り外してから起動してください。"
echo "============================================"
