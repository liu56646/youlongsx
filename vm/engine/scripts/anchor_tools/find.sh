#!/usr/bin/env bash
#
# 锚点定位助手 —— 补丁锚点失效时，用它在新源码树里快速找到"等价代码"。
#
# 用法：
#   ./find.sh <源码根> <关键字> [上下文行数]
# 例：
#   ./find.sh ~/vmbuild/qemu-aosp  virgl_cmd_get_capset_info
#   ./find.sh ~/vmbuild/gfxstream host/gl/ColorBufferGl.cpp Blit  # 第 2 参也可是文件局部关键字
#
# 流程：先列出所有命中（文件:行），再打印首个命中的上下文，方便你把新的
#       "old 锚点"整段抄回补丁脚本。
set -u

root="${1:?用法: find.sh <源码根> <关键字> [上下文行数]}"
kw="${2:?缺少关键字}"
ctx="${3:-25}"

grepargs=( -rn -F --include='*.c' --include='*.cpp' --include='*.cc' \
           --include='*.h' --include='*.hpp' "$kw" "$root" )

echo "== 命中（文件:行）=="
grep "${grepargs[@]}" 2>/dev/null | head -40

first="$(grep -rl -F --include='*.c' --include='*.cpp' --include='*.cc' \
                  --include='*.h' --include='*.hpp' "$kw" "$root" 2>/dev/null | head -1)"
if [ -n "$first" ]; then
    echo
    echo "== 首个命中点上下文（$first，±$ctx 行）=="
    grep -n -F -B "$ctx" -A "$ctx" "$kw" "$first"
else
    echo
    echo "!! 整树未找到 \"$kw\"。换个更稳定的关键字（函数名 / 宏 / 结构体名）再试。"
fi
