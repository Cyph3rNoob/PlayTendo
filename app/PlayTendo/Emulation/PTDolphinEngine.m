#import "PTDolphinEngine.h"
#import <dlfcn.h>

// Fonctions du moteur, trouvées par dlsym (déclarées dans PTDolphin.h).
#define PT_DOLPHIN_FUNCTIONS(X) \
    X(PTDolphinSetup) X(PTDolphinBoot) X(PTDolphinGetState) X(PTDolphinSetPaused) X(PTDolphinStop) \
    X(PTDolphinReset) X(PTDolphinSetTurbo) X(PTDolphinSetButton) X(PTDolphinSetStick) X(PTDolphinSaveState) \
    X(PTDolphinLoadState) X(PTDolphinCopyLastError) X(PTDolphinSetWiimote) X(PTDolphinSetPointer) \
    X(PTDolphinGetAspectRatio) X(PTDolphinSetImageOptions) X(PTDolphinCaptureScreen) X(PTDolphinFastmemStatus)

typedef struct {
#define PT_FIELD(name) __typeof__(&name) name;
    PT_DOLPHIN_FUNCTIONS(PT_FIELD)
#undef PT_FIELD
} PTDolphinFunctions;

static PTDolphinEngine *loadedEngine;
/// Échec après le chargement du moteur (dlopen réussi) : il ne se répare pas en cours de route. Les essais suivants
/// renvoient la même erreur au lieu de refaire une préparation à moitié faite.
static NSString *loadFailure;

@implementation PTDolphinEngine {
    PTDolphinFunctions _fn;
    /// Facultative (moteurs compilés avant elle).
    __typeof__(&PTDolphinShutdown) _shutdown;
}

+ (PTDolphinEngine *)loadedEngine {
    return loadedEngine;
}

+ (instancetype)loadWithFrameworkPath:(NSString *)path
                        userDirectory:(NSString *)userDirectory
                gameCubeSaveDirectory:(NSString *)gameCubeSaveDirectory
                     wiiSaveDirectory:(NSString *)wiiSaveDirectory
                                error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Moteur GameCube/Wii : préparation sur le thread principal");
    if (loadedEngine) return loadedEngine;
    if (loadFailure) return [self failWithMessage:loadFailure error:error];

    void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        return [self failWithMessage:[NSString stringWithFormat:@"Impossible de charger le moteur GameCube/Wii : %s", dlerror()]
                               error:error];
    }
    PTDolphinEngine *engine = [PTDolphinEngine new];
#define PT_LOOKUP(name) \
    engine->_fn.name = (__typeof__(&name))dlsym(handle, #name); \
    if (!engine->_fn.name) return [self failAfterLoad:@"Moteur GameCube/Wii incomplet : " #name " manquant" error:error];
    PT_DOLPHIN_FUNCTIONS(PT_LOOKUP)
#undef PT_LOOKUP
    engine->_shutdown = (__typeof__(&PTDolphinShutdown))dlsym(handle, "PTDolphinShutdown");

    void *view = engine->_fn.PTDolphinSetup(userDirectory.fileSystemRepresentation,
                                            gameCubeSaveDirectory.fileSystemRepresentation,
                                            wiiSaveDirectory.fileSystemRepresentation);
    if (!view) return [self failAfterLoad:@"Le moteur GameCube/Wii n'a pas pu démarrer." error:error];
    engine->_renderView = (__bridge PTPlatformView *)view;
    loadedEngine = engine;
    return engine;
}

+ (id)failAfterLoad:(NSString *)message error:(NSError **)error {
    loadFailure = [message stringByAppendingString:@" Relance PlayTendo pour réessayer."];
    return [self failWithMessage:loadFailure error:error];
}

+ (id)failWithMessage:(NSString *)message error:(NSError **)error {
    if (error) *error = [NSError errorWithDomain:@"PlayTendo" code:2 userInfo:@{NSLocalizedDescriptionKey: message}];
    return nil;
}

- (PTDolphinState)state {
    return _fn.PTDolphinGetState();
}

- (BOOL)bootGameAtPath:(NSString *)path jit:(BOOL)jit {
    return _fn.PTDolphinBoot(path.fileSystemRepresentation, jit);
}

- (void)setPaused:(BOOL)paused {
    _fn.PTDolphinSetPaused(paused);
}

- (void)shutdown {
    if (_shutdown) _shutdown();
}

- (void)stop {
    _fn.PTDolphinStop();
}

- (void)reset {
    _fn.PTDolphinReset();
}

- (void)setTurbo:(BOOL)enabled {
    _fn.PTDolphinSetTurbo(enabled);
}

- (void)setButton:(NSInteger)button pressed:(BOOL)pressed {
    _fn.PTDolphinSetButton((int)button, pressed);
}

- (void)setStick:(int)stick x:(float)x y:(float)y {
    _fn.PTDolphinSetStick(stick, x, y);
}

- (void)setWiimote:(BOOL)enabled {
    _fn.PTDolphinSetWiimote(enabled);
}

- (void)setPointerX:(float)x y:(float)y {
    _fn.PTDolphinSetPointer(x, y);
}

- (float)aspectRatio {
    return _fn.PTDolphinGetAspectRatio();
}

- (void)setImageScale:(int)scale smoothing:(BOOL)smoothing {
    _fn.PTDolphinSetImageOptions(scale, smoothing);
}

- (BOOL)captureScreenToPath:(NSString *)path {
    return _fn.PTDolphinCaptureScreen(path.fileSystemRepresentation);
}

- (BOOL)fastmemAvailableWithLargestBlock:(float *)largestBlockGB {
    return _fn.PTDolphinFastmemStatus(largestBlockGB);
}

- (BOOL)saveStateToPath:(NSString *)path {
    return _fn.PTDolphinSaveState(path.fileSystemRepresentation);
}

- (BOOL)loadStateFromPath:(NSString *)path {
    return _fn.PTDolphinLoadState(path.fileSystemRepresentation);
}

- (NSString *)lastError {
    char *string = _fn.PTDolphinCopyLastError();
    if (!string) return nil;
    NSString *result = [NSString stringWithUTF8String:string];
    free(string);
    return result;
}

@end
