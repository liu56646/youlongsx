# -*- coding: utf-8 -*-
# gles1_dec.cpp: decode 循环加 opcode 日志（文件用 Tab 缩进）
p = '/root/vmbuild/gfxstream/host/gl/gles1_dec/gles1_dec.cpp'
s = open(p, encoding='utf-8', errors='replace').read()
old = '\t\tuint32_t opcode = *(uint32_t *)ptr;\n\t\tuint32_t packetLen = *(uint32_t *)(ptr + 4);'
new = ('\t\tuint32_t opcode = *(uint32_t *)ptr;\n'
       '\t\tuint32_t packetLen = *(uint32_t *)(ptr + 4);\n'
       '\t\tfprintf(stderr, "VMHOST_GLES1_OP %u len=%u\\n", opcode, packetLen);')
assert old in s, 'marker not found'
s = s.replace(old, new, 1)
open(p, 'w', encoding='utf-8').write(s)
print('patch2 done')
