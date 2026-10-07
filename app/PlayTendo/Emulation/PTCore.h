// PTCore : pilote un moteur d'émulation libretro (chargé depuis un framework).
// Un seul moteur peut tourner à la fois. Toutes les méthodes, sauf celles des
// entrées (boutons, sticks, pointeur), doivent être appelées depuis le même thread.

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PTPixelFormat) {
    PTPixelFormatXRGB1555 NS_SWIFT_NAME(xrgb1555) = 0,
    PTPixelFormatXRGB8888 NS_SWIFT_NAME(xrgb8888) = 1,
    PTPixelFormatRGB565 NS_SWIFT_NAME(rgb565) = 2,
};

/// Boutons de la manette virtuelle libretro (« RetroPad »).
typedef NS_ENUM(NSInteger, PTButton) {
    PTButtonB NS_SWIFT_NAME(b) = 0,
    PTButtonY NS_SWIFT_NAME(y) = 1,
    PTButtonSelect NS_SWIFT_NAME(select) = 2,
    PTButtonStart NS_SWIFT_NAME(start) = 3,
    PTButtonUp NS_SWIFT_NAME(up) = 4,
    PTButtonDown NS_SWIFT_NAME(down) = 5,
    PTButtonLeft NS_SWIFT_NAME(left) = 6,
    PTButtonRight NS_SWIFT_NAME(right) = 7,
    PTButtonA NS_SWIFT_NAME(a) = 8,
    PTButtonX NS_SWIFT_NAME(x) = 9,
    PTButtonL NS_SWIFT_NAME(l) = 10,
    PTButtonR NS_SWIFT_NAME(r) = 11,
    PTButtonL2 NS_SWIFT_NAME(l2) = 12,
    PTButtonR2 NS_SWIFT_NAME(r2) = 13,
    PTButtonL3 NS_SWIFT_NAME(l3) = 14,
    PTButtonR3 NS_SWIFT_NAME(r3) = 15,
};

typedef void (^PTVideoHandler)(const void *pixels, unsigned width, unsigned height, size_t pitch, PTPixelFormat format);
typedef void (^PTAudioHandler)(const int16_t *samples, size_t frames);
/// Image dessinée en 3D (OpenGL ES) : `width`×`height` en haut à gauche du tampon,
/// à l'envers verticalement si `flipped`.
typedef void (^PTHardwareVideoHandler)(CVPixelBufferRef buffer, unsigned width, unsigned height, BOOL flipped);

@interface PTCore : NSObject

- (nullable instancetype)initWithLibraryPath:(NSString *)path error:(NSError **)error;

@property (nonatomic, readonly) NSString *libraryName;
@property (nonatomic, readonly) NSString *libraryVersion;

@property (nonatomic, copy, nullable) PTVideoHandler videoHandler;
@property (nonatomic, copy, nullable) PTAudioHandler audioHandler;
@property (nonatomic, copy, nullable) PTHardwareVideoHandler hardwareVideoHandler;
/// Vrai si le moteur dessine en 3D avec OpenGL ES.
/// Le moteur peut se servir de la réserve JIT de l'app (à régler avant le chargement du jeu).
@property (nonatomic) BOOL allowsJIT;
/// Le moteur dessine avec Vulkan (3DS, par MoltenVK) plutôt qu'OpenGL ES (à régler avant le chargement du jeu).
@property (nonatomic) BOOL prefersVulkan;

/// Renseignés après le chargement du jeu (et mis à jour si le moteur les change).
@property (nonatomic, readonly) double framesPerSecond;
@property (nonatomic, readonly) double sampleRate;
@property (nonatomic, readonly) float aspectRatio;
@property (nonatomic, readonly) BOOL shutdownRequested;

- (BOOL)loadGameAtPath:(NSString *)path
       systemDirectory:(NSString *)systemDirectory
         saveDirectory:(NSString *)saveDirectory
               options:(NSDictionary<NSString *, NSString *> *)options
                 error:(NSError **)error;
- (void)runFrame;
/// Change des réglages du moteur en cours de partie (le moteur les relit à l'image suivante).
- (void)updateOptions:(NSDictionary<NSString *, NSString *> *)options;
- (void)reset;
- (void)unloadGame;

/// Sauvegarde d'état (« save state »).
- (nullable NSData *)saveState;
- (BOOL)loadState:(NSData *)state;

/// Mémoire de sauvegarde de la cartouche (piles de sauvegarde, cartes mémoire…).
- (nullable NSData *)saveRAM;
- (void)restoreSaveRAM:(NSData *)data;

/// Mémoire vive de la console émulée (débogage, codes de triche).
/// Mémoire vive de la console (utilisée par le banc d'essai Mac, scripts/test/harness.m).
- (nullable NSData *)systemRAM;

/// Jeux sur plusieurs disques (PlayStation).
@property (nonatomic, readonly) NSUInteger diskCount;
@property (nonatomic, readonly) NSUInteger currentDiskIndex;
- (BOOL)switchToNextDisk;

/// Entrées — utilisables depuis n'importe quel thread.
- (void)setButton:(PTButton)button pressed:(BOOL)pressed port:(unsigned)port;
- (void)setAnalogStick:(unsigned)stick x:(int16_t)x y:(int16_t)y port:(unsigned)port;
- (void)setPointerX:(int16_t)x y:(int16_t)y pressed:(BOOL)pressed;
- (void)clearInput;

@end

/// Journal partagé (fichier Documents/Journal.txt).
void PTLogLine(NSString *line);
void PTLogSetFile(NSString *path);
/// Attend que les lignes en attente soient écrites sur le disque (avant une étape qui peut tuer l'app).
void PTLogFlush(void);

/// Tampon audio circulaire sans verrou (un producteur, un consommateur).
typedef struct PTAudioRing PTAudioRing;
PTAudioRing *PTAudioRingCreate(size_t capacityFrames);
void PTAudioRingDestroy(PTAudioRing *ring);
size_t PTAudioRingWrite(PTAudioRing *ring, const int16_t *interleaved, size_t frames);
size_t PTAudioRingRead(PTAudioRing *ring, float *left, float *right, size_t frames);
size_t PTAudioRingFill(PTAudioRing *ring);

NS_ASSUME_NONNULL_END
