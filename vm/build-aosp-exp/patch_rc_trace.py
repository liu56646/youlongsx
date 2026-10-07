# -*- coding: utf-8 -*-
# D1a 诊断：给 gfxstream 渲染命令加日志，观察 guest 是否真的创建 ColorBuffer /
# post / setDisplayColorBuffer，以定位"帧没进 FrameBuffer"的断点。
import io, sys

def patch(path, pairs):
    src = io.open(path, encoding="utf-8").read()
    for old, new, tag in pairs:
        if old in src:
            src = src.replace(old, new, 1)
            print("OK[%s]: %s" % (path, tag))
        else:
            print("MISS[%s]: %s" % (path, tag))
    io.open(path, "w", encoding="utf-8").write(src)

rc = "/root/vmbuild/gfxstream/host/RenderControl.cpp"
patch(rc, [
    (
        "static uint32_t rcCreateColorBuffer(uint32_t width,\n"
        "                                    uint32_t height, GLenum internalFormat)\n"
        "{\n"
        "    FrameBuffer *fb = FrameBuffer::getFB();\n"
        "    if (!fb) {\n"
        "        return 0;\n"
        "    }\n"
        "\n"
        "    return fb->createColorBuffer(width, height, internalFormat,\n"
        "                                 FRAMEWORK_FORMAT_GL_COMPATIBLE);\n"
        "}",
        "static uint32_t rcCreateColorBuffer(uint32_t width,\n"
        "                                    uint32_t height, GLenum internalFormat)\n"
        "{\n"
        "    FrameBuffer *fb = FrameBuffer::getFB();\n"
        "    if (!fb) {\n"
        "        return 0;\n"
        "    }\n"
        "    uint32_t cb = fb->createColorBuffer(width, height, internalFormat,\n"
        "                                        FRAMEWORK_FORMAT_GL_COMPATIBLE);\n"
        "    fprintf(stderr, \"RC_TRACE rcCreateColorBuffer w=%u h=%u fmt=0x%x -> cb=0x%x\\n\",\n"
        "            width, height, internalFormat, cb);\n"
        "    return cb;\n"
        "}",
        "rcCreateColorBuffer",
    ),
    (
        "static void rcFBPost(uint32_t colorBuffer)\n"
        "{\n"
        "    FrameBuffer *fb = FrameBuffer::getFB();\n"
        "    if (!fb) {\n"
        "        return;\n"
        "    }\n"
        "\n"
        "    fb->post(colorBuffer);\n"
        "}",
        "static void rcFBPost(uint32_t colorBuffer)\n"
        "{\n"
        "    FrameBuffer *fb = FrameBuffer::getFB();\n"
        "    if (!fb) {\n"
        "        return;\n"
        "    }\n"
        "    fprintf(stderr, \"RC_TRACE rcFBPost cb=0x%x\\n\", colorBuffer);\n"
        "    bool ok = fb->post(colorBuffer);\n"
        "    fprintf(stderr, \"RC_TRACE rcFBPost cb=0x%x post_ret=%d\\n\", colorBuffer, ok ? 1 : 0);\n"
        "}",
        "rcFBPost",
    ),
    (
        "static int rcSetDisplayColorBuffer(uint32_t displayId, uint32_t colorBuffer) {\n"
        "    FrameBuffer *fb = FrameBuffer::getFB();\n"
        "    if (!fb) {\n"
        "        return -1;\n"
        "    }\n"
        "\n"
        "    return fb->setDisplayColorBuffer(displayId, colorBuffer);\n"
        "}",
        "static int rcSetDisplayColorBuffer(uint32_t displayId, uint32_t colorBuffer) {\n"
        "    FrameBuffer *fb = FrameBuffer::getFB();\n"
        "    if (!fb) {\n"
        "        return -1;\n"
        "    }\n"
        "    fprintf(stderr, \"RC_TRACE rcSetDisplayColorBuffer display=%u cb=0x%x\\n\",\n"
        "            displayId, colorBuffer);\n"
        "    int ret = fb->setDisplayColorBuffer(displayId, colorBuffer);\n"
        "    fprintf(stderr, \"RC_TRACE rcSetDisplayColorBuffer display=%u cb=0x%x ret=%d\\n\",\n"
        "            displayId, colorBuffer, ret);\n"
        "    return ret;\n"
        "}",
        "rcSetDisplayColorBuffer",
    ),
])

fb = "/root/vmbuild/gfxstream/host/FrameBuffer.cpp"
patch(fb, [
    (
        "bool FrameBuffer::post(HandleType p_colorbuffer, bool needLockAndBind) {\n"
        "    if (m_guestUsesAngle) {\n"
        "        flushColorBufferFromGl(p_colorbuffer);\n"
        "    }\n",
        "bool FrameBuffer::post(HandleType p_colorbuffer, bool needLockAndBind) {\n"
        "    fprintf(stderr, \"RC_TRACE FrameBuffer::post cb=0x%x\\n\", p_colorbuffer);\n"
        "    if (m_guestUsesAngle) {\n"
        "        flushColorBufferFromGl(p_colorbuffer);\n"
        "    }\n",
        "FrameBuffer::post",
    ),
])
