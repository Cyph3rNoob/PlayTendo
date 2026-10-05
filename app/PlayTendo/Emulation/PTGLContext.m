// OpenGL ES est marqué « obsolète » par Apple mais reste fourni par iOS ; les moteurs 3D l'utilisent.
// (Les en-têtes système sont des modules : un #define ne suffit pas à taire l'avertissement.)
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#import "PTGLContext.h"
#import "PTCore.h"

#import <TargetConditionals.h>
#if TARGET_OS_IOS

#import <Accelerate/Accelerate.h>
#import <CoreVideo/CVOpenGLESTextureCache.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>

// Trois images qui tournent : une affichée, une en attente, une en cours de dessin.
#define PT_GL_BUFFERS 3

@implementation PTGLContext {
    EAGLContext *_context;
    CVOpenGLESTextureCacheRef _cache;
    CVPixelBufferRef _buffers[PT_GL_BUFFERS];
    CVOpenGLESTextureRef _textures[PT_GL_BUFFERS];
    GLuint _framebuffer;
    GLuint _depthStencil;
    int _current;
    // Méthode de secours (simulateur) : le moteur dessine dans une texture OpenGL ordinaire,
    // recopiée ensuite dans l'image partagée avec Metal.
    BOOL _copyMode;
    GLuint _copyTexture;
}

- (instancetype)initWithWidth:(unsigned)width height:(unsigned)height {
    self = [super init];
    if (!self) return nil;
    _context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    if (!_context) {
        PTLogLine(@"OpenGL ES 3 indisponible");
        return nil;
    }
    [EAGLContext setCurrentContext:_context];
    CVReturn status = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, _context, NULL, &_cache);
    if (status != kCVReturnSuccess) {
        PTLogLine([NSString stringWithFormat:@"Cache de textures OpenGL ES impossible (%d)", status]);
        return nil;
    }
    glGenFramebuffers(1, &_framebuffer);
    glGenRenderbuffers(1, &_depthStencil);
    if (![self allocateWidth:width height:height]) return nil;
    return self;
}

- (void)dealloc {
    [EAGLContext setCurrentContext:_context];
    [self releaseBuffers];
    if (_framebuffer) glDeleteFramebuffers(1, &_framebuffer);
    if (_depthStencil) glDeleteRenderbuffers(1, &_depthStencil);
    if (_cache) CFRelease(_cache);
    [EAGLContext setCurrentContext:nil];
}

- (unsigned)framebuffer {
    return _framebuffer;
}

- (void)makeCurrent {
    if ([EAGLContext currentContext] != _context) [EAGLContext setCurrentContext:_context];
}

- (void)releaseBuffers {
    for (int i = 0; i < PT_GL_BUFFERS; i++) {
        if (_textures[i]) CFRelease(_textures[i]);
        if (_buffers[i]) CVPixelBufferRelease(_buffers[i]);
        _textures[i] = NULL;
        _buffers[i] = NULL;
    }
    if (_copyTexture) glDeleteTextures(1, &_copyTexture);
    _copyTexture = 0;
    if (_cache) CVOpenGLESTextureCacheFlush(_cache, 0);
}

static void PTSetTextureParameters(void) {
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}

- (BOOL)allocateWidth:(unsigned)width height:(unsigned)height {
    [self releaseBuffers];
    NSDictionary *attributes = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferOpenGLESCompatibilityKey: @YES,
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    for (int i = 0; i < PT_GL_BUFFERS; i++) {
        CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                              (__bridge CFDictionaryRef)attributes, &_buffers[i]);
        if (status != kCVReturnSuccess) {
            PTLogLine([NSString stringWithFormat:@"Image partagée %u×%u impossible (%d)", width, height, status]);
            return NO;
        }
        if (_copyMode) continue;
        status = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _cache, _buffers[i], NULL, GL_TEXTURE_2D,
                                                              GL_RGBA, (GLsizei)width, (GLsizei)height, GL_BGRA,
                                                              GL_UNSIGNED_BYTE, 0, &_textures[i]);
        if (status != kCVReturnSuccess) {
            // Le simulateur refuse de partager l'image entre OpenGL ES et Metal (-6683).
            PTLogLine([NSString stringWithFormat:@"Image partagée OpenGL ES refusée (%d) : rendu 3D par copie", status]);
            _copyMode = YES;
            for (int j = 0; j < i; j++) {
                CFRelease(_textures[j]);
                _textures[j] = NULL;
            }
            continue;
        }
        glBindTexture(GL_TEXTURE_2D, CVOpenGLESTextureGetName(_textures[i]));
        PTSetTextureParameters();
    }
    if (_copyMode) {
        glGenTextures(1, &_copyTexture);
        glBindTexture(GL_TEXTURE_2D, _copyTexture);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, (GLsizei)width, (GLsizei)height, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
        PTSetTextureParameters();
    }
    glBindTexture(GL_TEXTURE_2D, 0);
    _width = width;
    _height = height;
    _current = 0;

    GLint previous = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &previous);
    glBindRenderbuffer(GL_RENDERBUFFER, _depthStencil);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, (GLsizei)width, (GLsizei)height);
    glBindRenderbuffer(GL_RENDERBUFFER, 0);
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, _depthStencil);
    // Images neuves = mémoire non effacée : le moteur ne dessine souvent qu'une partie de l'image,
    // le reste doit être noir et non des pixels parasites.
    glClearColor(0, 0, 0, 1);
    for (int i = _copyMode ? PT_GL_BUFFERS - 1 : 0; i < PT_GL_BUFFERS; i++) {
        GLuint texture = _copyMode ? _copyTexture : CVOpenGLESTextureGetName(_textures[i]);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
        glClear(GL_COLOR_BUFFER_BIT);
    }
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, [self drawingTexture], 0);
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)previous);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        PTLogLine([NSString stringWithFormat:@"Framebuffer OpenGL ES incomplet (0x%x, erreur GL 0x%x)", status, glGetError()]);
        return NO;
    }
    return YES;
}

/// Texture dans laquelle le moteur dessine l'image en cours.
- (GLuint)drawingTexture {
    return _copyMode ? _copyTexture : CVOpenGLESTextureGetName(_textures[_current]);
}

- (BOOL)ensureWidth:(unsigned)width height:(unsigned)height {
    if (width <= _width && height <= _height) return YES;
    return [self allocateWidth:MAX(width, _width) height:MAX(height, _height)];
}

- (CVPixelBufferRef)finishFrameWithWidth:(unsigned)width height:(unsigned)height {
    CVPixelBufferRef done = _buffers[_current];
    if (_copyMode) {
        [self copyFrameInto:done width:MIN(width, _width) height:MIN(height, _height)];
    } else {
        glFinish();
    }
    _current = (_current + 1) % PT_GL_BUFFERS;
    if (!_copyMode) {
        GLint previous = 0;
        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &previous);
        glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, [self drawingTexture], 0);
        glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)previous);
    }
    return done;
}

/// Méthode de secours : lit l'image dessinée (RGBA) et la range en BGRA dans l'image partagée.
/// Les lignes restent dans l'ordre d'OpenGL (bas en premier), comme avec l'image partagée.
- (void)copyFrameInto:(CVPixelBufferRef)buffer width:(unsigned)width height:(unsigned)height {
    if (width == 0 || height == 0) return;
    CVPixelBufferLockBaseAddress(buffer, 0);
    void *base = CVPixelBufferGetBaseAddress(buffer);
    size_t rowBytes = CVPixelBufferGetBytesPerRow(buffer);
    if (base) {
        GLint previousRead = 0;
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &previousRead);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, _framebuffer);
        glPixelStorei(GL_PACK_ALIGNMENT, 4);
        glPixelStorei(GL_PACK_ROW_LENGTH, (GLint)(rowBytes / 4));
        glReadPixels(0, 0, (GLsizei)width, (GLsizei)height, GL_RGBA, GL_UNSIGNED_BYTE, base);
        glPixelStorei(GL_PACK_ROW_LENGTH, 0);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, (GLuint)previousRead);
        vImage_Buffer image = {base, height, width, rowBytes};
        const uint8_t toBGRA[4] = {2, 1, 0, 3};
        vImagePermuteChannels_ARGB8888(&image, &image, toBGRA, kvImageNoFlags);
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
}

@end

#else

// Sur Mac (banc d'essai), pas d'OpenGL ES : les moteurs 3D ne sont testés que dans le simulateur.
@implementation PTGLContext
- (instancetype)initWithWidth:(unsigned)width height:(unsigned)height { return nil; }
- (unsigned)framebuffer { return 0; }
- (void)makeCurrent {}
- (BOOL)ensureWidth:(unsigned)width height:(unsigned)height { return NO; }
- (CVPixelBufferRef)finishFrameWithWidth:(unsigned)width height:(unsigned)height { return NULL; }
@end

#endif
