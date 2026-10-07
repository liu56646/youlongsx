# -*- coding: utf-8 -*-
# 核弹级修复：把所有 `this->glXxx(...)` 语句调用包成 NULL 检查宏。
# 排除 glGetError（其返回值被赋值，宏会破坏表达式）。
import re
p = '/root/vmbuild/gfxstream/host/gl/gles1_dec/gles1_dec.cpp'
s = open(p, encoding='utf-8', errors='replace').read()

# 1) 删除 per-iteration guard 块（两种缩进都试）
s = re.sub(r'\n\s*\{\n\s*void\*\* p_ = \(void\*\*\)static_cast<gles1_server_context_t\*>\(this\);\n\s*int n_ = \(int\)\(sizeof\(gles1_server_context_t\) / sizeof\(void\*\)\);\n\s*for \(int i = 0; i < n_; i\+\+\)\n\s*if \(!p_\[i\]\) p_\[i\] = \(void\*\)\(&gfxstream::gl::gles1_unimplemented\);\n\s*\}\n', '\n', s, count=1)

# 2) 删除诊断打印
s = s.replace('fprintf(stderr, "GLES1_CALL_glCTSI2D proc=%p ctx=%p\\n", (void*)this->glCompressedTexSubImage2D, (void*)this);\n', '')
s = s.replace('fprintf(stderr, "GLES1_CALL_glCAT proc=%p ctx=%p\\n", (void*)this->glClientActiveTexture, (void*)this);\n', '')

# 3) 安全调用宏
macro = '''// VMHOST_FIX: 安全调用宏 —— 调用前一刻校验 proc 非 NULL，防止 pc=0。
#define VMHOST_GLES1_CALL(proc, ...) do { if (this->proc) this->proc(__VA_ARGS__); } while (0)

'''
anchor = 'typedef unsigned int tsize_t;'
assert anchor in s, 'anchor not found'
if 'VMHOST_GLES1_CALL' not in s.split('typedef unsigned int tsize_t;')[0]:
    s = s.replace(anchor, macro + anchor, 1)

# 4) 包装（排除 glGetError）
s, n = re.subn(r'this->(gl(?!GetError)\w+)\(', r'VMHOST_GLES1_CALL(\1, ', s)
print('wrapped %d call sites' % n)

open(p, 'w', encoding='utf-8').write(s)
print('nuclear fix applied')
