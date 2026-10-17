#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
锚点探针 —— 换 AOSP QEMU / gfxstream 版本后，一键看每个补丁的锚点还在不在。

用法：
    python3 probe_anchors.py --qemu ~/vmbuild/qemu-aosp --gfx ~/vmbuild/gfxstream
    # 也可用环境变量：SRC_DIR / GFX_DIR
    python3 probe_anchors.py            # 读环境变量

对清单 anchors.txt 里每条：
    文件里能找到 token      -> ✅ 锚点大概率还在（微调文本即可）
    文件在但 token 没了     -> ❌ 代码被改名/搬走，需重找等价点（重点攻）
    文件都没有              -> ⚠️ 路径变了，用 find.sh 在整个根目录搜 token
    命中 mark               -> ✔ 该补丁「已应用」（幂等）
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_MANIFEST = os.path.join(HERE, "anchors.txt")


def read_manifest(path):
    entries = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split("|")]
            # name | root | relpath | token | [mark]
            while len(parts) < 5:
                parts.append("")
            entries.append(parts[:5])
    return entries


def read_file(path):
    try:
        with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
            return f.read()
    except OSError:
        return None


def search_tree(root, token, limit=3):
    """在 root 下按 token 搜，返回前若干 file:line。"""
    hits = []
    for dirpath, _dirs, files in os.walk(root):
        if "/.git" in dirpath:
            continue
        for name in files:
            if not name.endswith((".c", ".cpp", ".h", ".hpp", ".cc")):
                continue
            fp = os.path.join(dirpath, name)
            data = read_file(fp)
            if data is None:
                continue
            idx = data.find(token)
            if idx >= 0:
                line = data.count("\n", 0, idx) + 1
                hits.append("%s:%d" % (os.path.relpath(fp, root), line))
                if len(hits) >= limit:
                    return hits
    return hits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--qemu", default=os.environ.get("SRC_DIR", ""))
    ap.add_argument("--gfx", default=os.environ.get("GFX_DIR", ""))
    ap.add_argument("--manifest", default=DEFAULT_MANIFEST)
    args = ap.parse_args()

    entries = read_manifest(args.manifest)
    roots = {"qemu": args.qemu, "gfx": args.gfx}

    n_ok = n_miss = n_applied = n_warn = 0
    print("%-22s %-5s %-44s %s" % ("补丁", "根", "文件", "结果"))
    print("-" * 100)
    for name, root, relpath, token, mark in entries:
        base = roots.get(root, "")
        if not base or not os.path.isdir(base):
            print("%-22s %-5s %-44s ⚠️ 根目录缺（--%s 未给或不存在）" % (name, root, relpath, root))
            n_warn += 1
            continue

        if relpath == "*":
            hits = search_tree(base, token)
            if hits:
                print("%-22s %-5s %-44s ✅ 命中 %s" % (name, root, "*(" + token + ")", "", hits[0]))
                n_ok += 1
            else:
                print("%-22s %-5s %-44s ❌ 全树未找到 token=%s" % (name, root, "*", token))
                n_miss += 1
            continue

        fp = os.path.join(base, relpath)
        data = read_file(fp)
        if data is None:
            print("%-22s %-5s %-44s ⚠️ 文件不存在（用 find.sh 搜 token）" % (name, root, relpath))
            n_warn += 1
            continue
        if mark and mark in data:
            print("%-22s %-5s %-44s ✔ 已应用" % (name, root, relpath))
            n_applied += 1
        elif token in data:
            print("%-22s %-5s %-44s ✅ token 在" % (name, root, relpath))
            n_ok += 1
        else:
            print("%-22s %-5s %-44s ❌ token 没了（要重表达锚点）" % (name, root, relpath))
            n_miss += 1

    print("-" * 100)
    print("汇总：✅在=%d  ✔已应用=%d  ❌失效=%d  ⚠️待定=%d" % (n_ok, n_applied, n_miss, n_warn))
    print("❌ 的就是换版本后要逐个「重表达锚点」的清单——从它们开刀。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
