#!/usr/bin/env python3
"""基础检查 1/6 · 仓库卫生。

只查会造成「仓库变脏 / 变大 / 合并不完整」的硬性问题，不碰代码风格：

1. 关键文件齐全（构建入口、许可证、忽略规则、两份主干文档）
2. 没有提交构建产物 / 本地配置 / 日志 / IDE 文件
3. 单个被跟踪文件不超过 10 MiB
4. 没有残留的合并冲突标记
5. 文本文件是合法的 UTF-8

用法：python3 tools/ci/check_repo_hygiene.py
退出码：0 通过；1 有问题（逐条列出）
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):  # Windows 控制台默认 GBK，统一成 UTF-8 输出
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parents[2]
MAX_BYTES = 10 * 1024 * 1024

# 缺了任何一个，仓库就没法构建或者没法合规分发。
REQUIRED = (
    "LICENSE",
    "README.md",
    ".gitignore",
    "docs/构建指南.md",
    "docs/技术方案设计.md",
    "vm/settings.gradle.kts",
    "vm/build.gradle.kts",
    "vm/app/build.gradle.kts",
    "vm/core-vm/build.gradle.kts",
    "vm/engine-api/build.gradle.kts",
    "vm/engine/build.gradle.kts",
    "vm/gradlew",
    "vm/gradlew.bat",
    "vm/gradle/wrapper/gradle-wrapper.properties",
)

# 目录层级里不允许出现的构建 / 缓存目录。
FORBIDDEN_DIR_PARTS = ("/build/", "/.cxx/", "/.gradle/", "/.kotlin/", "/.idea/")

# 构建产物与本地配置：全部可重建，不该进版本库。
FORBIDDEN_SUFFIXES = (
    ".apk",
    ".aab",
    ".aar",
    ".class",
    ".dex",
    ".hprof",
    ".core",
    ".log",
    ".iml",
    ".pyc",
    ".tmp",
    ".swp",
)
FORBIDDEN_NAMES = ("local.properties", ".DS_Store", "Thumbs.db")

# 允许入库的少数「成品」文件（Gradle 官方 wrapper jar，见 3/6 检查）。
ALLOWED_FILES = {"vm/gradle/wrapper/gradle-wrapper.jar"}

# 这些后缀按二进制处理，跳过 UTF-8 / 冲突标记扫描。
BINARY_SUFFIXES = (
    ".so",
    ".jar",
    ".jks",
    ".qcow2",
    ".ppm",
    ".dtb",
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".zip",
    ".gz",
)

CONFLICT_PREFIXES = ("<<<<<<< ", ">>>>>>> ", "||||||| ")


def tracked_files() -> list[str]:
    """git 视角下真正被跟踪的文件（相对仓库根、正斜杠、排好序）。"""
    try:
        out = subprocess.run(
            ["git", "-C", str(ROOT), "ls-files", "-z"],
            check=True,
            capture_output=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as exc:  # pragma: no cover
        print(f"[FAIL] 读取 git 文件列表失败：{exc}")
        sys.exit(1)
    return sorted(p for p in out.decode("utf-8").split("\0") if p)


def is_binary(path: Path) -> bool:
    if path.suffix.lower() in BINARY_SUFFIXES:
        return True
    try:
        with path.open("rb") as fh:
            return b"\x00" in fh.read(8192)
    except OSError:
        return False


def main() -> int:
    files = tracked_files()
    errors: list[str] = []

    # 1) 关键文件齐全
    for rel in REQUIRED:
        if not (ROOT / rel).is_file():
            errors.append(f"缺少关键文件：{rel}")

    # 2..4) 逐个文件检查
    for rel in files:
        path = ROOT / rel
        posix = f"/{rel}"

        if any(part in posix for part in FORBIDDEN_DIR_PARTS):
            errors.append(f"构建/缓存目录不应入库：{rel}")
            continue

        if rel not in ALLOWED_FILES:
            if path.suffix.lower() in FORBIDDEN_SUFFIXES:
                errors.append(f"构建产物/本地配置不应入库：{rel}")
                continue
            if path.name in FORBIDDEN_NAMES:
                errors.append(f"本地配置不应入库：{rel}")
                continue

        if not path.exists():
            continue

        size = path.stat().st_size
        if size > MAX_BYTES:
            errors.append(
                f"文件过大（{size / 1024 / 1024:.1f} MiB > 10 MiB）：{rel}"
            )

        if is_binary(path):
            continue

        try:
            raw = path.read_bytes()
        except OSError as exc:
            errors.append(f"读取失败（{exc}）：{rel}")
            continue

        if raw.startswith(b"\xef\xbb\xbf"):
            errors.append(f"UTF-8 文件带 BOM：{rel}")

        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            errors.append(f"不是合法的 UTF-8（{exc}）：{rel}")
            continue

        for lineno, line in enumerate(text.splitlines(), 1):
            if line.startswith(CONFLICT_PREFIXES):
                errors.append(f"残留合并冲突标记：{rel}:{lineno}: {line[:60]}")

    if errors:
        print(f"[FAIL] 仓库卫生检查未通过，共 {len(errors)} 个问题：")
        for err in errors:
            print(f"  - {err}")
        return 1

    print(f"[OK] 仓库卫生检查通过（{len(files)} 个被跟踪文件）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
