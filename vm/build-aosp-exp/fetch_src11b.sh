#!/usr/bin/env bash
set -e
D=/mnt/k/youlongsx/vm/build-aosp-exp/src11
cd "$D"
B='https://cdn.jsdelivr.net/gh/aosp-mirror/platform_frameworks_base@android-11.0.0_r48'
for p in cmds/app_process/app_main.cpp core/jni/AndroidRuntime.cpp; do
  o=$(basename "$p")
  curl -fsSL "$B/$p" -o "$o" && echo "OK $o $(stat -c %s "$o")"
done
echo "=== grep startThreadPool / joinThreadPool ==="
grep -n "startThreadPool\|joinThreadPool\|ProcessState" app_main.cpp AndroidRuntime.cpp || true
