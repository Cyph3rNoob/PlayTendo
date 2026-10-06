#import "PTDolphinEngine.h"
#import <dlfcn.h>

// Fonctions du moteur, trouvées par dlsym (déclarées dans PTDolphin.h).
#define PT_DOLPHIN_FUNCTIONS(X) \
    X(PTDolphinSetup) X(PTDolphinBoot) X(PTDolphinGetState) X(PTDolphinSetPaused) X(PTDolphinStop) \
    X(PTDolphinReset) X(PTDolphinSetTurbo) X(PTDolphinSetButton) X(PTDolphinSetStick) X(PTDolphinSaveState) \
    X(PTDolphinLoadState) X(PTDolphinCopyLastError)

typedef struct {
#define PT_FIELD(name) __typeof__(&name) name;
    PT_DOLPHIN_FUNCTIONS(PT_FIELD)
#undef PT_FIELD
} PTDolphinFunctions;

static PTDolphinEngine *loadedEngine;

@implementation PTDolphinEngine {
    PTDolphinFunctions _fn;
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

    void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        return [self failWithMessage:[NSString stringWithFormat:@"Impossible de charger le moteur GameCube/Wii : %s", dlerror()]
                               error:error];
    }
    PTDolphinEngine *engine = [PTDolphinEngine new];
#define PT_LOOKUP(name) \
    engine->_fn.name = (__typeof__(&name))dlsym(handle, #name); \
    if (!engine->_fn.name) return [self failWithMessage:@"Moteur GameCube/Wii incomplet : " #name " manquant" error:error];
    PT_DOLPHIN_FUNCTIONS(PT_LOOKUP)
#undef PT_LOOKUP

    void *view = engine->_fn.PTDolphinSetup(userDirectory.fileSystemRepresentation,
                                            gameCubeSaveDirectory.fileSystemRepresentation,
                                            wiiSaveDirectory.fileSystemRepresentation);
    if (!view) return [self failWithMessage:@"Le moteur GameCube/Wii n'a pas pu démarrer." error:error];
    engine->_renderView = (__bridge UIView *)view;
    loadedEngine = engine;
    return engine;
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
