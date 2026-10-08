#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VMHOST 宿主侧 surface 修复：makeCurrent 加固 + pbuffer 真实创建。

背景（实测，见 docs/方案B排障交接.md §15）：
    访客跑到 SystemUI/SF 真正开始渲染时，宿主 QEMU 会在
        signal=11 addr=0x38 x21=0x0 eglGetCurrentContext=0x0
    上 SIGSEGV，崩点落在 /vendor/lib64/egl/libGLESv2_adreno.so —— 即
    **"有 EGL context、但 draw/read surface 为空"** 时 Adreno 830 驱动在固定指令
    `LDR x5, [x21, #0x38]`（x21=0）上解引用 NULL 打死整个进程。

    这个状态有两个来源，缺一不可：

    1) `EglOsEglDisplay::createPbufferSurface`（本文件 edit 2）
       实现被整段注释掉，恒 `return new EglOsEglSurface(PBUFFER, 0)` ——
       返回一个**句柄为 0 的"哑"surface**。访客的 SF 会为 GPU 上下文建 pbuffer
       （`EglImp.cpp: egCreatePbufferSurface`），拿到句柄 0 之后再
       eglMakeCurrent，平台侧就变成 `eglMakeCurrent(dpy, 0, 0, ctx)`。

    2) `EglOsEglDisplay::makeCurrent`（本文件 edit 1）
       旧实现在 `ctx && !readSfc` 时**直接 return false**，把调用线程留在
       "没有任何绑定"的状态上；调用方拿到 false 继续往下发 GL 调用，同样崩。
       另外**访客显式释放上下文之后仍会继续发 GL**（实测：`eglMakeCurrent` 释放的
       下一批命令就是 glUseProgram），旧实现把宿主绑定清空，于是又落回"无 current
       context"。所以释放分支不能再真的解绑 —— 改绑一个自造的 dummy 上下文 +
       1x1 pbuffer（访客侧 `eglGetCurrentContext` 由访客自己维护，看不到宿主，
       语义不变；宿主线程则始终有合法上下文，后续 GL 只写进 1x1 pbuffer，无害）。

    后果：访客永远走不到 rcFBPost / rcFlushWindowColorBuffer，宿主也就永远拿不到帧
    （VMHOST_POST / VMHOST_RCFLUSH 探针一条都不响）。

修法：
    edit 2 恢复真正的 pbuffer 创建（config 取自传入的 PixelFormat，即访客选的那个
    EGLConfig），创建失败仍退回旧行为；
    edit 1 在缺 surface（或直接绑定失败）时用 **能试绑成功的** 1x1 pbuffer 顶上，
    绝不把线程留在无 current context 状态。

    为什么 edit 1 要"试绑成功才采用"：pbuffer 必须与 context 的 config 兼容，
    否则 eglMakeCurrent 返回 EGL_BAD_MATCH —— 这正是**旧版内联补丁**（按
    eglChooseConfig 自选一个 config）失败、把 android_startOpenglesRenderer 打成
    -1 的原因。逐候选建 pbuffer 并立刻试绑，成功才缓存复用，失败即销毁换下一个。

用法：
    python3 patch_vmhost_surface.py <gfxstream 源码根目录>
"""

import io
import os
import sys

REL = "host/gl/glestranslator/EGL/EglOsApi_egl.cpp"
MK_MARKER = "VMHOST_MAKECURFIX"
PB_MARKER = "VMHOST_PBUFSURF"

# ============================================================ edit 1: makeCurrent
MK_HELPER = r'''
/* VMHOST_MAKECURFIX: 释放上下文后，仍然保证宿主线程有一个合法 current context。
 *
 * 实测：访客调用 eglMakeCurrent(NO_SURFACE, NO_SURFACE, NO_CONTEXT) 释放上下文之后，
 * 下一批命令里紧跟着就是 glUseProgram —— 宿主 Adreno 在"没有 current context"时
 * 执行 GL 会 SIGSEGV（实测 signal=11 addr=0x0，pc 落在 bionic libc，由 adreno 调用）
 * 打死整个 QEMU。
 *
 * 所以释放分支不能真的把宿主绑定清空。这里自造一个 dummy 上下文（ES2 + 1x1
 * pbuffer），释放时改绑到它：访客侧的 eglGetCurrentContext 由访客自己维护，看不到
 * 宿主，语义不变；宿主线程则始终有合法上下文，后续 GL 只写进 1x1 pbuffer，无害。
 * dummy 一旦建好就常驻（进程级），不会反复创建。
 */
static bool vmhost_bind_dummy(EglOsEglDispatcher* d, EGLDisplay dpy) {
    /* thread_local：一个 EGL context 同一时刻只能在一个线程上 current，所以 dummy
       必须**每线程一个**，否则第二个线程 eglMakeCurrent 会 EGL_BAD_ACCESS。 */
    static thread_local EGLContext s_dummyCtx = EGL_NO_CONTEXT;
    static thread_local EGLSurface s_dummySurf = EGL_NO_SURFACE;
    if (d == nullptr || dpy == EGL_NO_DISPLAY) {
        return false;
    }
    if (s_dummyCtx == EGL_NO_CONTEXT) {
        if (!d->eglChooseConfig || !d->eglCreateContext ||
            !d->eglCreatePbufferSurface) {
            return false;
        }
        const EGLint cfgAttrs[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                                   EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                                   EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                                   EGL_BLUE_SIZE, 8, EGL_NONE};
        EGLConfig cfg = nullptr;
        EGLint n = 0;
        if (!d->eglChooseConfig(dpy, cfgAttrs, &cfg, 1, &n) || n < 1 ||
            cfg == nullptr) {
            return false;
        }
        const EGLint ctxAttrs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
        s_dummyCtx = d->eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctxAttrs);
        if (s_dummyCtx == EGL_NO_CONTEXT) {
            return false;
        }
        const EGLint pbAttrs[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
        s_dummySurf = d->eglCreatePbufferSurface(dpy, cfg, pbAttrs);
        if (s_dummySurf == EGL_NO_SURFACE) {
            return false;
        }
        fprintf(stderr, "VMHOST_MC dummy 上下文已创建 ctx=%p pb=%p\n",
                (void*)(uintptr_t)s_dummyCtx, (void*)(uintptr_t)s_dummySurf);
    }
    return d->eglMakeCurrent(dpy, s_dummySurf, s_dummySurf, s_dummyCtx);
}

/* VMHOST_MAKECURFIX: 进程级记录（首次 makeCurrent 时填入），供解码线程兜底使用。 */
static EglOsEglDispatcher* g_mcDispatcher = nullptr;
static EGLDisplay g_mcDpy = EGL_NO_DISPLAY;
static void* (*g_mcGetCurrentContext)(void) = nullptr;
static int g_mcEnsureLogs = 0;

/* VMHOST_MAKECURFIX: 每条 GL 命令前的"上下文自愈"，由 gles2_dec 的解码循环调用。
 *
 * 实测：访客某个渲染线程从没在本线程做过 eglMakeCurrent，却直接提交 GL 命令
 * （日志里 release 与紧接着的 glUseProgram 不在一起），于是 GL 调用落到"没有
 * current context"的 Adreno 上 → SIGSEGV（signal=11 addr=0x0，pc 在 bionic libc）
 * 打死整个 QEMU。
 *
 * 真实设备驱动在无 current context 时只是给调用方一个 GL 错误、不会崩，所以这里
 * 的做法与真机语义一致：本线程没有 current context 时，补绑一个本线程专属的
 * dummy 上下文（ES2 + 1x1 pbuffer），让后续 GL 变成无害 no-op。
 * 有 current context 时**什么都不做**（只读一次 TLS，开销可忽略）。
 */
extern "C" void vmhost_mc_ensure_current(void) {
    EglOsEglDispatcher* d = g_mcDispatcher;
    EGLDisplay dpy = g_mcDpy;
    if (d == nullptr || dpy == EGL_NO_DISPLAY) {
        return;
    }
    if (g_mcGetCurrentContext == nullptr) {
        if (d->eglGetProcAddress == nullptr) {
            return;
        }
        g_mcGetCurrentContext =
            (void* (*)(void))d->eglGetProcAddress("eglGetCurrentContext");
        if (g_mcGetCurrentContext == nullptr) {
            return;
        }
    }
    if (g_mcGetCurrentContext() != nullptr) {
        return;
    }
    if (vmhost_bind_dummy(d, dpy) && g_mcEnsureLogs < 8) {
        g_mcEnsureLogs++;
        fprintf(stderr, "VMHOST_MC ensure 本线程无 current context，已补绑 dummy\n");
    }
}

/* VMHOST_MAKECURFIX: 给"有 context、缺 surface"的场景挑一个能用 1x1 pbuffer。
 *
 * 宿主 Adreno 830 在 eglMakeCurrent(dpy, 0, 0, ctx) 这个状态下会于固定指令
 * `LDR x5, [x21, #0x38]`（x21=0）上 SIGSEGV，直接打死整个 QEMU。这里补上缺的
 * 那一边，让驱动始终拿到合法 surface。
 *
 * 关键：pbuffer 必须与 context 的 config 兼容，否则 eglMakeCurrent 返回
 * EGL_BAD_MATCH（旧版补丁就栽在这上面）。所以逐个候选 config 建 pbuffer 并立刻
 * **试绑**，成功才采用；失败即销毁换下一个。绝不因为 config 不匹配把原本成功的
 * 绑定搞坏。
 *
 * 成功建成的 pbuffer 缓存起来（最多 kMaxPb），下次直接试绑，避免反复 eglChooseConfig。
 */
static EGLSurface vmhost_bind_pbuffer(EglOsEglDispatcher* d, EGLDisplay dpy,
                                      EGLContext ctxHndl) {
    const int kMaxPb = 32;
    static EGLSurface s_pbs[kMaxPb];
    static int s_pbCount = 0;
    static bool s_init = false;
    if (!s_init) {
        for (int i = 0; i < kMaxPb; i++) s_pbs[i] = EGL_NO_SURFACE;
        s_init = true;
    }
    if (d == nullptr || dpy == EGL_NO_DISPLAY || ctxHndl == EGL_NO_CONTEXT) {
        return EGL_NO_SURFACE;
    }
    /* 1) 先试已经缓存下来的 pbuffer */
    for (int i = 0; i < s_pbCount; i++) {
        if (s_pbs[i] != EGL_NO_SURFACE &&
            d->eglMakeCurrent(dpy, s_pbs[i], s_pbs[i], ctxHndl)) {
            return s_pbs[i];
        }
    }
    if (s_pbCount >= kMaxPb || !d->eglChooseConfig || !d->eglCreatePbufferSurface) {
        return EGL_NO_SURFACE;
    }

    const EGLint pbAttrs[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    /* 从"贴得最近"到"放得最宽"依次尝试；越靠前越可能同时满足 ES2 / 常见位宽。 */
    static const EGLint cand0[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                                   EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                                   EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                                   EGL_BLUE_SIZE, 8, EGL_NONE};
    static const EGLint cand1[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                                   EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                                   EGL_NONE};
    static const EGLint cand2[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_NONE};
    static const EGLint cand3[] = {EGL_NONE};
    static const EGLint* cands[4] = {cand0, cand1, cand2, cand3};

    for (int i = 0; i < 4; i++) {
        EGLConfig cfgs[64];
        EGLint n = 0;
        if (!d->eglChooseConfig(dpy, cands[i], cfgs, 64, &n) || n < 1) {
            continue;
        }
        for (EGLint j = 0; j < n; j++) {
            EGLSurface pb = d->eglCreatePbufferSurface(dpy, cfgs[j], pbAttrs);
            if (pb == EGL_NO_SURFACE) {
                continue;
            }
            if (d->eglMakeCurrent(dpy, pb, pb, ctxHndl)) {
                int slot = s_pbCount;
                s_pbs[slot] = pb;
                s_pbCount = slot + 1;
                fprintf(stderr,
                        "VMHOST_MC pbuffer 选定 cand=%d idx=%d pb=%p ctx=%p "
                        "（已试绑成功，缓存槽 %d）\n",
                        i, (int)j, (void*)(uintptr_t)pb,
                        (void*)(uintptr_t)ctxHndl, slot);
                return pb;
            }
            /* 绑定失败：销毁换下一个，绝不把当前的绑定弄坏 */
            if (d->eglDestroySurface) {
                d->eglDestroySurface(dpy, pb);
            }
        }
    }
    return EGL_NO_SURFACE;
}
'''

MK_ANCHOR = """bool EglOsEglDisplay::makeCurrent(Surface* read,
                                  Surface* draw,
                                  Context* context) {
    D("%s\\n", __FUNCTION__);
    EglOsEglSurface* readSfc = (EglOsEglSurface*)read;
    EglOsEglSurface* drawSfc = (EglOsEglSurface*)draw;
    EglOsEglContext* ctx = (EglOsEglContext*)context;
    if (ctx && !readSfc) {
        D("warning: makeCurrent a context without surface\\n");
        return false;
    }
    D("%s %p\\n", __FUNCTION__, ctx ? ctx->context() : nullptr);
    bool ret = mDispatcher.eglMakeCurrent(
            mDisplay, drawSfc ? drawSfc->getHndl() : EGL_NO_SURFACE,
            readSfc ? readSfc->getHndl() : EGL_NO_SURFACE,
            ctx ? ctx->context() : EGL_NO_CONTEXT);
    if (readSfc) {
        D("make current surface type %d %d\\n", readSfc->type(),
          drawSfc->type());
    }
    D("make current %d\\n", ret);
    CHECK_EGL_ERR
    return ret;
}"""

MK_REPL = """/* VMHOST_MAKECURFIX: 加固版 makeCurrent —— 缺 surface 时用能试绑成功的 1x1
   pbuffer 顶上，绝不把调用线程留在"没有 current context"的状态上。
   旧实现在 `ctx && !readSfc` 时直接 return false，以及 surface 句柄为 0 时退化成
   eglMakeCurrent(dpy, 0, 0, ctx)，两者都会让紧随其后的 GL 调用把 Adreno 830 打死
   （SIGSEGV @ addr=0x38，x21=0，eglGetCurrentContext=0x0）。 */
bool EglOsEglDisplay::makeCurrent(Surface* read,
                                  Surface* draw,
                                  Context* context) {
    D("%s\\n", __FUNCTION__);
    EglOsEglSurface* readSfc = (EglOsEglSurface*)read;
    EglOsEglSurface* drawSfc = (EglOsEglSurface*)draw;
    EglOsEglContext* ctx = (EglOsEglContext*)context;

    EGLContext vmhostCtxHndl = ctx ? ctx->context() : EGL_NO_CONTEXT;
    EGLSurface vmhostDrawHndl = drawSfc ? drawSfc->getHndl() : EGL_NO_SURFACE;
    EGLSurface vmhostReadHndl = readSfc ? readSfc->getHndl() : EGL_NO_SURFACE;

    /* 供 vmhost_mc_ensure_current()（解码线程逐条命令自愈）使用 */
    if (g_mcDispatcher == nullptr) {
        g_mcDispatcher = &mDispatcher;
        g_mcDpy = mDisplay;
    }

    /* 只在前若干次打参数，避免刷爆日志。 */
    static int s_vmhostMcCalls = 0;
    const bool vmhostDbg = (s_vmhostMcCalls++ < 80);
    if (vmhostDbg) {
        fprintf(stderr,
                "VMHOST_MC enter ctx=%p ch=%p readSfc=%p rh=%p drawSfc=%p dh=%p\\n",
                (void*)ctx, (void*)(uintptr_t)vmhostCtxHndl,
                (void*)readSfc, (void*)(uintptr_t)vmhostReadHndl,
                (void*)drawSfc, (void*)(uintptr_t)vmhostDrawHndl);
    }

    if (vmhostCtxHndl == EGL_NO_CONTEXT) {
        /* VMHOST_MAKECURFIX：访客释放上下文后仍会继续发 GL（实测：release 的下一批
           命令就是 glUseProgram）。宿主 Adreno 在"没有 current context"时执行 GL 会
           SIGSEGV 打死整个 QEMU，所以这里改绑 dummy 上下文而不是真的解绑。 */
        if (vmhost_bind_dummy(&mDispatcher, mDisplay)) {
            if (vmhostDbg) {
                fprintf(stderr, "VMHOST_MC release -> dummy\\n");
            }
            return true;
        }
        bool r = mDispatcher.eglMakeCurrent(mDisplay, EGL_NO_SURFACE,
                                            EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (vmhostDbg) {
            fprintf(stderr, "VMHOST_MC release ret=%d\\n", (int)r);
        }
        return r;
    }

    if (vmhostDrawHndl != EGL_NO_SURFACE && vmhostReadHndl != EGL_NO_SURFACE) {
        bool r = mDispatcher.eglMakeCurrent(mDisplay, vmhostDrawHndl,
                                            vmhostReadHndl, vmhostCtxHndl);
        if (r) {
            return true;
        }
        /* 两个句柄都在却绑不上，也走下面的 pbuffer 兜底。 */
        fprintf(stderr,
                "VMHOST_MC direct 失败 err=0x%x ctx=%p draw=%p read=%p\\n",
                mDispatcher.eglGetError ? mDispatcher.eglGetError() : 0,
                (void*)(uintptr_t)vmhostCtxHndl,
                (void*)(uintptr_t)vmhostDrawHndl,
                (void*)(uintptr_t)vmhostReadHndl);
    }

    /* 缺 surface（或上面直接绑定失败）→ 用试绑成功的 pbuffer 顶上。
       vmhost_bind_pbuffer 成功时**已经**完成绑定，直接返回即可。 */
    EGLSurface vmhostPb =
        vmhost_bind_pbuffer(&mDispatcher, mDisplay, vmhostCtxHndl);
    if (vmhostPb != EGL_NO_SURFACE) {
        return true;
    }

    fprintf(stderr,
            "VMHOST_MC 无可用 pbuffer，退到 surfaceless ctx=%p（可能仍崩，"
            "但会留下这行日志）\\n",
            (void*)(uintptr_t)vmhostCtxHndl);
    bool r = mDispatcher.eglMakeCurrent(mDisplay, EGL_NO_SURFACE,
                                        EGL_NO_SURFACE, vmhostCtxHndl);
    fprintf(stderr, "VMHOST_MC surfaceless ret=%d ctx=%p\\n", (int)r,
            (void*)(uintptr_t)vmhostCtxHndl);
    return r;
}"""

# ============================================================ edit 2: pbuffer
PB_ANCHOR = "    return new EglOsEglSurface(EglOS::Surface::PBUFFER, 0);"

PB_REPL = r'''    /* VMHOST_PBUFSURF：原实现被整段注释掉、恒返回 handle=0 的"哑"surface。
       访客的 SF 会为 GPU 上下文 / VirtualDisplay 建 pbuffer，拿到句柄 0 之后再
       eglMakeCurrent，平台侧就变成 eglMakeCurrent(dpy, 0, 0, ctx) —— 宿主 Adreno
       830 在这个状态下 SIGSEGV（addr=0x38、x21=0）打死整个 QEMU。
       这里恢复真正的 pbuffer 创建：config 取自传入的 PixelFormat（它携带访客选的
       那个 EGLConfig）。创建失败仍退回旧行为（handle=0），由 makeCurrent 的
       pbuffer 兜底接手。 */
    const EglOsEglPixelFormat* vmhostFormat =
        (const EglOsEglPixelFormat*)pixelFormat;
    if (vmhostFormat != nullptr && info != nullptr &&
        mDispatcher.eglCreatePbufferSurface != nullptr &&
        vmhostFormat->mConfigId != nullptr) {
        const EGLint vmhostAttrib[] = {
            EGL_WIDTH, info->width > 0 ? info->width : 1,
            EGL_HEIGHT, info->height > 0 ? info->height : 1,
            EGL_NONE};
        EGLSurface vmhostPb = mDispatcher.eglCreatePbufferSurface(
                mDisplay, vmhostFormat->mConfigId, vmhostAttrib);
        if (vmhostPb != EGL_NO_SURFACE) {
            fprintf(stderr, "VMHOST_PBUFSURF ok %dx%d cfg=%p pb=%p\n",
                    (int)(info->width > 0 ? info->width : 1),
                    (int)(info->height > 0 ? info->height : 1),
                    (void*)vmhostFormat->mConfigId,
                    (void*)(uintptr_t)vmhostPb);
            return new EglOsEglSurface(EglOS::Surface::PBUFFER, vmhostPb);
        }
        fprintf(stderr, "VMHOST_PBUFSURF 创建失败 err=0x%x cfg=%p %dx%d\n",
                mDispatcher.eglGetError ? mDispatcher.eglGetError() : 0,
                (void*)vmhostFormat->mConfigId,
                (int)(info->width > 0 ? info->width : 1),
                (int)(info->height > 0 ? info->height : 1));
    } else {
        fprintf(stderr, "VMHOST_PBUFSURF 参数不足，维持 handle=0\n");
    }
    return new EglOsEglSurface(EglOS::Surface::PBUFFER, 0);'''

# ============================================================ edit 3: 解码入口自愈
# GLES2 解码循环是"所有访客 GL 命令"的唯一汇聚点，在这里每条命令前做一次上下文
# 自愈，才能覆盖"线程从未绑过上下文"的情况（makeCurrent 钩子对那种线程不会触发）。
GLES2_DEC = "host/gl/gles2_dec/gles2_dec.cpp"
DECL_ANCHOR = 'typedef unsigned int tsize_t; // Target "size_t"'

DECL_REPL = ('/* VMHOST_MAKECURFIX: 上下文自愈入口，定义在\n'
             '   host/gl/glestranslator/EGL/EglOsApi_egl.cpp。 */\n'
             'extern "C" void vmhost_mc_ensure_current(void);\n'
             + DECL_ANCHOR)

CALL_ANCHOR = "\t\tuint32_t packetLen = *(uint32_t *)(ptr + 4);\n"

CALL_REPL = (CALL_ANCHOR +
             "\t\tvmhost_mc_ensure_current();   /* VMHOST_MAKECURFIX */\n")

# ============================================================ edit 3b: gles1 解码入口
# 实测：崩在 Adreno 上的那批命令（含 glUseProgram）是由 **gles1** 解码器消费的
# （日志里由 VMHOST_GLES1_OP 打印，见 gles1_dec.cpp），所以 gles1 侧也要挂同一个
# 自愈入口，否则那条路径没有兜底。
GLES1_DEC = "host/gl/gles1_dec/gles1_dec.cpp"

G1_DECL_ANCHOR = ("typedef unsigned int tsize_t; // Target \"size_t\", which is 32-bit "
                  "for now. It may or may not be the same as host's size_t when "
                  "emugen is compiled.")

G1_DECL_REPL = ('/* VMHOST_MAKECURFIX: 上下文自愈入口，定义在\n'
                '   host/gl/glestranslator/EGL/EglOsApi_egl.cpp。 */\n'
                'extern "C" void vmhost_mc_ensure_current(void);\n'
                + G1_DECL_ANCHOR)

G1_CALL_ANCHOR = ("\t\tfprintf(stderr, \"VMHOST_GLES1_OP %u len=%u\\n\", opcode, "
                  "packetLen);\n")

G1_CALL_REPL = (G1_CALL_ANCHOR +
                "\t\tvmhost_mc_ensure_current();   /* VMHOST_MAKECURFIX */\n")


def apply(path, marker, anchor, repl, what):
    with io.open(path, encoding="utf-8") as fp:
        src = fp.read()
    if marker in src:
        sys.stdout.write("==> patch: %s（已打过，跳过）\n" % what)
        return src
    if anchor not in src:
        sys.stderr.write("!! %s 锚点未命中：%s\n" % (what, path))
        return None
    src = src.replace(anchor, repl, 1)
    with io.open(path, "w", encoding="utf-8") as fp:
        fp.write(src)
    sys.stdout.write("==> patch: %s 已注入\n" % what)
    return src


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("用法: patch_vmhost_surface.py <gfxstream 源码根目录>\n")
        return 2
    path = os.path.join(sys.argv[1], REL)
    if not os.path.isfile(path):
        sys.stderr.write("!! 找不到 %s\n" % path)
        return 1

    # edit 1：makeCurrent 加固（含辅助函数，一起插入）
    src = apply(path, MK_MARKER, MK_ANCHOR, MK_HELPER + "\n" + MK_REPL,
                "makeCurrent 加固")
    if src is None:
        return 1
    # edit 2：恢复真实 pbuffer 创建
    src = apply(path, PB_MARKER, PB_ANCHOR, PB_REPL, "pbuffer 真实创建")
    if src is None:
        return 1

    # edit 3：GLES2 解码入口自愈（先加声明，再加逐条命令调用）
    dec_path = os.path.join(sys.argv[1], GLES2_DEC)
    if not os.path.isfile(dec_path):
        sys.stderr.write("!! 找不到 %s\n" % dec_path)
        return 1
    src = apply(dec_path, 'extern "C" void vmhost_mc_ensure_current(void);',
                DECL_ANCHOR, DECL_REPL, "gles2_dec 自愈声明")
    if src is None:
        return 1
    src = apply(dec_path, "vmhost_mc_ensure_current();   /* VMHOST_MAKECURFIX */",
                CALL_ANCHOR, CALL_REPL, "gles2_dec 逐条命令自愈")
    if src is None:
        return 1

    # edit 3b：gles1 解码入口自愈（实测崩溃命令走的就是这条通道）
    dec1_path = os.path.join(sys.argv[1], GLES1_DEC)
    if not os.path.isfile(dec1_path):
        sys.stderr.write("!! 找不到 %s\n" % dec1_path)
        return 1
    src = apply(dec1_path, 'extern "C" void vmhost_mc_ensure_current(void);',
                G1_DECL_ANCHOR, G1_DECL_REPL, "gles1_dec 自愈声明")
    if src is None:
        return 1
    src = apply(dec1_path, "vmhost_mc_ensure_current();   /* VMHOST_MAKECURFIX */",
                G1_CALL_ANCHOR, G1_CALL_REPL, "gles1_dec 逐条命令自愈")
    if src is None:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
