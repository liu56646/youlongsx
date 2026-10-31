#!/usr/bin/env python3
"""基础检查 2/6 · 文档链接。

docs/ 与 README 是本仓的主要交付物之一，链接断了等于文档没写。检查：

1. 所有被跟踪的 Markdown 里，**相对**链接 / 图片指向的文件真实存在
   （支持 `](<路径>)`、路径内含括号、%20 转义、`#锚点`）
2. Markdown 本身是合法的 UTF-8 且不带 BOM
3. 外链（http/https/mailto 等）不做联网校验 —— CI 不该依赖外网可用性

用法：python3 tools/ci/check_docs_links.py
退出码：0 通过；1 有问题（逐条列出）
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote

if hasattr(sys.stdout, "reconfigure"):  # Windows 控制台默认 GBK，统一成 UTF-8 输出
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parents[2]

SKIP_PREFIXES = (
    "http://",
    "https://",
    "mailto:",
    "tel:",
    "ftp://",
    "//",
    "#",
)


def tracked_markdown() -> list[str]:
    try:
        out = subprocess.run(
            ["git", "-C", str(ROOT), "ls-files", "-z"],
            check=True,
            capture_output=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as exc:  # pragma: no cover
        print(f"[FAIL] 读取 git 文件列表失败：{exc}")
        sys.exit(1)
    # 用后缀过滤而不是 git pathspec：`*.md` 在不同 git 版本/平台上的递归行为不一致。
    return sorted(p for p in out.decode("utf-8").split("\0") if p.endswith(".md"))


def strip_code_fences(text: str) -> str:
    """去掉围栏代码块：里面的 `](...)` 是示例，不是真链接。"""
    kept: list[str] = []
    in_fence = False
    fence = ""
    for line in text.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("```") or stripped.startswith("~~~"):
            marker = stripped[:3]
            if not in_fence:
                in_fence, fence = True, marker
            elif marker == fence:
                in_fence, fence = False, ""
            continue
        if not in_fence:
            kept.append(line)
    return "\n".join(kept)


def iter_link_targets(text: str):
    """产出 Markdown 链接/图片的目标，正确跳过路径内成对的括号。"""
    i = 0
    while True:
        start = text.find("](", i)
        if start < 0:
            return
        pos = start + 2
        if pos < len(text) and text[pos] == "<":
            end = text.find(">", pos + 1)
            if end < 0:
                return
            yield text[pos + 1 : end].strip()
            i = end + 1
            continue

        depth = 1
        buf: list[str] = []
        while pos < len(text):
            ch = text[pos]
            if ch == "\\" and pos + 1 < len(text):
                buf.append(text[pos : pos + 2])
                pos += 2
                continue
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    break
            buf.append(ch)
            pos += 1
        yield "".join(buf).strip()
        i = pos + 1


def normalize_target(target: str) -> str:
    # Markdown 允许 `path "title"`，标题按空格/引号起头，路径里不会有裸空格。
    for sep in (' "', " '"):
        if sep in target:
            target = target.split(sep, 1)[0]
    target = target.split("#", 1)[0].split("?", 1)[0].strip()
    return unquote(target)


def main() -> int:
    files = tracked_markdown()
    errors: list[str] = []
    checked = 0

    for rel in files:
        path = ROOT / rel
        raw = path.read_bytes()

        if raw.startswith(b"\xef\xbb\xbf"):
            errors.append(f"UTF-8 文件带 BOM：{rel}")

        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            errors.append(f"不是合法的 UTF-8（{exc}）：{rel}")
            continue

        for target in iter_link_targets(strip_code_fences(text)):
            if not target or target.startswith(SKIP_PREFIXES):
                continue

            clean = normalize_target(target)
            if not clean:
                continue

            checked += 1
            resolved = (path.parent / clean).resolve()
            if not resolved.exists():
                errors.append(f"链接目标不存在：{rel} → {clean}")

    if errors:
        print(f"[FAIL] 文档链接检查未通过，共 {len(errors)} 个问题：")
        for err in errors:
            print(f"  - {err}")
        return 1

    print(f"[OK] 文档链接检查通过（{len(files)} 个 Markdown、{checked} 个相对链接）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
