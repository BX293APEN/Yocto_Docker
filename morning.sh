#!/usr/bin/env bash
# =============================================================================
# morning.sh  ―  朝起きたら実行 (ホスト Ubuntu 上で sudo bash morning.sh)
# 役割: yocto-rootfs.tar.gz を展開して起動可能な USB / microSD を作成する
#
# 実行前にやること:
#   1. USB または microSD を挿す
#   2. lsblk でデバイス名を確認する
#   3. sudo bash morning.sh [オプション]
#
# オプション:
#   --size <MB>   rootfs パーティションの上限サイズ(MB単位)
#                 例: --size 8192  → 8 GB に制限
#                 例: --size 0     → デバイス全容量を使う(デフォルト)
#                 .env の USB_SIZE_MB でも指定可能(コマンドライン引数が優先)
#
# 警告: 選択したデバイスは完全消去されます！
#
# フロー:
#   1. yocto-rootfs.tar.gz の確認
#   2. デバイス選択・確認
#   3. GPT + EFI + rootfs パーティション作成
#   4. rootfs 展開
#   5. fstab 設定
#   6. GRUB インストール (x86_64 のみ: grub.cfg 生成 + chroot 内 grub-install)
#   7. アンマウント
# =============================================================================
# ─────────────────────────────────────────────
# ★ 起動デバイス設定
#   ターゲットPCでUSBが sda として認識される場合 → BOOT_DEVICE=sda
#   内蔵ディスクがある場合USBが sdb になるケースあり → BOOT_DEVICE=sdb
#   起動しない場合はここを書き換えて morning.sh を再実行してください
# ─────────────────────────────────────────────
BOOT_DEVICE=sda

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
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
DEVICE_PROFILE="x86_64"
USB_SIZE_MB=0
WS="build"

if [[ -f "${ENV_FILE}" ]]; then
    _dp=$(grep -E '^DEVICE_PROFILE=' "${ENV_FILE}" | tail -1 | cut -d= -f2 | tr -d '"'"'" | xargs 2>/dev/null || true)
    [[ -n "${_dp}" ]] && DEVICE_PROFILE="${_dp}"

    _sz=$(grep -E '^USB_SIZE_MB=' "${ENV_FILE}" | tail -1 | cut -d= -f2 | tr -d '"'"'" | xargs 2>/dev/null || true)
    [[ -n "${_sz}" ]] && USB_SIZE_MB="${_sz}"

    _ws=$(grep -E '^WS=' "${ENV_FILE}" | tail -1 | cut -d= -f2 | tr -d '"'"'" | xargs 2>/dev/null || true)
    [[ -n "${_ws}" ]] && WS="${_ws}"
fi

# コマンドライン引数は .env より優先
[[ -n "${_CLI_SIZE_MB}" ]] && USB_SIZE_MB="${_CLI_SIZE_MB}"

if ! [[ "${USB_SIZE_MB}" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] USB_SIZE_MB は 0 以上の整数で指定してください: ${USB_SIZE_MB}" >&2
    exit 1
fi

# ─────────────────────────────────────────────
# パス設定
# ─────────────────────────────────────────────
BUILD_DIR="${SCRIPT_DIR}/${WS}"
DONE_FLAG="${BUILD_DIR}/FLAGS/.build_done"
LOGFILE="${BUILD_DIR}/morning.log"
ROOTFS_TAR="${BUILD_DIR}/yocto-rootfs.tar.gz"
MOUNT_ROOT="/mnt/yocto"
EFI_SIZE_MB=512

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
log "morning.sh 開始"
echo "  DEVICE_PROFILE: ${DEVICE_PROFILE}"
echo "  rootfs        : ${ROOTFS_TAR}"
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

for cmd in dd parted mkfs.vfat mkfs.ext4 losetup mount tar blkid partprobe; do
    command -v "$cmd" &>/dev/null || err "必要なコマンドが見つかりません: $cmd (apt install util-linux parted dosfstools e2fsprogs)"
done

if [[ ! -f "${DONE_FLAG}" ]]; then
    warn "ビルド完了フラグ (${DONE_FLAG}) がありません。"
    warn "ビルドが中途半端かもしれません。"
    read -rp "  続行しますか？ (yes/no): " _c
    [[ "${_c}" == "yes" ]] || { echo "中止しました。"; exit 0; }
fi

[[ -f "${ROOTFS_TAR}" ]] || \
    err "rootfs が見つかりません: ${ROOTFS_TAR}\n  先に docker compose up --build -d でビルドしてください。"

# ─────────────────────────────────────────────
# 1. デバイス選択
# ─────────────────────────────────────────────
echo ""
echo "接続済みデバイス一覧:"
lsblk -po NAME,SIZE,LABEL,MOUNTPOINT | head -n1
lsblk -po NAME,SIZE,LABEL,MOUNTPOINT | grep -E '^(/dev/sd|/dev/nvme|/dev/mmcblk)|^[├└]' || \
    lsblk -po NAME,SIZE,LABEL,MOUNTPOINT | grep -v "^NAME"

echo ""
case "${DEVICE_PROFILE}" in
    rpi*)  echo -n "microSD / USB デバイス (例: sdb または /dev/sdb または mmcblk0): " ;;
    *)     echo -n "USB デバイス (例: sdb または /dev/sdb): " ;;
esac
read -r INPUT

# /dev/ 付きでも無しでもOK
TARGET_DEV="/dev/${INPUT#/dev/}"

[[ -b "${TARGET_DEV}" ]] || err "${TARGET_DEV} が見つかりません。lsblk でデバイス名を確認してください。"

# 安全確認: ルートデバイスへの書き込みを防止
ROOT_DEV=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//' | sed 's/p[0-9]*$//')
if [[ "${TARGET_DEV}" == "${ROOT_DEV}" ]]; then
    err "危険！ルートデバイス (${ROOT_DEV}) への書き込みは禁止されています。"
fi

DEVICE_SIZE=$(lsblk -dno SIZE "${TARGET_DEV}" 2>/dev/null || echo "不明")

echo ""
echo "========================================================"
echo "  ⚠️  警告: ${TARGET_DEV} の全データが消去されます！"
echo "  デバイス : ${TARGET_DEV}"
echo "  サイズ   : ${DEVICE_SIZE}"
echo "  rootfs   : ${ROOTFS_TAR}"
if [[ "${USB_SIZE_MB}" -eq 0 ]]; then
    echo "  rootfs容量: デバイス全容量(制限なし)"
else
    echo "  rootfs容量: ${USB_SIZE_MB} MB に制限"
fi
echo "========================================================"
read -rp "本当に続行しますか？ (yes と入力して Enter): " FINAL_CONFIRM
[[ "${FINAL_CONFIRM}" == "yes" ]] || { echo "中止しました。"; exit 0; }

# ─────────────────────────────────────────────
# 2. デバイスのアンマウント
# ─────────────────────────────────────────────
log "マウント済みパーティションをアンマウントします"
for part in "${TARGET_DEV}"?* "${TARGET_DEV}"; do
    [[ -b "$part" ]] || continue
    mp=$(lsblk -no MOUNTPOINT "$part" 2>/dev/null || true)
    if [[ -n "$mp" ]]; then
        umount "$mp" && log "  アンマウント: $part ($mp)"
    fi
done

# ─────────────────────────────────────────────
# 3. パーティションテーブル作成 (GPT + EFI + rootfs)
# ─────────────────────────────────────────────
log "3. GPT パーティションテーブル作成"

if [[ "${USB_SIZE_MB}" -gt 0 ]]; then
    ROOTFS_END="${USB_SIZE_MB}MiB"
else
    ROOTFS_END="100%"
fi

parted -s "${TARGET_DEV}" \
    mklabel gpt \
    mkpart ESP fat32 1MiB "${EFI_SIZE_MB}MiB" \
    set 1 esp on \
    mkpart primary ext4 "${EFI_SIZE_MB}MiB" "${ROOTFS_END}"

# カーネルにパーティションテーブルの変更を通知して完全に認識させる
sync
partprobe "${TARGET_DEV}" 2>/dev/null || true
udevadm settle --timeout=30 || true

# パーティションデバイス名の解決 (/dev/sdb1 or /dev/nvme0n1p1 or /dev/mmcblk0p1)
if [[ "${TARGET_DEV}" =~ (nvme|mmcblk) ]]; then
    PART1="${TARGET_DEV}p1"
    PART2="${TARGET_DEV}p2"
else
    PART1="${TARGET_DEV}1"
    PART2="${TARGET_DEV}2"
fi

# パーティションが実際に出現するまで最大10秒待つ
log "  パーティション出現待ち: ${PART1} ${PART2}"
for _i in $(seq 1 10); do
    [[ -b "${PART1}" ]] && [[ -b "${PART2}" ]] && break
    sleep 1
done
[[ -b "${PART1}" ]] || err "EFI パーティション ${PART1} が見つかりません"
[[ -b "${PART2}" ]] || err "rootfs パーティション ${PART2} が見つかりません"

# ─────────────────────────────────────────────
# 4. フォーマット
# ─────────────────────────────────────────────
log "4. パーティションフォーマット"
mkfs.vfat -F 32 -n "EFI"    "${PART1}"
mkfs.ext4 -F   -L "rootfs"  "${PART2}"

# フォーマット後にカーネルのデバイス認識と書き込みキャッシュを同期する
sync
udevadm settle --timeout=10 || true
sleep 1

# ─────────────────────────────────────────────
# 5. rootfs 展開
# ─────────────────────────────────────────────
log "5. rootfs 展開中 (時間がかかります)"
mkdir -p "${MOUNT_ROOT}"
mount "${PART2}" "${MOUNT_ROOT}"
# マウント後にext4ルートのパーミッションを設定する（マウント前のchmodは無意味）
chmod 755 "${MOUNT_ROOT}"
mkdir -p "${MOUNT_ROOT}/boot/efi"
mount "${PART1}" "${MOUNT_ROOT}/boot/efi"

tar -xzf "${ROOTFS_TAR}" \
    --xattrs-include='*.*' \
    --numeric-owner \
    -C "${MOUNT_ROOT}"
log "rootfs 展開完了"

# ─────────────────────────────────────────────
# 6. fstab 設定
# ─────────────────────────────────────────────
log "6. fstab 設定"
ROOTFS_UUID=$(blkid -s UUID -o value "${PART2}")
EFI_UUID=$(blkid -s UUID -o value "${PART1}")
log "  UUID: ROOT=${ROOTFS_UUID} EFI=${EFI_UUID}"

cat > "${MOUNT_ROOT}/etc/fstab" << FSTABEOF
# <device>                                <mount>   <type>  <options>       <dump> <pass>
UUID=${ROOTFS_UUID}  /         ext4    defaults        0      1
UUID=${EFI_UUID}          /boot/efi vfat    defaults        0      2
tmpfs                                     /tmp      tmpfs   defaults,nodev  0      0
FSTABEOF

log "fstab 設定完了"

# ─────────────────────────────────────────────
# 7. GRUB インストール (x86_64 のみ)
# ─────────────────────────────────────────────
if [[ "${DEVICE_PROFILE}" == "x86_64" ]]; then
    log "7. GRUB 設定・インストール (x86_64)"

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
    ' EXIT

    # ── /boot の内容を事前確認 ───────────────────────────────────
    log "  /boot の内容確認:"
    ls -la "${MOUNT_ROOT}/boot/" 2>/dev/null || warn "  /boot が空です"

    # ── grub-install + grub-mkconfig ─────────────────────────────
    # 優先順位:
    #   1. rootfs 内の grub-install を chroot で実行（.env に grub を追加した場合）
    #   2. ホスト側の grub-install を直接実行（フォールバック）
    #      → ホストに grub-efi-amd64-bin が必要: sudo apt install grub-efi-amd64-bin grub-common
    # grub-mkconfig は常に chroot 内で実行してカーネルを自動検出する。

    ROOTFS_GRUB_INSTALL=""
    for _p in usr/bin/grub-install usr/sbin/grub-install; do
        if [[ -f "${MOUNT_ROOT}/${_p}" ]]; then
            ROOTFS_GRUB_INSTALL="/${_p}"
            break
        fi
    done

    if [[ -n "${ROOTFS_GRUB_INSTALL}" ]]; then
        # ── パターン1: rootfs 内の grub-install を chroot で実行 ──
        log "  grub-install 実行中 (chroot: ${ROOTFS_GRUB_INSTALL})..."
        chroot "${MOUNT_ROOT}" /usr/bin/env -i \
            HOME=/root \
            PATH=/usr/bin:/usr/sbin:/bin:/sbin \
            GRUB_INSTALL_BIN="${ROOTFS_GRUB_INSTALL}" \
            /bin/bash << 'GRUB_INSTALL_EOF'
set -e
${GRUB_INSTALL_BIN} \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --boot-directory=/boot \
    --bootloader-id=yocto \
    --removable \
    --no-nvram
echo "[CHROOT] grub-install 完了"
GRUB_INSTALL_EOF
        log "  grub-install (chroot) 完了"

    elif command -v grub-install &>/dev/null && \
         [[ -d /usr/lib/grub/x86_64-efi ]]; then
        # ── パターン2: ホスト側の grub-install を直接実行 ──────────
        log "  grub-install 実行中 (ホスト側フォールバック)..."
        grub-install \
            --target=x86_64-efi \
            --efi-directory="${MOUNT_ROOT}/boot/efi" \
            --boot-directory="${MOUNT_ROOT}/boot" \
            --bootloader-id=yocto \
            --removable \
            --no-nvram
        log "  grub-install (ホスト) 完了"

    else
        err "  grub-install が見つかりません。\n  対処法A（推奨）: .env の EXTRA_PACKAGES に grub を追加して再ビルド\n  対処法B（即時）: sudo apt install grub-efi-amd64-bin grub-common"
    fi

    # ── カーネルファイル名の検索 ─────────────────────────────────
    # Yocto は bzImage がシンボリックリンク → 実体ファイル名を使う
    KERNEL=""
    for _pat in "bzImage" "bzImage-"* "vmlinuz" "vmlinuz-"* "zImage" "Image"; do
        _found=$(ls "${MOUNT_ROOT}/boot/${_pat}" 2>/dev/null | head -1 || true)
        if [[ -n "${_found}" && -e "${_found}" ]]; then
            if [[ -L "${_found}" ]]; then
                _found="$(readlink -f "${_found}")"
            fi
            KERNEL="$(basename "${_found}")"
            break
        fi
    done
    [[ -n "${KERNEL}" ]] || err "/boot/ にカーネルが見つかりません: $(ls ${MOUNT_ROOT}/boot/)"
    log "  カーネル: ${KERNEL}"

    # ── grub.cfg をデバイス名方式で生成し全箇所に書き込む ──────
    # 【重要】Yoctoはinitramfsを持たないため、起動時にUUIDでrootfsを
    # 探すことができず "unknown-block(0,0)" カーネルパニックになる。
    # LFSと同じく /dev/${BOOT_DEVICE}2 のデバイス名直指定方式を使う。
    # BOOT_DEVICE はスクリプト冒頭で設定（デフォルト: sda）。
    # Yoctoが自動生成する /boot/EFI/BOOT/grub.cfg も必ず上書きする。
    log "  grub.cfg 生成中 (root=/dev/${BOOT_DEVICE}2)..."

    mkdir -p "${MOUNT_ROOT}/boot/grub"
    cat > "${MOUNT_ROOT}/boot/grub/grub.cfg" << 'CFGEOF'
# grub.cfg  generated by morning.sh (Yocto)
# root はデバイス名直指定（initramfsなし環境ではUUID不可）
# 起動しない場合は冒頭の BOOT_DEVICE を書き換えて再実行してください
set default=0
set timeout=5

insmod part_gpt
insmod ext2
insmod fat

terminal_output console
terminal_input  console

menuentry "Yocto Linux" {
    set gfxpayload=text
    linux /boot/__KERNEL__ root=/dev/__BOOT_DEVICE__2 rw rootfstype=ext4 rootwait rootdelay=10 nomodeset console=tty0 net.ifnames=0 biosdevname=0
}

menuentry "Yocto Linux (verbose)" {
    set gfxpayload=text
    linux /boot/__KERNEL__ root=/dev/__BOOT_DEVICE__2 rw rootfstype=ext4 rootwait rootdelay=10 nomodeset console=tty0 loglevel=7 ignore_loglevel net.ifnames=0 biosdevname=0
}

menuentry "Yocto Linux (EFI framebuffer)" {
    set gfxpayload=keep
    linux /boot/__KERNEL__ root=/dev/__BOOT_DEVICE__2 rw rootfstype=ext4 rootwait rootdelay=10 console=tty0 video=efifb:on net.ifnames=0 biosdevname=0
}
CFGEOF

    # プレースホルダを実際の値に置換
    sed -i \
        -e "s|__KERNEL__|${KERNEL}|g" \
        -e "s|__BOOT_DEVICE__|${BOOT_DEVICE}|g" \
        "${MOUNT_ROOT}/boot/grub/grub.cfg"

    # /boot/EFI/BOOT/grub.cfg（Yocto自動生成を上書き・EFI起動時に参照）
    mkdir -p "${MOUNT_ROOT}/boot/EFI/BOOT"
    cp "${MOUNT_ROOT}/boot/grub/grub.cfg" "${MOUNT_ROOT}/boot/EFI/BOOT/grub.cfg"

    # /boot/efi/EFI/BOOT/grub.cfg（EFIパーティションマウント先・念のため）
    mkdir -p "${MOUNT_ROOT}/boot/efi/EFI/BOOT"
    cp "${MOUNT_ROOT}/boot/grub/grub.cfg" "${MOUNT_ROOT}/boot/efi/EFI/BOOT/grub.cfg" 2>/dev/null || true

    log "  grub.cfg 書き込み完了"
    log "  linux 行: $(grep 'linux /boot' ${MOUNT_ROOT}/boot/grub/grub.cfg | head -1)"

    # ── bind アンマウント ────────────────────────────────────────
    log "  bind アンマウント..."
    umount -R "${MOUNT_ROOT}/dev"  || true
    umount -R "${MOUNT_ROOT}/sys"  || true
    umount    "${MOUNT_ROOT}/proc" || true

    # trap をデフォルト状態に戻す（bind マウント解除済み）
    trap - EXIT
else
    log "7. GRUB スキップ (DEVICE_PROFILE=${DEVICE_PROFILE} は GRUB 不要)"
    trap - EXIT
fi

# ─────────────────────────────────────────────
# 8. アンマウント
# ─────────────────────────────────────────────
log "8. アンマウント"
sync
umount "${MOUNT_ROOT}/boot/efi"
umount "${MOUNT_ROOT}"
log "アンマウント完了"

# ─────────────────────────────────────────────
# 9. 完了
# ─────────────────────────────────────────────
echo ""
echo "============================================"
log "✅ USB書き込み完了！"
echo ""
echo "  デバイス: ${TARGET_DEV}"
echo "  rootfs  : ${ROOTFS_TAR}"
echo ""

case "${DEVICE_PROFILE}" in
    x86_64)
        echo "次のステップ:"
        echo "  1. USB を抜いてターゲットPCに差す"
        echo "  2. BIOS/UEFI の Boot Order を USB 優先に設定"
        echo "  3. 起動！"
        ;;
    rpi*)
        echo "次のステップ:"
        echo "  1. microSD / USB を抜いてラズパイに差す"
        echo "  2. 電源ON"
        echo "  3. しばらく待つと起動します(初回は少し時間がかかります)"
        ;;
esac

echo ""
echo "  USB を安全に取り外してから起動してください。"
echo "============================================"
