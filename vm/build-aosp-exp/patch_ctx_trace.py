# -*- coding: utf-8 -*-
# emu-34 深挖：给 EGL 初始化命令加 trace（rcCreateContext/rcMakeCurrent/rcSetPuid）
import io, sys

f = "/root/vmbuild/gfxstream/host/RenderControl.cpp"
src = io.open(f, encoding="utf-8").read()

pairs = [
    (
        "static uint32_t rcCreateContext(uint32_t config,\n"
        "                                uint32_t share, uint32_t glVersion)\n"
        "{\n"
        "    FrameBuffer *fb = FrameBuffer::getFB();\n"
        "    if (!fb) {\n"
        "        return 0;\n"
        "    }\n"
        "\n"
        "    HandleType ret = fb->createEmulatedEglContext(config, share, (GLESApi)glVersion);\n"
        "    return ret;\n"
        "}",
        "static uint32_t rcCreateContext(uint32_t config,\n"
        "                                uint32_t share, uint32_t glVersion)\n"
        "{\n"
        "    fprintf(stderr, \"RC_TRACE rcCreateContext config=%u share=%u glVersion=%u\\n\",\n"
        "            config, share, glVersion);\n"
        "    FrameBuffer *fb = FrameBuffer::getFB();\n"
        "    if (!fb) {\n"
        "        return 0;\n"
        "    }\n"
        "\n"
        "    HandleType ret = fb->createEmulatedEglContext(config, share, (GLESApi)glVersion);\n"
        "    fprintf(stderr, \"RC_TRACE rcCreateContext -> ctx=0x%x\\n\", ret);\n"
        "    return ret;\n"
        "}",
        "rcCreateContext",
    ),
    (
        "static EGLint rcMakeCurrent(uint32_t context,\n"
        "                            uint32_t drawSurf, uint32_t readSurf)\n"
        "{\n"
        "    FrameBuffer *fb = FrameBuffer::getFB();\n"
        "    if (!fb) {\n"
        "        return EGL_FALSE;\n"
        "    }\n"
        "\n"
        "    bool ret = fb->bindContext(context, drawSurf, readSurf);\n"
        "\n"
        "    return (ret ? EGL_TRUE : EGL_FALSE);\n"
        "}",
        "static EGLint rcMakeCurrent(uint32_t context,\n"
        "                            uint32_t drawSurf, uint32_t readSurf)\n"
        "{\n"
        "    fprintf(stderr, \"RC_TRACE rcMakeCurrent ctx=0x%x draw=0x%x read=0x%x\\n\",\n"
        "            context, drawSurf, readSurf);\n"
        "    FrameBuffer *fb = FrameBuffer::getFB();\n"
        "    if (!fb) {\n"
        "        return EGL_FALSE;\n"
        "    }\n"
        "\n"
        "    bool ret = fb->bindContext(context, drawSurf, readSurf);\n"
        "    fprintf(stderr, \"RC_TRACE rcMakeCurrent -> %d\\n\", ret ? 1 : 0);\n"
        "\n"
        "    return (ret ? EGL_TRUE : EGL_FALSE);\n"
        "}",
        "rcMakeCurrent",
    ),
    (
        "static void rcSetPuid(uint64_t puid) {\n"
        "    if (puid == kInvalidPUID) {\n"
        "        // The host process pipe implementation (GLProcessPipe) has been updated\n"
        "        // to not generate a unique pipe id when running with virtio gpu and\n"
        "        // instead send -1 to the guest. Ignore those requests as the PUID will\n"
        "        // instead be the virtio gpu context id.\n"
        "        return;\n"
        "    }\n"
        "\n"
        "    RenderThreadInfo *tInfo = RenderThreadInfo::get();\n"
        "    tInfo->m_puid = puid;\n"
        "}",
        "static void rcSetPuid(uint64_t puid) {\n"
        "    if (puid == kInvalidPUID) {\n"
        "        return;\n"
        "    }\n"
        "\n"
        "    fprintf(stderr, \"RC_TRACE rcSetPuid puid=%llu\\n\", (unsigned long long)puid);\n"
        "    RenderThreadInfo *tInfo = RenderThreadInfo::get();\n"
        "    tInfo->m_puid = puid;\n"
        "}",
        "rcSetPuid",
    ),
]
for old, new, tag in pairs:
    if old in src:
        src = src.replace(old, new, 1)
        print("OK: %s" % tag)
    else:
        print("MISS: %s" % tag)
io.open(f, "w", encoding="utf-8").write(src)
