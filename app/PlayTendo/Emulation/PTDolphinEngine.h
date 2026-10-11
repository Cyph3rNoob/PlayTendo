#import "PTPlatform.h"
#import "PTDolphin.h"

NS_ASSUME_NONNULL_BEGIN

/// Moteur GameCube/Wii (DolphinCore.framework, tiré de DolphiniOS) : chargé et préparé à la première partie,
/// puis gardé jusqu'à la fermeture de l'app. Il dessine lui-même dans sa vue Metal et joue lui-même le son ;
/// l'app place la vue et transmet les commandes.
@interface PTDolphinEngine : NSObject

/// Moteur déjà chargé, ou nil.
@property (class, nonatomic, readonly, nullable) PTDolphinEngine *loadedEngine;

/// Charge et prépare le moteur, sur le thread principal. Les appels suivants renvoient le même moteur.
+ (nullable instancetype)loadWithFrameworkPath:(NSString *)path
                                 userDirectory:(NSString *)userDirectory
                         gameCubeSaveDirectory:(NSString *)gameCubeSaveDirectory
                              wiiSaveDirectory:(NSString *)wiiSaveDirectory
                                         error:(NSError **)error;

/// Vue Metal où le jeu est dessiné (une seule pour toute la vie de l'app).
@property (nonatomic, readonly) PTPlatformView *renderView;
@property (nonatomic, readonly) PTDolphinState state;

/// `jit` : la réserve JIT de l'app est prête (recompilateur), sinon interpréteur.
- (BOOL)bootGameAtPath:(NSString *)path jit:(BOOL)jit;
- (void)setPaused:(BOOL)paused;
- (void)stop;
- (void)reset;
- (void)setTurbo:(BOOL)enabled;
/// Commandes envoyées à la Wiimote + Nunchuk (YES) ou à la manette GameCube (NO). Relâche tout.
- (void)setWiimote:(BOOL)enabled;
/// Bouton RetroPad (PTButton).
- (void)setButton:(NSInteger)button pressed:(BOOL)pressed;
/// Stick 0 (principal ; Nunchuk) ou 1 (stick C ; pointeur de la Wiimote), de -1 à 1.
- (void)setStick:(int)stick x:(float)x y:(float)y;
/// Pointeur de la Wiimote, de -1 à 1 sur l'image.
- (void)setPointerX:(float)x y:(float)y;
/// Format de l'image en cours (largeur / hauteur), 0 s'il n'est pas encore connu.
@property (nonatomic, readonly) float aspectRatio;
/// Résolution (×1 à ×4) et lissage des bords.
- (void)setImageScale:(int)scale smoothing:(BOOL)smoothing;
/// Capture l'image suivante en PNG (bloquant, ≤ 1 s, jeu en marche seulement).
- (BOOL)captureScreenToPath:(NSString *)path;
/// Mémoire rapide disponible ; `largestBlockGB` : plus grand bloc d'adresses libre mesuré.
- (BOOL)fastmemAvailableWithLargestBlock:(float *)largestBlockGB;
/// Sauvegarde et chargement rapides : bloquants, hors du thread principal.
- (BOOL)saveStateToPath:(NSString *)path;
- (BOOL)loadStateFromPath:(NSString *)path;
- (nullable NSString *)lastError;

@end

NS_ASSUME_NONNULL_END
