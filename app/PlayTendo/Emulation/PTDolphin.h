// PTDolphin.h — interface entre PlayTendo et son moteur GameCube/Wii (DolphinCore.framework, tiré de
// DolphiniOS). Le moteur exporte ces fonctions (dolphin/PTDolphinHost.mm) ; l'app les trouve par dlsym
// (PTDolphinEngine.m).
#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// État du moteur.
typedef enum {
    PTDolphinStateStopped = 0,   ///< aucun jeu
    PTDolphinStateStarting = 1,  ///< jeu en cours de démarrage (ou d'arrêt)
    PTDolphinStateRunning = 2,
    PTDolphinStatePaused = 3,
} PTDolphinState;

/// Prépare le moteur, une seule fois, sur le thread principal. `userDir` : réglages et fichiers internes de
/// Dolphin (journal : `Logs/dolphin.log`) ; `gcSaveDir` : cartes mémoire GameCube ; `wiiSaveDir` : mémoire
/// interne de la Wii (sauvegardes des jeux Wii). Renvoie la vue Metal (UIView) où le jeu est dessiné, ou NULL.
void *PTDolphinSetup(const char *userDir, const char *gcSaveDir, const char *wiiSaveDir);

/// Démarre un jeu (chemin complet d'un .iso, .rvz, .gcm, .wbfs…). `jit` : turbo (réserve JIT de l'app prête),
/// sinon interpréteur. Faux si le démarrage n'a pas pu être lancé.
bool PTDolphinBoot(const char *path, bool jit);
PTDolphinState PTDolphinGetState(void);
void PTDolphinSetPaused(bool paused);
/// Demande l'arrêt du jeu ; l'état repasse à « arrêté » quand c'est fait.
void PTDolphinStop(void);
void PTDolphinReset(void);
/// Avance rapide (vitesse ×3).
void PTDolphinSetTurbo(bool enabled);

/// Bouton de la manette GameCube, avec les numéros RetroPad de PlayTendo (PTButton) : B = B, A = A,
/// Y = Y, X = X, R1 = Z, L2/R2 = gâchettes L/R, Start, croix.
void PTDolphinSetButton(int retroPadButton, bool pressed);
/// Stick 0 (principal) ou 1 (stick C), de -1 à 1 (y positif vers le bas).
void PTDolphinSetStick(int stick, float x, float y);

/// Sauvegarde et chargement rapides (bloquants : hors du thread principal).
bool PTDolphinSaveState(const char *path);
bool PTDolphinLoadState(const char *path);

/// Dernière erreur signalée par le moteur (copie à libérer par free), ou NULL.
char *PTDolphinCopyLastError(void);

#ifdef __cplusplus
}
#endif
