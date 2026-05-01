#!/usr/bin/env bash
rm -rf ./build/FLAGS/.build_done
rm -rf ./build/build_yocto/tmp-glibc
rm -rf ./build/tmp

docker compose up --build -d
