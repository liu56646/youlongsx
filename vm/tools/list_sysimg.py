#!/usr/bin/env python3
"""
从 Google sys-img 仓库 XML 里列出各 Android 版本的 arm64 镜像直链。

这些 URL 可以直接下载，不必让 sdkmanager 把镜像装进 SDK 目录 ——
本机 C 盘空间紧张时，这是唯一可行的做法。

用法：
    curl -s -o /tmp/sysimg.xml \
        https://dl.google.com/android/repository/sys-img/android/sys-img2-1.xml
    python3 list_sysimg.py /tmp/sysimg.xml default
"""

import sys
import xml.etree.ElementTree as ET

BASE = "https://dl.google.com/android/repository/sys-img/android/"


def main() -> int:
    xml_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/sysimg.xml"
    variant = sys.argv[2] if len(sys.argv) > 2 else "default"

    try:
        root = ET.parse(xml_path).getroot()
    except Exception as exc:                       # noqa: BLE001
        print(f"解析失败：{exc}", file=sys.stderr)
        return 1

    rows = []
    for pkg in root:
        path = pkg.get("path", "")
        if not path.startswith("system-images;"):
            continue
        if ";arm64-v8a" not in path or f";{variant};" not in path:
            continue

        url = next((u.text for u in pkg.iter("url") if u.text), None)
        size = next((s.text for s in pkg.iter("size") if s.text), None)
        if not url:
            continue

        # path 形如 system-images;android-30;default;arm64-v8a
        parts = path.split(";")
        api = parts[1].replace("android-", "")
        size_mb = f"{int(size) / 1024 / 1024:.0f} MB" if size else "?"
        rows.append((int(api), api, url, size_mb))

    rows.sort()
    for _, api, url, size_mb in rows:
        print(f"API {api:>2}  {size_mb:>8}  {BASE}{url}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
