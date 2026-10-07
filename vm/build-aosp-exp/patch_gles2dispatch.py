# -*- coding: utf-8 -*-
# 把 gfxstream GLESv2Dispatch 的 LOOKUP 宏改为：优先 dlsym 宿主 libGLESv2.so
#（Android eglGetProcAddress 对核心函数返回 NULL，会 fallback 到 translator，
#  而 translator 在无 guest context 时丢弃 shader 源码 → 宿主编译空 shader 报错）。
import io, sys

f = "/root/vmbuild/gfxstream/host/gl/OpenGLESDispatch/GLESv2Dispatch.cpp"
src = io.open(f, encoding="utf-8").read()

old = "#define LOOKUP_SYMBOL_STATIC(return_type, function_name, signature, callargs)    \\\n" \
"    dispatch_table->function_name = nullptr;                                     \\\n" \
"    /* VMHost patch: prefer host GLES over translator, so host-internal      */ \\\n" \
"    /* components (TextureDraw, ColorBuffer readback...) talk straight to   */ \\\n" \
"    /* the Adreno driver instead of the guest GLES translator + ShaderParser */ \\\n" \
"    if (s_egl.eglGetProcAddress) {                                             \\\n" \
"        dispatch_table->function_name =                                        \\\n" \
"            reinterpret_cast<function_name##_t>(s_egl.eglGetProcAddress(#function_name)); \\\n" \
"    }                                                                          \\\n" \
"    if (!dispatch_table->function_name) {                                      \\\n" \
"        dispatch_table->function_name =                                        \\\n" \
"            reinterpret_cast<function_name##_t>(::translator::gles2::function_name); \\\n" \
"    }"

new = "#define LOOKUP_SYMBOL_STATIC(return_type, function_name, signature, callargs)    \\\n" \
"    if (!s_hostGlesLib) {                                                        \\\n" \
"        s_hostGlesLib = dlopen(\"libGLESv2.so\", RTLD_NOW | RTLD_GLOBAL);          \\\n" \
"    }                                                                            \\\n" \
"    dispatch_table->function_name = nullptr;                                     \\\n" \
"    if (s_hostGlesLib) {                                                         \\\n" \
"        dispatch_table->function_name =                                          \\\n" \
"            reinterpret_cast<function_name##_t>(dlsym(s_hostGlesLib, #function_name)); \\\n" \
"    }                                                                            \\\n" \
"    if (!dispatch_table->function_name && s_egl.eglGetProcAddress) {             \\\n" \
"        dispatch_table->function_name =                                          \\\n" \
"            reinterpret_cast<function_name##_t>(s_egl.eglGetProcAddress(#function_name)); \\\n" \
"    }                                                                            \\\n" \
"    if (!dispatch_table->function_name) {                                        \\\n" \
"        dispatch_table->function_name =                                          \\\n" \
"            reinterpret_cast<function_name##_t>(::translator::gles2::function_name); \\\n" \
"    }"

if old not in src:
    print("ERROR: old macro NOT found")
    sys.exit(1)
src = src.replace(old, new, 1)
if "static void* s_hostGlesLib = nullptr;" not in src:
    src = src.replace("#define LOOKUP_SYMBOL_STATIC",
                      "static void* s_hostGlesLib = nullptr;\n\n#define LOOKUP_SYMBOL_STATIC", 1)
io.open(f, "w", encoding="utf-8").write(src)
print("OK: patched")
