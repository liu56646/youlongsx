#!/usr/bin/env bash
F=/root/vmbuild/qemu-aosp/android-qemu2-glue/qemu-vm-operations-impl.cpp
echo "=== 相关函数行号 ==="
grep -n 'physical_memory_get_addr\|map_user_backed_ram\|unmap_user_backed_ram\|hostmem_register\|hostmem_unregister' "$F" | head -20
echo
for fn in physical_memory_get_addr map_user_backed_ram unmap_user_backed_ram hostmem_register hostmem_unregister; do
    echo "=== $fn ==="
    awk -v f=" $fn(" '
        $0 ~ f {p=1}
        p {print}
        p && /^}/ {exit}
    ' "$F"
    echo
done
