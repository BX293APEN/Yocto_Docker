#!/usr/bin/env bash
rm -rf ./build/FLAGS/.build_done
rm -rf ./build/build_yocto/tmp-glibc
rm -rf ./build/build_yocto/classes/
rm -rf ./build/tmp

echo 0 | sudo tee /proc/sys/kernel/apparmor_restrict_unprivileged_userns && docker compose up --build -d
