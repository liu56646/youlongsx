# -*- coding: utf-8 -*-
# VMHost 兜底修复：guest 走 QEMU_PIPE + GoldfishGralloc 时，gralloc/mapper 不创建
# host ColorBuffer（cb_handle.hostHandle==0），导致 rcSetWindowColorBuffer(surface, 0)
# 被宿主拒绝（"bad color buffer handle 0"），EGL 渲染目标缺失、无帧可回传。
# 修复：colorBuffer==0 时，宿主用窗口 surface 尺寸自动创建一个 ColorBuffer 并关联。
import io

def patch(path, pairs):
    src = io.open(path, encoding="utf-8").read()
    for old, new, tag in pairs:
        if old in src:
            src = src.replace(old, new, 1)
            print("OK[%s]: %s" % (path, tag))
        else:
            print("MISS[%s]: %s" % (path, tag))
    io.open(path, "w", encoding="utf-8").write(src)

# ---- FrameBuffer.h: 加声明 ----
h = "/root/vmbuild/gfxstream/host/FrameBuffer.h"
patch(h, [
    (
        "    bool setEmulatedEglWindowSurfaceColorBuffer(HandleType p_surface,\n"
        "                                                HandleType p_colorbuffer);\n",
        "    bool setEmulatedEglWindowSurfaceColorBuffer(HandleType p_surface,\n"
        "                                                HandleType p_colorbuffer);\n"
        "    // VMHost: guest 的 gralloc/mapper 未创建 host ColorBuffer（hostHandle==0）时\n"
        "    // 用窗口 surface 尺寸自动创建并关联，保证有渲染目标。\n"
        "    void autoCreateWindowSurfaceColorBuffer(HandleType p_surface);\n",
        "decl",
    ),
])

# ---- FrameBuffer.cpp: 加实现 ----
c = "/root/vmbuild/gfxstream/host/FrameBuffer.cpp"
patch(c, [
    (
        "    (*w).second.second = p_colorbuffer;\n"
        "\n"
        "    m_EmulatedEglWindowSurfaceToColorBuffer[p_surface] = p_colorbuffer;\n"
        "\n"
        "    return true;\n"
        "}\n",
        "    (*w).second.second = p_colorbuffer;\n"
        "\n"
        "    m_EmulatedEglWindowSurfaceToColorBuffer[p_surface] = p_colorbuffer;\n"
        "\n"
        "    return true;\n"
        "}\n"
        "\n"
        "// VMHost: guest 走 QEMU_PIPE + GoldfishGralloc 时，gralloc/mapper 不创建\n"
        "// host ColorBuffer（cb_handle.hostHandle==0），guest 把 0 传给 rcSetWindowColorBuffer。\n"
        "// 这里用窗口 surface 尺寸自动创建一个 ColorBuffer 并关联，作为渲染目标。\n"
        "// 注意 m_lock 是普通互斥锁，不能在持锁时调 createColorBuffer（其内部也锁 m_lock），\n"
        "// 所以分三步：锁内取尺寸 -> 解锁创建 -> 再锁回关联。\n"
        "void FrameBuffer::autoCreateWindowSurfaceColorBuffer(HandleType p_surface) {\n"
        "    GLuint sw = 0, sh = 0;\n"
        "    {\n"
        "        AutoLock mutex(m_lock);\n"
        "        EmulatedEglWindowSurfaceMap::iterator w(m_windows.find(p_surface));\n"
        "        if (w == m_windows.end()) {\n"
        "            ERR(\"autoCreateWindowSurfaceColorBuffer: bad surface %#x\", p_surface);\n"
        "            return;\n"
        "        }\n"
        "        sw = w->second.first->getWidth();\n"
        "        sh = w->second.first->getHeight();\n"
        "    }\n"
        "    if (sw == 0 || sh == 0) {\n"
        "        fprintf(stderr, \"VMHOSTGFX autoCreateWindowSurfaceColorBuffer: surface %#x size %ux%u\\n\",\n"
        "                p_surface, sw, sh);\n"
        "        return;\n"
        "    }\n"
        "    HandleType cb = createColorBuffer(sw, sh, GL_RGBA, FRAMEWORK_FORMAT_GL_COMPATIBLE);\n"
        "    if (!cb) {\n"
        "        ERR(\"autoCreateWindowSurfaceColorBuffer: createColorBuffer %ux%u failed\", sw, sh);\n"
        "        return;\n"
        "    }\n"
        "    fprintf(stderr, \"VMHOSTGFX auto-created ColorBuffer 0x%x %ux%u for surface 0x%x (guest hostHandle=0)\\n\",\n"
        "            cb, sw, sh, p_surface);\n"
        "    setEmulatedEglWindowSurfaceColorBuffer(p_surface, cb);\n"
        "}\n",
        "impl",
    ),
])

# ---- RenderControl.cpp: rcSetWindowColorBuffer 兜底 ----
r = "/root/vmbuild/gfxstream/host/RenderControl.cpp"
patch(r, [
    (
        "static void rcSetWindowColorBuffer(uint32_t windowSurface,\n"
        "                                   uint32_t colorBuffer)\n"
        "{\n"
        "    FrameBuffer *fb = FrameBuffer::getFB();\n"
        "    if (!fb) {\n"
        "        return;\n"
        "    }\n"
        "    fb->setEmulatedEglWindowSurfaceColorBuffer(windowSurface, colorBuffer);\n"
        "}\n",
        "static void rcSetWindowColorBuffer(uint32_t windowSurface,\n"
        "                                   uint32_t colorBuffer)\n"
        "{\n"
        "    FrameBuffer *fb = FrameBuffer::getFB();\n"
        "    if (!fb) {\n"
        "        return;\n"
        "    }\n"
        "    if (colorBuffer == 0) {\n"
        "        // VMHost: guest 的 gralloc/mapper 未创建 host ColorBuffer（hostHandle==0），\n"
        "        // 自动创建兜底，保证窗口 surface 有渲染目标。\n"
        "        fb->autoCreateWindowSurfaceColorBuffer(windowSurface);\n"
        "        return;\n"
        "    }\n"
        "    fb->setEmulatedEglWindowSurfaceColorBuffer(windowSurface, colorBuffer);\n"
        "}\n",
        "rcSetWindowColorBuffer fallback",
    ),
])
