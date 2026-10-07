#!/usr/bin/env bash
# 抓取 AOSP android-11.0.0_r48 关键源码，用于方案 2（IActivityController）
set -e
D=/mnt/k/youlongsx/vm/build-aosp-exp/src11
mkdir -p "$D"
cd "$D"
B='https://cdn.jsdelivr.net/gh/aosp-mirror/platform_frameworks_base@android-11.0.0_r48'
for p in \
  core/java/android/app/IActivityController.aidl \
  services/core/java/com/android/server/Watchdog.java \
  services/core/java/com/android/server/am/ActivityManagerService.java \
  services/core/java/com/android/server/am/ActivityManagerShellCommand.java \
  core/java/android/app/IActivityManager.aidl ; do
  o=$(basename "$p")
  if curl -fsSL "$B/$p" -o "$o"; then
    echo "OK $o $(wc -c < "$o")"
  else
    echo "FAIL $o"
  fi
done
