#include "vm_render.h"
#include "vm_guest_display.h"

#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <android/log.h>

#define TAG "VmRender"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

static EGLDisplay s_display = EGL_NO_DISPLAY;
static EGLSurface s_surface = EGL_NO_SURFACE;
static EGLContext s_context = EGL_NO_CONTEXT;
static int s_width = 0;
static int s_height = 0;
static int s_frame = 0;

/* 当前画面上屏时的等比缩放系数，触摸回传需要用它做逆变换 */
static float s_scale_x = 1.0f;
static float s_scale_y = 1.0f;

/* 用来把访客纹理贴到屏幕上的四边形 */
static GLuint s_program = 0;
static GLuint s_vbo = 0;
static GLint  s_attr_pos = -1;
static GLint  s_attr_uv = -1;
static GLint  s_uniform_tex = -1;

static const EGLint kConfigAttrs[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_NONE
};

static const EGLint kContextAttrs[] = {
        EGL_CONTEXT_CLIENT_VERSION, 2,
        EGL_NONE
};

static const char *kVertexShader =
        "attribute vec2 aPos;\n"
        "attribute vec2 aUV;\n"
        "varying vec2 vUV;\n"
        "void main() {\n"
        "    vUV = aUV;\n"
        "    gl_Position = vec4(aPos, 0.0, 1.0);\n"
        "}\n";

static const char *kFragmentShader =
        "precision mediump float;\n"
        "varying vec2 vUV;\n"
        "uniform sampler2D uTex;\n"
        "void main() {\n"
        "    gl_FragColor = texture2D(uTex, vUV);\n"
        "}\n";

static GLuint compile_shader(GLenum type, const char *source)
{
    GLuint shader = glCreateShader(type);
    if (shader == 0) {
        return 0;
    }
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);

    GLint ok = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (ok != GL_TRUE) {
        GLint log_len = 0;
        glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &log_len);
        if (log_len > 1) {
            char *log = (char *) __builtin_alloca((size_t) log_len);
            glGetShaderInfoLog(shader, log_len, NULL, log);
            LOGE("着色器编译失败：%s", log);
        }
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

static bool init_quad(void)
{
    GLuint vs = compile_shader(GL_VERTEX_SHADER, kVertexShader);
    GLuint fs = compile_shader(GL_FRAGMENT_SHADER, kFragmentShader);
    if (vs == 0 || fs == 0) {
        return false;
    }

    s_program = glCreateProgram();
    glAttachShader(s_program, vs);
    glAttachShader(s_program, fs);
    glLinkProgram(s_program);

    GLint linked = GL_FALSE;
    glGetProgramiv(s_program, GL_LINK_STATUS, &linked);
    if (linked != GL_TRUE) {
        LOGE("着色器程序链接失败");
        s_program = 0;
    }

    glDeleteShader(vs);
    glDeleteShader(fs);
    if (s_program == 0) {
        return false;
    }

    s_attr_pos = glGetAttribLocation(s_program, "aPos");
    s_attr_uv = glGetAttribLocation(s_program, "aUV");
    s_uniform_tex = glGetUniformLocation(s_program, "uTex");

    glGenBuffers(1, &s_vbo);
    return true;
}

int vm_render_init(ANativeWindow* window)
{
    if (window == NULL) {
        LOGE("init: null window");
        return -1;
    }

    s_display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (s_display == EGL_NO_DISPLAY) {
        LOGE("init: no display");
        return -1;
    }

    if (!eglInitialize(s_display, NULL, NULL)) {
        LOGE("init: eglInitialize failed");
        s_display = EGL_NO_DISPLAY;
        return -1;
    }

    EGLConfig config;
    EGLint numConfigs = 0;
    if (!eglChooseConfig(s_display, kConfigAttrs, &config, 1, &numConfigs) || numConfigs < 1) {
        LOGE("init: no suitable EGLConfig");
        return -1;
    }

    s_surface = eglCreateWindowSurface(s_display, config, window, NULL);
    if (s_surface == EGL_NO_SURFACE) {
        LOGE("init: eglCreateWindowSurface failed");
        return -1;
    }

    s_context = eglCreateContext(s_display, config, EGL_NO_CONTEXT, kContextAttrs);
    if (s_context == EGL_NO_CONTEXT) {
        LOGE("init: eglCreateContext failed");
        return -1;
    }

    if (!eglMakeCurrent(s_display, s_surface, s_surface, s_context)) {
        LOGE("init: eglMakeCurrent failed");
        return -1;
    }

    eglQuerySurface(s_display, s_surface, EGL_WIDTH, &s_width);
    eglQuerySurface(s_display, s_surface, EGL_HEIGHT, &s_height);

    if (!init_quad()) {
        LOGE("init: 四边形着色器初始化失败");
    }
    vm_guest_display_init();

    LOGI("init ok, surface = %dx%d, gl = %s", s_width, s_height, glGetString(GL_VERSION));
    return 0;
}

void vm_render_resize(int width, int height)
{
    s_width = width;
    s_height = height;
}

bool vm_render_map_to_guest(int px, int py, int *guest_x, int *guest_y)
{
    if (guest_x == NULL || guest_y == NULL) {
        return false;
    }
    if (s_width <= 0 || s_height <= 0) {
        return false;
    }

    const int gw = vm_guest_display_width();
    const int gh = vm_guest_display_height();
    if (gw <= 0 || gh <= 0) {
        return false;
    }

    /* 屏幕像素 → NDC（y 轴翻转：屏幕向下为 +y，NDC 向上为 +y） */
    const float ndc_x = 2.0f * (float) px / (float) s_width - 1.0f;
    const float ndc_y = 1.0f - 2.0f * (float) py / (float) s_height;

    /* NDC → 四边形局部 uv（抵消 letterbox 缩放） */
    float u = (ndc_x / (s_scale_x > 0.0f ? s_scale_x : 1.0f) + 1.0f) * 0.5f;
    float v = (1.0f - ndc_y / (s_scale_y > 0.0f ? s_scale_y : 1.0f)) * 0.5f;

    /* 落在黑边上的点夹到边界，避免丢掉边缘触摸 */
    if (u < 0.0f) { u = 0.0f; } else if (u > 1.0f) { u = 1.0f; }
    if (v < 0.0f) { v = 0.0f; } else if (v > 1.0f) { v = 1.0f; }

    *guest_x = (int) (u * (float) gw);
    *guest_y = (int) (v * (float) gh);
    if (*guest_x >= gw) { *guest_x = gw - 1; }
    if (*guest_y >= gh) { *guest_y = gh - 1; }
    return true;
}

void vm_render_frame(void)
{
    if (s_display == EGL_NO_DISPLAY || s_surface == EGL_NO_SURFACE) {
        return;
    }

    glViewport(0, 0, s_width, s_height);

    vm_guest_display_poll();

    const GLuint tex = vm_guest_display_texture();
    const int gw = vm_guest_display_width();
    const int gh = vm_guest_display_height();

    if (tex != 0 && gw > 0 && gh > 0 && s_program != 0 && s_height > 0 && s_width > 0) {
        /* 等比缩放 + 黑边（letterbox），避免访客画面被拉伸变形 */
        const float screen_aspect = (float) s_width / (float) s_height;
        const float guest_aspect = (float) gw / (float) gh;
        float sx = 1.0f;
        float sy = 1.0f;
        if (guest_aspect > screen_aspect) {
            sy = screen_aspect / guest_aspect;
        } else {
            sx = guest_aspect / screen_aspect;
        }
        s_scale_x = sx;
        s_scale_y = sy;

        glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);

        const GLfloat verts[16] = {
                /* x,   y,   u,   v   —— 顺序：左下、右下、左上、右上 */
                -sx, -sy, 0.0f, 1.0f,
                 sx, -sy, 1.0f, 1.0f,
                -sx,  sy, 0.0f, 0.0f,
                 sx,  sy, 1.0f, 0.0f,
        };

        glUseProgram(s_program);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, tex);
        glUniform1i(s_uniform_tex, 0);

        glBindBuffer(GL_ARRAY_BUFFER, s_vbo);
        glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_DYNAMIC_DRAW);

        glEnableVertexAttribArray((GLuint) s_attr_pos);
        glVertexAttribPointer((GLuint) s_attr_pos, 2, GL_FLOAT, GL_FALSE,
                              4 * sizeof(GLfloat), (const void *) 0);
        glEnableVertexAttribArray((GLuint) s_attr_uv);
        glVertexAttribPointer((GLuint) s_attr_uv, 2, GL_FLOAT, GL_FALSE,
                              4 * sizeof(GLfloat), (const void *) (2 * sizeof(GLfloat)));

        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

        glDisableVertexAttribArray((GLuint) s_attr_pos);
        glDisableVertexAttribArray((GLuint) s_attr_uv);
    } else {
        /* 还没拿到访客画面：用渐变底色表示引擎活着 */
        s_frame = (s_frame + 1) % 600;
        const float t = (float) s_frame / 600.0f;
        glClearColor(0.05f, 0.07f + 0.20f * t, 0.10f + 0.28f * t, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
    }

    eglSwapBuffers(s_display, s_surface);
}

void vm_render_destroy(void)
{
    /* 先销毁 GL 资源（此时上下文仍然有效），再拆 EGL */
    vm_guest_display_destroy();
    if (s_vbo != 0) {
        glDeleteBuffers(1, &s_vbo);
        s_vbo = 0;
    }
    if (s_program != 0) {
        glDeleteProgram(s_program);
        s_program = 0;
    }

    if (s_display != EGL_NO_DISPLAY) {
        eglMakeCurrent(s_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (s_context != EGL_NO_CONTEXT) {
            eglDestroyContext(s_display, s_context);
        }
        if (s_surface != EGL_NO_SURFACE) {
            eglDestroySurface(s_display, s_surface);
        }
        eglTerminate(s_display);
    }
    s_display = EGL_NO_DISPLAY;
    s_surface = EGL_NO_SURFACE;
    s_context = EGL_NO_CONTEXT;
    s_width = 0;
    s_height = 0;
}
