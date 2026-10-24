#import <Foundation/Foundation.h>

@class PTCore;

NS_ASSUME_NONNULL_BEGIN

/// Un succès RetroAchievements, pour la liste du menu pause et les notifications.
@interface PTAchievement : NSObject
@property (nonatomic, readonly) uint32_t identifier;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy) NSString *detail;
@property (nonatomic, readonly) uint32_t points;
@property (nonatomic, readonly) BOOL unlocked;
/// Progression mesurée (« 3/10 »), vide sinon.
@property (nonatomic, readonly, copy) NSString *progress;
/// Image du badge (débloqué, ou grisé tant qu'il ne l'est pas).
@property (nonatomic, readonly, copy, nullable) NSString *badgeURL;
@end

typedef NS_ENUM(NSInteger, PTAchievementEvent) {
    PTAchievementEventUnlocked,
    /// Tous les succès du jeu débloqués.
    PTAchievementEventMastered,
    PTAchievementEventLeaderboardStarted,
    PTAchievementEventLeaderboardFailed,
    PTAchievementEventLeaderboardSubmitted,
    /// Le serveur ne répond plus : les succès sont gardés et envoyés plus tard.
    PTAchievementEventDisconnected,
    PTAchievementEventReconnected,
    PTAchievementEventServerError,
    /// Le jeu doit recommencer (mode Hardcore activé en cours de partie).
    PTAchievementEventResetRequested,
};

/// Réponse d'une connexion : nom affiché, points, jeton à garder (jamais le mot de passe), ou erreur ; `rejected` :
/// identifiants ou jeton refusés par le serveur (pas une simple coupure du réseau).
typedef void (^PTAchievementLoginHandler)(NSString *_Nullable displayName, NSInteger score, NSString *_Nullable token,
                                          NSString *_Nullable error, BOOL rejected);
/// Jeu reconnu (ou non) par RetroAchievements.
typedef void (^PTAchievementGameHandler)(NSString *_Nullable title, NSUInteger unlocked, NSUInteger total,
                                         BOOL hardcore, NSString *_Nullable error);
typedef void (^PTAchievementEventHandler)(PTAchievementEvent event, PTAchievement *_Nullable achievement,
                                          NSString *_Nullable message);

/// RetroAchievements (bibliothèque rcheevos, licence MIT) pour les consoles libretro : connexion au compte du joueur,
/// identification du jeu par son empreinte, lecture de sa mémoire à chaque image, envoi des succès débloqués.
/// `doFrame`, `beginGame…`, `reset`, `endGame` et la progression : thread d'émulation. Le reste : n'importe lequel.
/// Les réponses et les évènements arrivent sur le thread principal.
@interface PTAchievements : NSObject

@property (class, nonatomic, readonly) PTAchievements *shared;

@property (nonatomic, readonly) BOOL loggedIn;
/// Mode Hardcore demandé (pris en compte au prochain jeu, ou tout de suite avec un « recommencer » demandé).
@property (nonatomic) BOOL hardcore;
@property (nonatomic, copy, nullable) PTAchievementEventHandler eventHandler;

- (void)loginWithUser:(NSString *)user password:(NSString *)password completion:(PTAchievementLoginHandler)completion;
- (void)loginWithUser:(NSString *)user token:(NSString *)token completion:(PTAchievementLoginHandler)completion;
- (void)logout;

/// Numéro RetroAchievements d'une console de PlayTendo (nom court « NES », « PS1 »…), 0 si elle n'en a pas.
+ (uint32_t)consoleForSystem:(NSString *)system;

/// Jeu chargé dans `core` : sa mémoire est préparée puis le jeu est demandé au serveur d'après le fichier `path`.
- (void)beginGameAtPath:(NSString *)path console:(uint32_t)console core:(PTCore *)core
             completion:(PTAchievementGameHandler)completion;
/// Moteur rechargé en cours de partie (réglages d'image de la N64) : sa mémoire a changé de place.
- (void)attachCore:(PTCore *)core;
@property (nonatomic, readonly) BOOL gameLoaded;
/// Jeu chargé avec ses succès en mode Hardcore (sauvegarde rapide, retour arrière et triche interdits).
@property (nonatomic, readonly) BOOL hardcoreActive;
/// Coupe le mode Hardcore pour ce jeu (codes de triche déjà actifs…).
- (void)leaveHardcore;
- (void)doFrame;
/// Partie en pause : garde la session active (messages réguliers au serveur).
- (void)idle;
- (void)reset;
- (void)endGame;

/// Où en sont les succès (à garder avec une sauvegarde rapide) ; nil sans jeu.
- (nullable NSData *)progress;
/// Reprend cette progression (nil : tout recommence à zéro, après un chargement sans elle ou un retour arrière).
- (void)restoreProgress:(nullable NSData *)data;

- (NSArray<PTAchievement *> *)achievements;
/// « 12 / 40 » : succès débloqués et total du jeu.
- (NSUInteger)unlockedCount;
- (NSUInteger)totalCount;

@end

NS_ASSUME_NONNULL_END
