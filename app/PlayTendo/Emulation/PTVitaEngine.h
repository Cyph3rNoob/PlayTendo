#import <UIKit/UIKit.h>
#import "PTVita.h"

NS_ASSUME_NONNULL_BEGIN

/// Moteur PS Vita (VitaCore.framework, tiré de Vita3K) : chargé et préparé à la première partie, puis gardé jusqu'à
/// la fermeture de l'app. Il dessine lui-même dans sa vue (couche Metal, Vulkan par MoltenVK) et joue lui-même le
/// son ; l'app place la vue et transmet les commandes. Les jeux sont d'abord installés dans la mémoire de la console.
@interface PTVitaEngine : NSObject

/// Moteur déjà chargé, ou nil.
@property (class, nonatomic, readonly, nullable) PTVitaEngine *loadedEngine;

/// Charge et prépare le moteur, sur le thread principal. Les appels suivants renvoient le même moteur.
/// `storageDirectory` : mémoire de la console, réglages et journal du moteur.
+ (nullable instancetype)loadWithFrameworkPath:(NSString *)path
                              storageDirectory:(NSString *)storageDirectory
                                         error:(NSError **)error;

/// Vue où le jeu est dessiné (une seule pour toute la vie de l'app).
@property (nonatomic, readonly) UIView *renderView;
@property (nonatomic, readonly) PTVitaState state;

/// Firmware (PSVUPDAT.PUP) installé.
@property (nonatomic, readonly) BOOL hasFirmware;
/// Polices de la console (PSP2UPDAT.PUP) installées.
@property (nonatomic, readonly) BOOL hasFonts;
/// Installe un fichier .PUP (bloquant, hors du thread principal). Renvoie la version installée, ou nil.
- (nullable NSString *)installFirmwareAtPath:(NSString *)path progress:(nullable void (^)(float progress))progress;
/// Installe un jeu (dossier extrait ou .vpk ; bloquant, hors du thread principal). Renvoie son identifiant, ou nil.
- (nullable NSString *)installGameAtPath:(NSString *)path progress:(nullable void (^)(float progress))progress;
- (BOOL)isGameInstalled:(NSString *)titleID;

/// Précision du rendu au prochain lancement (haute : plus juste, plus lente).
- (void)setHighAccuracy:(BOOL)high;
/// Démarre un jeu installé, d'après son identifiant (« PCSA00011 »).
- (BOOL)bootTitle:(NSString *)titleID;
- (void)setPaused:(BOOL)paused;
- (void)stop;
/// Bouton RetroPad (PTButton).
- (void)setButton:(NSInteger)button pressed:(BOOL)pressed;
/// Stick 0 (gauche) ou 1 (droit), de -1 à 1.
- (void)setStick:(int)stick x:(float)x y:(float)y;
/// Écran tactile avant, un doigt : position de 0 à 1 sur l'image, `pressed` faux quand le doigt se lève.
- (void)touchAtX:(float)x y:(float)y pressed:(BOOL)pressed;
- (nullable NSString *)lastError;

@end

NS_ASSUME_NONNULL_END
