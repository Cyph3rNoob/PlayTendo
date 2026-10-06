#import <UIKit/UIKit.h>
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
@property (nonatomic, readonly) UIView *renderView;
@property (nonatomic, readonly) PTDolphinState state;

/// `jit` : la réserve JIT de l'app est prête (recompilateur), sinon interpréteur.
- (BOOL)bootGameAtPath:(NSString *)path jit:(BOOL)jit;
- (void)setPaused:(BOOL)paused;
- (void)stop;
- (void)reset;
- (void)setTurbo:(BOOL)enabled;
/// Bouton RetroPad (PTButton).
- (void)setButton:(NSInteger)button pressed:(BOOL)pressed;
/// Stick 0 (principal) ou 1 (stick C), de -1 à 1.
- (void)setStick:(int)stick x:(float)x y:(float)y;
/// Sauvegarde et chargement rapides : bloquants, hors du thread principal.
- (BOOL)saveStateToPath:(NSString *)path;
- (BOOL)loadStateFromPath:(NSString *)path;
- (nullable NSString *)lastError;

@end

NS_ASSUME_NONNULL_END
