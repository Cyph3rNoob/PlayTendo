#import "PTPlatform.h"
#import "PTPS2.h"

NS_ASSUME_NONNULL_BEGIN

/// Moteur PS2 (PS2Core.framework, tiré d'ARMSX2) : chargé et préparé à la première partie PS2, puis gardé
/// jusqu'à la fermeture de l'app (son thread de console est permanent). Il dessine lui-même dans sa vue Metal
/// et joue lui-même le son ; l'app place la vue et transmet les commandes.
@interface PTPS2Engine : NSObject

/// Moteur déjà chargé, ou nil.
@property (class, nonatomic, readonly, nullable) PTPS2Engine *loadedEngine;

/// Charge et prépare le moteur, sur le thread principal. Les appels suivants renvoient le même moteur.
+ (nullable instancetype)loadWithFrameworkPath:(NSString *)path
                                      dataRoot:(NSString *)dataRoot
                                 biosDirectory:(NSString *)biosDirectory
                           memoryCardDirectory:(NSString *)memoryCardDirectory
                                         error:(NSError **)error;

/// Vue Metal où la PS2 dessine (une seule pour toute la vie de l'app).
@property (nonatomic, readonly) PTPlatformView *renderView;
@property (nonatomic, readonly) PTPS2State state;

/// Nom du BIOS PS2 retenu dans le dossier des BIOS, ou nil s'il n'y en a pas.
- (nullable NSString *)pickBIOS;
- (BOOL)bootGameAtPath:(NSString *)path;
- (void)setPaused:(BOOL)paused;
- (void)stop;
- (void)reset;
/// Rend la mémoire de la console PS2 en veille (avant de lancer une autre console). Bloquant.
- (void)releaseMemory;
/// Fermeture de l'app (Mac) : arrêt de la partie et du thread de la console.
- (void)shutdown;
- (void)setTurbo:(BOOL)enabled;
/// Bouton RetroPad (PTButton).
- (void)setButton:(NSInteger)button pressed:(BOOL)pressed;
/// Stick 0 (gauche) ou 1 (droit), de -1 à 1.
- (void)setStick:(int)stick x:(float)x y:(float)y;
/// Sauvegarde et chargement rapides : bloquants, hors du thread principal.
- (BOOL)saveStateToPath:(NSString *)path;
- (BOOL)loadStateFromPath:(NSString *)path;
/// Image : définition (multiple de la PS2, 1 à 4), lissage des bords et écran large (16:9 si le jeu a un correctif).
/// Appliqués tout de suite en partie.
- (void)setImageUpscale:(NSInteger)upscale smoothing:(BOOL)smoothing widescreen:(BOOL)widescreen;
/// Format de l'image du jeu (largeur / hauteur), 0 si inconnu.
@property (nonatomic, readonly) float aspectRatio;
/// Image du jeu en cours (640×480), pour la vignette « Continuer ». Bloquant, hors du thread principal.
- (nullable PTPlatformImage *)snapshot;
- (nullable NSString *)lastError;

@end

NS_ASSUME_NONNULL_END
