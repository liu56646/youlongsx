# -*- coding: utf-8 -*-
import re
p2 = '/root/vmbuild/gfxstream/host/gl/gles1_dec/gles1_dec.cpp'
s2 = open(p2, encoding='utf-8', errors='replace').read()

# 把校验从 decode 入口挪到 while 循环每轮开头（更鲁棒）
# 1) 删除入口处的校验块
old_entry = ('        {\n'
             '            void** p_ = (void**)static_cast<gles1_server_context_t*>(this);\n'
             '            int n_ = (int)(sizeof(gles1_server_context_t) / sizeof(void*));\n'
             '            for (int i = 0; i < n_; i++)\n'
             '                if (!p_[i]) p_[i] = (void*)(&gfxstream::gl::gles1_unimplemented);\n'
             '        }\n')
s2 = s2.replace(old_entry, '', 1)

# 2) 在 while 循环里，读 opcode 之后、switch 之前插入每轮校验
pat = re.compile(r'(while \(end - ptr >= 8\) \{\n)(\s*)(uint32_t opcode = \*\(uint32_t \*\)ptr;)')
def repl(m):
    ind = m.group(2)
    guard = (ind + '{\n' +
             ind + '    void** p_ = (void**)static_cast<gles1_server_context_t*>(this);\n' +
             ind + '    int n_ = (int)(sizeof(gles1_server_context_t) / sizeof(void*));\n' +
             ind + '    for (int i = 0; i < n_; i++)\n' +
             ind + '        if (!p_[i]) p_[i] = (void*)(&gfxstream::gl::gles1_unimplemented);\n' +
             ind + '}\n')
    return m.group(1) + guard + ind + m.group(3)
s2, nn = pat.subn(repl, s2, count=1)
assert nn == 1, 'while-loop marker not found'

# 3) glCompressedTexSubImage2D 调用前打印 proc 值
pat2 = re.compile(r'(\n)(\s*)(this->glCompressedTexSubImage2D\()')
s2, n2 = pat2.subn(lambda m: m.group(1) + m.group(2) + 'fprintf(stderr, "GLES1_CALL_glCTSI2D proc=%p ctx=%p\\n", (void*)this->glCompressedTexSubImage2D, (void*)this);\n' + m.group(2) + m.group(3), s2, count=1)
assert n2 == 1, 'cts2d marker not found'

open(p2, 'w', encoding='utf-8').write(s2)
print('per-iteration guard + diag done')
