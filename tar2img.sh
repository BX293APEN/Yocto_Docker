#!/usr/bin/env bash
# =============================================================================
# tar2img.sh  ―  Yocto rootfs.tar.gz をディスクイメージ (.img) に変換する
#
# 使い方:
#   sudo bash tar2img.sh [オプション]
#
# オプション:
#   -o <path>  出力imgファイル名 (デフォルト: ./build/yocto.img)
#   -s <MB>    imgサイズ MB単位  (デフォルト: 2048)
#   -t <path>  rootfs.tar.gz のパス (デフォルト: ./build/yocto-rootfs.tar.gz)
#   -h         このヘルプを表示
#
# 依存コマンド: dd, parted, mkfs.vfat, mkfs.ext4, losetup, mount, tar, blkid
#
# 生成された img はそのまま USB に書き込めます:
#   sudo dd if=yocto.img of=/dev/sdX bs=4M status=progress && sync
#   または: sudo bash morning.sh
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────
# .env からWSを読む（パス解決に使用）
# ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
WS="build"
if [[ -f "${ENV_FILE}" ]]; then
    _ws=$(grep -E '^WS=' "${ENV_FILE}" | tail -1 | cut -d= -f2 | tr -d '"'"'" | xargs 2>/dev/null || true)
    [[ -n "${_ws}" ]] && WS="${_ws}"
fi
BUILD_DIR="${SCRIPT_DIR}/${WS}"

# ─────────────────────────────────────────────
# デフォルト設定
# ─────────────────────────────────────────────
ROOTFS_TAR="${BUILD_DIR}/yocto-rootfs.tar.gz"
DONE_FLAG="${BUILD_DIR}/FLAGS/.build_done"
OUTPUT_IMG="${BUILD_DIR}/yocto.img"
IMG_SIZE_MB=2048
MOUNT_ROOT="/mnt/yocto_img"
LOGFILE="${BUILD_DIR}/tar2img.log"
EFI_SIZE_MB=100

# ─────────────────────────────────────────────
# オプション解析
# ─────────────────────────────────────────────
usage() {
    sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while getopts "o:s:t:h" opt; do
    case $opt in
        o) OUTPUT_IMG="$OPTARG" ;;
        s) IMG_SIZE_MB="$OPTARG" ;;
        t) ROOTFS_TAR="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# ─────────────────────────────────────────────
# ログ設定
# ─────────────────────────────────────────────
mkdir -p "${BUILD_DIR}"
chmod 777 "${BUILD_DIR}"
exec > >(tee -a "${LOGFILE}") 2>&1

log()  { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
warn() { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
err()  { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; exit 1; }

echo "============================================"
log "tar2img.sh 開始"
echo "  rootfs  : ${ROOTFS_TAR}"
echo "  出力    : ${OUTPUT_IMG}"
echo "  サイズ  : ${IMG_SIZE_MB} MB"
echo "============================================"

# ─────────────────────────────────────────────
# 0. 事前確認
# ─────────────────────────────────────────────
[[ "$EUID" -eq 0 ]] || err "root権限が必要です: sudo bash tar2img.sh"

for cmd in dd parted mkfs.vfat mkfs.ext4 losetup mount tar blkid; do
    command -v "$cmd" &>/dev/null || err "必要なコマンドが見つかりません: $cmd"
done

[[ -f "${ROOTFS_TAR}" ]] || err "${ROOTFS_TAR} が存在しません。先に docker compose up --build -d でビルドしてください。"

if [[ ! -f "${DONE_FLAG}" ]]; then
    warn "ビルド完了フラグ (${DONE_FLAG}) がありません。ビルドが中途半端かもしれません。"
    read -rp "  続行しますか？ (yes/no): " _c
    [[ "${_c}" == "yes" ]] || { echo "中止しました。"; exit 0; }
fi

echo ""
echo "========================================================"
echo "  rootfs    : ${ROOTFS_TAR}"
echo "  出力img   : ${OUTPUT_IMG}"
echo "  サイズ    : ${IMG_SIZE_MB} MB"
echo "========================================================"
read -rp "続行しますか？ (yes と入力して Enter): " CONFIRM
[[ "${CONFIRM}" == "yes" ]] || { echo "中止しました。"; exit 0; }

# ─────────────────────────────────────────────
# ループデバイスのクリーンアップ trap
# ─────────────────────────────────────────────
LOOP_DEV=""
cleanup() {
    log "クリーンアップ中..."
    sync || true
    mountpoint -q "${MOUNT_ROOT}/boot/efi" 2>/dev/null && umount "${MOUNT_ROOT}/boot/efi" || true
    mountpoint -q "${MOUNT_ROOT}"          2>/dev/null && umount "${MOUNT_ROOT}"          || true
    [[ -n "${LOOP_DEV}" ]] && losetup "${LOOP_DEV}" &>/dev/null && losetup -d "${LOOP_DEV}" || true
    log "クリーンアップ完了"
}
trap cleanup EXIT

# ─────────────────────────────────────────────
# 1. イメージファイル作成
# ─────────────────────────────────────────────
log "1. イメージファイル作成 (${IMG_SIZE_MB} MB)"
mkdir -p "$(dirname "${OUTPUT_IMG}")"
chmod 777 "$(dirname "${OUTPUT_IMG}")"
dd if=/dev/zero of="${OUTPUT_IMG}" bs=1M count="${IMG_SIZE_MB}" status=progress

# ─────────────────────────────────────────────
# 2. パーティションテーブル作成 (GPT + EFI + rootfs)
# ─────────────────────────────────────────────
log "2. GPT パーティションテーブル作成"
parted -s "${OUTPUT_IMG}" \
    mklabel gpt \
    mkpart ESP fat32 1MiB "${EFI_SIZE_MB}MiB" \
    set 1 esp on \
    mkpart primary ext4 "${EFI_SIZE_MB}MiB" 100%

# ─────────────────────────────────────────────
# 3. ループデバイスに接続
# ─────────────────────────────────────────────
log "3. ループデバイス設定"
LOOP_DEV=$(losetup --find --show --partscan "${OUTPUT_IMG}")
log "ループデバイス: ${LOOP_DEV}"

PART1="${LOOP_DEV}p1"
PART2="${LOOP_DEV}p2"
if [[ ! -b "${PART1}" ]]; then
    partprobe "${LOOP_DEV}" 2>/dev/null || true
    sleep 1
fi
[[ -b "${PART1}" ]] || err "EFI パーティション ${PART1} が見つかりません"
[[ -b "${PART2}" ]] || err "rootfs パーティション ${PART2} が見つかりません"

# ─────────────────────────────────────────────
# 4. フォーマット
# ─────────────────────────────────────────────
log "4. パーティションフォーマット"
mkfs.vfat -F 32 -n "EFI"    "${PART1}"
mkfs.ext4 -L    "rootfs"    "${PART2}"

# ─────────────────────────────────────────────
# 5. rootfs を展開
# ─────────────────────────────────────────────
log "5. rootfs 展開中 (時間がかかります)"
mkdir -p "${MOUNT_ROOT}"
chmod 777 "${MOUNT_ROOT}"
mount "${PART2}" "${MOUNT_ROOT}"
mkdir -p "${MOUNT_ROOT}/boot/efi"
mount "${PART1}" "${MOUNT_ROOT}/boot/efi"

tar -xzf "${ROOTFS_TAR}" -C "${MOUNT_ROOT}" --numeric-owner
log "rootfs 展開完了"

# ─────────────────────────────────────────────
# 6. fstab 設定
# ─────────────────────────────────────────────
log "6. fstab 設定"
ROOTFS_UUID=$(blkid -s UUID -o value "${PART2}")
EFI_UUID=$(blkid -s UUID -o value "${PART1}")

cat > "${MOUNT_ROOT}/etc/fstab" << FSTABEOF
# <device>                                <mount>   <type>  <options>       <dump> <pass>
UUID=${ROOTFS_UUID}  /         ext4    defaults        0      1
UUID=${EFI_UUID}          /boot/efi vfat    defaults        0      2
tmpfs                                     /tmp      tmpfs   defaults,nodev  0      0
FSTABEOF

log "fstab 設定完了"

# ─────────────────────────────────────────────
# 7. アンマウント
# ─────────────────────────────────────────────
log "7. アンマウント"
sync
umount "${MOUNT_ROOT}/boot/efi"
umount "${MOUNT_ROOT}"
losetup -d "${LOOP_DEV}"
LOOP_DEV=""

# ─────────────────────────────────────────────
# 8. 完了
# ─────────────────────────────────────────────
IMG_ACTUAL_SIZE=$(du -sh "${OUTPUT_IMG}" | cut -f1)
echo ""
echo "============================================"
log "✅ イメージ作成完了！"
echo "  出力: ${OUTPUT_IMG} (${IMG_ACTUAL_SIZE})"
echo ""
echo "  USB書き込み:"
echo "    sudo bash morning.sh"
echo "  または直接:"
echo "    sudo dd if=${OUTPUT_IMG} of=/dev/sdX bs=4M status=progress && sync"
echo "============================================"
