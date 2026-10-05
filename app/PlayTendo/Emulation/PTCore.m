#import "PTCore.h"
#import "PTGLContext.h"
#import "libretro.h"

#import <dlfcn.h>
#import <mach/mach_time.h>
#import <stdatomic.h>

#pragma mark - Journal

static dispatch_queue_t PTLogQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("playtendo.log", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static NSFileHandle *gLogHandle;
static unsigned long long gLogBytes;

void PTLogSetFile(NSString *path) {
    dispatch_async(PTLogQueue(), ^{
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        gLogHandle = [NSFileHandle fileHandleForWritingAtPath:path];
        gLogBytes = 0;
    });
}

void PTLogLine(NSString *line) {
#if DEBUG
    NSLog(@"%@", line);
#endif
    NSDate *now = [NSDate date];
    dispatch_async(PTLogQueue(), ^{
        if (!gLogHandle || gLogBytes > 4 * 1024 * 1024) return;
        static NSDateFormatter *formatter;
        if (!formatter) {
            formatter = [NSDateFormatter new];
            formatter.dateFormat = @"HH:mm:ss.SSS";
        }
        NSString *text = [NSString stringWithFormat:@"%@ %@\n", [formatter stringFromDate:now], line];
        NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
        [gLogHandle writeData:data];
        gLogBytes += data.length;
    });
}

#pragma mark - Tampon audio

struct PTAudioRing {
    int16_t *buffer;
    size_t capacity;
    _Atomic size_t readPosition;
    _Atomic size_t writePosition;
};

PTAudioRing *PTAudioRingCreate(size_t capacityFrames) {
    PTAudioRing *ring = calloc(1, sizeof(PTAudioRing));
    ring->buffer = calloc(capacityFrames * 2, sizeof(int16_t));
    ring->capacity = capacityFrames;
    atomic_init(&ring->readPosition, 0);
    atomic_init(&ring->writePosition, 0);
    return ring;
}

void PTAudioRingDestroy(PTAudioRing *ring) {
    if (!ring) return;
    free(ring->buffer);
    free(ring);
}

size_t PTAudioRingWrite(PTAudioRing *ring, const int16_t *interleaved, size_t frames) {
    size_t read = atomic_load_explicit(&ring->readPosition, memory_order_acquire);
    size_t write = atomic_load_explicit(&ring->writePosition, memory_order_relaxed);
    size_t space = ring->capacity - (write - read);
    size_t count = MIN(frames, space);
    for (size_t i = 0; i < count; i++) {
        size_t index = ((write + i) % ring->capacity) * 2;
        ring->buffer[index] = interleaved[i * 2];
        ring->buffer[index + 1] = interleaved[i * 2 + 1];
    }
    atomic_store_explicit(&ring->writePosition, write + count, memory_order_release);
    return count;
}

size_t PTAudioRingRead(PTAudioRing *ring, float *left, float *right, size_t frames) {
    size_t write = atomic_load_explicit(&ring->writePosition, memory_order_acquire);
    size_t read = atomic_load_explicit(&ring->readPosition, memory_order_relaxed);
    size_t count = MIN(frames, write - read);
    const float scale = 1.0f / 32768.0f;
    for (size_t i = 0; i < count; i++) {
        size_t index = ((read + i) % ring->capacity) * 2;
        left[i] = ring->buffer[index] * scale;
        right[i] = ring->buffer[index + 1] * scale;
    }
    for (size_t i = count; i < frames; i++) {
        left[i] = 0;
        right[i] = 0;
    }
    atomic_store_explicit(&ring->readPosition, read + count, memory_order_release);
    return count;
}

size_t PTAudioRingFill(PTAudioRing *ring) {
    size_t write = atomic_load_explicit(&ring->writePosition, memory_order_acquire);
    size_t read = atomic_load_explicit(&ring->readPosition, memory_order_acquire);
    return write - read;
}

size_t PTAudioRingCapacity(PTAudioRing *ring) {
    return ring->capacity;
}

#pragma mark - Moteur

typedef struct {
    void (*set_environment)(retro_environment_t);
    void (*set_video_refresh)(retro_video_refresh_t);
    void (*set_audio_sample)(retro_audio_sample_t);
    void (*set_audio_sample_batch)(retro_audio_sample_batch_t);
    void (*set_input_poll)(retro_input_poll_t);
    void (*set_input_state)(retro_input_state_t);
    void (*init)(void);
    void (*deinit)(void);
    unsigned (*api_version)(void);
    void (*get_system_info)(struct retro_system_info *);
    void (*get_system_av_info)(struct retro_system_av_info *);
    void (*set_controller_port_device)(unsigned, unsigned);
    void (*reset)(void);
    void (*run)(void);
    size_t (*serialize_size)(void);
    bool (*serialize)(void *, size_t);
    bool (*unserialize)(const void *, size_t);
    bool (*load_game)(const struct retro_game_info *);
    void (*unload_game)(void);
    void *(*get_memory_data)(unsigned);
    size_t (*get_memory_size)(unsigned);
} PTCoreAPI;

#define PT_ENV(cmd) ((cmd) & ~RETRO_ENVIRONMENT_EXPERIMENTAL)

static PTCore *gCore;

@implementation PTCore {
    void *_handle;
    PTCoreAPI _api;
    char *_libraryPath;
    char *_systemDirectory;
    char *_saveDirectory;
    char *_gamePath;
    char *_gameDirectory;
    char *_gameName;
    char *_gameExtension;
    NSData *_gameData;
    struct retro_game_info_ext _gameInfoExt;
    BOOL _gameLoaded;
    BOOL _initialized;

    enum retro_pixel_format _pixelFormat;

    NSMutableDictionary<NSString *, NSString *> *_optionDefaults;
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *_optionValues;
    NSMutableDictionary<NSString *, NSString *> *_optionOverrides;
    BOOL _optionsDirty;
    NSMutableDictionary<NSString *, NSData *> *_optionCStrings;

    struct retro_disk_control_ext_callback _disk;
    BOOL _hasDiskControl;

    // Rendu 3D (OpenGL ES) demandé par le moteur.
    struct retro_hw_render_callback _hw;
    BOOL _hwRequested;
    PTGLContext *_gl;
    unsigned _pendingGLWidth;
    unsigned _pendingGLHeight;

    _Atomic uint32_t _buttons[2];
    _Atomic int32_t _analog[2][2][2];
    _Atomic int32_t _pointerX;
    _Atomic int32_t _pointerY;
    _Atomic int32_t _pointerPressed;
}

#pragma mark Callbacks C

static void PTCoreLog(enum retro_log_level level, const char *fmt, ...) {
    if (level < RETRO_LOG_INFO) return;
    char buffer[2048];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buffer, sizeof buffer, fmt, args);
    va_end(args);
    size_t length = strlen(buffer);
    while (length > 0 && (buffer[length - 1] == '\n' || buffer[length - 1] == '\r')) buffer[--length] = 0;
    static const char *levels[] = {"debug", "info", "attention", "erreur"};
    NSString *name = gCore ? gCore.libraryName : @"moteur";
    PTLogLine([NSString stringWithFormat:@"[%@ %s] %s", name, levels[MIN(level, 3)], buffer]);
}

static bool PTEnvironment(unsigned cmd, void *data) {
    PTCore *core = gCore;
    return core ? [core handleEnvironment:cmd data:data] : false;
}

static void PTVideoRefresh(const void *data, unsigned width, unsigned height, size_t pitch) {
    PTCore *core = gCore;
    if (!core || !data) return;
    if (data == RETRO_HW_FRAME_BUFFER_VALID) {
        PTHardwareVideoHandler handler = core->_hardwareVideoHandler;
        if (core->_gl && handler && width > 0 && height > 0) {
            handler([core->_gl finishFrame], MIN(width, core->_gl.width), MIN(height, core->_gl.height),
                    core->_hw.bottom_left_origin);
        }
        return;
    }
    PTVideoHandler handler = core->_videoHandler;
    if (handler) handler(data, width, height, pitch, (PTPixelFormat)core->_pixelFormat);
}

static size_t PTAudioSampleBatch(const int16_t *data, size_t frames) {
    PTCore *core = gCore;
    if (!core || !data) return frames;
    PTAudioHandler handler = core->_audioHandler;
    if (handler) handler(data, frames);
    return frames;
}

static void PTAudioSample(int16_t left, int16_t right) {
    int16_t frame[2] = {left, right};
    PTAudioSampleBatch(frame, 1);
}

static void PTInputPoll(void) {}

static int16_t PTInputState(unsigned port, unsigned device, unsigned index, unsigned identifier) {
    PTCore *core = gCore;
    if (!core || port > 1) return 0;
    switch (device & RETRO_DEVICE_MASK) {
        case RETRO_DEVICE_JOYPAD: {
            uint32_t bits = atomic_load_explicit(&core->_buttons[port], memory_order_relaxed);
            if (identifier == RETRO_DEVICE_ID_JOYPAD_MASK) return (int16_t)(bits & 0xFFFF);
            return identifier < 16 ? (int16_t)((bits >> identifier) & 1) : 0;
        }
        case RETRO_DEVICE_ANALOG:
            if (index < 2 && identifier < 2) {
                return (int16_t)atomic_load_explicit(&core->_analog[port][index][identifier], memory_order_relaxed);
            }
            return 0;
        case RETRO_DEVICE_POINTER:
            if (port != 0 || index != 0) return 0;
            switch (identifier) {
                case RETRO_DEVICE_ID_POINTER_X: return (int16_t)atomic_load_explicit(&core->_pointerX, memory_order_relaxed);
                case RETRO_DEVICE_ID_POINTER_Y: return (int16_t)atomic_load_explicit(&core->_pointerY, memory_order_relaxed);
                case RETRO_DEVICE_ID_POINTER_PRESSED:
                case RETRO_DEVICE_ID_POINTER_COUNT:
                    return (int16_t)atomic_load_explicit(&core->_pointerPressed, memory_order_relaxed);
            }
            return 0;
    }
    return 0;
}

static retro_time_t PTPerfTimeUsec(void) {
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) mach_timebase_info(&timebase);
    return (retro_time_t)(mach_absolute_time() * timebase.numer / timebase.denom / 1000);
}

static uint64_t PTPerfCPUFeatures(void) { return RETRO_SIMD_NEON | RETRO_SIMD_ASIMD; }
static retro_perf_tick_t PTPerfCounter(void) { return mach_absolute_time(); }
static void PTPerfRegister(struct retro_perf_counter *counter) { counter->registered = true; }
static void PTPerfStart(struct retro_perf_counter *counter) {}
static void PTPerfStop(struct retro_perf_counter *counter) {}
static void PTPerfLog(void) {}
static bool PTSetRumble(unsigned port, enum retro_rumble_effect effect, uint16_t strength) { return false; }

static uintptr_t PTHardwareFramebuffer(void) {
    PTCore *core = gCore;
    return (core && core->_gl) ? core->_gl.framebuffer : 0;
}

static retro_proc_address_t PTHardwareProcAddress(const char *symbol) {
    return (retro_proc_address_t)dlsym(RTLD_DEFAULT, symbol);
}

#pragma mark Chargement du moteur

- (instancetype)initWithLibraryPath:(NSString *)path error:(NSError **)error {
    self = [super init];
    if (!self) return nil;

    _handle = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
    if (!_handle) {
        return [self failWithMessage:[NSString stringWithFormat:@"Impossible de charger le moteur : %s", dlerror()] error:error];
    }

#define PT_LOAD(name) \
    _api.name = dlsym(_handle, "retro_" #name); \
    if (!_api.name) return [self failWithMessage:@"Fonction manquante dans le moteur : retro_" #name error:error];

    PT_LOAD(set_environment)
    PT_LOAD(set_video_refresh)
    PT_LOAD(set_audio_sample)
    PT_LOAD(set_audio_sample_batch)
    PT_LOAD(set_input_poll)
    PT_LOAD(set_input_state)
    PT_LOAD(init)
    PT_LOAD(deinit)
    PT_LOAD(api_version)
    PT_LOAD(get_system_info)
    PT_LOAD(get_system_av_info)
    PT_LOAD(set_controller_port_device)
    PT_LOAD(reset)
    PT_LOAD(run)
    PT_LOAD(serialize_size)
    PT_LOAD(serialize)
    PT_LOAD(unserialize)
    PT_LOAD(load_game)
    PT_LOAD(unload_game)
    PT_LOAD(get_memory_data)
    PT_LOAD(get_memory_size)
#undef PT_LOAD

    if (_api.api_version() != RETRO_API_VERSION) {
        return [self failWithMessage:@"Version d'API libretro incompatible." error:error];
    }

    struct retro_system_info info = {0};
    _api.get_system_info(&info);
    _libraryName = info.library_name ? @(info.library_name) : @"?";
    _libraryVersion = info.library_version ? @(info.library_version) : @"?";
    _libraryPath = strdup(path.fileSystemRepresentation);
    _pixelFormat = RETRO_PIXEL_FORMAT_0RGB1555;
    _aspectRatio = 4.0f / 3.0f;
    _framesPerSecond = 60;
    _sampleRate = 44100;
    return self;
}

- (id)failWithMessage:(NSString *)message error:(NSError **)error {
    PTLogLine(message);
    if (error) *error = [NSError errorWithDomain:@"PlayTendo" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
    return nil;
}

- (void)dealloc {
    free(_libraryPath);
    [self freeGameStrings];
    // Le moteur n'est jamais déchargé (dlclose) : certains n'aiment pas être rechargés.
}

- (void)freeGameStrings {
    free(_systemDirectory); _systemDirectory = NULL;
    free(_saveDirectory); _saveDirectory = NULL;
    free(_gamePath); _gamePath = NULL;
    free(_gameDirectory); _gameDirectory = NULL;
    free(_gameName); _gameName = NULL;
    free(_gameExtension); _gameExtension = NULL;
}

#pragma mark Chargement du jeu

- (BOOL)loadGameAtPath:(NSString *)path
       systemDirectory:(NSString *)systemDirectory
         saveDirectory:(NSString *)saveDirectory
               options:(NSDictionary<NSString *, NSString *> *)options
                 error:(NSError **)error {
    if (gCore && gCore != self) [gCore unloadGame];

    [self freeGameStrings];
    _systemDirectory = strdup(systemDirectory.fileSystemRepresentation);
    _saveDirectory = strdup(saveDirectory.fileSystemRepresentation);
    _gamePath = strdup(path.fileSystemRepresentation);
    _gameDirectory = strdup(path.stringByDeletingLastPathComponent.fileSystemRepresentation);
    _gameName = strdup(path.lastPathComponent.stringByDeletingPathExtension.UTF8String);
    _gameExtension = strdup(path.pathExtension.lowercaseString.UTF8String);

    _optionDefaults = [NSMutableDictionary dictionary];
    _optionValues = [NSMutableDictionary dictionary];
    _optionCStrings = [NSMutableDictionary dictionary];
    _optionOverrides = [options mutableCopy];
    _optionsDirty = NO;
    _hasDiskControl = NO;
    _hwRequested = NO;
    _gl = nil;
    _pendingGLWidth = 0;
    _pendingGLHeight = 0;
    memset(&_hw, 0, sizeof _hw);
    _shutdownRequested = NO;
    _pixelFormat = RETRO_PIXEL_FORMAT_0RGB1555;
    [self clearInput];

    // Même ordre que RetroArch : environnement, initialisation, puis les autres
    // fonctions de rappel (certains moteurs, comme Mesen, en dépendent).
    gCore = self;
    _api.set_environment(PTEnvironment);
    _api.init();
    _initialized = YES;
    _api.set_video_refresh(PTVideoRefresh);
    _api.set_audio_sample(PTAudioSample);
    _api.set_audio_sample_batch(PTAudioSampleBatch);
    _api.set_input_poll(PTInputPoll);
    _api.set_input_state(PTInputState);

    struct retro_system_info info = {0};
    _api.get_system_info(&info);

    _gameData = nil;
    if (!info.need_fullpath) {
        NSError *readError = nil;
        _gameData = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:&readError];
        if (!_gameData) {
            [self unloadGame];
            return [self failWithMessage:[NSString stringWithFormat:@"Lecture du jeu impossible : %@", readError.localizedDescription] error:error] != nil;
        }
    }

    _gameInfoExt = (struct retro_game_info_ext){
        .full_path = _gamePath,
        .dir = _gameDirectory,
        .name = _gameName,
        .ext = _gameExtension,
        .data = _gameData.bytes,
        .size = _gameData.length,
        .persistent_data = true,
    };

    struct retro_game_info game = {
        .path = _gamePath,
        .data = _gameData.bytes,
        .size = _gameData.length,
        .meta = NULL,
    };

    PTLogLine([NSString stringWithFormat:@"Chargement de « %@ » avec %@ %@", path.lastPathComponent, _libraryName, _libraryVersion]);
    if (!_api.load_game(&game)) {
        [self unloadGame];
        return [self failWithMessage:@"Le moteur n'a pas réussi à charger ce jeu (fichier incompatible ou incomplet ?)." error:error] != nil;
    }
    _gameLoaded = YES;

    struct retro_system_av_info av = {0};
    _api.get_system_av_info(&av);
    [self applyGeometry:&av.geometry];
    [self applyTiming:&av.timing];

    if (_hwRequested) {
        // Le moteur dessine en 3D : on lui prépare son contexte OpenGL ES puis on le prévient.
        unsigned width = MAX(MAX(av.geometry.max_width, av.geometry.base_width), 64);
        unsigned height = MAX(MAX(av.geometry.max_height, av.geometry.base_height), 64);
        _gl = [[PTGLContext alloc] initWithWidth:width height:height];
        if (!_gl) {
            [self unloadGame];
            return [self failWithMessage:@"Affichage 3D (OpenGL ES) indisponible pour ce moteur." error:error] != nil;
        }
        [_gl makeCurrent];
        PTLogLine([NSString stringWithFormat:@"Rendu 3D OpenGL ES prêt (%u×%u)", width, height]);
        if (_hw.context_reset) _hw.context_reset();
    }
    _api.set_controller_port_device(0, RETRO_DEVICE_JOYPAD);
    PTLogLine([NSString stringWithFormat:@"Jeu chargé : %u×%u, %.3f images/s, son %.0f Hz",
               av.geometry.base_width, av.geometry.base_height, _framesPerSecond, _sampleRate]);
    return YES;
}

- (BOOL)usesHardwareRendering {
    return _gl != nil;
}

- (void)applyGeometry:(const struct retro_game_geometry *)geometry {
    if (_gl && (geometry->max_width > _gl.width || geometry->max_height > _gl.height)) {
        // Agrandi après l'image en cours (on ne touche pas aux tampons pendant que le moteur dessine).
        _pendingGLWidth = MAX(geometry->max_width, _pendingGLWidth);
        _pendingGLHeight = MAX(geometry->max_height, _pendingGLHeight);
    }
    if (geometry->aspect_ratio > 0) {
        _aspectRatio = geometry->aspect_ratio;
    } else if (geometry->base_height > 0) {
        _aspectRatio = (float)geometry->base_width / (float)geometry->base_height;
    }
}

- (void)applyTiming:(const struct retro_system_timing *)timing {
    if (timing->fps > 0) _framesPerSecond = timing->fps;
    if (timing->sample_rate > 0) _sampleRate = timing->sample_rate;
}

- (void)updateOptions:(NSDictionary<NSString *, NSString *> *)options {
    if (options.count == 0) return;
    [_optionOverrides addEntriesFromDictionary:options];
    _optionsDirty = YES;
}

- (void)runFrame {
    if (!_gameLoaded) return;
    _api.run();
    if (_gl && (_pendingGLWidth || _pendingGLHeight)) {
        [_gl ensureWidth:_pendingGLWidth height:_pendingGLHeight];
        _pendingGLWidth = 0;
        _pendingGLHeight = 0;
    }
}

- (void)reset {
    if (_gameLoaded) _api.reset();
}

- (void)unloadGame {
    if (_gl) {
        [_gl makeCurrent];
        if (_hw.context_destroy) _hw.context_destroy();
    }
    if (_gameLoaded) _api.unload_game();
    _gameLoaded = NO;
    if (_initialized) _api.deinit();
    _initialized = NO;
    _gameData = nil;
    _gl = nil;
    _hwRequested = NO;
    if (gCore == self) gCore = nil;
}

#pragma mark Sauvegardes

- (NSData *)saveState {
    if (!_gameLoaded) return nil;
    size_t size = _api.serialize_size();
    if (size == 0) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:size];
    return _api.serialize(data.mutableBytes, size) ? data : nil;
}

- (BOOL)loadState:(NSData *)state {
    return _gameLoaded && _api.unserialize(state.bytes, state.length);
}

- (NSData *)saveRAM {
    if (!_gameLoaded) return nil;
    size_t size = _api.get_memory_size(RETRO_MEMORY_SAVE_RAM);
    void *bytes = _api.get_memory_data(RETRO_MEMORY_SAVE_RAM);
    return (size > 0 && bytes) ? [NSData dataWithBytes:bytes length:size] : nil;
}

- (void)restoreSaveRAM:(NSData *)data {
    if (!_gameLoaded) return;
    size_t size = _api.get_memory_size(RETRO_MEMORY_SAVE_RAM);
    void *bytes = _api.get_memory_data(RETRO_MEMORY_SAVE_RAM);
    if (size > 0 && bytes) memcpy(bytes, data.bytes, MIN(size, data.length));
}

- (NSData *)systemRAM {
    if (!_gameLoaded) return nil;
    size_t size = _api.get_memory_size(RETRO_MEMORY_SYSTEM_RAM);
    void *bytes = _api.get_memory_data(RETRO_MEMORY_SYSTEM_RAM);
    return (size > 0 && bytes) ? [NSData dataWithBytes:bytes length:size] : nil;
}

#pragma mark Disques

- (NSUInteger)diskCount {
    return (_hasDiskControl && _disk.get_num_images) ? _disk.get_num_images() : 0;
}

- (NSUInteger)currentDiskIndex {
    return (_hasDiskControl && _disk.get_image_index) ? _disk.get_image_index() : 0;
}

- (BOOL)switchToNextDisk {
    NSUInteger count = self.diskCount;
    if (count < 2 || !_disk.set_eject_state || !_disk.set_image_index) return NO;
    unsigned next = (unsigned)((self.currentDiskIndex + 1) % count);
    _disk.set_eject_state(true);
    BOOL ok = _disk.set_image_index(next);
    _disk.set_eject_state(false);
    PTLogLine([NSString stringWithFormat:@"Changement de disque → %u/%lu", next + 1, (unsigned long)count]);
    return ok;
}

#pragma mark Entrées

- (void)setButton:(PTButton)button pressed:(BOOL)pressed port:(unsigned)port {
    if (port > 1 || button < 0 || button > 15) return;
    uint32_t mask = 1u << button;
    if (pressed) atomic_fetch_or_explicit(&_buttons[port], mask, memory_order_relaxed);
    else atomic_fetch_and_explicit(&_buttons[port], ~mask, memory_order_relaxed);
}

- (void)setAnalogStick:(unsigned)stick x:(int16_t)x y:(int16_t)y port:(unsigned)port {
    if (port > 1 || stick > 1) return;
    atomic_store_explicit(&_analog[port][stick][0], x, memory_order_relaxed);
    atomic_store_explicit(&_analog[port][stick][1], y, memory_order_relaxed);
}

- (void)setPointerX:(int16_t)x y:(int16_t)y pressed:(BOOL)pressed {
    atomic_store_explicit(&_pointerX, x, memory_order_relaxed);
    atomic_store_explicit(&_pointerY, y, memory_order_relaxed);
    atomic_store_explicit(&_pointerPressed, pressed ? 1 : 0, memory_order_relaxed);
}

- (void)clearInput {
    for (int port = 0; port < 2; port++) {
        atomic_store(&_buttons[port], 0);
        for (int stick = 0; stick < 2; stick++) {
            atomic_store(&_analog[port][stick][0], 0);
            atomic_store(&_analog[port][stick][1], 0);
        }
    }
    atomic_store(&_pointerPressed, 0);
}

#pragma mark Options des moteurs

- (void)registerOption:(const char *)key defaultValue:(const char *)defaultValue values:(NSArray<NSString *> *)values {
    if (!key) return;
    NSString *name = @(key);
    NSString *fallback = defaultValue ? @(defaultValue) : values.firstObject;
    if (fallback) _optionDefaults[name] = fallback;
    _optionValues[name] = values;
}

- (void)registerValues:(const struct retro_core_option_value *)values key:(const char *)key defaultValue:(const char *)defaultValue {
    NSMutableArray<NSString *> *list = [NSMutableArray array];
    for (int i = 0; i < RETRO_NUM_CORE_OPTION_VALUES_MAX && values[i].value; i++) {
        [list addObject:@(values[i].value)];
    }
    [self registerOption:key defaultValue:defaultValue values:list];
}

- (void)registerOptionsV1:(const struct retro_core_option_definition *)definitions {
    for (; definitions && definitions->key; definitions++) {
        [self registerValues:definitions->values key:definitions->key defaultValue:definitions->default_value];
    }
}

- (void)registerOptionsV2:(const struct retro_core_options_v2 *)options {
    if (!options) return;
    for (const struct retro_core_option_v2_definition *d = options->definitions; d && d->key; d++) {
        [self registerValues:d->values key:d->key defaultValue:d->default_value];
    }
}

- (void)registerLegacyVariables:(const struct retro_variable *)variables {
    for (; variables && variables->key; variables++) {
        // Format : "Description; valeur1|valeur2|…" — la première valeur est celle par défaut.
        NSString *text = variables->value ? @(variables->value) : @"";
        NSRange separator = [text rangeOfString:@"; "];
        NSString *list = separator.location == NSNotFound ? text : [text substringFromIndex:NSMaxRange(separator)];
        NSArray<NSString *> *values = [list componentsSeparatedByString:@"|"];
        [self registerOption:variables->key defaultValue:NULL values:values];
    }
}

- (const char *)optionValueForKey:(const char *)key {
    if (!key) return NULL;
    NSString *name = @(key);
    NSString *value = _optionOverrides[name];
    NSArray<NSString *> *allowed = _optionValues[name];
    if (value && allowed.count > 0 && ![allowed containsObject:value]) value = nil;
    if (!value) value = _optionDefaults[name];
    if (!value) return NULL;
    NSMutableData *cString = [[value dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [cString appendBytes:"\0" length:1];
    _optionCStrings[name] = cString;
    return cString.bytes;
}

#pragma mark Environnement libretro

- (bool)handleEnvironment:(unsigned)cmd data:(void *)data {
    switch (PT_ENV(cmd)) {
        case PT_ENV(RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY):
        case PT_ENV(RETRO_ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY):
            *(const char **)data = _systemDirectory;
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY):
            *(const char **)data = _saveDirectory;
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_GET_LIBRETRO_PATH):
            *(const char **)data = _libraryPath;
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT): {
            enum retro_pixel_format format = *(const enum retro_pixel_format *)data;
            if (format > RETRO_PIXEL_FORMAT_RGB565) return false;
            _pixelFormat = format;
            return true;
        }
        case PT_ENV(RETRO_ENVIRONMENT_GET_LOG_INTERFACE):
            ((struct retro_log_callback *)data)->log = PTCoreLog;
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_GET_CAN_DUPE):
            *(bool *)data = true;
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_GET_VARIABLE): {
            struct retro_variable *variable = data;
            variable->value = [self optionValueForKey:variable->key];
            return variable->value != NULL;
        }
        case PT_ENV(RETRO_ENVIRONMENT_SET_VARIABLES):
            [self registerLegacyVariables:data];
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE):
            *(bool *)data = _optionsDirty;
            _optionsDirty = NO;
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION):
            *(unsigned *)data = 2;
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_SET_CORE_OPTIONS):
            [self registerOptionsV1:data];
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL):
            [self registerOptionsV1:((const struct retro_core_options_intl *)data)->us];
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2):
            [self registerOptionsV2:data];
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL):
            [self registerOptionsV2:((const struct retro_core_options_v2_intl *)data)->us];
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY):
        case PT_ENV(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK):
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO): {
            const struct retro_system_av_info *av = data;
            [self applyGeometry:&av->geometry];
            [self applyTiming:&av->timing];
            return true;
        }
        case PT_ENV(RETRO_ENVIRONMENT_SET_GEOMETRY):
            [self applyGeometry:data];
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_GET_INPUT_BITMASKS):
        case PT_ENV(RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME):
        case PT_ENV(RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL):
        case PT_ENV(RETRO_ENVIRONMENT_SET_SERIALIZATION_QUIRKS):
        case PT_ENV(RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS):
        case PT_ENV(RETRO_ENVIRONMENT_SET_CONTROLLER_INFO):
        case PT_ENV(RETRO_ENVIRONMENT_SET_MEMORY_MAPS):
        case PT_ENV(RETRO_ENVIRONMENT_SET_SUBSYSTEM_INFO):
        case PT_ENV(RETRO_ENVIRONMENT_SET_CONTENT_INFO_OVERRIDE):
        case PT_ENV(RETRO_ENVIRONMENT_SET_SUPPORT_ACHIEVEMENTS):
        case PT_ENV(RETRO_ENVIRONMENT_SET_KEYBOARD_CALLBACK):
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_GET_LANGUAGE):
            *(unsigned *)data = RETRO_LANGUAGE_FRENCH;
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_GET_USERNAME):
            *(const char **)data = "PlayTendo";
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_GET_PERF_INTERFACE): {
            struct retro_perf_callback *perf = data;
            perf->get_time_usec = PTPerfTimeUsec;
            perf->get_cpu_features = PTPerfCPUFeatures;
            perf->get_perf_counter = PTPerfCounter;
            perf->perf_register = PTPerfRegister;
            perf->perf_start = PTPerfStart;
            perf->perf_stop = PTPerfStop;
            perf->perf_log = PTPerfLog;
            return true;
        }
        case PT_ENV(RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE):
            ((struct retro_rumble_interface *)data)->set_rumble_state = PTSetRumble;
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_SET_MESSAGE): {
            const struct retro_message *message = data;
            if (message->msg) PTLogLine([NSString stringWithFormat:@"[%@ message] %s", _libraryName, message->msg]);
            return true;
        }
        case PT_ENV(RETRO_ENVIRONMENT_SET_MESSAGE_EXT): {
            const struct retro_message_ext *message = data;
            if (message->msg) PTLogLine([NSString stringWithFormat:@"[%@ message] %s", _libraryName, message->msg]);
            return true;
        }
        case PT_ENV(RETRO_ENVIRONMENT_GET_MESSAGE_INTERFACE_VERSION):
            *(unsigned *)data = 1;
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_GET_GAME_INFO_EXT):
            *(const struct retro_game_info_ext **)data = &_gameInfoExt;
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE):
            if (data) *(int *)data = 3;
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_GET_FASTFORWARDING):
            *(bool *)data = false;
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_GET_INPUT_MAX_USERS):
            *(unsigned *)data = 2;
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_GET_DISK_CONTROL_INTERFACE_VERSION):
            *(unsigned *)data = 1;
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE):
            memset(&_disk, 0, sizeof _disk);
            memcpy(&_disk, data, sizeof(struct retro_disk_control_callback));
            _hasDiskControl = YES;
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE):
            memcpy(&_disk, data, sizeof _disk);
            _hasDiskControl = YES;
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_GET_OVERSCAN):
            *(bool *)data = false;
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_GET_SAVESTATE_CONTEXT):
            *(int *)data = RETRO_SAVESTATE_CONTEXT_NORMAL;
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_GET_JIT_CAPABLE):
            *(bool *)data = false;
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_SET_HW_RENDER): {
            struct retro_hw_render_callback *callback = data;
            BOOL supported = callback->context_type == RETRO_HW_CONTEXT_OPENGLES2
                || callback->context_type == RETRO_HW_CONTEXT_OPENGLES3
                || (callback->context_type == RETRO_HW_CONTEXT_OPENGLES_VERSION && callback->version_major <= 3);
#if !TARGET_OS_IOS
            supported = NO;
#endif
            if (!supported) {
                PTLogLine([NSString stringWithFormat:@"[%@] type d'affichage 3D refusé (%d)", _libraryName, callback->context_type]);
                return false;
            }
            callback->get_current_framebuffer = PTHardwareFramebuffer;
            callback->get_proc_address = PTHardwareProcAddress;
            _hw = *callback;
            _hwRequested = YES;
            return true;
        }
        case PT_ENV(RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER):
            *(unsigned *)data = RETRO_HW_CONTEXT_OPENGLES3;
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_SET_HW_SHARED_CONTEXT):
            return true;
        case PT_ENV(RETRO_ENVIRONMENT_SHUTDOWN):
            _shutdownRequested = YES;
            return true;
        default:
            return false;
    }
}

@end
