#!/usr/bin/env bash

rm -rf ./build/FLAGS/.build_done

echo 0 | sudo tee /proc/sys/kernel/apparmor_restrict_unprivileged_userns && docker compose up --build -d
