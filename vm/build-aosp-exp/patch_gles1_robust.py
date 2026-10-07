# -*- coding: utf-8 -*-
# 更稳健的修复：直接在构造函数里用内存循环把 base 的全部 proc 设为
# gles1_unimplemented（覆盖 initDispatchByName 未设置的成员）；
# 并给 extended 类的 4 个 WithDataSize proc 也设默认值。
p2 = '/root/vmbuild/gfxstream/host/gl/gles1_dec/gles1_dec.cpp'
s2 = open(p2, encoding='utf-8', errors='replace').read()
old2 = '''gles1_decoder_context_t::gles1_decoder_context_t() {
    initDispatchByName(gles1_safe_getproc, nullptr);
    {
        void** p_ = (void**)static_cast<gles1_server_context_t*>(this);
        int n_ = (int)(sizeof(gles1_server_context_t) / sizeof(void*));
        int nulls_ = 0;
        for (int i = 0; i < n_; i++) if (!p_[i]) nulls_++;
        fprintf(stderr, "GLES1_CTOR_DONE total=%d nulls=%d ctx=%p\\n", n_, nulls_, (void*)this);
    }
}'''
new2 = '''gles1_decoder_context_t::gles1_decoder_context_t() {
    // VMHOST_FIX: 直接把 base 的全部 proc 成员强制设为 gles1_unimplemented
    // （安全非 NULL），覆盖 initDispatchByName 未设置的成员。initGL 之后
    // 会用真实函数覆盖。host 是 GLES2/3-only，GLES1 固定管线函数缺失，
    // 若 proc 为 NULL，guest 一调即 pc=0 崩溃。
    void** p_ = (void**)static_cast<gles1_server_context_t*>(this);
    int n_ = (int)(sizeof(gles1_server_context_t) / sizeof(void*));
    for (int i = 0; i < n_; i++) p_[i] = (void*)(&gfxstream::gl::gles1_unimplemented);
}'''
assert old2 in s2, 'ctor marker not found'
s2 = s2.replace(old2, new2, 1)
open(p2, 'w', encoding='utf-8').write(s2)

# extended context 的 4 个 WithDataSize 默认值
p_h = '/root/vmbuild/gfxstream/host/gl/gles1_dec/GLESv1Decoder.h'
sh = open(p_h, encoding='utf-8', errors='replace').read()
oldh = '''    int initDispatch( void *(*getProc)(const char *name, void *userData), void *userData);
};'''
newh = '''    int initDispatch( void *(*getProc)(const char *name, void *userData), void *userData);

    // VMHOST_FIX: 默认指向 gles1_unimplemented（非 NULL），防止未走 initGL
    // 时这 4 个 proc 为 NULL，s_gl*PointerData 调用即 pc=0。
    gles1_decoder_extended_context() {
        glColorPointerWithDataSize = (glColorPointerWithDataSize_server_proc_t)(void*)&gles1_unimplemented;
        glNormalPointerWithDataSize = (glNormalPointerWithDataSize_server_proc_t)(void*)&gles1_unimplemented;
        glTexCoordPointerWithDataSize = (glTexCoordPointerWithDataSize_server_proc_t)(void*)&gles1_unimplemented;
        glVertexPointerWithDataSize = (glVertexPointerWithDataSize_server_proc_t)(void*)&gles1_unimplemented;
    }
};'''
assert oldh in sh, 'extended hdr marker not found'
sh = sh.replace(oldh, newh, 1)
open(p_h, 'w', encoding='utf-8').write(sh)
print('robust ctor patch done')
