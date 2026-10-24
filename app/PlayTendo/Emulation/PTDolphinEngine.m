#import "PTDolphinEngine.h"
#import "PTRumble.h"
#import <dlfcn.h>

// Fonctions du moteur, trouvées par dlsym (déclarées dans PTDolphin.h).
#define PT_DOLPHIN_FUNCTIONS(X) \
    X(PTDolphinSetup) X(PTDolphinBoot) X(PTDolphinGetState) X(PTDolphinSetPaused) X(PTDolphinStop) \
    X(PTDolphinReset) X(PTDolphinSetSpeed) X(PTDolphinSetButton) X(PTDolphinSetStick) X(PTDolphinSaveState) \
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

/// Vibrations des manettes GameCube et de la Wiimote → manette de l'app (GamepadManager).
static void PTDolphinRumble(int pad, double strength) {
    PTRumbleSet((unsigned int)MAX(pad, 0), (float)strength, 0);
}

@implementation PTDolphinEngine {
    PTDolphinFunctions _fn;
    /// Facultatives (moteurs compilés avant elles).
    __typeof__(&PTDolphinShutdown) _shutdown;
    __typeof__(&PTDolphinBootDiscs) _bootDiscs;
    __typeof__(&PTDolphinGetDisc) _getDisc;
    __typeof__(&PTDolphinChangeDisc) _changeDisc;
    __typeof__(&PTDolphinSetBootState) _setBootState;
    __typeof__(&PTDolphinSetWidescreen) _setWidescreen;
    __typeof__(&PTDolphinSetCheats) _setCheats;
    __typeof__(&PTDolphinGetPerformance) _getPerformance;
    __typeof__(&PTDolphinSetPadButton) _setPadButton;
    __typeof__(&PTDolphinSetPadStick) _setPadStick;
    __typeof__(&PTDolphinSetSecondPlayer) _setSecondPlayer;
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
    engine->_bootDiscs = (__typeof__(&PTDolphinBootDiscs))dlsym(handle, "PTDolphinBootDiscs");
    engine->_getDisc = (__typeof__(&PTDolphinGetDisc))dlsym(handle, "PTDolphinGetDisc");
    engine->_changeDisc = (__typeof__(&PTDolphinChangeDisc))dlsym(handle, "PTDolphinChangeDisc");
    engine->_setBootState = (__typeof__(&PTDolphinSetBootState))dlsym(handle, "PTDolphinSetBootState");
    engine->_setWidescreen = (__typeof__(&PTDolphinSetWidescreen))dlsym(handle, "PTDolphinSetWidescreen");
    engine->_setCheats = (__typeof__(&PTDolphinSetCheats))dlsym(handle, "PTDolphinSetCheats");
    engine->_getPerformance = (__typeof__(&PTDolphinGetPerformance))dlsym(handle, "PTDolphinGetPerformance");
    engine->_setPadButton = (__typeof__(&PTDolphinSetPadButton))dlsym(handle, "PTDolphinSetPadButton");
    engine->_setPadStick = (__typeof__(&PTDolphinSetPadStick))dlsym(handle, "PTDolphinSetPadStick");
    engine->_setSecondPlayer = (__typeof__(&PTDolphinSetSecondPlayer))dlsym(handle, "PTDolphinSetSecondPlayer");
    __typeof__(&PTDolphinSetRumbleHandler) setRumble = dlsym(handle, "PTDolphinSetRumbleHandler");
    if (setRumble) setRumble(PTDolphinRumble);

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

- (BOOL)bootGameAtPaths:(NSArray<NSString *> *)paths jit:(BOOL)jit {
    if (!_bootDiscs || paths.count < 2) return [self bootGameAtPath:paths.firstObject ?: @"" jit:jit];
    const char *list[paths.count];
    for (NSUInteger i = 0; i < paths.count; i++) list[i] = paths[i].fileSystemRepresentation;
    return _bootDiscs(list, (int)paths.count, jit);
}

- (BOOL)setBootState:(NSString *)statePath {
    if (!_setBootState) return NO;
    _setBootState(statePath.length > 0 ? statePath.fileSystemRepresentation : NULL);
    return YES;
}

- (void)setWidescreen:(BOOL)enabled {
    if (_setWidescreen) _setWidescreen(enabled);
}

- (BOOL)getFPS:(double *)fps speed:(double *)speed {
    return _getPerformance ? _getPerformance(fps, speed) : NO;
}

- (void)setButton:(NSInteger)button pressed:(BOOL)pressed player:(NSInteger)player {
    if (player == 0) {
        [self setButton:button pressed:pressed];
    } else if (_setPadButton) {
        _setPadButton((int)player, (int)button, pressed);
    }
}

- (void)setStick:(int)stick x:(float)x y:(float)y player:(NSInteger)player {
    if (player == 0) {
        [self setStick:stick x:x y:y];
    } else if (_setPadStick) {
        _setPadStick((int)player, stick, x, y);
    }
}

- (void)setSecondPlayer:(BOOL)connected {
    if (_setSecondPlayer) _setSecondPlayer(connected);
}

- (void)setCheatsActionReplay:(NSString *)actionReplay gecko:(NSString *)gecko {
    if (_setCheats) _setCheats(actionReplay.UTF8String, gecko.UTF8String);
}

- (NSInteger)discIndex {
    return _getDisc ? _getDisc() : -1;
}

- (BOOL)changeDiscAt:(NSInteger)index {
    return _changeDisc ? _changeDisc((int)index) : NO;
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

- (void)setSpeed:(double)factor {
    _fn.PTDolphinSetSpeed((float)factor);
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
