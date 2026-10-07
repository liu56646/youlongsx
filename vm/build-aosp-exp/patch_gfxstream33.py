# -*- coding: utf-8 -*-
# 把 emu-34 上验证过的宿主侧修复应用到 emu-33 gfxstream：
#   1. GLESVersionDetector.cpp: host 模式强制 GLES2（宿主 context 用 ES2）
#   2. GLESv2Dispatch.cpp: 优先 dlsym 宿主 libGLESv2.so（TextureDraw 用宿主 GLES）
#   3. FrameBuffer.cpp: getScreenshot(displayId=0) 在 m_lastPostedColorBuffer 无效时
#      回退 display 0 的 color buffer（guest 用 rcSetDisplayColorBuffer 时也能截到帧）
import io, sys

def patch(path, pairs, base="/root/vmbuild/gfxstream-33"):
    f = base + path
    src = io.open(f, encoding="utf-8").read()
    for old, new, tag in pairs:
        if old in src:
            src = src.replace(old, new, 1)
            print("OK[%s]: %s" % (path, tag))
        else:
            print("MISS[%s]: %s" % (path, tag))
    io.open(f, "w", encoding="utf-8").write(src)

# ---- 1. GLESVersionDetector.cpp ----
patch("/host/gl/GLESVersionDetector.cpp", [
    (
        "    if (emugl::getRenderer() == SELECTED_RENDERER_HOST\n"
        "        || emugl::getRenderer() == SELECTED_RENDERER_SWIFTSHADER_INDIRECT\n"
        "        || emugl::getRenderer() == SELECTED_RENDERER_ANGLE_INDIRECT\n"
        "        || emugl::getRenderer() == SELECTED_RENDERER_ANGLE9_INDIRECT) {\n"
        "        if (s_egl.eglGetMaxGLESVersion) {\n"
        "            maxVersion =\n"
        "                (GLESDispatchMaxVersion)s_egl.eglGetMaxGLESVersion(dpy);\n"
        "        }\n"
        "    } else {",
        "    if (emugl::getRenderer() == SELECTED_RENDERER_HOST\n"
        "        || emugl::getRenderer() == SELECTED_RENDERER_SWIFTSHADER_INDIRECT\n"
        "        || emugl::getRenderer() == SELECTED_RENDERER_ANGLE_INDIRECT\n"
        "        || emugl::getRenderer() == SELECTED_RENDERER_ANGLE9_INDIRECT) {\n"
        "        // VMHost patch (D1a): force GLES2 so host EGL context is ES2,\n"
        "        // otherwise guest GLSL1.0 shaders fail to compile on Adreno ES3.\n"
        "        maxVersion = GLES_DISPATCH_MAX_VERSION_2;\n"
        "    } else {",
        "force GLES2",
    ),
])

# ---- 2. GLESv2Dispatch.cpp ----
patch("/host/gl/OpenGLESDispatch/GLESv2Dispatch.cpp", [
    (
        "#define LOOKUP_SYMBOL_STATIC(return_type, function_name, signature, callargs)    \\\n"
        "    dispatch_table->function_name =                                              \\\n"
        "        reinterpret_cast<function_name##_t>(::translator::gles2::function_name); \\\n"
        "    if ((!dispatch_table->function_name) && s_egl.eglGetProcAddress)             \\\n"
        "        dispatch_table->function_name =                                          \\\n"
        "            reinterpret_cast<function_name##_t>(s_egl.eglGetProcAddress(#function_name));",
        "static void* s_hostGlesLib = nullptr;\n\n"
        "#define LOOKUP_SYMBOL_STATIC(return_type, function_name, signature, callargs)    \\\n"
        "    if (!s_hostGlesLib) {                                                        \\\n"
        "        s_hostGlesLib = dlopen(\"libGLESv2.so\", RTLD_NOW | RTLD_GLOBAL);          \\\n"
        "    }                                                                            \\\n"
        "    dispatch_table->function_name = nullptr;                                     \\\n"
        "    if (s_hostGlesLib) {                                                         \\\n"
        "        dispatch_table->function_name =                                          \\\n"
        "            reinterpret_cast<function_name##_t>(dlsym(s_hostGlesLib, #function_name)); \\\n"
        "    }                                                                            \\\n"
        "    if (!dispatch_table->function_name && s_egl.eglGetProcAddress) {             \\\n"
        "        dispatch_table->function_name =                                          \\\n"
        "            reinterpret_cast<function_name##_t>(s_egl.eglGetProcAddress(#function_name)); \\\n"
        "    }                                                                            \\\n"
        "    if (!dispatch_table->function_name) {                                        \\\n"
        "        dispatch_table->function_name =                                          \\\n"
        "            reinterpret_cast<function_name##_t>(::translator::gles2::function_name); \\\n"
        "    }",
        "dlsym host GLES",
    ),
])

# ---- 3. FrameBuffer.cpp getScreenshot 回退 ----
patch("/host/FrameBuffer.cpp", [
    (
        "    emugl::get_emugl_multi_display_operations().getDisplayColorBuffer(displayId, &cb);\n"
        "    if (displayId == 0) {\n"
        "        cb = m_lastPostedColorBuffer;\n"
        "    }",
        "    emugl::get_emugl_multi_display_operations().getDisplayColorBuffer(displayId, &cb);\n"
        "    if (displayId == 0) {\n"
        "        if (m_lastPostedColorBuffer) {\n"
        "            cb = m_lastPostedColorBuffer;\n"
        "        }\n"
        "    }",
        "screenshot fallback display cb",
    ),
])
