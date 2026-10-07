#!/usr/bin/env bash
Q=/root/vmbuild/qemu-aosp
echo "=== QEMU 树里 goldfish_address_space 相关文件 ==="
find "$Q" -iname '*goldfish_address_space*' 2>/dev/null
echo
echo "=== 谁定义了这个 TYPE ==="
grep -rn 'goldfish_address_space' "$Q/hw" "$Q/include" 2>/dev/null | grep -viE '\.o:|/\.git' | head -40
echo
echo "=== guest mapper-impl 里的字符串 ==="
strings -a /tmp/hwclibs/mapper30-impl-ranchu.so 2>/dev/null | grep -iE 'GoldfishMapper|HostMemoryAllocator|is_opened|failed to open|address_space|mapper 4' | head -40
echo
echo "=== gfxstream 树里 GoldfishMapper / HostMemoryAllocator ==="
grep -rln --include='*.cpp' --include='*.h' -E 'GoldfishMapper|HostMemoryAllocator' /root/vmbuild/gfxstream 2>/dev/null | head -20
