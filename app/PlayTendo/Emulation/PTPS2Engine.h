#import <UIKit/UIKit.h>
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
@property (nonatomic, readonly) UIView *renderView;
@property (nonatomic, readonly) PTPS2State state;

/// Nom du BIOS PS2 retenu dans le dossier des BIOS, ou nil s'il n'y en a pas.
- (nullable NSString *)pickBIOS;
- (BOOL)bootGameAtPath:(NSString *)path;
- (void)setPaused:(BOOL)paused;
- (void)stop;
- (void)reset;
/// Rend la mémoire de la console PS2 en veille (avant de lancer une autre console). Bloquant.
- (void)releaseMemory;
- (void)setTurbo:(BOOL)enabled;
/// Bouton RetroPad (PTButton).
- (void)setButton:(NSInteger)button pressed:(BOOL)pressed;
/// Stick 0 (gauche) ou 1 (droit), de -1 à 1.
- (void)setStick:(int)stick x:(float)x y:(float)y;
/// Sauvegarde et chargement rapides : bloquants, hors du thread principal.
- (BOOL)saveStateToPath:(NSString *)path;
- (BOOL)loadStateFromPath:(NSString *)path;
- (nullable NSString *)lastError;

@end

NS_ASSUME_NONNULL_END
