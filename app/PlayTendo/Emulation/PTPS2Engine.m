#import "PTPS2Engine.h"
#import <dlfcn.h>

// Fonctions du moteur, trouvées par dlsym (déclarées dans PTPS2.h).
#define PT_PS2_FUNCTIONS(X) \
    X(PTPS2Setup) X(PTPS2PickBIOS) X(PTPS2Boot) X(PTPS2GetState) X(PTPS2SetPaused) X(PTPS2Stop) \
    X(PTPS2Reset) X(PTPS2ReleaseMemory) X(PTPS2SetTurbo) X(PTPS2SetButton) X(PTPS2SetStick) X(PTPS2SaveState) X(PTPS2LoadState) \
    X(PTPS2SetImageOptions) X(PTPS2CopySnapshot) X(PTPS2CopyLastError)

typedef struct {
#define PT_FIELD(name) __typeof__(&name) name;
    PT_PS2_FUNCTIONS(PT_FIELD)
#undef PT_FIELD
} PTPS2Functions;

static PTPS2Engine *loadedEngine;

@implementation PTPS2Engine {
    PTPS2Functions _fn;
}

+ (PTPS2Engine *)loadedEngine {
    return loadedEngine;
}

+ (instancetype)loadWithFrameworkPath:(NSString *)path
                             dataRoot:(NSString *)dataRoot
                        biosDirectory:(NSString *)biosDirectory
                  memoryCardDirectory:(NSString *)memoryCardDirectory
                                error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Moteur PS2 : préparation sur le thread principal");
    if (loadedEngine) return loadedEngine;

    void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        return [self failWithMessage:[NSString stringWithFormat:@"Impossible de charger le moteur PS2 : %s", dlerror()]
                               error:error];
    }
    PTPS2Engine *engine = [PTPS2Engine new];
#define PT_LOOKUP(name) \
    engine->_fn.name = (__typeof__(&name))dlsym(handle, #name); \
    if (!engine->_fn.name) return [self failWithMessage:@"Moteur PS2 incomplet : " #name " manquant" error:error];
    PT_PS2_FUNCTIONS(PT_LOOKUP)
#undef PT_LOOKUP

    void *view = engine->_fn.PTPS2Setup(dataRoot.fileSystemRepresentation, biosDirectory.fileSystemRepresentation,
                                        memoryCardDirectory.fileSystemRepresentation);
    if (!view) return [self failWithMessage:@"Le moteur PS2 n'a pas pu démarrer." error:error];
    engine->_renderView = (__bridge UIView *)view;
    loadedEngine = engine;
    return engine;
}

+ (id)failWithMessage:(NSString *)message error:(NSError **)error {
    if (error) *error = [NSError errorWithDomain:@"PlayTendo" code:2 userInfo:@{NSLocalizedDescriptionKey: message}];
    return nil;
}

- (PTPS2State)state {
    return _fn.PTPS2GetState();
}

- (NSString *)pickBIOS {
    return [self takeString:_fn.PTPS2PickBIOS()];
}

- (BOOL)bootGameAtPath:(NSString *)path {
    return _fn.PTPS2Boot(path.fileSystemRepresentation);
}

- (void)setPaused:(BOOL)paused {
    _fn.PTPS2SetPaused(paused);
}

- (void)stop {
    _fn.PTPS2Stop();
}

- (void)reset {
    _fn.PTPS2Reset();
}

- (void)releaseMemory {
    _fn.PTPS2ReleaseMemory();
}

- (void)setTurbo:(BOOL)enabled {
    _fn.PTPS2SetTurbo(enabled);
}

- (void)setButton:(NSInteger)button pressed:(BOOL)pressed {
    _fn.PTPS2SetButton((int)button, pressed);
}

- (void)setStick:(int)stick x:(float)x y:(float)y {
    _fn.PTPS2SetStick(stick, x, y);
}

- (BOOL)saveStateToPath:(NSString *)path {
    return _fn.PTPS2SaveState(path.fileSystemRepresentation);
}

- (BOOL)loadStateFromPath:(NSString *)path {
    return _fn.PTPS2LoadState(path.fileSystemRepresentation);
}

- (void)setImageUpscale:(NSInteger)upscale smoothing:(BOOL)smoothing {
    _fn.PTPS2SetImageOptions((int)upscale, smoothing);
}

- (UIImage *)snapshot {
    int width = 0, height = 0;
    void *pixels = _fn.PTPS2CopySnapshot(&width, &height);
    if (!pixels) return nil;
    NSData *data = [NSData dataWithBytesNoCopy:pixels length:(size_t)width * height * 4 freeWhenDone:YES];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image = CGImageCreate(width, height, 8, 32, (size_t)width * 4, space,
                                     (CGBitmapInfo)kCGImageAlphaNoneSkipLast, provider, NULL, false,
                                     kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    if (!image) return nil;
    UIImage *result = [UIImage imageWithCGImage:image];
    CGImageRelease(image);
    return result;
}

- (NSString *)lastError {
    return [self takeString:_fn.PTPS2CopyLastError()];
}

/// Chaîne C allouée par le moteur (malloc) → NSString, puis libérée.
- (NSString *)takeString:(char *)string {
    if (!string) return nil;
    NSString *result = [NSString stringWithUTF8String:string];
    free(string);
    return result;
}

@end
