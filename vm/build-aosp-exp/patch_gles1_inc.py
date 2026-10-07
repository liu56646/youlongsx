# -*- coding: utf-8 -*-
# gles1_dec.cpp 加 include GLESv1Dispatch.h（提供 gles1_unimplemented 声明）
p = '/root/vmbuild/gfxstream/host/gl/gles1_dec/gles1_dec.cpp'
s = open(p, encoding='utf-8', errors='replace').read()
old = '''#include "host-common/logging.h"
'''
new = '''#include "host-common/logging.h"
#include "OpenGLESDispatch/GLESv1Dispatch.h"
'''
assert old in s, 'include marker not found'
s = s.replace(old, new, 1)
open(p, 'w', encoding='utf-8').write(s)
print('include added')
