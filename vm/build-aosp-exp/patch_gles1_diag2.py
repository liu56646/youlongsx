# -*- coding: utf-8 -*-
# 诊断2：ctor 后打印 nulls 数；decode 的 glClientActiveTexture case 打印 proc 值
p2 = '/root/vmbuild/gfxstream/host/gl/gles1_dec/gles1_dec.cpp'
s2 = open(p2, encoding='utf-8', errors='replace').read()

old2 = '''    void** p_ = (void**)static_cast<gles1_server_context_t*>(this);
    int n_ = (int)(sizeof(gles1_server_context_t) / sizeof(void*));
    for (int i = 0; i < n_; i++) p_[i] = (void*)(&gfxstream::gl::gles1_unimplemented);
}'''
new2 = '''    void** p_ = (void**)static_cast<gles1_server_context_t*>(this);
    int n_ = (int)(sizeof(gles1_server_context_t) / sizeof(void*));
    for (int i = 0; i < n_; i++) p_[i] = (void*)(&gfxstream::gl::gles1_unimplemented);
    {
        int nulls_ = 0;
        for (int i = 0; i < n_; i++) if (!p_[i]) nulls_++;
        fprintf(stderr, "GLES1_CTOR_DONE total=%d nulls=%d ctx=%p glCAT=%p\\n", n_, nulls_, (void*)this, (void*)this->glClientActiveTexture);
    }
}'''
assert old2 in s2, 'ctor marker not found'
s2 = s2.replace(old2, new2, 1)

old3 = '''                        DECODER_DEBUG_LOG("gles1(%p): glClientActiveTexture(texture:0x%08x )", stream, var_texture);
                        this->glClientActiveTexture(var_texture);'''
new3 = '''                        DECODER_DEBUG_LOG("gles1(%p): glClientActiveTexture(texture:0x%08x )", stream, var_texture);
                        fprintf(stderr, "GLES1_CALL_glCAT proc=%p ctx=%p\\n", (void*)this->glClientActiveTexture, (void*)this);
                        this->glClientActiveTexture(var_texture);'''
assert old3 in s2, 'case marker not found'
s2 = s2.replace(old3, new3, 1)
open(p2, 'w', encoding='utf-8').write(s2)
print('diag2 patch done')
