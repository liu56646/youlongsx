// Android device regression: compile with NDK clang++, -lEGL -lGLESv3.
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <cstdio>
#include <cstring>
#include "../scripts/qemu_patches/vmhost_snapshot_texture.h"

struct NativeGL {
#define FN(name) decltype(&::name) name = ::name
    FN(glGetIntegerv); FN(glGetBooleanv); FN(glActiveTexture); FN(glGetError); FN(glPixelStorei);
    FN(glBindTexture); FN(glGetTexParameteriv); FN(glBindSampler);
    FN(glTexParameteri); FN(glIsEnabled); FN(glDisable); FN(glEnable);
    FN(glColorMask); FN(glCreateShader); FN(glShaderSource);
    FN(glCompileShader); FN(glGetShaderiv); FN(glCreateProgram);
    FN(glAttachShader); FN(glLinkProgram); FN(glGetProgramiv);
    FN(glGenTextures); FN(glTexImage2D); FN(glGenFramebuffers);
    FN(glBindFramebuffer); FN(glFramebufferTexture2D);
    FN(glCheckFramebufferStatus); FN(glGenVertexArrays);
    FN(glBindVertexArray); FN(glUseProgram); FN(glUniform1i);
    FN(glGetUniformLocation); FN(glViewport); FN(glDrawArrays);
    FN(glReadPixels); FN(glBindBuffer); FN(glDeleteVertexArrays);
    FN(glDeleteFramebuffers); FN(glDeleteTextures);
    FN(glDeleteProgram); FN(glDeleteShader);
#undef FN
};

int main() {
    EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (!eglInitialize(display, nullptr, nullptr)) return 2;
    const EGLint attrs[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
    EGLConfig config;
    EGLint count;
    if (!eglChooseConfig(display, attrs, &config, 1, &count) || !count) return 3;
    const EGLint surfaceAttrs[] = {EGL_WIDTH, 4, EGL_HEIGHT, 4, EGL_NONE};
    const EGLint contextAttrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    EGLSurface surface = eglCreatePbufferSurface(display, config, surfaceAttrs);
    EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttrs);
    if (!eglMakeCurrent(display, surface, surface, context)) return 4;
    NativeGL gl;
    int failures = 0;
    // Width 7 catches accidental row padding; distinct bytes catch component,
    // orientation, filtering and sampling errors instead of just nonzero output.
    for (GLenum format : {GL_ALPHA, GL_LUMINANCE, GL_LUMINANCE_ALPHA}) {
        const int channels = format == GL_LUMINANCE_ALPHA ? 2 : 1;
        uint8_t input[7 * 5 * 2], output[sizeof(input)] = {};
        const size_t bytes = 7 * 5 * channels;
        for (size_t i = 0; i < bytes; ++i) input[i] = (i * 37 + 19) & 255;
        GLuint texture;
        glGenTextures(1, &texture);
        glBindTexture(GL_TEXTURE_2D, texture);
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        glPixelStorei(GL_PACK_ALIGNMENT, 1);
        glTexImage2D(GL_TEXTURE_2D, 0, format, 7, 5, 0, format, GL_UNSIGNED_BYTE, input);
        GLuint buffer;
        glGenBuffers(1, &buffer);
        glBindBuffer(GL_PIXEL_PACK_BUFFER, buffer);
        glBufferData(GL_PIXEL_PACK_BUFFER, 1, nullptr, GL_STATIC_DRAW);
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, buffer);
        glPixelStorei(GL_PACK_ALIGNMENT, 8);
        glPixelStorei(GL_PACK_ROW_LENGTH, 13);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_A, GL_ONE);
        glEnable(GL_SCISSOR_TEST);
        glScissor(0, 0, 1, 1);
        glColorMask(GL_FALSE, GL_TRUE, GL_FALSE, GL_FALSE);
        bool ok = vmhostReadLegacyTexture(gl, texture, format, 7, 5, output);
        GLenum error = glGetError();
        GLboolean mask[4];
        glGetBooleanv(GL_COLOR_WRITEMASK, mask);
        GLint packBuffer, alignment, rowLength, swizzle;
        glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &packBuffer);
        glGetIntegerv(GL_PACK_ALIGNMENT, &alignment);
        glGetIntegerv(GL_PACK_ROW_LENGTH, &rowLength);
        glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_A, &swizzle);
        ok = ok && error == GL_NO_ERROR && !memcmp(input, output, bytes) &&
             glIsEnabled(GL_SCISSOR_TEST) && !mask[0] && mask[1] && !mask[2] && !mask[3] &&
             packBuffer == static_cast<GLint>(buffer) && alignment == 8 &&
             rowLength == 13 && swizzle == GL_ONE;
        printf("format=0x%x bytes=%zu error=0x%x %s\n", format, bytes, error, ok ? "PASS" : "FAIL");
        if (!ok) ++failures;
        glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
        glDeleteBuffers(1, &buffer);
        glPixelStorei(GL_PACK_ROW_LENGTH, 0);
        glDeleteTextures(1, &texture);
    }
    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(display, context);
    eglDestroySurface(display, surface);
    eglTerminate(display);
    return failures ? 1 : 0;
}
