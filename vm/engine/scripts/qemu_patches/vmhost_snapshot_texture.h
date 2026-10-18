// GLES has no glGetTexImage, and legacy A/L/LA textures are not framebuffer
// attachments. Sample them into RGBA before reading their original components.
#pragma once

#include <cstdint>
#include <vector>

template <class GL>
static bool vmhostReadLegacyTexture(GL& gl, GLuint source, GLenum format,
                                    GLint width, GLint height, uint8_t* data) {
    GLint program, arrayBuffer, activeTexture, texture, readFbo, drawFbo;
    GLint viewport[4], minFilter, magFilter;
    GLboolean colorMask[4];
    gl.glGetIntegerv(GL_CURRENT_PROGRAM, &program);
    gl.glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &arrayBuffer);
    gl.glGetIntegerv(GL_ACTIVE_TEXTURE, &activeTexture);
    gl.glGetIntegerv(GL_VIEWPORT, viewport);
    gl.glGetBooleanv(GL_COLOR_WRITEMASK, colorMask);
    // The Android backend uses an ES3 context (also for ES2 guests).
    gl.glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &readFbo);
    gl.glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &drawFbo);
    GLint vao;
    gl.glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &vao);
    GLint packBuffer, unpackBuffer;
    gl.glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &packBuffer);
    gl.glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &unpackBuffer);
    gl.glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    gl.glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    const GLenum packParams[] = {GL_PACK_ALIGNMENT, GL_PACK_ROW_LENGTH,
                                GL_PACK_SKIP_PIXELS, GL_PACK_SKIP_ROWS};
    GLint packValues[4];
    for (int i = 0; i < 4; ++i) {
        gl.glGetIntegerv(packParams[i], &packValues[i]);
        gl.glPixelStorei(packParams[i], i == 0 ? 1 : 0);
    }
    gl.glActiveTexture(GL_TEXTURE0);
    gl.glGetIntegerv(GL_TEXTURE_BINDING_2D, &texture);
    gl.glBindTexture(GL_TEXTURE_2D, source);
    gl.glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, &minFilter);
    gl.glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, &magFilter);
    GLint baseLevel, maxLevel, sampler;
    gl.glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_BASE_LEVEL, &baseLevel);
    gl.glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, &maxLevel);
    gl.glGetIntegerv(GL_SAMPLER_BINDING, &sampler);
    gl.glBindSampler(0, 0);
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_BASE_LEVEL, 0);
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
    const GLenum swizzleParams[] = {GL_TEXTURE_SWIZZLE_R, GL_TEXTURE_SWIZZLE_G,
                                   GL_TEXTURE_SWIZZLE_B, GL_TEXTURE_SWIZZLE_A};
    const GLint identitySwizzle[] = {GL_RED, GL_GREEN, GL_BLUE, GL_ALPHA};
    GLint swizzleValues[4];
    for (int i = 0; i < 4; ++i) {
        gl.glGetTexParameteriv(GL_TEXTURE_2D, swizzleParams[i], &swizzleValues[i]);
        gl.glTexParameteri(GL_TEXTURE_2D, swizzleParams[i], identitySwizzle[i]);
    }

    const GLenum caps[] = {GL_BLEND, GL_DEPTH_TEST, GL_STENCIL_TEST,
                          GL_SCISSOR_TEST, GL_CULL_FACE, GL_RASTERIZER_DISCARD};
    GLboolean enabled[6];
    for (int i = 0; i < 6; ++i) {
        enabled[i] = gl.glIsEnabled(caps[i]);
        gl.glDisable(caps[i]);
    }
    gl.glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);

    const char* vs = "#version 300 es\n"
        "out highp vec2 uv;void main(){"
        "vec2 p=vec2(float((gl_VertexID<<1)&2),float(gl_VertexID&2));"
        "uv=p;gl_Position=vec4(p*2.0-1.0,0.0,1.0);}";
    const char* fs = "#version 300 es\n"
        "precision highp float;in highp vec2 uv;uniform sampler2D image;"
        "out vec4 color;void main(){color=texture(image,uv);}";
    GLuint shaders[2] = {gl.glCreateShader(GL_VERTEX_SHADER),
                         gl.glCreateShader(GL_FRAGMENT_SHADER)};
    const char* sources[2] = {vs, fs};
    bool ok = true;
    for (int i = 0; i < 2; ++i) {
        gl.glShaderSource(shaders[i], 1, &sources[i], nullptr);
        gl.glCompileShader(shaders[i]);
        GLint status = 0;
        gl.glGetShaderiv(shaders[i], GL_COMPILE_STATUS, &status);
        ok = ok && status == GL_TRUE;
    }
    GLuint copyProgram = gl.glCreateProgram();
    for (GLuint shader : shaders) gl.glAttachShader(copyProgram, shader);
    gl.glLinkProgram(copyProgram);
    GLint linked = 0;
    gl.glGetProgramiv(copyProgram, GL_LINK_STATUS, &linked);
    ok = ok && linked == GL_TRUE;

    GLuint rgba, fbo, copyVao;
    gl.glGenTextures(1, &rgba);
    gl.glBindTexture(GL_TEXTURE_2D, rgba);
    gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0,
                    GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    gl.glGenFramebuffers(1, &fbo);
    gl.glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    gl.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                              GL_TEXTURE_2D, rgba, 0);
    ok = ok && gl.glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
    gl.glGenVertexArrays(1, &copyVao);
    gl.glBindVertexArray(copyVao);
    if (ok) {
        // This is the renderer's snapshot context, not a guest error queue.
        while (gl.glGetError() != GL_NO_ERROR) {}
        gl.glBindTexture(GL_TEXTURE_2D, source);
        gl.glUseProgram(copyProgram);
        gl.glUniform1i(gl.glGetUniformLocation(copyProgram, "image"), 0);
        gl.glViewport(0, 0, width, height);
        gl.glDrawArrays(GL_TRIANGLES, 0, 3);
        std::vector<uint8_t> pixels(static_cast<size_t>(width) * height * 4);
        gl.glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
        ok = gl.glGetError() == GL_NO_ERROR;
        const int channels = format == GL_LUMINANCE_ALPHA ? 2 : 1;
        for (size_t i = 0; i < pixels.size() / 4; ++i) {
            data[i * channels] = pixels[i * 4 + (format == GL_ALPHA ? 3 : 0)];
            if (channels == 2) data[i * 2 + 1] = pixels[i * 4 + 3];
        }
    }

    gl.glBindTexture(GL_TEXTURE_2D, source);
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, minFilter);
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, magFilter);
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_BASE_LEVEL, baseLevel);
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, maxLevel);
    for (int i = 0; i < 4; ++i) {
        gl.glTexParameteri(GL_TEXTURE_2D, swizzleParams[i], swizzleValues[i]);
        gl.glPixelStorei(packParams[i], packValues[i]);
    }
    gl.glBindBuffer(GL_PIXEL_PACK_BUFFER, packBuffer);
    gl.glBindBuffer(GL_PIXEL_UNPACK_BUFFER, unpackBuffer);
    gl.glBindTexture(GL_TEXTURE_2D, texture);
    gl.glBindSampler(0, sampler);
    gl.glActiveTexture(activeTexture);
    gl.glUseProgram(program);
    gl.glBindVertexArray(vao);
    gl.glBindBuffer(GL_ARRAY_BUFFER, arrayBuffer);
    gl.glBindFramebuffer(GL_READ_FRAMEBUFFER, readFbo);
    gl.glBindFramebuffer(GL_DRAW_FRAMEBUFFER, drawFbo);
    gl.glViewport(viewport[0], viewport[1], viewport[2], viewport[3]);
    gl.glColorMask(colorMask[0], colorMask[1], colorMask[2], colorMask[3]);
    for (int i = 0; i < 6; ++i) if (enabled[i]) gl.glEnable(caps[i]);
    gl.glDeleteVertexArrays(1, &copyVao);
    gl.glDeleteFramebuffers(1, &fbo);
    gl.glDeleteTextures(1, &rgba);
    gl.glDeleteProgram(copyProgram);
    for (GLuint shader : shaders) gl.glDeleteShader(shader);
    return ok;
}
