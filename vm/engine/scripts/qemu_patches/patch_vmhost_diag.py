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
        case 2153:  /* glTexImage2D   —— 看尺寸/格式，判断访客有没有真上传纹理 */
        case 2158:  /* glTexSubImage2D */
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
        /* 按包长逐级打印参数（最多 7 个）：rc 包的 len 只有 12/16；
           glTexImage2D 要看 a3/a4 才是宽高，所以不能只打 3 个。 */
        char args[160] = {0};
        int n = 0;
        for (int i = 0; i < 7; i++) {
            if (len < (uint32_t)(12 + 4 * i)) {
                break;
            }
            n += snprintf(args + n, sizeof(args) - n, " a%d=0x%x",
                          i, *(const uint32_t*)(p + 8 + 4 * i));
        }
        fprintf(stderr, "VMHOST_GLES2_LOWFREQ op=%u len=%u%s\n", opcode, len, args);
    }

    if (g_total - g_lastDumpTotal >= 20000) {
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

# 在解码循环里调用 note()：**必须按"真实剩余字节"夹紧 packetLen**（§19 真正根因）。
#
# 上游把「这个包放不下就返回、让调用方补数据」的校验放在**我们这行之后**：
#     uint32_t packetLen = *(uint32_t *)(ptr + 4);
#     vmhost_gles2_note(opcode, packetLen, ptr);        <-- 我们插的
#     if (end - ptr < packetLen) return ptr - buf;      <-- 真正的校验在上游很后面
# 也就是说 packetLen 是访客自报值，**末尾那个包可能只到了一半**（正常情况：命令
# 缓冲被拆包，decode() 处理不完就返回），此时 packetLen > end - ptr。而 note() 内部
# 会按 len 读 `p + 8 + 4*i` 的参数 —— 不夹紧就会越过缓冲区末尾。当末尾恰好落在
# 页边界（scudo secondary 分配后面的 guard page）时，读到 PROT_NONE 页 →
# SIGSEGV si_code=2 打死整个 QEMU。这正是 §17.5「跑约 17 分钟必崩」的根因：
# 崩溃 pc 落在 gles2_decoder_context_t::decode() 里那条
# `ldr w5, [x25, x21]`（x25 = ptr + 8、x21 = 4*i），与 note() 的参数循环逐字对应。
#
# 修法：调用点先算 avail = end - ptr，传 min(packetLen, avail)，保证 note() 的所有
# 读取都落在 [ptr, end) 内（len >= 12 + 4*i 时读 p+8+4*i 才成立，read 结束于
# 12 + 4*i <= len <= avail，安全）。
GLES2_CALL_MARK = "VMHOST_DIAG: packetLen 是访客自报值"

GLES2_CALL_OLD = (
    "\t\tuint32_t packetLen = *(uint32_t *)(ptr + 4);\n"
    "\t\tvmhost_gles2_note(opcode, packetLen, ptr);   /* VMHOST_DIAG */\n")
GLES2_CALL_PRISTINE = "\t\tuint32_t packetLen = *(uint32_t *)(ptr + 4);\n"
GLES2_CALL_NEW = (
    "\t\tuint32_t packetLen = *(uint32_t *)(ptr + 4);\n"
    "\t\t/* " + GLES2_CALL_MARK + "，可能大于缓冲区实际剩余（上游校验在下一行才做）。\n"
    "\t\t   note() 会按 len 读 p+8+4*i 的参数，不夹紧就会越过缓冲区末尾；末尾落在\n"
    "\t\t   页边界（scudo guard page）时 SIGSEGV si_code=2 打死 QEMU（§19）。\n"
    "\t\t   这里按真实剩余字节 avail 夹紧，保证读取都在 [ptr, end) 内。 */\n"
    "\t\t{\n"
    "\t\t\tconst uint32_t vmhostAvail = (uint32_t)(end - ptr);\n"
    "\t\t\tvmhost_gles2_note(opcode, packetLen < vmhostAvail ? packetLen : vmhostAvail, ptr);\n"
    "\t\t}\n")


def apply_gles2_call_site(root):
    """幂等且能自愈旧版（未夹紧）注入。"""
    path = os.path.join(root, "host/gl/gles2_dec/gles2_dec.cpp")
    if not os.path.isfile(path):
        print("WARN  文件不存在，跳过：%s" % path)
        return "miss"
    src = io.open(path, encoding="utf-8").read()
    if GLES2_CALL_MARK in src:
        return "skip"
    if GLES2_CALL_OLD in src:                 # 旧版注入（未夹紧）：先替换掉
        src = src.replace(GLES2_CALL_OLD, GLES2_CALL_NEW, 1)
    elif GLES2_CALL_PRISTINE in src:          # 干净起点
        src = src.replace(GLES2_CALL_PRISTINE, GLES2_CALL_NEW, 1)
    else:
        print("WARN  解码循环调用点锚点未命中：%s" % path)
        return "miss"
    io.open(path, "w", encoding="utf-8").write(src)
    return "apply"


# ----------------------------------------------------------------------------
# 2) ColorBufferGl：blit 分段日志 + 源/目标采样 + readback 内容校验
# ----------------------------------------------------------------------------
edit("host/gl/ColorBufferGl.cpp", "VMHOST_FBO",
     [("""bool bindFbo(GLuint* fbo, GLuint tex, bool ensureTextureAttached) {
    if (*fbo) {
        // fbo already exist - just bind
        s_gles2.glBindFramebuffer(GL_FRAMEBUFFER, *fbo);
        if (ensureTextureAttached) {
            s_gles2.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0_OES,
                                           GL_TEXTURE_2D, tex, 0);
        }
        return true;
    }

    s_gles2.glGenFramebuffers(1, fbo);
    s_gles2.glBindFramebuffer(GL_FRAMEBUFFER, *fbo);
    s_gles2.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0_OES,
                                   GL_TEXTURE_2D, tex, 0);
""",
       """bool bindFbo(GLuint* fbo, GLuint tex, bool ensureTextureAttached) {
    if (*fbo) {
        // fbo already exist - just bind
        s_gles2.glBindFramebuffer(GL_FRAMEBUFFER, *fbo);
        if (ensureTextureAttached) {
            s_gles2.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0_OES,
                                           GL_TEXTURE_2D, tex, 0);
        }
        /* VMHOST_DIAG: 复用已有 FBO。注意 ensureTextureAttached=false 时**不会**重新
           挂附件 —— 若该 FBO 上挂的不是 tex，就会读到别的纹理（"读回恒为 0"的嫌疑点）。 */
        fprintf(stderr, "VMHOST_FBO reuse fbo=%u tex=%u attached=%d\\n",
                *fbo, tex, (int)ensureTextureAttached);
        return true;
    }

    s_gles2.glGenFramebuffers(1, fbo);
    s_gles2.glBindFramebuffer(GL_FRAMEBUFFER, *fbo);
    s_gles2.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0_OES,
                                   GL_TEXTURE_2D, tex, 0);
    fprintf(stderr, "VMHOST_FBO create fbo=%u tex=%u\\n", *fbo, tex);
""")],
     note="bindFbo 复用/新建分支日志")


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
            /* 只数 RGB 非零的像素（排除 alpha：A=255 会掩盖"其实是黑的"） */
            size_t nz = 0;
            for (size_t p = 0; p + 3 < sizeof(block); p += 4u) {
                if (block[p] | block[p + 1] | block[p + 2]) nz++;
            }
            fprintf(stderr,
                    "VMHOST_BLIT src m_blitTex=%u fboStatus=0x%x nonzeroRGB=%zu/64 err=0x%x\\n",
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
            /* 只数 RGB 非零的像素（排除 alpha） */
            size_t nz = 0;
            for (size_t p = 0; p + 3 < sizeof(block); p += 4u) {
                if (block[p] | block[p + 1] | block[p + 2]) nz++;
            }
            fprintf(stderr, "VMHOST_BLIT dst m_tex=%u nonzeroRGB=%zu/64 err=0x%x\\n",
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

        /* VMHOST_DIAG: 整块统计（**只看 RGB，排除 alpha**）。
           注意：按字节抽样会把"RGB=0 但 A=255"的不透明黑误判成"有内容"
           （nz 恰好等于像素数就是这种情形）；反过来每 64 字节抽样又总落在 R 上，
           会把真实内容误判成全黑。所以这里明确按像素统计 RGB。 */
        {
            const size_t total = (size_t) m_width * (size_t) m_height * 4u;
            size_t nzPix = 0;
            unsigned mx = 0;
            for (size_t p = 0; p + 3 < total; p += 4u) {
                const unsigned r = img[p];
                const unsigned g = img[p + 1];
                const unsigned b = img[p + 2];
                const unsigned v = r > g ? (r > b ? r : b) : (g > b ? g : b);
                if (v) {
                    nzPix++;
                    if (v > mx) mx = v;
                }
            }
            fprintf(stderr,
                    "VMHOST_READBACK tex=%u %dx%d fbo=%u reattach=%d nzRGBpix=%zu/%zu maxRGB=%u err=0x%x\\n",
                    m_tex, m_width, m_height, m_fbo, (int) m_needFboReattach,
                    nzPix, (size_t) m_width * (size_t) m_height, mx,
                    s_gles2.glGetError());
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
edit("host/FrameBuffer.cpp", "VMHOST_POST fb=",
     [("""    m_lastPostedColorBuffer = p_colorbuffer;
""",
       """    m_lastPostedColorBuffer = p_colorbuffer;

    /* VMHOST_DIAG: 记录"被 post 的那块 buffer"——访客 handle 与宿主 GL 纹理名。
       与 VMHOST_BLIT 的目标纹理对照，即可判定"渲染的 buffer 是否就是被 post 的
       buffer"（黑帧的直接原因）。fb= 打印的是本 FrameBuffer 实例地址，用来和
       VMHOST_FBREG / VMHOST_RCFLUSH 的指针对比：若三者不一致，说明访客的提交
       落在另一个 FrameBuffer 上，我们注册回调的那个自然永远收不到帧。 */
    fprintf(stderr, "VMHOST_POST fb=%p handle=0x%llx cbHndl=0x%llx tex=%u %ux%u\\n",
            (void*) this,
            (unsigned long long) p_colorbuffer,
            (unsigned long long) colorBuffer->getHndl(),
            (unsigned) colorBuffer->glOpGetTexture(),
            colorBuffer->getWidth(), colorBuffer->getHeight());
""")],
     note="post 的 ColorBuffer 打点（含 FB 实例）")


# ----------------------------------------------------------------------------
# 4b) RenderControl::rcBindTexture —— 判定"被绑定的图层 buffer 里到底有没有内容"
#
# rcBindTexture（renderControl opcode 10020，a0 = CB handle）是访客把某块 ColorBuffer
# 当纹理采样的时刻。就在这一刻把这块 CB 的内容按 **RGB 口径**（排除 alpha）采出来，
# 回答"guest 画的东西到底有没有落进这块 CB"。
#
# 为什么在 RenderControl 层直接走 GL（而不是退化成只记录纹理名）：
#   - rcBindTexture 拿到的只是 ColorBuffer（不是 Gl 子类），但 glOpGetTexture() 给出了
#     宿主 GL 纹理名，采样不需要 Gl 子类；
#   - 此刻 render 线程**一定**有 current context —— 否则上面的 bindColorBufferToTexture
#     （ColorBufferGl::bindToTexture 里 `if (!tInfo->currContext.get()) return false;`）
#     会直接返回 false；所以可以直接调 s_gles2；
#   - RenderControl.cpp 的 include 链已带进 <GLES2/gl2.h>（经 renderControl_types.h →
#     apigen-codec-common/glUtils.h），且本文件已在用 gl::s_gles2，无需新增 include。
#   - 采样手法与 ColorBufferGl::blitFromCurrentReadBuffer 里的 VMHOST_BLIT src/dst
#     段落完全一致：临时 FBO + glFramebufferTexture2D + glReadPixels，**只数 RGB 非零的
#     像素**（A=255 来自访客每帧的 glClear，不能当成"有内容"）。
# 限速：每 60 次绑定采一次，避免拖慢 60fps 的回传路径。
# ----------------------------------------------------------------------------
edit("host/RenderControl.cpp", "VMHOST_BINDTEX",
     [("""static void rcBindTexture(uint32_t colorBuffer)
{
    FrameBuffer *fb = FrameBuffer::getFB();
    if (!fb) {
        return;
    }

    // Update for GL use if necessary.
    fb->invalidateColorBufferForGl(colorBuffer);

    fb->bindColorBufferToTexture(colorBuffer);
}""",
       """static void rcBindTexture(uint32_t colorBuffer)
{
    FrameBuffer *fb = FrameBuffer::getFB();
    if (!fb) {
        return;
    }

    // Update for GL use if necessary.
    fb->invalidateColorBufferForGl(colorBuffer);

    fb->bindColorBufferToTexture(colorBuffer);

    /* VMHOST_DIAG: 判定"被绑定的图层 buffer 里到底有没有内容"。
       rcBindTexture 是访客（renderControl opcode 10020，a0 = CB handle）把某块
       ColorBuffer 当纹理采样的时刻 —— 就在这一刻把这块 CB 的内容按 **RGB 口径**
       （排除 alpha）采出来，回答"guest 画的东西到底有没有落进这块 CB"。
       为什么在 RenderControl 层直接走 GL：rcBindTexture 只拿得到 ColorBuffer
       （不是 Gl 子类），但 glOpGetTexture() 给出了宿主 GL 纹理名；此刻 render 线程
       已经有 current context（否则上面的 bindColorBufferToTexture 会直接返回 false），
       所以这里直接调 s_gles2 的临时 FBO + glReadPixels，手法与
       ColorBufferGl::blitFromCurrentReadBuffer 里的 VMHOST_BLIT src/dst 段落一致
       （只数 RGB 非零的像素，A=255 不算内容）。限速：每 60 次绑定采一次，
       避免拖慢 60fps 的回传路径。 */
    {
        static uint32_t s_bindCount = 0;
        const uint32_t n = ++s_bindCount;
        if ((n % 60u) == 0u) {
            ColorBufferPtr cb = fb->findColorBuffer(colorBuffer);
            RenderThreadInfoGl* tInfo = RenderThreadInfoGl::get();
            if (!cb) {
                fprintf(stderr, "VMHOST_BINDTEX cb=0x%x n=%u NO_CB\\n", colorBuffer, n);
            } else if (!tInfo || !tInfo->currContext.get()) {
                /* 无 current context 时 GL 采样无意义 —— 退化为只记录 handle + 纹理名 */
                fprintf(stderr, "VMHOST_BINDTEX cb=0x%x n=%u tex=%u NO_CONTEXT\\n",
                        colorBuffer, n, (unsigned) cb->glOpGetTexture());
            } else {
                const unsigned w = cb->getWidth();
                const unsigned h = cb->getHeight();
                const unsigned sw = w >= 8u ? 8u : (w ? w : 1u);
                const unsigned sh = h >= 8u ? 8u : (h ? h : 1u);
                const unsigned sx = w >= sw ? (w - sw) / 2u : 0u;
                const unsigned sy = h >= sh ? (h - sh) / 2u : 0u;
                const GLuint tex = cb->glOpGetTexture();

                uint8_t block[8 * 8 * 4] = {0};
                GLint prevFbo = 0;
                GLuint tmpFbo = 0;
                gl::s_gles2.glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prevFbo);
                gl::s_gles2.glGenFramebuffers(1, &tmpFbo);
                gl::s_gles2.glBindFramebuffer(GL_FRAMEBUFFER, tmpFbo);
                gl::s_gles2.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                                   GL_TEXTURE_2D, tex, 0);
                const GLenum st = gl::s_gles2.glCheckFramebufferStatus(GL_FRAMEBUFFER);
                gl::s_gles2.glReadPixels((GLint) sx, (GLint) sy, (GLsizei) sw, (GLsizei) sh,
                                         GL_RGBA, GL_UNSIGNED_BYTE, block);
                /* 只数 RGB 非零的像素（排除 alpha：A=255 会掩盖"其实是黑的"） */
                size_t nz = 0;
                for (size_t p = 0; p + 3 < (size_t) sw * sh * 4u; p += 4u) {
                    if (block[p] | block[p + 1] | block[p + 2]) nz++;
                }
                fprintf(stderr,
                        "VMHOST_BINDTEX cb=0x%x n=%u tex=%u %ux%u at(%u,%u) "
                        "fboStatus=0x%x nonzeroRGB=%zu/%zu err=0x%x\\n",
                        colorBuffer, n, (unsigned) tex, w, h, sx, sy, st,
                        nz, (size_t) sw * (size_t) sh, gl::s_gles2.glGetError());
                gl::s_gles2.glBindFramebuffer(GL_FRAMEBUFFER, prevFbo);
                gl::s_gles2.glDeleteFramebuffers(1, &tmpFbo);
            }
        }
    }
}""")],
     note="rcBindTexture 采样被绑定 CB 的 8x8 内容（RGB 口径）")


# ----------------------------------------------------------------------------
# 5) 验证性兜底（**默认不启用**，需 VMHOST_HACK_POST_CB=1）：被 post 的 CB 与渲染的
#    window surface CB 不是同一块（见 docs/方案B排障交接.md §11：guest flush 进
#    5/9/a，却 post 8/b）。这是验证假设用的 hack，不是最终修法。
# ----------------------------------------------------------------------------
if os.environ.get("VMHOST_HACK_POST_CB") == "1":
    edit("host/FrameBuffer.h", "HandleType m_lastFlushedWindowCb",
     [("""    HandleType m_lastPostedColorBuffer = 0;
""",
       """    HandleType m_lastPostedColorBuffer = 0;

    /* VMHOST_HACK: 最近一次 flush 过的 window surface CB —— 用于绕过"post 的 handle
       与渲染的 window surface CB 不是同一块"（见 FrameBuffer::postImpl 的说明）。 */
    HandleType m_lastFlushedWindowCb = 0;
""")],
     note="记录最近 flush 的 window CB（成员声明）")

    edit("host/FrameBuffer.cpp", "记住刚刚 flush 的这块 CB",
     [("""    EmulatedEglWindowSurface* surface = it->second.first.get();
    surface->flushColorBuffer();

    return true;
}""",
       """    EmulatedEglWindowSurface* surface = it->second.first.get();
    surface->flushColorBuffer();

    /* VMHOST_HACK: 记住刚刚 flush 的这块 CB（post 时作为像素源的兜底） */
    {
        auto cbIt = m_EmulatedEglWindowSurfaceToColorBuffer.find(p_surface);
        if (cbIt != m_EmulatedEglWindowSurfaceToColorBuffer.end() &&
            cbIt->second != 0) {
            m_lastFlushedWindowCb = cbIt->second;
        }
    }

    return true;
}""")],
     note="flush 时记录 window CB")

    edit("host/FrameBuffer.cpp", "优先用最近 flush",
     [("""    for (auto& iter : m_onPost) {
        ColorBufferPtr cb;
        if (iter.first == 0) {
            cb = colorBuffer;
        } else {""",
       """    for (auto& iter : m_onPost) {
        ColorBufferPtr cb;
        if (iter.first == 0) {
            cb = colorBuffer;
            /* VMHOST_HACK: guest 的 rcFBPost(handle) 与它实际渲染的 window surface
               CB 不是同一块（实测：渲染结果 flush 进 5/9/a，post 的却是 8/b，
               后者恒空 → 画面全黑）。这里在被 post 的 CB 之外，优先用最近 flush
               过的 window surface CB 作为像素源，用于验证"就是这一处错配"。 */
            if (m_lastFlushedWindowCb != 0 && m_lastFlushedWindowCb != p_colorbuffer) {
                ColorBufferPtr alt = findColorBuffer(m_lastFlushedWindowCb);
                if (alt) {
                    cb = alt;
                }
            }
        } else {""")],
     note="post 时优先用 window CB")


# ----------------------------------------------------------------------------
# 执行
# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# 5) 帧提交路径探针：访客把帧交给了谁、我们的 post 回调有没有真的挂上
#
#    背景：SF 健康、访客开机完成，但 FrameBuffer::m_lastPostedColorBuffer 始终
#    无效（getScreenshot 兜底一直 res=-1）→ 意味着"访客的帧没有走到我们注册回调
#    的那个 FrameBuffer"。这里测三件事，靠打印的 fb= 指针互相对照：
#      a) setPostCallback 有没有被 display 检查拦下 —— 该分支会
#         ERR("... cancelling OnPost callback") 后直接 return，而 glue 侧是 void
#         调用，照样会打"已注册 post callback"，属于静默失败；
#      b) 访客有没有真的调 rcFBPost（→ VMHOST_POST，带 fb=）；
#      c) 访客有没有 rcFlushWindowColorBuffer（历史探针说见过 flush 5/9/a）。
#    三者 fb= 不一致 => 两个 FrameBuffer 实例；全都一致且都有日志 => 提交路径正常，
#    问题另在别处（例如 displayId 不是 0）。
# ----------------------------------------------------------------------------
edit("host/RenderControl.cpp", "VMHOST_RCFLUSH",
     [("""    HandleType colorBufferHandle = fb->getEmulatedEglWindowSurfaceColorBufferHandle(windowSurface);
""",
       """    HandleType colorBufferHandle = fb->getEmulatedEglWindowSurfaceColorBufferHandle(windowSurface);

    /* VMHOST_DIAG: 访客提交路径之二 —— 把 window surface 对应的 CB flush 给宿主。
       限速：只在 cb 或 FrameBuffer 实例变化时打印，避免拖慢渲染。 */
    {
        static unsigned long long s_vmhostLastCb = ~0ull;
        static FrameBuffer* s_vmhostLastFb = nullptr;
        if ((unsigned long long) colorBufferHandle != s_vmhostLastCb || fb != s_vmhostLastFb) {
            s_vmhostLastCb = (unsigned long long) colorBufferHandle;
            s_vmhostLastFb = fb;
            fprintf(stderr, "VMHOST_RCFLUSH fb=%p ws=%u cb=0x%llx\\n",
                    (void*) fb, windowSurface, (unsigned long long) colorBufferHandle);
        }
    }
""")],
     note="rcFlushWindowColorBuffer 打点")

edit("host/FrameBuffer.cpp", "VMHOST_FBREG enter",
     [("""void FrameBuffer::setPostCallback(Renderer::OnPostCallback onPost, void* onPostContext,
                                  uint32_t displayId, bool useBgraReadback) {
    AutoLock lock(m_lock);
    if (onPost) {
""",
       """void FrameBuffer::setPostCallback(Renderer::OnPostCallback onPost, void* onPostContext,
                                  uint32_t displayId, bool useBgraReadback) {
    AutoLock lock(m_lock);
    /* VMHOST_DIAG: 记录回调挂在哪个 FrameBuffer 实例上（与 VMHOST_POST /
       VMHOST_RCFLUSH 的 fb= 对照）。 */
    fprintf(stderr, "VMHOST_FBREG enter fb=%p displayId=%u onPost=%p\\n",
            (void*) this, displayId, (void*) onPost);
    if (onPost) {
"""),
      ("""            ERR("display %d not exist, cancelling OnPost callback", displayId);
            return;
""",
       """            ERR("display %d not exist, cancelling OnPost callback", displayId);
            /* VMHOST_DIAG: 回调被静默取消了 —— glue 是 void 调用，看不出来。 */
            fprintf(stderr, "VMHOST_FBREG 取消：display %u 不存在，回调没挂上\\n", displayId);
            return;
""")],
     note="setPostCallback 打点（含被取消分支）")


def main():
    if len(sys.argv) < 2:
        print("用法: patch_vmhost_diag.py <gfxstream 源码根目录>", file=sys.stderr)
        return 1
    root = sys.argv[1]
    applied = 0
    skipped = 0
    missed = 0

    # 解码循环的调用点单独处理（要能自愈"未夹紧"的旧版注入）。
    r = apply_gles2_call_site(root)
    if r == "apply":
        applied += 1
        print("APPLY %-28s %s" % ("解码循环调用点按 avail 夹紧 packetLen",
                                  "host/gl/gles2_dec/gles2_dec.cpp"))
    elif r == "skip":
        skipped += 1
    else:
        missed += 1

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
