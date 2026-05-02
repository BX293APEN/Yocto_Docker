#!/usr/bin/env bash
# =============================================================================
# tar2img.sh  ―  yocto-rootfs.tar.gz をディスクイメージ (.img) に変換する
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
# フロー:
#   1. イメージファイル作成
#   2. GPT + EFI + rootfs パーティション作成
#   3. ループデバイス設定
#   4. フォーマット
#   5. rootfs 展開
#   6. fstab 設定
#   7. GRUB インストール (grub.cfg 生成 + chroot 内 grub-install)
#   8. アンマウント
#
# 生成された img はそのまま USB に書き込めます:
#   sudo dd if=yocto.img of=/dev/sdX bs=4M status=progress && sync
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────
# .env からWSを読む
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
    sync || true
    mountpoint -q "${MOUNT_ROOT}/boot/efi" 2>/dev/null && umount "${MOUNT_ROOT}/boot/efi" || true
    mountpoint -q "${MOUNT_ROOT}"          2>/dev/null && umount "${MOUNT_ROOT}"          || true
    [[ -n "${LOOP_DEV}" ]] && losetup "${LOOP_DEV}" &>/dev/null && losetup -d "${LOOP_DEV}" || true
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
# 2. GPT + EFI + rootfs パーティション作成
# ─────────────────────────────────────────────
log "2. パーティションテーブル作成 (GPT: EFI ${EFI_SIZE_MB}MiB + rootfs)"
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
log "4. フォーマット (EFI=vfat, rootfs=ext4)"
mkfs.vfat -F 32 -n "EFI"    "${PART1}"
mkfs.ext4 -L    "rootfs"    "${PART2}"

# ─────────────────────────────────────────────
# 5. rootfs を展開
# ─────────────────────────────────────────────
log "5. rootfs 展開中 (時間がかかります)"
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
# 7. GRUB インストール
# ─────────────────────────────────────────────
log "7. GRUB 設定・インストール"

# ── bind マウント（chroot 内 grub-install 用）────────────────
log "  bind マウント中..."
mount --types proc /proc  "${MOUNT_ROOT}/proc"
mount --rbind      /sys   "${MOUNT_ROOT}/sys"
mount --make-rslave       "${MOUNT_ROOT}/sys"
mount --rbind      /dev   "${MOUNT_ROOT}/dev"
mount --make-rslave       "${MOUNT_ROOT}/dev"
# systemd環境では /etc/resolv.conf がdangling symlinkになっているため
# シンボリックリンクを削除してから実ファイルとしてコピーする
rm -f "${MOUNT_ROOT}/etc/resolv.conf"
cp /etc/resolv.conf "${MOUNT_ROOT}/etc/resolv.conf"

# cleanup トラップを更新（bind マウントも確実に解除）
trap '
    sync || true
    umount -R "${MOUNT_ROOT}/dev"      2>/dev/null || true
    umount -R "${MOUNT_ROOT}/sys"      2>/dev/null || true
    umount    "${MOUNT_ROOT}/proc"     2>/dev/null || true
    umount    "${MOUNT_ROOT}/boot/efi" 2>/dev/null || true
    umount    "${MOUNT_ROOT}"          2>/dev/null || true
    [[ -n "${LOOP_DEV}" ]] && losetup "${LOOP_DEV}" &>/dev/null && losetup -d "${LOOP_DEV}" || true
' EXIT

# ── grub.cfg 生成（プレースホルダ→sed 方式）─────────────────
log "  grub.cfg 生成中..."
KERNEL=$(ls "${MOUNT_ROOT}/boot/vmlinuz-"* 2>/dev/null | head -1 | xargs basename 2>/dev/null || true)
if [[ -z "${KERNEL}" ]]; then
    warn "  /boot/vmlinuz-* が見つかりません。grub.cfg のカーネル行はプレースホルダのままです。"
    KERNEL="vmlinuz"
fi
log "  カーネル: ${KERNEL}  rootfs UUID: ${ROOTFS_UUID}"

INITRD_LINE=""
INITRD_FILE=$(ls "${MOUNT_ROOT}/boot/initrd-"* "${MOUNT_ROOT}/boot/initramfs-"* 2>/dev/null \
              | head -1 | xargs basename 2>/dev/null || true)
if [[ -n "${INITRD_FILE}" ]]; then
    INITRD_LINE="    initrd /boot/${INITRD_FILE}"
    log "  initrd: ${INITRD_FILE}"
fi

mkdir -p "${MOUNT_ROOT}/boot/grub"
cat > "${MOUNT_ROOT}/boot/grub/grub.cfg" << 'CFGEOF'
# /boot/grub/grub.cfg  generated by tar2img.sh (Yocto)
set default=0
set timeout=10

insmod part_gpt
insmod ext2
insmod fat

terminal_output console
terminal_input  console

menuentry "Yocto Linux" {
    set gfxpayload=text
    linux /boot/__KERNEL__ root=UUID=__ROOTFS_UUID__ rw rootfstype=ext4 rootwait rootdelay=5 nomodeset console=tty0 net.ifnames=0 biosdevname=0
__INITRD_LINE__
}

menuentry "Yocto Linux (verbose boot)" {
    set gfxpayload=text
    linux /boot/__KERNEL__ root=UUID=__ROOTFS_UUID__ rw rootfstype=ext4 rootwait rootdelay=5 nomodeset console=tty0 loglevel=7 ignore_loglevel net.ifnames=0 biosdevname=0
__INITRD_LINE__
}

menuentry "Yocto Linux (EFI framebuffer)" {
    set gfxpayload=keep
    linux /boot/__KERNEL__ root=UUID=__ROOTFS_UUID__ rw rootfstype=ext4 rootwait rootdelay=5 console=tty0 video=efifb:on net.ifnames=0 biosdevname=0
__INITRD_LINE__
}
CFGEOF

# プレースホルダを実値に置換
sed -i \
    -e "s|__KERNEL__|${KERNEL}|g" \
    -e "s|__ROOTFS_UUID__|${ROOTFS_UUID}|g" \
    -e "s|__INITRD_LINE__|${INITRD_LINE}|g" \
    "${MOUNT_ROOT}/boot/grub/grub.cfg"

log "  grub.cfg 生成完了 (linux 行確認):"
grep "linux " "${MOUNT_ROOT}/boot/grub/grub.cfg" | head -1

# ── chroot 内で grub-install ──────────────────────────────────
if [[ ! -f "${MOUNT_ROOT}/usr/bin/grub-install" ]] && \
   [[ ! -f "${MOUNT_ROOT}/usr/sbin/grub-install" ]]; then
    warn "  grub-install が rootfs に含まれていません。GRUB インストールをスキップします。"
    warn "  dd 書き込み後、ターゲット PC 上で手動実行が必要です: grub-install --target=x86_64-efi ..."
else
    log "  chroot 内で grub-install 実行中..."
    chroot "${MOUNT_ROOT}" /usr/bin/env -i \
        HOME=/root \
        PATH=/usr/bin:/usr/sbin:/bin:/sbin \
        /bin/bash << 'GRUB_EOF'
set -e

grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=yocto \
    --removable \
    --modules="part_gpt part_msdos ext2 fat normal boot linux configfile \
               search search_fs_uuid search_fs_file search_label \
               minicmd ls echo test true"

# EFI パーティションにモジュールをコピー
GRUB_MOD_SRC="/usr/lib/grub/x86_64-efi"
GRUB_MOD_DST="/boot/efi/EFI/BOOT/grub"
mkdir -p "${GRUB_MOD_DST}"
cp -r "${GRUB_MOD_SRC}/"*.mod "${GRUB_MOD_DST}/" 2>/dev/null || true
cp -r "${GRUB_MOD_SRC}/"*.lst "${GRUB_MOD_DST}/" 2>/dev/null || true
echo "[CHROOT] EFI モジュール数: $(find /boot/efi -name '*.mod' | wc -l)"
echo "[CHROOT] grub-install 完了"
GRUB_EOF

    # grub.cfg を EFI パーティションにもコピー
    cp "${MOUNT_ROOT}/boot/grub/grub.cfg" "${MOUNT_ROOT}/boot/efi/EFI/BOOT/grub.cfg"
    log "  grub.cfg → EFI パーティションにコピー完了"
    log "  最終 linux 行:"
    grep "linux " "${MOUNT_ROOT}/boot/grub/grub.cfg" | head -1
fi

# ── bind アンマウント ────────────────────────────────────────
log "  bind アンマウント..."
umount -R "${MOUNT_ROOT}/dev"  || true
umount -R "${MOUNT_ROOT}/sys"  || true
umount    "${MOUNT_ROOT}/proc" || true

# trap をシンプルなクリーンアップに戻す
trap '
    sync || true
    mountpoint -q "${MOUNT_ROOT}/boot/efi" 2>/dev/null && umount "${MOUNT_ROOT}/boot/efi" || true
    mountpoint -q "${MOUNT_ROOT}"          2>/dev/null && umount "${MOUNT_ROOT}"          || true
    [[ -n "${LOOP_DEV}" ]] && losetup "${LOOP_DEV}" &>/dev/null && losetup -d "${LOOP_DEV}" || true
' EXIT

# ─────────────────────────────────────────────
# 8. アンマウント
# ─────────────────────────────────────────────
log "8. アンマウント"
sync
umount "${MOUNT_ROOT}/boot/efi"
umount "${MOUNT_ROOT}"
losetup -d "${LOOP_DEV}"
LOOP_DEV=""

# ─────────────────────────────────────────────
# 9. 完了
# ─────────────────────────────────────────────
IMG_ACTUAL_SIZE=$(du -sh "${OUTPUT_IMG}" | cut -f1)
echo ""
echo "============================================"
log "✅ イメージ作成完了！"
echo "  出力: ${OUTPUT_IMG} (${IMG_ACTUAL_SIZE})"
echo ""
echo "  USB書き込み:"
echo "    sudo dd if=${OUTPUT_IMG} of=/dev/sdX bs=4M status=progress && sync"
echo "============================================"
