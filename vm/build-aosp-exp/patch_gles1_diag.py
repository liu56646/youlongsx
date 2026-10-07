# -*- coding: utf-8 -*-
# 诊断：在 gles1 decoder 的构造与 initGL 后，扫描并打印为 NULL 的 proc
p = '/root/vmbuild/gfxstream/host/gl/gles1_dec/GLESv1Decoder.cpp'
s = open(p, encoding='utf-8', errors='replace').read()

# initGL 末尾（return 0; 之前）加扫描
old = '''    glDeleteVertexArraysOES_dec = s_glDeleteVertexArraysOES;

    return 0;
}'''
new = '''    glDeleteVertexArraysOES_dec = s_glDeleteVertexArraysOES;

    {
        void** p_ = (void**)static_cast<gles1_server_context_t*>(this);
        int n_ = (int)(sizeof(gles1_server_context_t) / sizeof(void*));
        int nulls_ = 0;
        for (int i = 0; i < n_; i++) {
            if (!p_[i]) { nulls_++; if (nulls_ <= 12) fprintf(stderr, "GLES1_INITGL_NULLPROC idx=%d\\n", i); }
        }
        fprintf(stderr, "GLES1_INITGL_DONE total=%d nulls=%d ctx=%p\\n", n_, nulls_, (void*)this);
    }

    return 0;
}'''
assert old in s, 'initGL marker not found'
s = s.replace(old, new, 1)
open(p, 'w', encoding='utf-8').write(s)

# 构造函数里也扫一次
p2 = '/root/vmbuild/gfxstream/host/gl/gles1_dec/gles1_dec.cpp'
s2 = open(p2, encoding='utf-8', errors='replace').read()
old2 = '''gles1_decoder_context_t::gles1_decoder_context_t() {
    initDispatchByName(gles1_safe_getproc, nullptr);
}'''
new2 = '''gles1_decoder_context_t::gles1_decoder_context_t() {
    initDispatchByName(gles1_safe_getproc, nullptr);
    {
        void** p_ = (void**)static_cast<gles1_server_context_t*>(this);
        int n_ = (int)(sizeof(gles1_server_context_t) / sizeof(void*));
        int nulls_ = 0;
        for (int i = 0; i < n_; i++) if (!p_[i]) nulls_++;
        fprintf(stderr, "GLES1_CTOR_DONE total=%d nulls=%d ctx=%p\\n", n_, nulls_, (void*)this);
    }
}'''
assert old2 in s2, 'ctor marker not found'
s2 = s2.replace(old2, new2, 1)
open(p2, 'w', encoding='utf-8').write(s2)
print('diag patch done')
