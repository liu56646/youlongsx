// VMHost: 在 QEMU 启动早期把 gfxstream 宿主渲染器拉起来，并注册
// `pipe:opengles` AndroidPipe 服务。
//
// 背景：guest（Android 11）的 hwcomposer 是 EmuHWC2，启动时必须经
// HostConnection 建立到宿主 gfxstream 的连接（即 pipe:opengles）。宿主没有
// 渲染器时该管道返回 -1，HWC 致命 abort，init 随即 onrestart restart
// surfaceflinger，SurfaceFlinger 永远起不来。
//
// 上游的做法是在 gfxstream 的 virtio-gpu 后端里
// （host/virtio-gpu-gfxstream-renderer.cpp）调这几个 API。我们不用 virtio-gpu
// 那条路，所以在这里手工按同样的顺序拉起：
//
//   1. 装 graphics agents —— gfxstream 自带 GfxStreamGraphicsAgentFactory，
//      给 vm / window / multi_display 三套 agent 都提供了安全实现；
//      android_startOpenglesRenderer() 会无条件解引用这三个指针，不能传 null。
//   2. emuglConfig_init(..., "host", ...) —— 明确选宿主 GPU 模式（也就是用
//      手机自己的系统 libEGL.so / libGLESv2.so，不用 ANGLE/SwiftShader）。
//   3. android_setOpenglesEmulation(&renderLib) —— 把 RenderLibImpl 注入。
//      注意：绝不能调 android_initOpenglesEmulation()，那个函数在新构建里直接 abort。
//      也正因为不调它，静态 sRendererUsesSubWindow 保持默认 false，渲染器走
//      headless（不需要 ANativeWindow，我们也没有窗口）。
//   4. android_startOpenglesRenderer() —— 真正建 EGL context / FrameBuffer。
//   5. android_init_opengles_pipe() —— 注册 AndroidPipe 服务 "opengles"，
//      必须在 guest 连接之前完成。
//
// 整个过程失败也不致命：只打日志并返回非 0，QEMU 继续跑（guest 仍能启动，
// 只是没有 GPU，行为与接线之前一致），方便逐项排障。

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <android/native_window.h>

// ---------------------------------------------------------- ANativeWindow 桩
// gfxstream 的 NativeSubWindow_android.cpp / EglOsApi_egl.cpp 引用了这几个
// ANativeWindow_* 符号，它们只在 libandroid.so 里。但真机上链 libandroid 会把
// libharfbuzz_ng.so 一起拖进来，而后者依赖 libicu.so，在 app 的 linker namespace
// 里解析不到，直接 "CANNOT LINK EXECUTABLE"。
//
// 我们走的是 headless 路径（渲染器不用子窗口，见下方 sRendererUsesSubWindow
// 的说明），这几个函数实际不会被调用，给最小实现即可，从而完全不依赖
// libandroid.so。
extern "C" {
void ANativeWindow_acquire(ANativeWindow* window) { (void)window; }
void ANativeWindow_release(ANativeWindow* window) { (void)window; }
int32_t ANativeWindow_getWidth(ANativeWindow* window) {
    (void)window;
    return 0;
}
int32_t ANativeWindow_getHeight(ANativeWindow* window) {
    (void)window;
    return 0;
}
int32_t ANativeWindow_setBuffersGeometry(ANativeWindow* window, int32_t width,
                                         int32_t height, int32_t format) {
    (void)window;
    (void)width;
    (void)height;
    (void)format;
    return 0;
}
}  // extern "C"

// 截图回传（D1a / v2）：
//   - vmhost_gfx_screenshot_to_file()：从 gfxstream post 回调的最新帧取像素，
//     按请求尺寸处理后写**原生 RGBA** 文件（不再走 PPM，见 vmhost_gfx_write_latest_raw）；
//   - 后台线程 vmhost_gfx_screen_thread()：8ms 一轮轮询 <frame_dir>/frame.request
//     （内容 "宽 高"），**有新帧时**才写真 frame.rgba（临时文件 + rename 原子替换）
//     并自增写 frame.seq，然后删掉请求文件。App 侧写请求 → 轮询 seq 变化 → 读
//     frame.rgba 即得当前画面。
//   B1 模式下 QEMU 是独立子进程，渲染/取帧都在子进程里，所以必须用
//   "请求文件 + 结果文件"这种文件握手，App 主进程轮询即可，无需额外 IPC。
//
// D1f（本版）：改用 Renderer::setPostCallback 直接抓 post 帧像素。
//   m_lastPostedColorBuffer 只在 rcFBPost 路径更新；若 guest 走 ASG 数据面
//   （address space graphics，GL 命令不经过 renderControl 的 rc 命令），
//   getScreenshot 就拿不到帧。而 setPostCallback 在**每次帧显示前**回调并
//   提供像素拷贝，与传输路径无关。这里把最新一帧存进 s_latest_*，截图线程
//   从这份拷贝写 PPM，完全绕开 m_lastPostedColorBuffer。
#include <pthread.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>
#include <mutex>
#include <dlfcn.h>

// 共享内存帧回传的布局（与 App 进程 engine/src/main/cpp/src/vm_frame_relay.c 共用）。
// build_qemu_aosp.sh 通过 -I$ENGINE_DIR/src/main/cpp/src 让本头可见。
#include "vm_frame_shm.h"

// gfxstream
#include "GfxStreamAgents.h"
#include "OpenGLESDispatch/EGLDispatch.h"
#include "RenderLibImpl.h"
#include "host-common/opengl/emugl_config.h"
#include "host-common/opengl/logger.h"
#include "host-common/opengles-pipe.h"
#include "host-common/opengles.h"
// aemu
#include "host-common/GraphicsAgentFactory.h"
#include "host-common/multi_display_agent.h"
#include "host-common/vm_operations.h"
#include "host-common/window_agent.h"

// 方案 B（virtio-gpu + gfxstream stream_renderer）接线：
//   - goldfish_virtio_init()：virtio-gpu 设备 realize 时被调用，把 QEMU 的
//     goldfish pipe 服务 ops 交给 stream_renderer（替代前端的 dlopen 加载）。
//   - android_init_refcount_pipe()：aemu-host-common（RefcountPipe.cpp）自带真实现，
//     已随 libaemu-host-common.a 链接，这里只需调用。
extern "C" {
#include "gfxstream/virtio-gpu-gfxstream-renderer.h"
#include "gfxstream/virtio-gpu-gfxstream-renderer-goldfish.h"
#include "host-common/goldfish_pipe.h"
#include "host-common/address_space_device.h"
#include "host-common/refcount-pipe.h"
}

extern "C" int goldfish_virtio_init(void) {
    fprintf(stderr, "VMHOSTGFX goldfish_virtio_init: stream_renderer_set_service_ops(QEMU pipe ops)\n");
    stream_renderer_set_service_ops(goldfish_pipe_get_service_ops());
    return 0;
}

// 屏幕尺寸：gfxstream 用它作为"默认显示配置"上报给 guest 的显示驱动，
// guest 侧 hwcomposer(EmuHWC2) 通过 gfxstream 拿到的就是这里传的尺寸
// （实测 guest 的 DisplayDeviceInfo 正是 1080x1920，与下面的宏一致）。
//
// TCG 下"每个像素"都要由 guest 的 SF/HWC 合成，像素量直接决定合成耗时，
// 所以这里从 1080x1920 降到 720x1280：像素量 921600/2073600 ≈ 44%，
// 即合成工作量 -56%。720p 是清晰度仍可接受的最低档。
#define VMHOST_GFX_DISPLAY_WIDTH 720
#define VMHOST_GFX_DISPLAY_HEIGHT 1280
#define VMHOST_GFX_GUEST_API_LEVEL 28

/* 显示尺寸允许被环境变量覆盖：引擎在 fork QEMU 子进程前会 setenv
   VMHOST_GFX_W / VMHOST_GFX_H（见 vm_qemu.c），这里读它。好处是同一个
   二进制就能 A/B 对比不同分辨率下的合成开销，不用每次重编 QEMU。
   未设置或非法（<320 / >4096）时回落上面的编译期默认值。 */
static int vmhost_gfx_dim_env(const char *name, int def)
{
    const char *e = getenv(name);
    if (e == NULL || *e == '\0') return def;
    const int v = atoi(e);
    return (v >= 320 && v <= 4096) ? v : def;
}

static gfxstream::RenderLibImpl* sVmHostRenderLib = nullptr;

// 截图回传线程的帧目录（D1a），由 vmhost_gfx_init 从 VMHOST_FRAME_DIR 填入。
// vmhost_gfx_screen_thread 定义在文件末尾，这里先给原型。
static char s_frame_dir[512];
static void* vmhost_gfx_screen_thread(void* arg);
// D1f：post callback 定义在文件末尾，vmhost_gfx_init 要先注册它，给原型。
static void vmhost_gfx_on_post(void* ctx, uint32_t displayId, int width, int height,
                               int ydir, int format, int type,
                               unsigned char* pixels);

static void vmhost_gfx_log(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fputs("VMHOSTGFX ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

// p71 uses the ranchu goldfish_fb, not virtio-gpu. Its pixels are published
// by ui/vmhost_goldfish_fb.c into frame.shm; leave gfxstream's post callback
// and screenshot thread disabled in that mode so there is only one writer.
static bool vmhost_gfx_goldfish_fb_mode(void) {
    const char* v = getenv("VMHOST_GOLDFISH_FB");
    return v != NULL && strcmp(v, "1") == 0;
}

// p9 keeps the goldfish_fb bridge for the boot path but the framework UI is
// rendered through gfxstream.  Capture both: the bridge covers bootanim,
// the post callback covers the framework.
static bool vmhost_gfx_post_mode(void) {
    const char* v = getenv("VMHOST_GFX_POST");
    return v != NULL && strcmp(v, "1") == 0;
}

// -------------------- 共享内存帧回传（v3，替代 frame.rgba 文件）--------------
// 布局见 vm_frame_shm.h。写端把最新帧 memcpy 进轮转缓冲并 release 递增 seq；
// App 进程 mmap 同一文件按 seq 取帧 —— 省掉每帧 open/write/rename 三条系统
// 调用与文件页缓存抖动。拿不到共享内存（建失败 / 帧比预留大）时上层会回退
// 原来的文件回传，所以这里失败也不致命。
static int               s_shm_fd = -1;
static VmFrameShmHeader* s_shm = nullptr;
static size_t            s_shm_len = 0;

static void vmhost_gfx_shm_close(void) {
    if (s_shm != nullptr) {
        munmap(s_shm, s_shm_len);
        s_shm = nullptr;
    }
    if (s_shm_fd >= 0) {
        close(s_shm_fd);
        s_shm_fd = -1;
    }
    s_shm_len = 0;
}

// 建立并映射 <frame_dir>/frame.shm。按显示尺寸预留 nbufs 个缓冲。
static void vmhost_gfx_shm_open(int disp_w, int disp_h) {
    if (s_shm != nullptr || s_frame_dir[0] == '\0') {
        return;
    }
    /* 逃生舱：VMHOST_FRAME_SHM=0 强制回退到 frame.rgba 文件回传，便于排障。 */
    const char* off = getenv("VMHOST_FRAME_SHM");
    if (off != NULL && off[0] == '0' && off[1] == '\0') {
        vmhost_gfx_log("shm: VMHOST_FRAME_SHM=0，改用文件回传");
        return;
    }
    if (disp_w <= 0 || disp_h <= 0) {
        return;
    }

    size_t stride = (size_t)disp_w * (size_t)disp_h * 4u;
    stride = (stride + 4095u) & ~(size_t)4095u;   // 4KB 对齐
    if (stride < 4096u) {
        stride = 4096u;
    }

    char path[1024];
    if (snprintf(path, sizeof(path), "%s/frame.shm", s_frame_dir) >= (int)sizeof(path)) {
        vmhost_gfx_log("shm: 路径过长，回退文件回传");
        return;
    }

    const size_t total = vm_frame_shm_total((uint32_t)stride);
    const int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0644);
    if (fd < 0) {
        vmhost_gfx_log("shm: open %s 失败：%s，回退文件回传", path, strerror(errno));
        return;
    }
    if (ftruncate(fd, (off_t)total) != 0) {
        vmhost_gfx_log("shm: ftruncate 失败：%s", strerror(errno));
        close(fd);
        return;
    }
    void* m = mmap(nullptr, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (m == MAP_FAILED) {
        vmhost_gfx_log("shm: mmap 失败：%s", strerror(errno));
        close(fd);
        return;
    }

    VmFrameShmHeader* h = (VmFrameShmHeader*)m;
    h->magic = 0;                 // 先置无效，避免 App 端读到半初始化的头
    h->version = VM_FRAME_SHM_VERSION;
    h->nbufs = VM_FRAME_SHM_NBUFS;
    h->stride_cap = (uint32_t)stride;
    h->disp_w = (uint32_t)disp_w;
    h->disp_h = (uint32_t)disp_h;
    h->seq = 0;
    h->slot = 0;
    h->width = 0;
    h->height = 0;
    h->format = 0;
    __atomic_thread_fence(__ATOMIC_RELEASE);
    h->magic = VM_FRAME_SHM_MAGIC;   // 最后写 magic：App 端据此判定"已就绪"

    s_shm_fd = fd;
    s_shm = h;
    s_shm_len = total;
    vmhost_gfx_log("shm: 帧回传共享内存就绪 %s（%dx%d stride=%zu n=%u total=%zu）",
                   path, disp_w, disp_h, stride, (unsigned)VM_FRAME_SHM_NBUFS, total);
}

// 把一帧 RGBA 发布到共享内存。返回 0 成功；-1 不可用 / 帧过大。
static int vmhost_gfx_shm_publish(const uint8_t* rgba, unsigned w, unsigned h) {
    if (s_shm == nullptr || rgba == nullptr || w == 0 || h == 0) {
        return -1;
    }
    const size_t need = (size_t)w * (size_t)h * 4u;
    if (need > s_shm->stride_cap) {
        return -1;   // 帧比预留大：交给上层回退文件路径
    }
    const uint32_t next = s_shm->seq + 1u;
    const uint32_t slot = next % s_shm->nbufs;
    uint8_t* dst = (uint8_t*)s_shm + VM_FRAME_SHM_HDR_SIZE +
                   (size_t)slot * (size_t)s_shm->stride_cap;
    memcpy(dst, rgba, need);
    s_shm->slot = slot;
    s_shm->width = w;
    s_shm->height = h;
    __atomic_thread_fence(__ATOMIC_RELEASE);
    __atomic_store_n(&s_shm->seq, next, __ATOMIC_RELEASE);
    return 0;
}


// ---- D15：「崩溃线程有没有 current GL 上下文」探针 --------------------------
// 动机：宿主 Adreno 驱动在**固定指令**上 SIGSEGV（addr=0x38，near-null 解引用），
// 最像"某线程没有 current EGL context 就发了 GL 调用，驱动在入口桩里解引用
// NULL 的线程局部上下文"。
//
// 这里只查 **EGL 自己的状态**（eglGetCurrentContext / eglGetCurrentSurface），
// 不去读 gfxstream 的 RenderThreadInfo —— 后者会连带拉进 gles1_dec/gles2_dec/
// glsnapshot/vulkan 一大串内部头，给 glue 的编译链平添脆性；而"这一线程到底
// 有没有绑定上下文"本来就该以 EGL 的回答为准。
//
// 安全性：两个入口都只查线程局部状态，信号处理器里调用可以接受；函数指针在
// vmhost_gfx_init 里**预先解析**，免得在信号处理器里做 dlopen/dlsym。
static void* (*s_eglGetCurrentContext)(void) = nullptr;
static void* (*s_eglGetCurrentSurface)(int) = nullptr;

static void vmhost_gfx_resolve_egl_probe(void) {
    /* 注意：**不要**在这里 dlopen("libEGL.so")。
       本函数在 vmhost_gfx_init 的最早期执行，此时主动把平台 libEGL 拉进全局
       作用域，会改变 gfxstream 之后解析 EGL 符号的优先级（RTLD_DEFAULT 先命中
       平台 libEGL 而不是它自己的 translator），实测会让
       android_startOpenglesRenderer 直接返回 -1（宿主渲染器根本起不来）。
       探针只是诊断用，取不到符号就退化成不打那一行。 */
    s_eglGetCurrentContext =
        reinterpret_cast<void* (*)(void)>(dlsym(RTLD_DEFAULT, "eglGetCurrentContext"));
    s_eglGetCurrentSurface =
        reinterpret_cast<void* (*)(int)>(dlsym(RTLD_DEFAULT, "eglGetCurrentSurface"));
}

// out 至少 3 项：[0] eglGetCurrentContext() [1] eglGetCurrentSurface(EGL_DRAW)
//               [2] eglGetCurrentSurface(EGL_READ)
// 由崩溃处理器（vmhost_pipe_glue.cpp）以弱符号调用。
extern "C" int vmhost_gfx_egl_ctx_info(unsigned long long* out) {
    for (int i = 0; i < 3; i++) {
        out[i] = 0;
    }
    if (s_eglGetCurrentContext != nullptr) {
        out[0] = (unsigned long long)(uintptr_t) s_eglGetCurrentContext();
    }
    if (s_eglGetCurrentSurface != nullptr) {
        out[1] = (unsigned long long)(uintptr_t) s_eglGetCurrentSurface(0x3059 /*EGL_DRAW*/);
        out[2] = (unsigned long long)(uintptr_t) s_eglGetCurrentSurface(0x305A /*EGL_READ*/);
    }
    return 0;
}

extern "C" int vmhost_gfx_init(void);
extern "C" int vmhost_gfx_renderer_ready(void);

// ---- D16：surfaceless make-current 的工作区修复 -----------------------------
// D15 结论：宿主 Adreno 830 驱动在"上下文有效、但 draw/read surface 都是 NULL"时，
// 会在固定指令 `LDR x5, [x21, #0x38]`（x21=0）上 SIGSEGV，**直接打死整个 QEMU 进程**。
// 位置在 host/FrameBuffer.cpp 之外的某条 make-current 路径上（bindContext 已排除）。
//
// 与其逐个揪调用点，不如在**宿主侧唯一汇聚点**上包一层：gfxstream 所有内部调用
// 都走 `gfxstream::gl::s_egl.eglMakeCurrent`（翻译器自己的 EglOsApi 那条路本来
// 就拒绝无 surface 的 make-current，见 EglOsApi_egl.cpp 的 "warning: makeCurrent
// a context without surface"）。
//
// 规则：
//   1) ctx 非空 + draw/read 都是 NULL → 改绑一个 1x1 pbuffer。
//      这类调用本来就是往 FBO 里画，pbuffer 的内容无关紧要。
//   2) 若该 pbuffer 与 context 的 config 不匹配（eglMakeCurrent 失败），退化成
//      "完全不绑上下文" —— 之后该线程的 GL 调用是无害的 no-op，总比驱动解引用
//      NULL 把进程崩掉强。
// 只有真的收到 surfaceless 请求才介入，其余一律原样透传。
static EGLBoolean (*s_realEglMakeCurrent)(EGLDisplay, EGLSurface, EGLSurface,
                                          EGLContext) = nullptr;
static EGLSurface s_vmhostPbSurface = EGL_NO_SURFACE;

static EGLSurface vmhost_get_probe_pbuffer(EGLDisplay dpy) {
    if (s_vmhostPbSurface != EGL_NO_SURFACE) {
        return s_vmhostPbSurface;
    }
    if (gfxstream::gl::s_egl.eglChooseConfig == nullptr ||
        gfxstream::gl::s_egl.eglCreatePbufferSurface == nullptr) {
        return EGL_NO_SURFACE;
    }
    const EGLint cfgAttribs[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
        EGL_NONE};
    EGLConfig cfg = nullptr;
    EGLint n = 0;
    if (!gfxstream::gl::s_egl.eglChooseConfig(dpy, cfgAttribs, &cfg, 1, &n) ||
        n < 1 || cfg == nullptr) {
        return EGL_NO_SURFACE;
    }
    const EGLint pbAttribs[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    s_vmhostPbSurface =
        gfxstream::gl::s_egl.eglCreatePbufferSurface(dpy, cfg, pbAttribs);
    return s_vmhostPbSurface;
}

static EGLBoolean vmhost_eglMakeCurrent(EGLDisplay dpy, EGLSurface draw,
                                        EGLSurface read, EGLContext ctx) {
    if (s_realEglMakeCurrent == nullptr) {
        return EGL_FALSE;
    }
    if (ctx == EGL_NO_CONTEXT || draw != EGL_NO_SURFACE ||
        read != EGL_NO_SURFACE) {
        return s_realEglMakeCurrent(dpy, draw, read, ctx);
    }
    const EGLSurface pb = vmhost_get_probe_pbuffer(dpy);
    if (pb != EGL_NO_SURFACE &&
        s_realEglMakeCurrent(dpy, pb, pb, ctx) == EGL_TRUE) {
        fprintf(stderr, "VMHOST_PBFIX surfaceless->pbuffer ok ctx=%p\n",
                (void*)(uintptr_t)ctx);
        return EGL_TRUE;
    }
    fprintf(stderr, "VMHOST_PBFIX surfaceless->unbind ctx=%p（总比驱动崩掉强）\n",
            (void*)(uintptr_t)ctx);
    return s_realEglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE,
                                EGL_NO_CONTEXT);
}

static void vmhost_gfx_install_makecurrent_fix(void) {
    if (s_realEglMakeCurrent != nullptr) {
        return; /* 已装 */
    }
    if (gfxstream::gl::s_egl.eglMakeCurrent == nullptr) {
        /* 表还没初始化就主动拉一次（init_egl_dispatch 自身幂等）。 */
        gfxstream::gl::init_egl_dispatch();
    }
    if (gfxstream::gl::s_egl.eglMakeCurrent == nullptr) {
        vmhost_gfx_log("D16 未装：s_egl.eglMakeCurrent 仍为空");
        return;
    }
    s_realEglMakeCurrent = gfxstream::gl::s_egl.eglMakeCurrent;
    gfxstream::gl::s_egl.eglMakeCurrent = vmhost_eglMakeCurrent;
    vmhost_gfx_log("D16 已挂钩 s_egl.eglMakeCurrent（surfaceless → 1x1 pbuffer）");
}

// GLcommon/GLutils.h（gfxstream translator）：
//   void setGles2Gles(bool isGles2gles);
// 强制 guest GLES 直通宿主 GLES。宿主是 Android 的 Adreno GLES，
// 若保持默认 false（sEgl2Egl=false），translator 会把所有 GLSL shader
// 交给 ShaderParser 做 GLES→GL 转译（面向 desktop GL 的产物），
// 在 Adreno 上编译失败：TextureDraw 与 guest 合成 shader 全崩，
// SurfaceFlinger 合不出帧 → guest 从不 post → 截图永远拿不到画面。
void setGles2Gles(bool isGles2gles);


// 渲染器是否已就绪（供打点/判据 A2 使用）
extern "C" int vmhost_gfx_renderer_ready(void) {
    const gfxstream::RendererPtr& renderer = android_getOpenglesRenderer();
    return renderer ? 1 : 0;
}

extern "C" int vmhost_gfx_init(void) {
    if (sVmHostRenderLib) {
        return 0;
    }

    // 0. guest GLES 直通宿主 GLES（见 setGles2Gles 声明处的说明）。
    //    必须在 renderer 启动前设置，且要在 guest 建立 HostConnection 之前。
    setGles2Gles(true);
    vmhost_gfx_log("已强制 gles2gles（GLSL 直通宿主，不做 desktop-GL 转译）");

    // D15：预先解析崩溃探针要用的 EGL 入口（信号处理器里不做 dlopen/dlsym）
    vmhost_gfx_resolve_egl_probe();
    vmhost_gfx_log("D15 崩溃探针就绪：eglGetCurrentContext=%s eglGetCurrentSurface=%s",
                   s_eglGetCurrentContext ? "ok" : "NULL",
                   s_eglGetCurrentSurface ? "ok" : "NULL");

    // 1. agents
    android::emulation::injectGraphicsAgents(
            android::emulation::GfxStreamGraphicsAgentFactory());
    const GraphicsAgents* agents = getGraphicsAgents();
    if (!agents || !agents->vm || !agents->emu || !agents->multi_display) {
        vmhost_gfx_log("agents 不完整，放弃启动渲染器");
        return -1;
    }
    vmhost_gfx_log("graphics agents 已注入");

    // 2. emugl 配置：宿主 GPU + 无窗口
    // uiPreferredBackend 取 0 = WINSYS_GLESBACKEND_PREFERENCE_AUTO
    // （该枚举定义在 QEMU UI 侧的 android/skin/backend-defs.h，我们不引那个头，
    //  直接用字面量）。
    EmuglConfig config;
    memset(&config, 0, sizeof(config));
    if (!emuglConfig_init(&config, /*gpu_enabled*/ true, /*gpu_mode*/ "auto",
                          /*gpu_option*/ "host", /*bitness*/ 64,
                          /*no_window*/ true, /*blacklisted*/ false,
                          /*google_apis*/ false,
                          /*uiPreferredBackend*/ 0,
                          /*use_host_vulkan*/ false)) {
        vmhost_gfx_log("emuglConfig_init 失败：%s", config.status);
        return -1;
    }
    emuglConfig_setupEnv(&config);
    vmhost_gfx_log("emugl 渲染器 = %s",
                   emuglConfig_renderer_to_string(emuglConfig_get_current_renderer()));

    // 打开 gfxstream 自己的日志。
    // 注意：上游是在 android_initOpenglesEmulation() 里根据 ANDROID_EMUGL_FINE_LOG /
    // ANDROID_EMUGL_LOG_PRINT 设这两个 flag 的，而那个函数在新构建里直接 abort
    // （我们本来就不能调），所以这里显式设。
    // 打开后 gfxstream 的 coarse/fine 日志会 printf 到 stdout（宿主 stdout 要记得收，
    // 否则会被丢进 /dev/null）。设 VMHOST_GFX_DEBUG=0 可关掉。
    if (getenv("VMHOST_GFX_DEBUG") == NULL ||
        strcmp(getenv("VMHOST_GFX_DEBUG"), "0") != 0) {
        android_opengl_logger_set_flags(
                static_cast<AndroidOpenglLoggerFlags>(
                        OPENGL_LOGGER_DO_FINE_LOGGING |
                        OPENGL_LOGGER_PRINT_TO_STDOUT));
        vmhost_gfx_log("gfxstream 详细日志已打开（DO_FINE_LOGGING | PRINT_TO_STDOUT）");
    }

    // 3. 注入 RenderLib
    //
    // 打开 egl2egl：我们的宿主就是"跑在系统 EGL/GLES 之上"的场景（手机只有
    // GLES 3.2，没有 GL1）。gl-host-common/opengles.cpp 正是用这个环境变量填
    // sEgl2egl，再经 EglImp.cpp 的 initGLESx(EglGlobalInfo::isEgl2Egl()) 传到
    // GLES1 翻译器：
    //   isGles2Gles() == true → GLEScmContext 建 CoreProfileEngine(gles2gles)，
    //   在 GLES2 上用着色器模拟固定管线；
    //   == false → 直通 host 的 GL1 函数表，而那张表在 GLES2-only 宿主上
    //   （glShadeModel / glMatrixMode 等 GL1 专用项）全是 NULL
    //   → 访客一发固定管线命令就 pc=0 崩溃（实测 glShadeModel 首崩）。
    // 必须在 android_setOpenglesEmulation() 之前设，它在那里读这个变量。
    setenv("ANDROID_EGL_ON_EGL", "1", 1);

    sVmHostRenderLib = new gfxstream::RenderLibImpl();
    {
        const char* goldfishGralloc = getenv("VMHOST_GOLDFISH_GRALLOC");
        if (goldfishGralloc != NULL && strcmp(goldfishGralloc, "1") == 0) {
            sVmHostRenderLib->setGrallocImplementation(GOLDFISH_GRALLOC);
            vmhost_gfx_log("gralloc implementation: GOLDFISH_GRALLOC");
        } else {
            vmhost_gfx_log("gralloc implementation: MINIGBM");
        }
    }
    android_setOpenglesEmulation(sVmHostRenderLib, nullptr, nullptr);

    // 4. 启动渲染器
    int glesMajor = 0;
    int glesMinor = 0;
    const int dispW = vmhost_gfx_dim_env("VMHOST_GFX_W", VMHOST_GFX_DISPLAY_WIDTH);
    const int dispH = vmhost_gfx_dim_env("VMHOST_GFX_H", VMHOST_GFX_DISPLAY_HEIGHT);
    vmhost_gfx_log("display %dx%d（env VMHOST_GFX_W/H 可覆盖）", dispW, dispH);
    int ret = android_startOpenglesRenderer(
            dispW, dispH,
            /*guestPhoneApi*/ 1, VMHOST_GFX_GUEST_API_LEVEL, agents->vm,
            agents->emu, agents->multi_display, &glesMajor, &glesMinor);
    vmhost_gfx_log("android_startOpenglesRenderer ret=%d gles=%d.%d", ret,
                   glesMajor, glesMinor);

    if (!vmhost_gfx_renderer_ready()) {
        vmhost_gfx_log("renderer 为空（EGL 没建起来），opengles 管道仍会注册但无法服务");
    } else {
        char* vendor = nullptr;
        char* renderer = nullptr;
        char* version = nullptr;
        android_getOpenglesHardwareStrings(&vendor, &renderer, &version);
        vmhost_gfx_log("GL vendor=[%s] renderer=[%s] version=[%s]",
                       vendor ? vendor : "(null)", renderer ? renderer : "(null)",
                       version ? version : "(null)");
        free(vendor);
        free(renderer);
        free(version);

        // D1f：注册 post callback，直接抓每次显示的帧像素（与传输路径无关）。
        if (!vmhost_gfx_goldfish_fb_mode() || vmhost_gfx_post_mode()) {
            const gfxstream::RendererPtr& r = android_getOpenglesRenderer();
            r->setPostCallback(vmhost_gfx_on_post, nullptr, 0,
                               /*useBgraReadback*/ false);
            vmhost_gfx_log("已注册 post callback（displayId=0，直接抓帧）");
        } else {
            vmhost_gfx_log("p9/p71 goldfish_fb 模式：跳过 gfxstream post callback");
        }
    }

    // 5. 注册 opengles 管道服务（必须在 guest 连接之前）
    android_init_opengles_pipe();
    vmhost_gfx_log("opengles 管道服务已注册（renderer_ready=%d）",
                   vmhost_gfx_renderer_ready());

    // 5b. 方案 B（virtio-gpu）：guest 用 virtio-gpu-pipe 传输。与 emulator 的
    // stream_renderer_opengles_init() 对齐：
    //   - recv_mode(2)：opengles 管道切到 virtio-gpu 数据面（guest 不再走
    //     goldfish pipe 传 GL 命令）；
    //   - refcount：aemu 自带真实现（RefcountPipe.cpp），注册 refcount 管道。
    // 注意：**不要**在这里调 address_space_set_vm_operations —— vmhost_pipe_init()
    // 已经用 vmhost_vm_ops 接好（含 user-backed RAM 映射等真实现），再用 gfxstream
    // 的 GfxStreamGraphicsAgentFactory 覆盖会把 vm ops 换成一堆空实现，guest 一敲
    // 地址空间设备的 PING 就崩（实测 SIGSEGV）。
    // 用 VMHOST_VIRTIO_GPU=1 环境变量开关（d1a.sh 设置），便于回退旧路径。
    if (getenv("VMHOST_VIRTIO_GPU") != NULL) {
        android_opengles_pipe_set_recv_mode(2); /* virtio-gpu */
        vmhost_gfx_log("virtio-gpu 模式：recv_mode=2");
    }
    // VMHOST_FIX：guest 的 allocator@3.0-service（gralloc）在 allocateCb 里
    // qemu_pipe_open_ns("refcount")，host 不注册该服务则 fd<0 -> NO_RESOURCES
    // -> gralloc 分配失败 -> SF 无 color buffer。aemu 的 RefcountPipe 是真实现，
    // 无条件注册（与 recv_mode 无关），让 guest 的 refcount 连接成功。
    android_init_refcount_pipe();
    vmhost_gfx_log("refcount 管道已注册（guest allocator 依赖）");

    // 6. 截图回传线程（D1a）：读 VMHOST_FRAME_DIR，非空就起后台线程，
    //    轮询 frame.request → 截图 frame.ppm + frame.seq。B1 子进程模式下
    //    由 vm_qemu.c spawn 时 setenv 注入，目录即 <dataDir>/logs。
    if (!vmhost_gfx_goldfish_fb_mode() || vmhost_gfx_post_mode()) {
        const char* fd = getenv("VMHOST_FRAME_DIR");
        if (fd != NULL && fd[0] != '\0') {
            snprintf(s_frame_dir, sizeof(s_frame_dir), "%s", fd);
            // 建共享内存回传（首选路径）；失败则线程回退文件回传。
            vmhost_gfx_shm_open(dispW, dispH);
            if (!vmhost_gfx_goldfish_fb_mode()) {
                pthread_t tid;
                if (pthread_create(&tid, NULL, vmhost_gfx_screen_thread, NULL) == 0) {
                    vmhost_gfx_log("截图回传线程已启动（frame_dir=%s）", s_frame_dir);
                } else {
                    vmhost_gfx_log("截图回传线程启动失败");
                }
            } else {
                vmhost_gfx_log("p9: gfxstream post callback + goldfish_fb 双通道");
            }
        }
    } else {
        vmhost_gfx_log("p9/p71 goldfish_fb 模式：帧由 ui/vmhost_goldfish_fb.c 回传");
    }

    // 7. D16（surfaceless make-current 的工作区修复）**已停用**：
    //    它把"surfaceless 的 makeCurrent"改成"绑 1x1 pbuffer"，pbuffer 不可用时
    //    还会退化成"完全不绑上下文"—— 后者会在该线程上制造出"没有 current
    //    context"的状态，紧接着的 GL 调用就会让 Adreno 驱动解引用 NULL
    //    （实测崩溃现场 D15 探针正是 eglGetCurrentContext=0x0）。而且它整轮
    //    一次都没命中（PBFIX 计数 0）。保留函数体备查，但不再安装。
    // vmhost_gfx_install_makecurrent_fix();
    return 0;
}

// ---------------------------------------------------------- 截图回传（D1a）
// 把 gfxstream 的**最新一帧**（m_lastPostedColorBuffer）按 max_w/max_h 等比缩放
// 后写成一个 P6 PPM 文件。max_w/max_h 任一为 0 表示取原生分辨率。
// 返回 0 成功；-1 失败。可被后台线程或外部显式调用（排障用）。

// ---- D1f：post callback 抓帧（与传输路径无关）----
static std::mutex s_latest_mutex;
static std::vector<uint8_t> s_latest_pixels;
static int s_latest_w = 0;
static int s_latest_h = 0;
static unsigned long long s_latest_seq = 0;

// Renderer::OnPostCallback 签名：每次帧显示前回调，pixels 为帧内容拷贝。
//
// VMHOST_FIX（朝向）：实测 gfxstream 这次回调传进来的 pixels **已经是
// top-to-bottom**（pixels[0] 就是图像顶部的第一行）。此前按 ydir<0 又翻了一次，
// 于是 s_latest_pixels 变成 bottom-up 写进 frame.ppm；宿主按 PPM 的 top-down
// 约定读走，画面就上下颠倒了（实测访客 "Phone is starting" 在宿主上倒置：
// 字母 P 的圈朝下、结尾 g 的降部朝上，而左右顺序正常）。这里改成原样拷贝，
// ydir 只打一次日志便于复核。
static void vmhost_gfx_on_post(void* ctx, uint32_t displayId, int width, int height,
                               int ydir, int format, int type,
                               unsigned char* pixels) {
    (void)ctx;
    if (displayId != 0 || !pixels || width <= 0 || height <= 0) {
        return;
    }
    static bool s_logged_ydir = false;
    if (!s_logged_ydir) {
        s_logged_ydir = true;
        vmhost_gfx_log("post callback ydir=%d %dx%d fmt=%d type=%d（按 top-down 原样使用）",
                       ydir, width, height, format, type);
    }
    std::lock_guard<std::mutex> lk(s_latest_mutex);
    const size_t row = (size_t)width * 4u;
    const size_t need = row * (size_t)height;
    if (s_latest_pixels.size() != need) {
        s_latest_pixels.resize(need);
    }
    memcpy(s_latest_pixels.data(), pixels, need);
    s_latest_w = width;
    s_latest_h = height;
    s_latest_seq++;
}

/*
 * 帧回传文件格式（v2，与引擎侧 vm_frame_relay.c 的 load_raw() 一致，小端）：
 *   [0..3] u32 width   [4..7] u32 height   [8..] width*height*4 字节 RGBA8888
 *
 * 为什么不再写 P6 PPM：
 *   PPM 每像素 3 字节，QEMU 侧要跑一遍 RGBA->RGB、App 侧再跑一遍 RGB->RGBA，
 *   1080p 每帧两侧各 200 万次逐像素循环；而且 App 拿到 RGB 后还要再拷一次
 *   才能 glTexSubImage2D。改成原生 RGBA 后：QEMU 侧只做一次 memcpy，
 *   App 侧直接把读进来的缓冲交给 GL 上传 —— 两侧的转换与一次全帧拷贝全部消失。
 *   代价是每帧多 33% 字节，换回几次百万级标量循环，很值。
 */
static int vmhost_gfx_write_raw_file(const char* path, const uint8_t* rgba,
                                     unsigned w, unsigned h) {
    const size_t need = (size_t)w * (size_t)h * 4u;
    char tmp[1024];
    if (snprintf(tmp, sizeof(tmp), "%s.tmp", path) >= (int)sizeof(tmp)) {
        return -1;
    }
    const int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        return -1;
    }
    uint8_t hdr[8];
    memcpy(hdr + 0, &w, 4);
    memcpy(hdr + 4, &h, 4);
    const bool ok = (write(fd, hdr, sizeof(hdr)) == (ssize_t)sizeof(hdr)) &&
                    (write(fd, rgba, need) == (ssize_t)need);
    close(fd);
    if (!ok) {
        unlink(tmp);
        return -1;
    }
    /* 先写临时文件再 rename：App 侧永远读不到半帧。 */
    if (rename(tmp, path) != 0) {
        unlink(tmp);
        return -1;
    }
    return 0;
}

/* 上次已经写出过的 post 序号，用来跳过重复帧（访客没 post 就不重写）。 */
static unsigned long long s_written_seq = 0;
/* 换出的帧缓冲：与 s_latest_pixels 来回换，两边都常驻，不产生每帧分配。 */
static std::vector<uint8_t> s_snapshot;
static int s_logged_w = 0;
static int s_logged_h = 0;

// 从 post callback 保存的最新帧写出**一帧新画面**（原生 RGBA）。
// 返回 0：写出成功；-1：还没有 post 帧或出错；-2：自上次写出后没有新帧。
static int vmhost_gfx_write_latest_raw(const char* path) {
    int w = 0;
    int h = 0;
    unsigned long long seq = 0;
    {
        /*
         * 锁内只做 O(1) 的指针交换 —— 绝不持锁写盘、也不持锁做色彩转换。
         *
         * 旧实现持着这把锁跑完 200 万次 RGBA->RGB 转换 + 一次几 MB 的 fwrite，
         * 而访客的 post 回调（vmhost_gfx_on_post）要用**同一把锁**：等于每秒数次
         * 把访客的渲染管线整条堵死。对 TCG 访客来说，这一堵还会连锁放大。
         */
        std::lock_guard<std::mutex> lk(s_latest_mutex);
        if (s_latest_pixels.empty() || s_latest_w <= 0 || s_latest_h <= 0) {
            return -1;
        }
        if (s_latest_seq == s_written_seq) {
            return -2;   /* 访客没有再 post，别把同一帧重复写一遍占满 IO */
        }
        w = s_latest_w;
        h = s_latest_h;
        seq = s_latest_seq;
        s_snapshot.swap(s_latest_pixels);   /* 换出后 s_latest_pixels 复用旧快照缓冲 */
    }
    s_written_seq = seq;

    const size_t need = (size_t)w * (size_t)h * 4u;
    if (s_snapshot.size() < need) {
        return -1;
    }
    if (vmhost_gfx_write_raw_file(path, s_snapshot.data(), (unsigned)w, (unsigned)h) != 0) {
        return -1;
    }
    if (w != s_logged_w || h != s_logged_h) {
        s_logged_w = w;
        s_logged_h = h;
        vmhost_gfx_log("frame relay v2: %dx%d 原生 RGBA（无色彩转换，锁内不再写盘）", w, h);
    }
    return 0;
}

// 从最新 post 帧发布到共享内存。返回 0 成功；-2 无新帧；-1 不可用（帧过大等）。
static int vmhost_gfx_shm_publish_latest(void) {
    if (s_shm == nullptr) {
        return -1;
    }
    int w = 0;
    int h = 0;
    unsigned long long seq = 0;
    {
        std::lock_guard<std::mutex> lk(s_latest_mutex);
        if (s_latest_pixels.empty() || s_latest_w <= 0 || s_latest_h <= 0) {
            return -2;
        }
        if (s_latest_seq == s_written_seq) {
            return -2;   /* 访客没有再 post，别把同一帧重复发布 */
        }
        w = s_latest_w;
        h = s_latest_h;
        seq = s_latest_seq;
        s_snapshot.swap(s_latest_pixels);
    }
    s_written_seq = seq;

    const size_t need = (size_t)w * (size_t)h * 4u;
    if (s_snapshot.size() < need) {
        return -1;
    }
    if (vmhost_gfx_shm_publish(s_snapshot.data(), (unsigned)w, (unsigned)h) != 0) {
        return -1;
    }
    if (w != s_logged_w || h != s_logged_h) {
        s_logged_w = w;
        s_logged_h = h;
        vmhost_gfx_log("frame relay v3(shm): %dx%d 原生 RGBA（零文件 IO）", w, h);
    }
    return 0;
}

/* 单调毫秒时钟（只给兜底限流用，不需要墙钟语义）。 */
static uint64_t vmhost_gfx_now_ms(void) {    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return 0;
    }
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)(ts.tv_nsec / 1000000L);
}

extern "C" int vmhost_gfx_screenshot_to_file(const char* path, int max_w, int max_h) {
    if (path == NULL) {
        return -1;
    }
    /* D1f：优先用 post callback 抓到的最新帧（ASG 数据面也能拿）。
       拿到了就不再走 getScreenshot（它依赖 rcFBPost 更新的 m_lastPostedColorBuffer）。 */
    const int wr = vmhost_gfx_write_latest_raw(path);
    if (wr == 0) {
        return 0;
    }
    if (wr == -2) {
        /* 访客没有新帧：既不要自增 seq，也别走 getScreenshot 去重复回读同一帧。
           返回 -2 与 -1（真失败）区分开，调用方据此决定要不要推进 seq。 */
        return -2;
    }

    /*
     * 兜底（getScreenshot）**必须限流**，否则启动阶段会失控。
     *
     * 访客还没 post 过帧时（启动前中期），post-callback 路径必然拿不到东西，
     * 于是每次都落到这里。回传线程现在 8ms 一轮、App 侧 16ms 请求一次，
     * 不限流就是每秒几十次注定失败的 getScreenshot 探测，而且每次刷一条
     * stderr —— 实测 80 秒把 qemu-stderr.log 写到 54MB，同时把 CPU 从
     * TCG 访客手里抢走（越抢越晚出帧，恶性循环）。
     * 所以两次兜底之间至少隔 250ms，失败日志只打第一次。
     */
    static uint64_t s_last_fallback_ms = 0;
    static bool s_logged_fallback_fail = false;
    const uint64_t now = vmhost_gfx_now_ms();
    if (now - s_last_fallback_ms < 250) {
        return -2;   /* 当成"暂时没有新帧"，调用方不要自增 seq */
    }
    s_last_fallback_ms = now;

    /* D14b：恢复 getScreenshot 兜底 —— 复核 gfxstream 源码后确认它是**线程安全**的。
     *
     * RendererImpl::getScreenshot → FrameBuffer::getScreenshot 会把回读命令
     * （PostCmd::Screenshot）经 sendPostWorkerCmd 投给 **post worker 线程**执行并等
     * future 完成，GL 命令并**不在调用线程上发**。之前把它当成"在 200ms 轮询线程上
     * 直接发 GL"而禁用（D14），是误判 —— 当时真正坏掉的是 MAKECURFIX/D16 造出来的
     * "没有 current context"状态。
     *
     * 它自身失败的真正原因是：displayId==0 时取 m_lastPostedColorBuffer，访客没有
     * post 过就没有可读的 CB，此时干净返回 -1（不会崩）。所以作为兜底是安全的。
     */
    const gfxstream::RendererPtr& renderer = android_getOpenglesRenderer();
    if (!renderer) {
        if (!s_logged_fallback_fail) {
            s_logged_fallback_fail = true;
            vmhost_gfx_log("screenshot: renderer 未就绪（后续同类失败不再刷日志）");
        }
        return -1;
    }
    unsigned int w = 0, h = 0;
    size_t cap = 0;
    // 第一步：pixels=NULL 探尺寸。gfxstream 约定：空间不够返回 -2 并回填需要的字节数。
    int res = renderer->getScreenshot(3, &w, &h, NULL, &cap, /*displayId*/ 0,
                                      max_w > 0 ? max_w : 0,
                                      max_h > 0 ? max_h : 0, /*desiredRotation*/ 0);
    if (res != -2 || cap == 0 || w == 0 || h == 0) {
        // res=-1：m_lastPostedColorBuffer 无效，即 guest 还没有成功 post 过帧。
        if (!s_logged_fallback_fail) {
            s_logged_fallback_fail = true;
            vmhost_gfx_log("screenshot: 兜底暂不可用（访客还没 post 过帧）res=%d cap=%zu %ux%u"
                           "（后续同类失败不再刷日志）", res, cap, w, h);
        }
        return -1;
    }
    std::vector<uint8_t> pixels(cap);
    res = renderer->getScreenshot(3, &w, &h, pixels.data(), &cap, /*displayId*/ 0,
                                  max_w > 0 ? max_w : 0,
                                  max_h > 0 ? max_h : 0, /*desiredRotation*/ 0);
    if (res != 0) {
        vmhost_gfx_log("screenshot: 读取失败 res=%d", res);
        return -1;
    }
    // getScreenshot(format=3) 给的就是 RGBA8888，每像素 4 字节 —— 与 v2 帧格式一致，
    // 原样落盘即可，不需要任何色彩转换。
    const size_t px = (size_t)w * (size_t)h;
    if (cap < px * 4u) {
        vmhost_gfx_log("screenshot: 缓冲不足 cap=%zu 需要=%zu", cap, px * 4u);
        return -1;
    }
    if (vmhost_gfx_write_raw_file(path, pixels.data(), w, h) != 0) {
        vmhost_gfx_log("screenshot: 写 %s 失败", path);
        return -1;
    }
    return 0;
}

// 后台线程：轮询 <frame_dir>/frame.request（内容 "宽 高"，可缺省）。
// 有新帧 → 写 frame.rgba + 自增 frame.seq → 删请求文件。
//
// 轮询间隔 8ms（原来 200ms）。这是本次优化里最要命的一条：200ms 直接把整个
// 显示回传卡在 ~5 FPS，触摸和滚动的跟手感几乎全丢在这一处，与 TCG 快慢无关。
// 请求文件是个近乎空的标记文件，QEMU 侧先 access() 再看在不在，所以高频轮询
// 本身几乎不花 CPU；真正做转换+落盘的次数由"访客是否出新帧"决定。
static void* vmhost_gfx_screen_thread(void* arg) {
    (void)arg;
    unsigned long long seq = 0;
    char req[1024], raw[1024], seqp[1024];
    /* VMHOST_PERF：每秒打一行「guest post 了多少帧 / 我们发布了多少帧 /
       发布本身花了多少时间」。用来区分“guest 只画了 9 帧”和“管线把帧丢了”。 */
    uint64_t s_perf_last_ms = vmhost_gfx_now_ms();
    unsigned long long s_perf_posts = 0;
    unsigned long long s_perf_pubs = 0;
    uint64_t s_perf_publish_us = 0;
    if (snprintf(req, sizeof(req), "%s/frame.request", s_frame_dir) >= (int)sizeof(req) ||
        snprintf(raw, sizeof(raw), "%s/frame.rgba", s_frame_dir) >= (int)sizeof(raw) ||
        snprintf(seqp, sizeof(seqp), "%s/frame.seq", s_frame_dir) >= (int)sizeof(seqp)) {
        vmhost_gfx_log("frame_dir 过长，回传线程退出：%s", s_frame_dir);
        return NULL;
    }
    for (;;) {
        if (s_shm != nullptr) {
            /* 共享内存路径：不再依赖 frame.request。
               访客有新帧就发布一次；没有新帧 publish_latest 返回 -2，不产生任何
               工作。这样省掉了"App 写请求文件 + 本线程 access() 轮询"的往返，
               也去掉了请求周期（原本最多 ~16ms）给每帧加的延迟 —— 对滑动的
               "跟手感"是最直接的一刀。 */
            const uint32_t _seq_before = s_shm->seq;
            struct timespec _ts0, _ts1;
            clock_gettime(CLOCK_MONOTONIC, &_ts0);
            vmhost_gfx_shm_publish_latest();
            clock_gettime(CLOCK_MONOTONIC, &_ts1);
            if (s_shm->seq != _seq_before) {
                s_perf_pubs++;
                s_perf_publish_us += (uint64_t)(_ts1.tv_sec - _ts0.tv_sec) * 1000000u +
                                     (uint64_t)(_ts1.tv_nsec - _ts0.tv_nsec) / 1000u;
            }
            usleep(8 * 1000);
            {
                const uint64_t now = vmhost_gfx_now_ms();
                static const bool s_perf_on = getenv("VMHOST_PERF") != nullptr;
                if (s_perf_on && now - s_perf_last_ms >= 1000) {
                    unsigned long long posts;
                    {
                        std::lock_guard<std::mutex> lk(s_latest_mutex);
                        posts = s_latest_seq;
                    }
                    const double secs = (double)(now - s_perf_last_ms) / 1000.0;
                    fprintf(stderr,
                            "VMHOST_PERF post_total=%llu shm_seq=%u "
                            "publish_calls=%llu publish_ms=%.1f\n",
                            posts, s_shm->seq, s_perf_pubs,
                            (double)s_perf_publish_us / 1000.0);
                    (void)secs;
                    s_perf_last_ms = now;
                    s_perf_pubs = 0;
                    s_perf_publish_us = 0;
                }
            }
            continue;
        }
        if (access(req, F_OK) == 0) {
            int max_w = 0;
            int max_h = 0;
            FILE* fp = fopen(req, "rb");
            if (fp != NULL) {
                char buf[64];
                size_t n = fread(buf, 1, sizeof(buf) - 1, fp);
                fclose(fp);
                buf[n] = '\0';
                if (sscanf(buf, "%d %d", &max_w, &max_h) < 2) {
                    max_w = 0;
                    max_h = 0;
                }
            }
            /* 文件回退路径：只有本线程真正产出新帧才自增 seq，避免 App 白读。 */
            if (vmhost_gfx_screenshot_to_file(raw, max_w, max_h) == 0) {
                seq++;
                FILE* sq = fopen(seqp, "wb");
                if (sq != NULL) {
                    fprintf(sq, "%llu\n", seq);
                    fclose(sq);
                }
            }
            unlink(req);
        }
        usleep(8 * 1000);
    }
    return NULL;
}
