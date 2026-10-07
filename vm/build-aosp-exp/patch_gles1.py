# -*- coding: utf-8 -*-
# 1) gles1_server_context.cpp: getProc 返回 NULL 的 proc 用 no-op stub 兜底（防崩溃）
# 2) gles1_dec.cpp: decode 循环开头打印 opcode（定位 guest 调用）
import re

# ---- patch 1: gles1_server_context.cpp ----
p1 = '/root/vmbuild/gfxstream/host/gl/gles1_dec/gles1_server_context.cpp'
s = open(p1, encoding='utf-8', errors='replace').read()

# 插入 no-op helper（在 initDispatchByName 之前）
helper = '''// VMHOST_FIX: host 是 GLES2/3-only（Adreno ES 驱动），GLES1 固定管线函数
// getProc 返回 NULL；guest 一调就 pc=0 崩溃。统一用 no-op 兜底，保持不崩。
static void gles1_noop_proc(void) { }

int gles1_server_context_t::initDispatchByName'''
s = s.replace('int gles1_server_context_t::initDispatchByName', helper, 1)

# 把 getProc 行改成 NULL 兜底
def fix_line(m):
    var = m.group(1)
    typ = m.group(2)
    name = m.group(3)
    return ('do { void* p_ = getProc("%s", userData); %s = (%s)(p_ ? p_ : (void*)gles1_noop_proc); } while(0);'
            % (name, var, typ))

pat = re.compile(r'(\w+)\s*=\s*\((\w+_server_proc_t)\)\s*getProc\("([^"]+)",\s*userData\);')
s2, n1 = pat.subn(fix_line, s)
open(p1, 'w', encoding='utf-8').write(s2)
print('patch1: replaced %d getProc lines' % n1)

# ---- patch 2: gles1_dec.cpp ----
p2 = '/root/vmbuild/gfxstream/host/gl/gles1_dec/gles1_dec.cpp'
s = open(p2, encoding='utf-8', errors='replace').read()
old = '''                uint32_t opcode = *(uint32_t *)ptr;
                uint32_t packetLen = *(uint32_t *)(ptr + 4);'''
new = '''                uint32_t opcode = *(uint32_t *)ptr;
                uint32_t packetLen = *(uint32_t *)(ptr + 4);
                fprintf(stderr, "VMHOST_GLES1_OP %u len=%u\\n", opcode, packetLen);'''
assert old in s, 'decode marker not found'
s = s.replace(old, new, 1)
open(p2, 'w', encoding='utf-8').write(s)
print('patch2: opcode log added')
