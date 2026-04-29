#!/usr/bin/env bash
# =============================================================================
# tar2img.sh  ―  Yocto rootfs.tar.gz をディスクイメージ (.img) に変換する
#
# 使い方:
#   sudo bash tar2img.sh [オプション]
#
# オプション:
#   -o <path>  出力imgファイル名 (デフォルト: ./build/yocto.img)
#   -s <size>  imgサイズ MB単位 (デフォルト: 2048)
#   -h         このヘルプを表示
#
# 依存コマンド: dd, parted, mkfs.vfat, mkfs.ext4, losetup, mount, tar
#
# 生成されたimgはそのままUSBに書き込める:
#   sudo dd if=yocto.img of=/dev/sdX bs=4M status=progress && sync
#
# 注意: Yocto の WIC イメージが存在する場合はそちらの使用を推奨します。
#       rootfs.tar.gz からカスタム構成でイメージを作りたい場合に使用してください。
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────
# デフォルト設定
# ─────────────────────────────────────────────
ROOTFS_TAR="./build/yocto-rootfs.tar.gz"
DONE_FLAG="./build/FLAGS/.build_done"
OUTPUT_IMG="./build/yocto.img"
IMG_SIZE_MB=2048
MOUNT_ROOT="/mnt/yocto_img"
LOGFILE="./build/tar2img.log"

# EFI パーティション設定
EFI_SIZE_MB=100

# ─────────────────────────────────────────────
# オプション解析
# ─────────────────────────────────────────────
usage() {
    sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while getopts "o:s:h" opt; do
    case $opt in
        o) OUTPUT_IMG="$OPTARG" ;;
        s) IMG_SIZE_MB="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# ─────────────────────────────────────────────
# ログ設定
# ─────────────────────────────────────────────
mkdir -p "$(dirname "$LOGFILE")"
exec > >(tee -a "$LOGFILE") 2>&1

log()  { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
warn() { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
err()  { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; exit 1; }

echo "============================================"
log "tar2img.sh 開始"
echo "============================================"

# ─────────────────────────────────────────────
# 0. 事前確認
# ─────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
    err "root権限が必要です: sudo bash tar2img.sh"
fi

for cmd in dd parted mkfs.vfat mkfs.ext4 losetup mount tar blkid; do
    command -v "$cmd" &>/dev/null || err "必要なコマンドが見つかりません: $cmd"
done

if [[ ! -f "$ROOTFS_TAR" ]]; then
    err "${ROOTFS_TAR} が存在しません。ビルドが完了しているか確認してください。"
fi

if [[ ! -f "$DONE_FLAG" ]]; then
    warn "ビルド完了フラグ (${DONE_FLAG}) がありません。"
    read -rp "  続行しますか？ (yes/no): " WARN_CONFIRM
    [[ "$WARN_CONFIRM" == "yes" ]] || { echo "中止しました。"; exit 0; }
fi

echo ""
echo "========================================================"
echo "  出力ファイル : ${OUTPUT_IMG}"
echo "  イメージサイズ: ${IMG_SIZE_MB} MB"
echo "  rootfs      : ${ROOTFS_TAR}"
echo "========================================================"
read -rp "続行しますか？ (yes と入力して Enter): " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "中止しました。"; exit 0; }

# ─────────────────────────────────────────────
# ループデバイス管理
# ─────────────────────────────────────────────
LOOP_DEV=""
cleanup() {
    log "クリーンアップ中..."
    sync || true
    if mountpoint -q "${MOUNT_ROOT}/boot/efi" 2>/dev/null; then
        umount "${MOUNT_ROOT}/boot/efi" || true
    fi
    if mountpoint -q "${MOUNT_ROOT}" 2>/dev/null; then
        umount "${MOUNT_ROOT}" || true
    fi
    if [[ -n "${LOOP_DEV}" ]] && losetup "${LOOP_DEV}" &>/dev/null; then
        losetup -d "${LOOP_DEV}" || true
    fi
    log "クリーンアップ完了"
}
trap cleanup EXIT

# ─────────────────────────────────────────────
# 1. イメージファイル作成
# ─────────────────────────────────────────────
log "1. イメージファイル作成 (${IMG_SIZE_MB} MB)"
mkdir -p "$(dirname "$OUTPUT_IMG")"
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

# パーティション名の解決
PART1="${LOOP_DEV}p1"
PART2="${LOOP_DEV}p2"
# loopXp1 が存在しない場合は loopXp1 → loop0p1 形式
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
log "5. rootfs 展開"
mkdir -p "${MOUNT_ROOT}"
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
echo "    sudo dd if=${OUTPUT_IMG} of=/dev/sdX bs=4M status=progress && sync"
echo ""
echo "  または morning.sh を使用:"
echo "    sudo bash morning.sh"
echo "============================================"
