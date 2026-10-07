# -*- coding: utf-8 -*-
# 修复：值返回型调用 `= VMHOST_GLES1_CALL(glXxx, args);` 还原为 `= this->glXxx(args);`
import re
p = '/root/vmbuild/gfxstream/host/gl/gles1_dec/gles1_dec.cpp'
s = open(p, encoding='utf-8', errors='replace').read()
s, n = re.subn(r'=\s*VMHOST_GLES1_CALL\((\w+), ([^;]*)\);', r'= this->\1(\2);', s)
print('reverted %d expression-context calls' % n)
open(p, 'w', encoding='utf-8').write(s)
