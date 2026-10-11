// PTGLESCompat.cpp — équivalents OpenGL ES 3.0 des fonctions OpenGL « ordinateur » de melonDS (PlayTendo).
// Voir PTGLESCompat.h. Ce fichier appelle les vraies fonctions d'OpenGL ES : il n'inclut pas PlatformOGLPrivate.h,
// dont les macros renvoient vers les fonctions ci-dessous.
// Sur Mac, melonDS garde son rendu OpenGL d'origine : ce fichier y est vide.

#include <TargetConditionals.h>
#if TARGET_OS_IOS

#include <OpenGLES/ES3/gl.h>
#include <OpenGLES/ES3/glext.h>

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

#include "Platform.h"

namespace
{

constexpr int kMaxBuffers = 8;

/// Masque voulu par melonDS pour chaque image de sortie (glColorMaski) : appliqué avant chaque dessin.
GLboolean g_masks[kMaxBuffers][4] = {
    {GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE}, {GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE},
    {GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE}, {GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE},
    {GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE}, {GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE},
    {GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE}, {GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE},
};

/// Images de sortie d'un framebuffer : celles que melonDS a choisies (glDrawBuffers) et celles réellement données à
/// OpenGL ES (les images entièrement masquées en moins).
struct FramebufferBuffers
{
    std::vector<GLenum> intended{GL_COLOR_ATTACHMENT0};
    std::vector<GLenum> applied{GL_COLOR_ATTACHMENT0};
};

std::unordered_map<GLuint, FramebufferBuffers> g_framebuffers;
bool g_warnedMixedMasks = false;

GLuint CurrentDrawFramebuffer()
{
    GLint framebuffer = 0;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &framebuffer);
    return static_cast<GLuint>(framebuffer);
}

bool Masked(const GLboolean* mask)
{
    return !mask[0] && !mask[1] && !mask[2] && !mask[3];
}

/// OpenGL ES 3.0 n'a qu'un masque de couleur pour toutes les images de sortie. Une image entièrement masquée est
/// retirée de la liste des sorties ; les autres partagent un masque commun. Deux masques partiels différents (rare :
/// drapeau de brouillard sans brouillard, fenêtre des sprites) sont réunis.
void ApplyMasks()
{
    const GLuint framebuffer = CurrentDrawFramebuffer();
    GLboolean global[4] = {GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE};
    if (framebuffer == 0)
    {
        std::memcpy(global, g_masks[0], sizeof global);
    }
    else
    {
        FramebufferBuffers& buffers = g_framebuffers[framebuffer];
        std::vector<GLenum> wanted = buffers.intended;
        const GLboolean* first = nullptr;
        bool mixed = false;
        int enabled = 0;
        for (size_t i = 0; i < wanted.size() && i < kMaxBuffers; i++)
        {
            if (wanted[i] == GL_NONE)
                continue;
            if (Masked(g_masks[i]))
            {
                wanted[i] = GL_NONE;
                continue;
            }
            if (first && std::memcmp(first, g_masks[i], 4 * sizeof(GLboolean)) != 0)
                mixed = true;
            if (!first)
                first = g_masks[i];
            for (int c = 0; c < 4; c++)
                global[c] = global[c] || g_masks[i][c];
            enabled++;
        }
        // Tout est masqué : la liste reste celle de melonDS, le masque commun suffit (rien n'est écrit).
        if (enabled == 0)
            wanted = buffers.intended;
        if (mixed && !g_warnedMixedMasks)
        {
            g_warnedMixedMasks = true;
            melonDS::Platform::Log(melonDS::Platform::LogLevel::Warn,
                                   "[PlayTendo] OpenGL ES : masques de couleur differents reunis\n");
        }
        if (wanted != buffers.applied)
        {
            glDrawBuffers(static_cast<GLsizei>(wanted.size()), wanted.data());
            buffers.applied = wanted;
        }
    }
    glColorMask(global[0], global[1], global[2], global[3]);
}

/// Pixel 1-5-5-5 inversé de la DS (rouge dans les bits 0-4, alpha dans le bit 15) → RGBA 8 bits.
std::vector<uint8_t> ToRGBA8(const void* pixels, size_t count)
{
    const uint16_t* source = static_cast<const uint16_t*>(pixels);
    std::vector<uint8_t> out(count * 4);
    for (size_t i = 0; i < count; i++)
    {
        const uint16_t value = source[i];
        const uint8_t r = value & 0x1F, g = (value >> 5) & 0x1F, b = (value >> 10) & 0x1F;
        out[i * 4 + 0] = static_cast<uint8_t>((r << 3) | (r >> 2));
        out[i * 4 + 1] = static_cast<uint8_t>((g << 3) | (g >> 2));
        out[i * 4 + 2] = static_cast<uint8_t>((b << 3) | (b >> 2));
        out[i * 4 + 3] = (value & 0x8000) ? 0xFF : 0x00;
    }
    return out;
}

// Diagnostic (essai DS, seulement avec -DPT_GLES_DIAGNOSTIC) : premières erreurs d'OpenGL ES après un appel,
// framebuffers incomplets.
int g_loggedErrors = 0;
std::unordered_map<GLuint, bool> g_checkedFramebuffers;

void CheckAfter(const char* what)
{
#ifndef PT_GLES_DIAGNOSTIC
    (void)what;
    return;
#endif
    const GLenum error = glGetError();
    if (error != GL_NO_ERROR && g_loggedErrors < 40)
    {
        g_loggedErrors++;
        GLint program = 0, framebuffer = 0;
        glGetIntegerv(GL_CURRENT_PROGRAM, &program);
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &framebuffer);
        melonDS::Platform::Log(melonDS::Platform::LogLevel::Warn,
                               "[PlayTendo] GLES erreur 0x%x apres %s (programme %d, framebuffer %d)\n",
                               error, what, program, framebuffer);
    }
}

void CheckFramebuffer()
{
#ifndef PT_GLES_DIAGNOSTIC
    return;
#endif
    GLint framebuffer = 0;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &framebuffer);
    if (framebuffer == 0 || g_checkedFramebuffers.count(framebuffer))
        return;
    g_checkedFramebuffers[framebuffer] = true;
    const GLenum status = glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE)
        melonDS::Platform::Log(melonDS::Platform::LogLevel::Warn,
                               "[PlayTendo] GLES framebuffer %d incomplet (0x%x)\n", framebuffer, status);
}

GLuint MapBinding(GLuint binding)
{
    switch (binding)
    {
    case 20: return 1;
    case 21: return 2;
    case 22: return 3;
    case 23: return 4;
    case 24: return 5;
    case 25: return 6;
    case 30: return 7;
    case 31: return 8;
    default: return binding;
    }
}

uint16_t To5(uint8_t value)
{
    return static_cast<uint16_t>((value * 31 + 127) / 255);
}

}

extern "C" {

void ptgl_ColorMaski(GLuint buf, GLboolean r, GLboolean g, GLboolean b, GLboolean a)
{
    if (buf >= kMaxBuffers)
        return;
    g_masks[buf][0] = r;
    g_masks[buf][1] = g;
    g_masks[buf][2] = b;
    g_masks[buf][3] = a;
}

void ptgl_ColorMask(GLboolean r, GLboolean g, GLboolean b, GLboolean a)
{
    for (int i = 0; i < kMaxBuffers; i++)
        ptgl_ColorMaski(i, r, g, b, a);
    glColorMask(r, g, b, a);
}

void ptgl_DrawBuffers(GLsizei n, const GLenum* bufs)
{
    const GLuint framebuffer = CurrentDrawFramebuffer();
    glDrawBuffers(n, bufs);
    if (framebuffer != 0)
    {
        FramebufferBuffers& buffers = g_framebuffers[framebuffer];
        buffers.intended.assign(bufs, bufs + n);
        buffers.applied = buffers.intended;
    }
}

void ptgl_DrawBuffer(GLenum buf)
{
    ptgl_DrawBuffers(1, &buf);
}

void ptgl_DeleteFramebuffers(GLsizei n, const GLuint* framebuffers)
{
    for (GLsizei i = 0; i < n; i++)
        g_framebuffers.erase(framebuffers[i]);
    glDeleteFramebuffers(n, framebuffers);
}

void ptgl_DrawArrays(GLenum mode, GLint first, GLsizei count)
{
    ApplyMasks();
    CheckFramebuffer();
    glDrawArrays(mode, first, count);
    CheckAfter("glDrawArrays");
}

void ptgl_DrawElements(GLenum mode, GLsizei count, GLenum type, const void* indices)
{
    ApplyMasks();
    CheckFramebuffer();
    glDrawElements(mode, count, type, indices);
    CheckAfter("glDrawElements");
}

void ptgl_Clear(GLbitfield mask)
{
    ApplyMasks();
    CheckFramebuffer();
    glClear(mask);
    CheckAfter("glClear");
}

/// OpenGL ES 3.0 attache une image 2D ou une couche d'un tableau d'images, pas « une texture » quelconque.
void ptgl_FramebufferTexture(GLenum target, GLenum attachment, GLuint texture, GLint level)
{
    while (glGetError() != GL_NO_ERROR) {}
    glFramebufferTexture2D(target, attachment, GL_TEXTURE_2D, texture, level);
    if (texture != 0 && glGetError() != GL_NO_ERROR)
        glFramebufferTextureLayer(target, attachment, texture, level, 0);
}

void* ptgl_MapBuffer(GLenum target, GLenum access)
{
    GLint size = 0;
    glGetBufferParameteriv(target, GL_BUFFER_SIZE, &size);
    const GLbitfield bits = access == 0x88B8 /* GL_READ_ONLY */ ? GL_MAP_READ_BIT
                                                                 : (GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
    return glMapBufferRange(target, 0, size, bits);
}

void ptgl_TexImage2D(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLint border,
                     GLenum format, GLenum type, const void* pixels)
{
    if (type == 0x8366 /* GL_UNSIGNED_SHORT_1_5_5_5_REV */)
    {
        std::vector<uint8_t> converted;
        if (pixels)
            converted = ToRGBA8(pixels, static_cast<size_t>(width) * height);
        glTexImage2D(target, level, internalformat, width, height, border, GL_RGBA, GL_UNSIGNED_BYTE,
                     pixels ? converted.data() : nullptr);
        return;
    }
    glTexImage2D(target, level, internalformat, width, height, border, format, type, pixels);
    CheckAfter("glTexImage2D");
}

void ptgl_TexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height,
                        GLenum format, GLenum type, const void* pixels)
{
    if (type == 0x8366 && pixels)
    {
        std::vector<uint8_t> converted = ToRGBA8(pixels, static_cast<size_t>(width) * height);
        glTexSubImage2D(target, level, xoffset, yoffset, width, height, GL_RGBA, GL_UNSIGNED_BYTE, converted.data());
        return;
    }
    glTexSubImage2D(target, level, xoffset, yoffset, width, height, format, type, pixels);
    CheckAfter("glTexSubImage2D");
}

void ptgl_TexImage3D(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLsizei depth,
                     GLint border, GLenum format, GLenum type, const void* pixels)
{
    if (type == 0x8366)
    {
        std::vector<uint8_t> converted;
        if (pixels)
            converted = ToRGBA8(pixels, static_cast<size_t>(width) * height * depth);
        glTexImage3D(target, level, internalformat, width, height, depth, border, GL_RGBA, GL_UNSIGNED_BYTE,
                     pixels ? converted.data() : nullptr);
        return;
    }
    glTexImage3D(target, level, internalformat, width, height, depth, border, format, type, pixels);
    CheckAfter("glTexImage3D");
}

void ptgl_TexSubImage3D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width,
                        GLsizei height, GLsizei depth, GLenum format, GLenum type, const void* pixels)
{
    if (type == 0x8366 && pixels)
    {
        std::vector<uint8_t> converted = ToRGBA8(pixels, static_cast<size_t>(width) * height * depth);
        glTexSubImage3D(target, level, xoffset, yoffset, zoffset, width, height, depth, GL_RGBA, GL_UNSIGNED_BYTE,
                        converted.data());
        return;
    }
    glTexSubImage3D(target, level, xoffset, yoffset, zoffset, width, height, depth, format, type, pixels);
    CheckAfter("glTexSubImage3D");
}

/// Relecture d'une image en 1-5-5-5 inversé (capture d'écran de la DS vers sa mémoire vidéo) : lue en RGBA 8 bits,
/// puis convertie.
void ptgl_ReadPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, void* pixels)
{
    if (type == 0x8366 && format == GL_RGBA)
    {
        const size_t count = static_cast<size_t>(width) * height;
        std::vector<uint8_t> rgba(count * 4);
        glReadPixels(x, y, width, height, GL_RGBA, GL_UNSIGNED_BYTE, rgba.data());
        uint16_t* out = static_cast<uint16_t*>(pixels);
        for (size_t i = 0; i < count; i++)
        {
            const uint8_t* p = &rgba[i * 4];
            out[i] = static_cast<uint16_t>(To5(p[0]) | (To5(p[1]) << 5) | (To5(p[2]) << 10) | (p[3] >= 128 ? 0x8000 : 0));
        }
        return;
    }
    glReadPixels(x, y, width, height, format, type, pixels);
    CheckAfter("glReadPixels");
}

void ptgl_Check(const char* call)
{
    CheckAfter(call);
}

void ptgl_UniformBlockBinding(GLuint program, GLuint uniformBlockIndex, GLuint uniformBlockBinding)
{
    glUniformBlockBinding(program, uniformBlockIndex, MapBinding(uniformBlockBinding));
}

void ptgl_BindBufferBase(GLenum target, GLuint index, GLuint buffer)
{
    glBindBufferBase(target, target == GL_UNIFORM_BUFFER ? MapBinding(index) : index, buffer);
}

void ptgl_BindBufferRange(GLenum target, GLuint index, GLuint buffer, GLintptr offset, GLsizeiptr size)
{
    glBindBufferRange(target, target == GL_UNIFORM_BUFFER ? MapBinding(index) : index, buffer, offset, size);
}

char* ptgl_AdaptShaderSource(const char* source)
{
    static const char* header =
        "#version 300 es\n"
        "precision highp float;\n"
        "precision highp int;\n"
        "precision highp sampler2D;\n"
        "precision highp sampler3D;\n"
        "precision highp sampler2DArray;\n"
        "precision highp isampler2D;\n"
        "precision highp usampler2D;\n"
        "precision highp isampler2DArray;\n"
        "precision highp usampler2DArray;\n";
    std::string text(source ? source : "");
    const size_t version = text.find("#version");
    if (version != std::string::npos)
    {
        const size_t end = text.find('\n', version);
        text.replace(version, end == std::string::npos ? std::string::npos : end - version + 1, header);
    }
    else
    {
        text.insert(0, header);
    }
    // Le compilateur OpenGL ES d'Apple refuse le mot « smooth » (l'interpolation par défaut, de toute façon).
    for (const char* qualifier : {"smooth in ", "smooth out "})
    {
        const std::string pattern(qualifier);
        const std::string replacement = pattern.substr(7);
        for (size_t at = text.find(pattern); at != std::string::npos; at = text.find(pattern, at))
            text.replace(at, pattern.size(), replacement);
    }
    return strdup(text.c_str());
}

}

#endif // TARGET_OS_IOS
