#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把「宿主侧诊断插桩」幂等地补进 gfxstream 源码树 —— VMHOST_DIAG 系列。

为什么需要这个脚本：
    这批插桩（GLES2 命令直方图/环形缓冲、ColorBuffer 的 blit 与 readback 探针、
    TextureDraw 链接结果、FrameBuffer::post 打点）此前是直接改在 WSL 源码树里的，
    换机器或重新 clone 后不可复现。这里把它们固化成幂等补丁，由
    engine/scripts/build_gfxstream.sh 调用。

设计要点：
    - **逐条幂等**：每条编辑有自己的 marker；marker 已在文件里就跳过，
      所以反复执行安全。
    - **只告警不中断**：诊断插桩不是构建必需，锚点没命中时打印 WARN 继续
      （上游代码漂移不应该把整条构建链卡死）。
    - 输出都带 `VMHOST_DIAG` / `VMHOST_*` 前缀，方便 grep 与事后清理。

用法：
    python3 patch_vmhost_diag.py <gfxstream 源码根目录>
"""

import io
import os
import sys

# (相对路径, marker, [(old, new), ...])
# marker 出现在文件里 => 认为这条已打过，跳过。
EDITS = []


def edit(relpath, marker, pairs, note=""):
    EDITS.append((relpath, marker, pairs, note))


# ----------------------------------------------------------------------------
# 1) GLES2 解码器：命令直方图 + 崩溃前最后 64 条 + 低频调用参数
# ----------------------------------------------------------------------------
GLES2_HELPER = r'''/*
 * VMHOST_DIAG: GLES2 命令直方图 + 最近 64 条环形缓冲。
 *
 * 为什么不能逐条 fprintf：GLES2 是真正的渲染流量（每帧几千条），逐条打印会把
 * qemu-stderr.log 写爆并拖慢 TCG。所以这里只累计计数，每 20 万条 dump 一次累计
 * 直方图；崩溃时由崩溃处理器（vmhost_pipe_glue.cpp）回调 vmhost_gles2_dump_recent()
 * 打印最后 64 条 —— 那正是把宿主驱动打崩的那串调用。
 */
namespace {
constexpr int kRecentCap = 64;
constexpr uint32_t kMaxOp = 70000;
struct RecentOp { uint32_t opcode; uint32_t len; };
RecentOp g_recent[kRecentCap];
int      g_recentPos = 0;
uint32_t g_counts[kMaxOp];
uint64_t g_total = 0;
uint64_t g_lastDumpTotal = 0;
}  // namespace

/* VMHOST_DIAG: 低频但关键的调用 —— 逐个打印参数（每帧只有几条，不会写爆日志）。
   这些正是崩溃前最后 64 条里出现的那些。 */
static bool vmhost_gles2_lowfreq(uint32_t opcode) {
    switch (opcode) {
        case 2052:  /* glBindFramebuffer */
        case 2062:  /* glCheckFramebufferStatus */
        case 2095:  /* glFramebufferTexture2D */
        case 2111:  /* glGetIntegerv */
        case 2137:  /* glLinkProgram */
        case 2178:  /* glUseProgram */
        case 2189:  /* glViewport */
        case 10015: /* rcSetWindowColorBuffer */
        case 10016: /* rcFlushWindowColorBuffer */
        case 10018: /* rcFBPost */
        case 10020: /* rcBindTexture */
        case 10035: /* rcCreateColorBufferDMA */
            return true;
        default:
            return false;
    }
}

static void vmhost_gles2_note(uint32_t opcode, uint32_t len, const unsigned char* p) {
    if (opcode < kMaxOp) {
        g_counts[opcode]++;
    }
    g_recent[g_recentPos].opcode = opcode;
    g_recent[g_recentPos].len = len;
    g_recentPos = (g_recentPos + 1) % kRecentCap;
    g_total++;

    if (vmhost_gles2_lowfreq(opcode)) {
        /* 按包长逐级打印：rc 包的 len 只有 12/16，不能只看 len>=20 */
        char args[80] = {0};
        int n = snprintf(args, sizeof(args), "a0=0x%x",
                         len >= 12 ? *(const uint32_t*)(p + 8) : 0u);
        if (len >= 16) {
            n += snprintf(args + n, sizeof(args) - n, " a1=0x%x",
                          *(const uint32_t*)(p + 12));
        }
        if (len >= 20) {
            (void)snprintf(args + n, sizeof(args) - n, " a2=0x%x",
                           *(const uint32_t*)(p + 16));
        }
        fprintf(stderr, "VMHOST_GLES2_LOWFREQ op=%u len=%u %s\n", opcode, len, args);
    }

    if (g_total - g_lastDumpTotal >= 200000) {
        g_lastDumpTotal = g_total;
        fprintf(stderr, "VMHOST_GLES2_HIST total=%llu\n",
                (unsigned long long) g_total);
        for (uint32_t i = 0; i < kMaxOp; i++) {
            if (g_counts[i]) {
                fprintf(stderr, "VMHOST_GLES2_HIST op=%u n=%u\n", i, g_counts[i]);
            }
        }
    }
}

extern "C" void vmhost_gles2_dump_recent(void) {
    fprintf(stderr, "VMHOST_GLES2_RECENT total=%llu\n",
            (unsigned long long) g_total);
    for (int i = 0; i < kRecentCap; i++) {
        const int idx = (g_recentPos + i) % kRecentCap;
        fprintf(stderr, "VMHOST_GLES2_RECENT op=%u len=%u\n",
                g_recent[idx].opcode, g_recent[idx].len);
    }
}

'''

edit("host/gl/gles2_dec/gles2_dec.cpp", "VMHOST_GLES2_HIST",
     [("typedef unsigned int tsize_t; // Target \"size_t\"",
       GLES2_HELPER + "typedef unsigned int tsize_t; // Target \"size_t\"")],
     note="GLES2 直方图/环形缓冲/低频参数")

edit("host/gl/gles2_dec/gles2_dec.cpp", "vmhost_gles2_note(opcode, packetLen, ptr)",
     [("\t\tuint32_t packetLen = *(uint32_t *)(ptr + 4);\n\t\tif (end - ptr < packetLen) return ptr - (unsigned char*)buf;",
       "\t\tuint32_t packetLen = *(uint32_t *)(ptr + 4);\n\t\tvmhost_gles2_note(opcode, packetLen, ptr);   /* VMHOST_DIAG */\n\t\tif (end - ptr < packetLen) return ptr - (unsigned char*)buf;")],
     note="在解码循环里调用 note()")


# ----------------------------------------------------------------------------
# 2) ColorBufferGl：blit 分段日志 + 源/目标采样 + readback 内容校验
# ----------------------------------------------------------------------------
edit("host/gl/ColorBufferGl.cpp", "VMHOST_BLIT enter",
     [("""    if (!tInfo->currContext.get()) {
        // no Current context
        return false;
    }

    if (m_fastBlitSupported) {""",
       """    if (!tInfo->currContext.get()) {
        // no Current context
        return false;
    }

    /* VMHOST_DIAG: 进 blit 前先读一次 GL 错误队列 —— 每帧 glClear 前那个
       0x502(INVALID_OPERATION) 是上一条调用留下的，这里能确认它是不是在
       本函数之前就已经存在。注意 glGetError 会清空队列。 */
    fprintf(stderr, "VMHOST_BLIT enter fastBlit=%d pendingErr=0x%x clientVer=%d\\n",
            (int)m_fastBlitSupported, s_gles2.glGetError(),
            (int)tInfo->currContext->clientVersion());

    if (m_fastBlitSupported) {""")],
     note="blit 入口日志")

edit("host/gl/ColorBufferGl.cpp", "VMHOST_BLIT copy_done",
     [("""            if (prev_fbo != 0) {
                s_gles2.glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)prev_fbo);
            }
        }
""",
       """            if (prev_fbo != 0) {
                s_gles2.glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)prev_fbo);
            }
        }

        /* VMHOST_DIAG: 把"当前读缓冲 → m_blitTex"的拷贝做完后的错误打出来
           （GLES1 客户端走 s_gles1.glCopyTexSubImage2D 那条分支） */
        fprintf(stderr, "VMHOST_BLIT copy_done m_blitTex=%u err=0x%x\\n",
                m_blitTex, s_gles2.glGetError());
""")],
     note="拷贝结束错误")

edit("host/gl/ColorBufferGl.cpp", "VMHOST_BLIT src",
     [("""        // render m_blitTex
        m_textureDraw->draw(m_blitTex, 0., 0, 0);
""",
       """        /* VMHOST_DIAG: 采样搬运的"源" m_blitTex（用临时 FBO 读 8x8 像素）。
           它全 0 → 问题在"当前读缓冲 → m_blitTex"的拷贝（即访客渲染的目标
           与我们拷贝的宿主 surface 不是同一个）；它有内容而 m_tex 是 0 →
           问题在下面那次 TextureDraw 绘制。 */
        {
            uint8_t block[8 * 8 * 4] = {0};
            GLint prevFbo = 0;
            GLuint tmpFbo = 0;
            s_gles2.glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prevFbo);
            s_gles2.glGenFramebuffers(1, &tmpFbo);
            s_gles2.glBindFramebuffer(GL_FRAMEBUFFER, tmpFbo);
            s_gles2.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                           GL_TEXTURE_2D, m_blitTex, 0);
            const GLenum st = s_gles2.glCheckFramebufferStatus(GL_FRAMEBUFFER);
            s_gles2.glReadPixels(m_width / 2 - 4, m_height / 2 - 4, 8, 8,
                                 GL_RGBA, GL_UNSIGNED_BYTE, block);
            size_t nz = 0;
            for (size_t i = 0; i < sizeof(block); i++) {
                if (block[i]) nz++;
            }
            fprintf(stderr,
                    "VMHOST_BLIT src m_blitTex=%u fboStatus=0x%x nonzero=%zu/256 err=0x%x\\n",
                    m_blitTex, st, nz, s_gles2.glGetError());
            s_gles2.glBindFramebuffer(GL_FRAMEBUFFER, prevFbo);
            s_gles2.glDeleteFramebuffers(1, &tmpFbo);
        }

        // render m_blitTex
        m_textureDraw->draw(m_blitTex, 0., 0, 0);
""")],
     note="blit 源采样")

edit("host/gl/ColorBufferGl.cpp", "VMHOST_BLIT dst",
     [("""        // render m_blitTex
        m_textureDraw->draw(m_blitTex, 0., 0, 0);
""",
       """        // render m_blitTex
        m_textureDraw->draw(m_blitTex, 0., 0, 0);

        /* VMHOST_DIAG: 采样搬运的**目标** m_tex —— 与 src 对照即可判定
           「搬运是把内容写进了目标，还是只写进了源」。 */
        {
            uint8_t block[8 * 8 * 4] = {0};
            GLint prevFbo = 0;
            GLuint tmpFbo = 0;
            s_gles2.glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prevFbo);
            s_gles2.glGenFramebuffers(1, &tmpFbo);
            s_gles2.glBindFramebuffer(GL_FRAMEBUFFER, tmpFbo);
            s_gles2.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                           GL_TEXTURE_2D, m_tex, 0);
            s_gles2.glReadPixels(m_width / 2 - 4, m_height / 2 - 4, 8, 8,
                                 GL_RGBA, GL_UNSIGNED_BYTE, block);
            size_t nz = 0;
            for (size_t i = 0; i < sizeof(block); i++) {
                if (block[i]) nz++;
            }
            fprintf(stderr, "VMHOST_BLIT dst m_tex=%u nonzero=%zu/256 err=0x%x\\n",
                    m_tex, nz, s_gles2.glGetError());
            s_gles2.glBindFramebuffer(GL_FRAMEBUFFER, prevFbo);
            s_gles2.glDeleteFramebuffers(1, &tmpFbo);
        }
""")],
     note="blit 目标采样")

edit("host/gl/ColorBufferGl.cpp", "VMHOST_BLIT after_viewport",
     [("""        // Restore previous viewport.
        s_gles2.glViewport(vport[0], vport[1], vport[2], vport[3]);
        unbindFbo();""",
       """        // Restore previous viewport.
        s_gles2.glViewport(vport[0], vport[1], vport[2], vport[3]);
        /* VMHOST_DIAG: 逐调用定位那个每帧一次的 0x502 到底是哪一行产生的 */
        fprintf(stderr, "VMHOST_BLIT after_viewport err=0x%x\\n", s_gles2.glGetError());
        unbindFbo();
        fprintf(stderr, "VMHOST_BLIT after_unbind err=0x%x\\n", s_gles2.glGetError());""")],
     note="0x502 逐调用定位")

edit("host/gl/ColorBufferGl.cpp", "VMHOST_READBACK",
     [("""void ColorBufferGl::readback(unsigned char* img, bool readbackBgra) {
    RecursiveScopedContextBind context(m_helper);
    if (!context.isOk()) {
        return;
    }

    waitSync();

    if (bindFbo(&m_fbo, m_tex, m_needFboReattach)) {
        m_needFboReattach = false;
        // Flip the readback format if RED/BLUE components are swizzled.
        bool shouldReadbackBgra = m_BRSwizzle ? !readbackBgra : readbackBgra;
        GLenum format = shouldReadbackBgra ? GL_BGRA_EXT : GL_RGBA;

        s_gles2.glReadPixels(0, 0, m_width, m_height, format, GL_UNSIGNED_BYTE, img);
        unbindFbo();
    }
}""",
       """void ColorBufferGl::readback(unsigned char* img, bool readbackBgra) {
    RecursiveScopedContextBind context(m_helper);
    if (!context.isOk()) {
        fprintf(stderr, "VMHOST_READBACK contextBIND failed tex=%u\\n", m_tex);
        return;
    }

    waitSync();

    if (bindFbo(&m_fbo, m_tex, m_needFboReattach)) {
        m_needFboReattach = false;
        // Flip the readback format if RED/BLUE components are swizzled.
        bool shouldReadbackBgra = m_BRSwizzle ? !readbackBgra : readbackBgra;
        GLenum format = shouldReadbackBgra ? GL_BGRA_EXT : GL_RGBA;

        s_gles2.glReadPixels(0, 0, m_width, m_height, format, GL_UNSIGNED_BYTE, img);

        /* VMHOST_DIAG: 内容校验 —— 读回来的到底是不是黑的？
           与写入侧（VMHOST_BLIT src/dst）对照即可判定黑帧在读侧还是写侧。 */
        {
            const size_t total = (size_t) m_width * (size_t) m_height * 4u;
            size_t nz = 0;
            for (size_t i = 0; i < total; i += 64u) {
                if (img[i]) nz++;
            }
            fprintf(stderr,
                    "VMHOST_READBACK tex=%u %dx%d sampled=%zu nonzero=%zu err=0x%x\\n",
                    m_tex, m_width, m_height, total / 64u, nz, s_gles2.glGetError());
        }
        unbindFbo();
    } else {
        /* 原来是静默 return —— 那会表现为"回调照常触发、内容恒为 0" */
        fprintf(stderr, "VMHOST_READBACK bindFbo FAILED tex=%u\\n", m_tex);
    }
}""")],
     note="readback 内容校验")


# ----------------------------------------------------------------------------
# 3) TextureDraw：program 链接结果（排除"GLSL 在 Adreno 上编译失败"的历史坑）
# ----------------------------------------------------------------------------
edit("host/gl/TextureDraw.cpp", "VMHOST_TEXTUREDRAW",
     [("""        glGetProgramInfoLog(
                mProgram, sizeof(messages), 0, &messages[0]);
        ERR("%s: Could not create/link program: %s\\n", __FUNCTION__, messages);""",
       """        glGetProgramInfoLog(
                mProgram, sizeof(messages), 0, &messages[0]);
        /* VMHOST_DIAG: 本项目历史上 TextureDraw 的 GLSL 在 Adreno 上编译失败
           （GLESVersionDetector 为此把渲染器压到 ES2）。链接失败 → mProgram=0
           → 后续所有 draw 静默无效 → 画面全黑。 */
        fprintf(stderr, "VMHOST_TEXTUREDRAW link FAILED: %s\\n", &messages[0]);
        ERR("%s: Could not create/link program: %s\\n", __FUNCTION__, messages);"""),
      ("""    s_gles2.glUseProgram(mProgram);

    // Retrieve attribute/uniform locations.""",
       """    s_gles2.glUseProgram(mProgram);

    /* VMHOST_DIAG: 程序是否真的可用（program=0 说明创建/链接失败） */
    fprintf(stderr, "VMHOST_TEXTUREDRAW program=%u vs=%u fs=%u link_ok=%d err=0x%x\\n",
            mProgram, mVertexShader, mFragmentShader, (int)success,
            s_gles2.glGetError());

    // Retrieve attribute/uniform locations.""")],
     note="TextureDraw 链接结果")


# ----------------------------------------------------------------------------
# 4) FrameBuffer::post：记录被 post 的 ColorBuffer（访客 handle ↔ 宿主 GL 纹理）
# ----------------------------------------------------------------------------
edit("host/FrameBuffer.cpp", "VMHOST_POST handle=",
     [("""    m_lastPostedColorBuffer = p_colorbuffer;
""",
       """    m_lastPostedColorBuffer = p_colorbuffer;

    /* VMHOST_DIAG: 记录"被 post 的那块 buffer"——访客 handle 与宿主 GL 纹理名。
       与 VMHOST_BLIT 的目标纹理对照，即可判定"渲染的 buffer 是否就是被 post 的
       buffer"（黑帧的直接原因）。 */
    fprintf(stderr, "VMHOST_POST handle=0x%llx cbHndl=0x%llx tex=%u %ux%u\\n",
            (unsigned long long) p_colorbuffer,
            (unsigned long long) colorBuffer->getHndl(),
            (unsigned) colorBuffer->glOpGetTexture(),
            colorBuffer->getWidth(), colorBuffer->getHeight());
""")],
     note="post 的 ColorBuffer 打点")


# ----------------------------------------------------------------------------
# 执行
# ----------------------------------------------------------------------------
def main():
    if len(sys.argv) < 2:
        print("用法: patch_vmhost_diag.py <gfxstream 源码根目录>", file=sys.stderr)
        return 1
    root = sys.argv[1]
    applied = 0
    skipped = 0
    missed = 0

    for relpath, marker, pairs, note in EDITS:
        path = os.path.join(root, relpath)
        if not os.path.isfile(path):
            print("WARN  文件不存在，跳过：%s" % relpath)
            missed += 1
            continue

        src = io.open(path, encoding="utf-8").read()
        if marker in src:
            skipped += 1
            continue

        new_src = src
        ok = True
        for old, new in pairs:
            if old not in new_src:
                print("WARN  锚点未命中（%s）：%s" % (note or marker, relpath))
                ok = False
                break
            new_src = new_src.replace(old, new, 1)

        if not ok:
            missed += 1
            continue

        io.open(path, "w", encoding="utf-8").write(new_src)
        print("APPLY %-28s %s" % (note or marker, relpath))
        applied += 1

    print("VMHOST_DIAG 补丁完成：应用 %d 条，已存在 %d 条，未命中 %d 条"
          % (applied, skipped, missed))
    # 诊断插桩不是构建必需，未命中只告警
    return 0


if __name__ == "__main__":
    sys.exit(main())
