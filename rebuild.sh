#!/usr/bin/env bash
rm -rf ./build/FLAGS/.build_done
rm -rf ./build/build_yocto/tmp-glibc
rm -rf ./build/build_yocto/classes/
rm -rf ./build/build_yocto/conf/bblayers.conf
rm -rf ./build/sstate-cache/
rm -rf ./build/tmp
rm -rf ./build/images/
rm -rf ./build/yocto-rootfs.tar.gz
# poky を削除して再クローン（git fetch による意図しない更新を防ぐ）
rm -rf ./build/poky

echo 0 | sudo tee /proc/sys/kernel/apparmor_restrict_unprivileged_userns && docker compose build --no-cache && docker compose up -d
