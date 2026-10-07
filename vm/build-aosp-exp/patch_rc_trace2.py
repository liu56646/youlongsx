# -*- coding: utf-8 -*-
# D1a 诊断（第 2 轮）：补 gralloc 关键路径 trace —— rcCreateColorBufferWithHandle /
# rcUpdateColorBuffer(DMA) + goldfish_address_space 分配，判断 guest buffer 分配是否成功。
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
        "static void rcCreateColorBufferWithHandle(\n"
        "    uint32_t width, uint32_t height, GLenum internalFormat, uint32_t handle)\n"
        "{\n"
        "    FrameBuffer *fb = FrameBuffer::getFB();\n"
        "\n"
        "    if (!fb) {\n"
        "        return;\n"
        "    }\n"
        "\n"
        "    fb->createColorBufferWithHandle(\n"
        "        width, height, internalFormat,\n"
        "        FRAMEWORK_FORMAT_GL_COMPATIBLE, handle);\n"
        "}",
        "static void rcCreateColorBufferWithHandle(\n"
        "    uint32_t width, uint32_t height, GLenum internalFormat, uint32_t handle)\n"
        "{\n"
        "    fprintf(stderr, \"RC_TRACE rcCreateColorBufferWithHandle w=%u h=%u fmt=0x%x handle=0x%x\\n\",\n"
        "            width, height, internalFormat, handle);\n"
        "    FrameBuffer *fb = FrameBuffer::getFB();\n"
        "\n"
        "    if (!fb) {\n"
        "        return;\n"
        "    }\n"
        "\n"
        "    fb->createColorBufferWithHandle(\n"
        "        width, height, internalFormat,\n"
        "        FRAMEWORK_FORMAT_GL_COMPATIBLE, handle);\n"
        "}",
        "rcCreateColorBufferWithHandle",
    ),
    (
        "static int rcUpdateColorBuffer(uint32_t colorBuffer,\n"
        "                               GLint x, GLint y,\n"
        "                               GLint width, GLint height,\n"
        "                               GLenum format, GLenum type, void* pixels)\n"
        "{\n"
        "    FrameBuffer *fb = FrameBuffer::getFB();\n"
        "\n"
        "    if (!fb) {\n",
        "static int rcUpdateColorBuffer(uint32_t colorBuffer,\n"
        "                               GLint x, GLint y,\n"
        "                               GLint width, GLint height,\n"
        "                               GLenum format, GLenum type, void* pixels)\n"
        "{\n"
        "    fprintf(stderr, \"RC_TRACE rcUpdateColorBuffer cb=0x%x %dx%d+%d+%d fmt=0x%x\\n\",\n"
        "            colorBuffer, width, height, x, y, format);\n"
        "    FrameBuffer *fb = FrameBuffer::getFB();\n"
        "\n"
        "    if (!fb) {\n",
        "rcUpdateColorBuffer",
    ),
    (
        "static int rcUpdateColorBufferDMA(uint32_t colorBuffer,\n"
        "                                  GLint x, GLint y,\n"
        "                                  GLint width, GLint height,\n"
        "                                  GLenum format, GLenum type,\n"
        "                                  void* pixels, uint32_t pixels_size)\n"
        "{\n"
        "    FrameBuffer *fb = FrameBuffer::getFB();\n"
        "\n"
        "    if (!fb) {\n",
        "static int rcUpdateColorBufferDMA(uint32_t colorBuffer,\n"
        "                                  GLint x, GLint y,\n"
        "                                  GLint width, GLint height,\n"
        "                                  GLenum format, GLenum type,\n"
        "                                  void* pixels, uint32_t pixels_size)\n"
        "{\n"
        "    fprintf(stderr, \"RC_TRACE rcUpdateColorBufferDMA cb=0x%x %dx%d+%d+%d size=%u\\n\",\n"
        "            colorBuffer, width, height, x, y, pixels_size);\n"
        "    FrameBuffer *fb = FrameBuffer::getFB();\n"
        "\n"
        "    if (!fb) {\n",
        "rcUpdateColorBufferDMA",
    ),
])

asf = "/root/vmbuild/qemu-aosp/hw/pci/goldfish_address_space.c"
patch(asf, [
    (
        "int goldfish_address_space_alloc_shared_host_region(\n"
        "    uint64_t page_aligned_size, uint64_t* offset)\n"
        "{\n"
        "    uint64_t offset_out = ANDROID_EMU_ADDRESS_SPACE_BAD_OFFSET;\n"
        "    int res;\n"
        "\n"
        "    if (!s_current_state)\n"
        "    {\n"
        "        fprintf(stderr, \"%s: ERROR: no allocator present!\\n\", __func__);\n"
        "        return -EINVAL;\n"
        "    }\n"
        "\n"
        "    qemu_mutex_lock(&s_current_state->mutex);\n"
        "\n"
        "    res = goldfish_address_space_alloc_shared_host_region_locked(\n"
        "        page_aligned_size, offset);\n"
        "\n"
        "    qemu_mutex_unlock(&s_current_state->mutex);\n"
        "\n"
        "    return res;\n"
        "}",
        "int goldfish_address_space_alloc_shared_host_region(\n"
        "    uint64_t page_aligned_size, uint64_t* offset)\n"
        "{\n"
        "    uint64_t offset_out = ANDROID_EMU_ADDRESS_SPACE_BAD_OFFSET;\n"
        "    int res;\n"
        "\n"
        "    if (!s_current_state)\n"
        "    {\n"
        "        fprintf(stderr, \"%s: ERROR: no allocator present!\\n\", __func__);\n"
        "        return -EINVAL;\n"
        "    }\n"
        "\n"
        "    qemu_mutex_lock(&s_current_state->mutex);\n"
        "\n"
        "    res = goldfish_address_space_alloc_shared_host_region_locked(\n"
        "        page_aligned_size, offset);\n"
        "\n"
        "    qemu_mutex_unlock(&s_current_state->mutex);\n"
        "\n"
        "    fprintf(stderr, \"AS_TRACE alloc_shared_host_region size=%llu -> res=%d offset=%llu\\n\",\n"
        "            (unsigned long long)page_aligned_size, res,\n"
        "            offset ? (unsigned long long)*offset : 0ULL);\n"
        "    return res;\n"
        "}",
        "alloc_shared_host_region",
    ),
])
