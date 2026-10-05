#import "PTGLContext.h"

#import <TargetConditionals.h>
#if TARGET_OS_IOS

#define GLES_SILENCE_DEPRECATION 1
#import <CoreVideo/CVOpenGLESTextureCache.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>

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
}

- (instancetype)initWithWidth:(unsigned)width height:(unsigned)height {
    self = [super init];
    if (!self) return nil;
    _context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    if (!_context) return nil;
    [EAGLContext setCurrentContext:_context];
    if (CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, _context, NULL, &_cache) != kCVReturnSuccess) return nil;
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
    [EAGLContext setCurrentContext:_context];
}

- (void)releaseBuffers {
    for (int i = 0; i < PT_GL_BUFFERS; i++) {
        if (_textures[i]) CFRelease(_textures[i]);
        if (_buffers[i]) CVPixelBufferRelease(_buffers[i]);
        _textures[i] = NULL;
        _buffers[i] = NULL;
    }
    if (_cache) CVOpenGLESTextureCacheFlush(_cache, 0);
}

- (BOOL)allocateWidth:(unsigned)width height:(unsigned)height {
    [self releaseBuffers];
    NSDictionary *attributes = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferOpenGLESCompatibilityKey: @YES,
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    for (int i = 0; i < PT_GL_BUFFERS; i++) {
        if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                (__bridge CFDictionaryRef)attributes, &_buffers[i]) != kCVReturnSuccess) return NO;
        if (CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _cache, _buffers[i], NULL, GL_TEXTURE_2D,
                                                         GL_RGBA, (GLsizei)width, (GLsizei)height, GL_BGRA,
                                                         GL_UNSIGNED_BYTE, 0, &_textures[i]) != kCVReturnSuccess) return NO;
        glBindTexture(GL_TEXTURE_2D, CVOpenGLESTextureGetName(_textures[i]));
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
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
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                           CVOpenGLESTextureGetName(_textures[_current]), 0);
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)previous);
    return status == GL_FRAMEBUFFER_COMPLETE;
}

- (BOOL)ensureWidth:(unsigned)width height:(unsigned)height {
    if (width <= _width && height <= _height) return YES;
    return [self allocateWidth:MAX(width, _width) height:MAX(height, _height)];
}

- (CVPixelBufferRef)finishFrame {
    glFinish();
    CVPixelBufferRef done = _buffers[_current];
    _current = (_current + 1) % PT_GL_BUFFERS;
    GLint previous = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &previous);
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                           CVOpenGLESTextureGetName(_textures[_current]), 0);
    glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)previous);
    return done;
}

@end

#else

// Sur Mac (banc d'essai), pas d'OpenGL ES : les moteurs 3D ne sont testés que dans le simulateur.
@implementation PTGLContext
- (instancetype)initWithWidth:(unsigned)width height:(unsigned)height { return nil; }
- (unsigned)framebuffer { return 0; }
- (void)makeCurrent {}
- (BOOL)ensureWidth:(unsigned)width height:(unsigned)height { return NO; }
- (CVPixelBufferRef)finishFrame { return NULL; }
@end

#endif
