# -*- coding: utf-8 -*-
# GLESv1Decoder.h 加 include GLESv1Dispatch.h（gles1_unimplemented 声明）
p = '/root/vmbuild/gfxstream/host/gl/gles1_dec/GLESv1Decoder.h'
s = open(p, encoding='utf-8', errors='replace').read()
old = '''#include "GLDecoderContextData.h"
#include "aemu/base/SharedLibrary.h"'''
new = '''#include "GLDecoderContextData.h"
#include "OpenGLESDispatch/GLESv1Dispatch.h"
#include "aemu/base/SharedLibrary.h"'''
assert old in s, 'include marker not found'
s = s.replace(old, new, 1)
open(p, 'w', encoding='utf-8').write(s)
print('include added to GLESv1Decoder.h')
