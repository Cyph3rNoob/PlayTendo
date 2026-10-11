// PTGLESCompat.h — rendu OpenGL de melonDS sur l'OpenGL ES 3.0 de l'iPhone (PlayTendo).
//
// melonDS dessine en OpenGL « ordinateur » (3.2) ; l'iPhone n'a qu'OpenGL ES 3.0. Cet en-tête, inclus à la fin de
// PlatformOGLPrivate.h de melonDS DS (scripts/patch_melonds.py), remplace les fonctions absentes d'OpenGL ES par des
// équivalents (PTGLESCompat.cpp) :
// - masques de couleur par image de sortie (glColorMaski) : rendus par la liste des images de sortie (glDrawBuffers)
//   et le masque commun (glColorMask), recalculés avant chaque dessin ;
// - images 1-5-5-5 inversées de la DS (envoi et relecture) : converties en RGBA 8 bits ;
// - glFramebufferTexture, glMapBuffer, glClearDepth, glDepthRange : leurs équivalents d'OpenGL ES ;
// - glBindFragDataLocation : remplacé par « layout(location = …) » dans les shaders (OpenGLSupport.cpp retouché).
#ifndef PT_GLES_COMPAT_H
#define PT_GLES_COMPAT_H

#define PT_GLES_COMPAT 1

#ifndef GL_UNSIGNED_SHORT_1_5_5_5_REV
#define GL_UNSIGNED_SHORT_1_5_5_5_REV 0x8366
#endif
// Pas de couleur de bord en OpenGL ES 3.0 : le bord de l'image est répété (fonds 2D qui ne se répètent pas).
#ifndef GL_CLAMP_TO_BORDER
#define GL_CLAMP_TO_BORDER GL_CLAMP_TO_EDGE
#endif
#ifndef GL_WRITE_ONLY
#define GL_WRITE_ONLY 0x88B9
#endif
// États de framebuffer d'OpenGL « ordinateur », cités par les messages d'erreur de melonDS DS.
#ifndef GL_FRAMEBUFFER_INCOMPLETE_DRAW_BUFFER
#define GL_FRAMEBUFFER_INCOMPLETE_DRAW_BUFFER 0x8CDB
#endif
#ifndef GL_FRAMEBUFFER_INCOMPLETE_READ_BUFFER
#define GL_FRAMEBUFFER_INCOMPLETE_READ_BUFFER 0x8CDC
#endif
#ifndef GL_FRAMEBUFFER_INCOMPLETE_LAYER_TARGETS
#define GL_FRAMEBUFFER_INCOMPLETE_LAYER_TARGETS 0x8DA8
#endif
// libretro-common renvoie GL_WRITE_ONLY vers l'extension GL_OES_mapbuffer, absente des en-têtes ES3 de l'iPhone.
#ifndef GL_WRITE_ONLY_OES
#define GL_WRITE_ONLY_OES 0x88B9
#endif

#ifdef __cplusplus
extern "C" {
#endif

void ptgl_ColorMaski(GLuint buf, GLboolean r, GLboolean g, GLboolean b, GLboolean a);
void ptgl_ColorMask(GLboolean r, GLboolean g, GLboolean b, GLboolean a);
void ptgl_DrawBuffer(GLenum buf);
void ptgl_DrawBuffers(GLsizei n, const GLenum* bufs);
void ptgl_DeleteFramebuffers(GLsizei n, const GLuint* framebuffers);
void ptgl_DrawArrays(GLenum mode, GLint first, GLsizei count);
void ptgl_DrawElements(GLenum mode, GLsizei count, GLenum type, const void* indices);
void ptgl_Clear(GLbitfield mask);
void ptgl_FramebufferTexture(GLenum target, GLenum attachment, GLuint texture, GLint level);
void* ptgl_MapBuffer(GLenum target, GLenum access);
void ptgl_TexImage2D(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLint border,
                     GLenum format, GLenum type, const void* pixels);
void ptgl_TexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height,
                        GLenum format, GLenum type, const void* pixels);
void ptgl_TexImage3D(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLsizei depth,
                     GLint border, GLenum format, GLenum type, const void* pixels);
void ptgl_TexSubImage3D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width,
                        GLsizei height, GLsizei depth, GLenum format, GLenum type, const void* pixels);
void ptgl_ReadPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, void* pixels);
/// Diagnostic (essai DS) : erreur d'OpenGL ES en attente juste après un appel, notée avec son nom.
void ptgl_Check(const char* call);
/// Blocs de données des shaders : melonDS utilise les numéros 0, 16, 20 à 25, 30 et 31 ; OpenGL ES 3.0 n'en garantit
/// que 24 (0 à 23). Ceux au-delà de 19 sont renumérotés.
void ptgl_UniformBlockBinding(GLuint program, GLuint uniformBlockIndex, GLuint uniformBlockBinding);
void ptgl_BindBufferBase(GLenum target, GLuint index, GLuint buffer);
void ptgl_BindBufferRange(GLenum target, GLuint index, GLuint buffer, GLintptr offset, GLsizeiptr size);
/// Shader « #version 140 » (OpenGL 3.1) → « #version 300 es » avec les précisions demandées par OpenGL ES.
/// Chaîne allouée (malloc), à libérer par l'appelant.
char* ptgl_AdaptShaderSource(const char* source);

// Rendu « compute » de melonDS (OpenGL 4.3) : compilé avec le reste mais jamais utilisé sur iPhone. Ses fonctions
// absentes d'OpenGL ES 3.0 ne font rien.
#ifndef GL_DEBUG_OUTPUT
#define GL_DEBUG_OUTPUT 0x92E0
#endif
typedef void (*ptgl_DebugProc)(GLenum source, GLenum type, GLuint id, GLenum severity, GLsizei length,
                               const GLchar* message, const void* userParam);
static inline void ptgl_BindImageTexture(GLuint unit, GLuint texture, GLint level, GLboolean layered, GLint layer,
                                         GLenum access, GLenum format) {}
static inline void ptgl_DispatchCompute(GLuint x, GLuint y, GLuint z) {}
static inline void ptgl_DispatchComputeIndirect(GLintptr indirect) {}
static inline void ptgl_MemoryBarrier(GLbitfield barriers) {}
static inline void ptgl_TexBuffer(GLenum target, GLenum internalformat, GLuint buffer) {}
static inline void ptgl_DebugMessageCallback(ptgl_DebugProc callback, const void* userParam) {}

#ifdef __cplusplus
}
#endif

#define glBindImageTexture ptgl_BindImageTexture
#define glDispatchCompute ptgl_DispatchCompute
#define glDispatchComputeIndirect ptgl_DispatchComputeIndirect
#define glMemoryBarrier ptgl_MemoryBarrier
#define glTexBuffer ptgl_TexBuffer
#define glDebugMessageCallback ptgl_DebugMessageCallback

// Diagnostic (essai DS, -DPT_GLES_DIAGNOSTIC) : chaque appel courant suivi d'une vérification d'erreur.
#ifdef PT_GLES_DIAGNOSTIC
#define glTexParameteri(...) (glTexParameteri(__VA_ARGS__), ptgl_Check("glTexParameteri"))
#define glBindTexture(...) (glBindTexture(__VA_ARGS__), ptgl_Check("glBindTexture"))
#define glActiveTexture(...) (glActiveTexture(__VA_ARGS__), ptgl_Check("glActiveTexture"))
#define glBindFramebuffer(...) (glBindFramebuffer(__VA_ARGS__), ptgl_Check("glBindFramebuffer"))
#define glFramebufferTextureLayer(...) (glFramebufferTextureLayer(__VA_ARGS__), ptgl_Check("glFramebufferTextureLayer"))
#define glFramebufferTexture2D(...) (glFramebufferTexture2D(__VA_ARGS__), ptgl_Check("glFramebufferTexture2D"))
#define glBlitFramebuffer(...) (glBlitFramebuffer(__VA_ARGS__), ptgl_Check("glBlitFramebuffer"))
#define glReadBuffer(...) (glReadBuffer(__VA_ARGS__), ptgl_Check("glReadBuffer"))
#define glVertexAttribPointer(...) (glVertexAttribPointer(__VA_ARGS__), ptgl_Check("glVertexAttribPointer"))
#define glVertexAttribIPointer(...) (glVertexAttribIPointer(__VA_ARGS__), ptgl_Check("glVertexAttribIPointer"))
#define glEnableVertexAttribArray(...) (glEnableVertexAttribArray(__VA_ARGS__), ptgl_Check("glEnableVertexAttribArray"))
#define glBlendFuncSeparate(...) (glBlendFuncSeparate(__VA_ARGS__), ptgl_Check("glBlendFuncSeparate"))
#define glBlendEquationSeparate(...) (glBlendEquationSeparate(__VA_ARGS__), ptgl_Check("glBlendEquationSeparate"))
#define glBlendColor(...) (glBlendColor(__VA_ARGS__), ptgl_Check("glBlendColor"))
#define glDepthFunc(...) (glDepthFunc(__VA_ARGS__), ptgl_Check("glDepthFunc"))
#define glDepthMask(...) (glDepthMask(__VA_ARGS__), ptgl_Check("glDepthMask"))
#define glStencilFunc(...) (glStencilFunc(__VA_ARGS__), ptgl_Check("glStencilFunc"))
#define glStencilOp(...) (glStencilOp(__VA_ARGS__), ptgl_Check("glStencilOp"))
#define glStencilMask(...) (glStencilMask(__VA_ARGS__), ptgl_Check("glStencilMask"))
#define glEnable(...) (glEnable(__VA_ARGS__), ptgl_Check("glEnable"))
#define glDisable(...) (glDisable(__VA_ARGS__), ptgl_Check("glDisable"))
#define glScissor(...) (glScissor(__VA_ARGS__), ptgl_Check("glScissor"))
#define glViewport(...) (glViewport(__VA_ARGS__), ptgl_Check("glViewport"))
#define glUniform1i(...) (glUniform1i(__VA_ARGS__), ptgl_Check("glUniform1i"))
#define glUniform1ui(...) (glUniform1ui(__VA_ARGS__), ptgl_Check("glUniform1ui"))
#define glUniform2f(...) (glUniform2f(__VA_ARGS__), ptgl_Check("glUniform2f"))
#define glUniform4ui(...) (glUniform4ui(__VA_ARGS__), ptgl_Check("glUniform4ui"))
#define glUseProgram(...) (glUseProgram(__VA_ARGS__), ptgl_Check("glUseProgram"))
#define glBufferData(...) (glBufferData(__VA_ARGS__), ptgl_Check("glBufferData"))
#define glBufferSubData(...) (glBufferSubData(__VA_ARGS__), ptgl_Check("glBufferSubData"))
#define glTexStorage3D(...) (glTexStorage3D(__VA_ARGS__), ptgl_Check("glTexStorage3D"))
#define glLineWidth(...) (glLineWidth(__VA_ARGS__), ptgl_Check("glLineWidth"))
#define glPixelStorei(...) (glPixelStorei(__VA_ARGS__), ptgl_Check("glPixelStorei"))
#define glBindVertexArray(...) (glBindVertexArray(__VA_ARGS__), ptgl_Check("glBindVertexArray"))
#define glBindBuffer(...) (glBindBuffer(__VA_ARGS__), ptgl_Check("glBindBuffer"))
#define glClearColor(...) (glClearColor(__VA_ARGS__), ptgl_Check("glClearColor"))
#define glClearBufferfv(...) (glClearBufferfv(__VA_ARGS__), ptgl_Check("glClearBufferfv"))
#define glClearBufferuiv(...) (glClearBufferuiv(__VA_ARGS__), ptgl_Check("glClearBufferuiv"))
#endif

#define glUniformBlockBinding ptgl_UniformBlockBinding
#define glBindBufferBase ptgl_BindBufferBase
#define glBindBufferRange ptgl_BindBufferRange
#define glColorMaski ptgl_ColorMaski
#define glColorMask ptgl_ColorMask
#define glDrawBuffer ptgl_DrawBuffer
#define glDrawBuffers ptgl_DrawBuffers
#define glDeleteFramebuffers ptgl_DeleteFramebuffers
#define glDrawArrays ptgl_DrawArrays
#define glDrawElements ptgl_DrawElements
#define glClear ptgl_Clear
#define glFramebufferTexture ptgl_FramebufferTexture
#define glMapBuffer ptgl_MapBuffer
#define glTexImage2D ptgl_TexImage2D
#define glTexSubImage2D ptgl_TexSubImage2D
#define glTexImage3D ptgl_TexImage3D
#define glTexSubImage3D ptgl_TexSubImage3D
#define glReadPixels ptgl_ReadPixels
#define glClearDepth(depth) glClearDepthf((GLfloat)(depth))
#define glDepthRange(n, f) glDepthRangef((GLfloat)(n), (GLfloat)(f))
#define glBindFragDataLocation(program, location, name) ((void)0)
#define glObjectLabel(identifier, name, length, label) ((void)0)

#endif
