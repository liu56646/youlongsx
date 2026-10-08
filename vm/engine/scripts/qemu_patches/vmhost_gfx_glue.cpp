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
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

// 截图回传（D1a）：
//   - vmhost_gfx_screenshot_to_file()：从 gfxstream FrameBuffer 取**最新一帧**
//     （m_lastPostedColorBuffer），按请求缩放后写 PPM 文件；
//   - 后台线程 vmhost_gfx_screen_thread()：轮询 <frame_dir>/frame.request
//     （内容 "宽 高"），有请求就截图写 frame.ppm（临时文件 + rename 原子替换），
//     自增写 frame.seq，再删掉请求文件。App 侧写请求 → 轮询 seq 变化 → 读
//     frame.ppm 即得当前画面。
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
#include <sys/stat.h>
#include <unistd.h>
#include <vector>
#include <mutex>
#include <dlfcn.h>

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

// 屏幕尺寸只用于初始化时上报给 guest 的显示驱动，真正的分辨率由 guest 侧
// 的 SurfaceFlinger/display 决定；这里给一个常见值即可。
#define VMHOST_GFX_DISPLAY_WIDTH 1080
#define VMHOST_GFX_DISPLAY_HEIGHT 1920
#define VMHOST_GFX_GUEST_API_LEVEL 28

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
    android_setOpenglesEmulation(sVmHostRenderLib, nullptr, nullptr);

    // 4. 启动渲染器
    int glesMajor = 0;
    int glesMinor = 0;
    int ret = android_startOpenglesRenderer(
            VMHOST_GFX_DISPLAY_WIDTH, VMHOST_GFX_DISPLAY_HEIGHT,
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
        {
            const gfxstream::RendererPtr& r = android_getOpenglesRenderer();
            r->setPostCallback(vmhost_gfx_on_post, nullptr, 0,
                               /*useBgraReadback*/ false);
            vmhost_gfx_log("已注册 post callback（displayId=0，直接抓帧）");
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
    {
        const char* fd = getenv("VMHOST_FRAME_DIR");
        if (fd != NULL && fd[0] != '\0') {
            snprintf(s_frame_dir, sizeof(s_frame_dir), "%s", fd);
            pthread_t tid;
            if (pthread_create(&tid, NULL, vmhost_gfx_screen_thread, NULL) == 0) {
                vmhost_gfx_log("截图回传线程已启动（frame_dir=%s）", s_frame_dir);
            } else {
                vmhost_gfx_log("截图回传线程启动失败");
            }
        }
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
// 注意 ydir=-1 表示 bottom-to-top（GL 约定），这里翻成 top-to-bottom 存。
static void vmhost_gfx_on_post(void* ctx, uint32_t displayId, int width, int height,
                               int ydir, int format, int type,
                               unsigned char* pixels) {
    (void)ctx;
    (void)format;
    (void)type;
    if (displayId != 0 || !pixels || width <= 0 || height <= 0) {
        return;
    }
    std::lock_guard<std::mutex> lk(s_latest_mutex);
    const size_t row = (size_t)width * 4u;
    const size_t need = row * (size_t)height;
    if (s_latest_pixels.size() != need) {
        s_latest_pixels.resize(need);
    }
    if (ydir < 0) {
        for (int y = 0; y < height; y++) {
            memcpy(s_latest_pixels.data() + (size_t)y * row,
                   pixels + (size_t)(height - 1 - y) * row, row);
        }
    } else {
        memcpy(s_latest_pixels.data(), pixels, need);
    }
    s_latest_w = width;
    s_latest_h = height;
    s_latest_seq++;
}

// 从 post callback 保存的最新帧写 PPM（RGBA -> P6 RGB，top-bottom）。
// 返回 0 成功；-1 还没有任何 post 帧。
static int vmhost_gfx_write_latest_ppm(const char* path) {
    std::lock_guard<std::mutex> lk(s_latest_mutex);
    if (s_latest_pixels.empty() || s_latest_w <= 0 || s_latest_h <= 0) {
        return -1;
    }
    char tmp[1024];
    if (snprintf(tmp, sizeof(tmp), "%s.tmp", path) >= (int)sizeof(tmp)) {
        return -1;
    }
    FILE* fp = fopen(tmp, "wb");
    if (fp == NULL) {
        return -1;
    }
    fprintf(fp, "P6\n%d %d\n255\n", s_latest_w, s_latest_h);
    /*
     * RGBA -> RGB 先在内存里打包，再一次 fwrite。
     * 原来逐像素 fputc，720x1280 一帧要 276 万次调用（+无缓冲 IO），
     * 单帧可达上百毫秒 —— 这条是截图线程的热路径。
     */
    {
        const size_t px = (size_t)s_latest_w * (size_t)s_latest_h;
        std::vector<uint8_t> rgb(px * 3u);
        for (size_t i = 0; i < px; i++) {
            rgb[i * 3u + 0] = s_latest_pixels[i * 4u + 0];
            rgb[i * 3u + 1] = s_latest_pixels[i * 4u + 1];
            rgb[i * 3u + 2] = s_latest_pixels[i * 4u + 2];
        }
        if (fwrite(rgb.data(), 1, rgb.size(), fp) != rgb.size()) {
            fclose(fp);
            unlink(tmp);
            return -1;
        }
    }
    fclose(fp);
    if (rename(tmp, path) != 0) {
        unlink(tmp);
        return -1;
    }
    vmhost_gfx_log("screenshot: post-callback %dx%d -> %s (seq=%llu)",
                   s_latest_w, s_latest_h, path, s_latest_seq);
    return 0;
}

extern "C" int vmhost_gfx_screenshot_to_file(const char* path, int max_w, int max_h) {
    if (path == NULL) {
        return -1;
    }
    /* D1f：优先用 post callback 抓到的最新帧（ASG 数据面也能拿）。
       拿到了就不再走 getScreenshot（它依赖 rcFBPost 更新的 m_lastPostedColorBuffer）。 */
    if (vmhost_gfx_write_latest_ppm(path) == 0) {
        return 0;
    }
    /* D14b：恢复 getScreenshot 兜底 —— 复核 gfxstream 源码后确认它是**线程安全**的。
     *
     * RendererImpl::getScreenshot → FrameBuffer::getScreenshot 会把回读命令
     * （PostCmd::Screenshot）经 sendPostWorkerCmd 投给 **post worker 线程**执行并等
     * future 完成，GL 命令并**不在调用线程上发**。之前把它当成"在 200ms 轮询线程上
     * 直接发 GL"而禁用（D14），是误判 —— 当时真正坏掉的是 MAKECURFIX/D16 造出来的
     * "没有 current context"状态。
     *
     * 它自身失败的真正原因是：displayId==0 时取 m_lastPostedColorBuffer，访客没有
     * post 过就没有可读的 CB，此时干净返回 -1（不会崩）。所以作为兜底是安全的：
     * 有 post 帧时优先用 post callback（不缩放），没有时按请求尺寸回读一次。
     */
    if (max_w > 0 || max_h > 0) {
        vmhost_gfx_log("screenshot: 无 post-callback 帧，走 getScreenshot 兜底（不做缩放）");
    }
    const gfxstream::RendererPtr& renderer = android_getOpenglesRenderer();
    if (!renderer) {
        vmhost_gfx_log("screenshot: renderer 未就绪");
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
        vmhost_gfx_log("screenshot: 尺寸探测失败 res=%d cap=%zu %ux%u", res, cap, w, h);
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
    // getScreenshot(format=3) 给的是 RGBA8888，每像素 4 字节；而 P6 每像素 3 字节。
    const size_t px = (size_t)w * (size_t)h;
    if (cap < px * 4u) {
        vmhost_gfx_log("screenshot: 缓冲不足 cap=%zu 需要=%zu", cap, px * 4u);
        return -1;
    }
    // 先写临时文件再 rename，保证 App 侧永远读不到半帧。
    char tmp[1024];
    if (snprintf(tmp, sizeof(tmp), "%s.tmp", path) >= (int)sizeof(tmp)) {
        return -1;
    }
    FILE* fp = fopen(tmp, "wb");
    if (fp == NULL) {
        vmhost_gfx_log("screenshot: 无法写 %s", tmp);
        return -1;
    }
    fprintf(fp, "P6\n%u %u\n255\n", w, h);
    // 必须把 RGBA 拆成 RGB 写入：直接 fwrite 4 字节/像素会让 P6 数据整体错位。
    size_t written = 0;
    for (size_t i = 0; i < px; i++) {
        const uint8_t* s = pixels.data() + i * 4u;
        if (fputc(s[0], fp) == EOF || fputc(s[1], fp) == EOF || fputc(s[2], fp) == EOF) {
            break;
        }
        written += 3;
    }
    fclose(fp);
    if (written != px * 3u) {
        vmhost_gfx_log("screenshot: 写入不完整 %zu/%zu", written, px * 3u);
        remove(tmp);
        return -1;
    }
    if (rename(tmp, path) != 0) {
        vmhost_gfx_log("screenshot: rename 失败 %s", tmp);
        remove(tmp);
        return -1;
    }
    return 0;
}

// 后台线程：轮询 <frame_dir>/frame.request（内容 "宽 高"，可缺省）。
// 有请求 → 截图写 frame.ppm + frame.seq（自增）→ 删请求文件。
// 200ms 一轮；QEMU 子进程被 SIGTERM 杀掉时线程自然消亡，无需清理。
static void* vmhost_gfx_screen_thread(void* arg) {
    (void)arg;
    unsigned long long seq = 0;
    char req[1024], ppm[1024], seqp[1024];
    for (;;) {
        if (snprintf(req, sizeof(req), "%s/frame.request", s_frame_dir) >=
            (int)sizeof(req)) {
            usleep(200 * 1000);
            continue;
        }
        FILE* fp = fopen(req, "rb");
        if (fp != NULL) {
            char buf[64];
            size_t n = fread(buf, 1, sizeof(buf) - 1, fp);
            fclose(fp);
            buf[n] = '\0';
            int max_w = 0, max_h = 0;
            if (sscanf(buf, "%d %d", &max_w, &max_h) < 2) {
                max_w = 0;
                max_h = 0;
            }
            if (snprintf(ppm, sizeof(ppm), "%s/frame.ppm", s_frame_dir) >=
                    (int)sizeof(ppm) ||
                vmhost_gfx_screenshot_to_file(ppm, max_w, max_h) == 0) {
                if (snprintf(seqp, sizeof(seqp), "%s/frame.seq", s_frame_dir) <
                    (int)sizeof(seqp)) {
                    seq++;
                    FILE* sq = fopen(seqp, "wb");
                    if (sq != NULL) {
                        fprintf(sq, "%llu\n", seq);
                        fclose(sq);
                    }
                }
            }
            unlink(req);
        }
        usleep(200 * 1000);
    }
    return NULL;
}
