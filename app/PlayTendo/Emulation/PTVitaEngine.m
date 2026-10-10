#import "PTVitaEngine.h"
#import <dlfcn.h>

// Fonctions du moteur, trouvées par dlsym (déclarées dans PTVita.h).
#define PT_VITA_FUNCTIONS(X) \
    X(PTVitaSetup) X(PTVitaGetFirmware) X(PTVitaInstallFirmware) X(PTVitaInstallGame) X(PTVitaIsInstalled) \
    X(PTVitaBoot) X(PTVitaGetState) X(PTVitaSetPaused) X(PTVitaStop) X(PTVitaSetButton) X(PTVitaSetStick) \
    X(PTVitaTouch) X(PTVitaCopyLastError) X(PTVitaSetHighAccuracy)

typedef struct {
#define PT_FIELD(name) __typeof__(&name) name;
    PT_VITA_FUNCTIONS(PT_FIELD)
#undef PT_FIELD
} PTVitaFunctions;

static PTVitaEngine *loadedEngine;

/// Avancement d'une installation : `context` est le bloc Objective-C de l'appelant.
static void PTVitaReportProgress(float progress, void *context) {
    void (^block)(float) = (__bridge void (^)(float))context;
    if (block) block(progress);
}

@implementation PTVitaEngine {
    PTVitaFunctions _fn;
    BOOL _touching;
}

+ (PTVitaEngine *)loadedEngine {
    return loadedEngine;
}

+ (instancetype)loadWithFrameworkPath:(NSString *)path
                     storageDirectory:(NSString *)storageDirectory
                                error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Moteur PS Vita : préparation sur le thread principal");
    if (loadedEngine) return loadedEngine;

    void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        return [self failWithMessage:[NSString stringWithFormat:@"Impossible de charger le moteur PS Vita : %s", dlerror()]
                               error:error];
    }
    PTVitaEngine *engine = [PTVitaEngine new];
#define PT_LOOKUP(name) \
    engine->_fn.name = (__typeof__(&name))dlsym(handle, #name); \
    if (!engine->_fn.name) return [self failWithMessage:@"Moteur PS Vita incomplet : " #name " manquant" error:error];
    PT_VITA_FUNCTIONS(PT_LOOKUP)
#undef PT_LOOKUP

    // Les fichiers fixes du moteur (shaders, icônes) sont rangés dans son framework.
    NSString *assets = path.stringByDeletingLastPathComponent;
    void *view = engine->_fn.PTVitaSetup(storageDirectory.fileSystemRepresentation, assets.fileSystemRepresentation);
    if (!view) {
        char *reason = engine->_fn.PTVitaCopyLastError();
        NSString *message = reason ? [NSString stringWithUTF8String:reason] : @"Le moteur PS Vita n'a pas pu démarrer.";
        free(reason);
        return [self failWithMessage:message error:error];
    }
    engine->_renderView = (__bridge UIView *)view;
    loadedEngine = engine;
    return engine;
}

+ (id)failWithMessage:(NSString *)message error:(NSError **)error {
    if (error) *error = [NSError errorWithDomain:@"PlayTendo" code:2 userInfo:@{NSLocalizedDescriptionKey: message}];
    return nil;
}

- (PTVitaState)state {
    return _fn.PTVitaGetState();
}

- (BOOL)hasFirmware {
    return (_fn.PTVitaGetFirmware() & PTVitaFirmwareMain) != 0;
}

- (BOOL)hasFonts {
    return (_fn.PTVitaGetFirmware() & PTVitaFirmwareFonts) != 0;
}

- (NSString *)installFirmwareAtPath:(NSString *)path progress:(void (^)(float))progress {
    char *version = _fn.PTVitaInstallFirmware(path.fileSystemRepresentation, progress ? PTVitaReportProgress : NULL,
                                              (__bridge void *)progress);
    if (!version) return nil;
    NSString *result = [NSString stringWithUTF8String:version];
    free(version);
    return result;
}

- (NSString *)installGameAtPath:(NSString *)path progress:(void (^)(float))progress {
    char *titleID = _fn.PTVitaInstallGame(path.fileSystemRepresentation, progress ? PTVitaReportProgress : NULL,
                                          (__bridge void *)progress);
    if (!titleID) return nil;
    NSString *result = [NSString stringWithUTF8String:titleID];
    free(titleID);
    return result;
}

- (BOOL)isGameInstalled:(NSString *)titleID {
    return _fn.PTVitaIsInstalled(titleID.UTF8String);
}

- (void)setHighAccuracy:(BOOL)high {
    _fn.PTVitaSetHighAccuracy(high);
}

- (BOOL)bootTitle:(NSString *)titleID {
    _touching = NO;
    return _fn.PTVitaBoot(titleID.UTF8String);
}

- (void)setPaused:(BOOL)paused {
    _fn.PTVitaSetPaused(paused);
}

- (void)stop {
    _fn.PTVitaStop();
}

- (void)setButton:(NSInteger)button pressed:(BOOL)pressed {
    _fn.PTVitaSetButton((int)button, pressed);
}

- (void)setStick:(int)stick x:(float)x y:(float)y {
    _fn.PTVitaSetStick(stick, x, y);
}

- (void)touchAtX:(float)x y:(float)y pressed:(BOOL)pressed {
    // Un seul doigt (celui que l'écran de jeu suit) : posé, déplacé, levé.
    if (pressed) {
        _fn.PTVitaTouch(0, _touching ? 1 : 0, x, y);
        _touching = YES;
    } else if (_touching) {
        _fn.PTVitaTouch(0, 2, x, y);
        _touching = NO;
    }
}

- (NSString *)lastError {
    char *string = _fn.PTVitaCopyLastError();
    if (!string) return nil;
    NSString *result = [NSString stringWithUTF8String:string];
    free(string);
    return result;
}

@end
