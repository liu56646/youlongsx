# -*- coding: utf-8 -*-
import re
p2 = '/root/vmbuild/gfxstream/host/gl/gles1_dec/gles1_dec.cpp'
s2 = open(p2, encoding='utf-8', errors='replace').read()

# 1) decode() 入口插入 NULL-proc 兜底（在 "if (len < 8) return 0;" 之前）
pat = re.compile(r'(size_t gles1_decoder_context_t::decode\([^\n]*\{\n)(\s*if \(len < 8\) return 0;)')
guard = ('        {\n'
         '            void** p_ = (void**)static_cast<gles1_server_context_t*>(this);\n'
         '            int n_ = (int)(sizeof(gles1_server_context_t) / sizeof(void*));\n'
         '            for (int i = 0; i < n_; i++)\n'
         '                if (!p_[i]) p_[i] = (void*)(&gfxstream::gl::gles1_unimplemented);\n'
         '        }\n')
n = pat.subn(lambda m: m.group(1) + guard + m.group(2), s2, count=1)
assert n[1] == 1, 'decode marker not found'
s2 = n[0]

# 2) glClientActiveTexture case 打印
pat2 = re.compile(r'(\n)(\s*)(this->glClientActiveTexture\(var_texture\);)')
n2 = pat2.subn(lambda m: m.group(1) + m.group(2) + 'fprintf(stderr, "GLES1_CALL_glCAT proc=%p ctx=%p\\n", (void*)this->glClientActiveTexture, (void*)this);\n' + m.group(2) + m.group(3), s2, count=1)
assert n2[1] == 1, 'case marker not found'
s2 = n2[0]

open(p2, 'w', encoding='utf-8').write(s2)
print('decode-entry fix + case print done')
