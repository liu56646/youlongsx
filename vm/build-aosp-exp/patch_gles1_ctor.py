# -*- coding: utf-8 -*-
# gles1_dec: 构造函数默认初始化 procs 为 gles1_unimplemented（防 NULL proc 崩溃）
p_h = '/root/vmbuild/gfxstream/host/gl/gles1_dec/gles1_dec.h'
s = open(p_h, encoding='utf-8', errors='replace').read()

old = '''struct gles1_decoder_context_t : public gles1_server_context_t {

\tsize_t decode(void *buf, size_t bufsize, IOStream *stream, ChecksumCalculator* checksumCalc);

};'''
new = '''struct gles1_decoder_context_t : public gles1_server_context_t {

\t// VMHOST_FIX: 默认把所有 proc 指向 gles1_unimplemented，避免
\t// decoder 未走 initGL 模板拷贝时 proc 为 NULL，guest 一调就 pc=0。
\tgles1_decoder_context_t();

\tsize_t decode(void *buf, size_t bufsize, IOStream *stream, ChecksumCalculator* checksumCalc);

};'''
assert old in s, 'hdr marker not found'
s = s.replace(old, new, 1)
open(p_h, 'w', encoding='utf-8').write(s)

p_c = '/root/vmbuild/gfxstream/host/gl/gles1_dec/gles1_dec.cpp'
s = open(p_c, encoding='utf-8', errors='replace').read()

old2 = '''namespace gfxstream {

typedef unsigned int tsize_t;'''
new2 = '''namespace gfxstream {

// VMHOST_FIX: 构造函数把所有 proc 默认指到 gles1_unimplemented（安全非 NULL）
static void* gles1_safe_getproc(const char*, void*) {
    return (void*)(&gfxstream::gl::gles1_unimplemented);
}
gles1_decoder_context_t::gles1_decoder_context_t() {
    initDispatchByName(gles1_safe_getproc, nullptr);
}

typedef unsigned int tsize_t;'''
assert old2 in s, 'cpp marker not found'
s = s.replace(old2, new2, 1)
open(p_c, 'w', encoding='utf-8').write(s)
print('constructor patch done')
