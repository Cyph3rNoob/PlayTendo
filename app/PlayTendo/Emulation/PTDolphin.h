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

/// Commandes envoyées à la Wiimote + Nunchuk (vrai) ou à la manette GameCube (faux, par défaut). Relâche tout.
void PTDolphinSetWiimote(bool enabled);
/// Bouton RetroPad de PlayTendo (PTButton), placé par position. Manette GameCube : bas = A, gauche = B,
/// droite = X, haut = Y, R1 = Z, L1/L2 = L, R2 = R, Start, croix. Wiimote : bas = A, droite et R2 = B,
/// gauche = 1, haut = 2, Start = +, Select = −, R3 = Home, L1 = C, L2 = Z, R1 = secouer, croix.
void PTDolphinSetButton(int retroPadButton, bool pressed);
/// Stick 0 (principal ; Nunchuk) ou 1 (stick C ; pointeur de la Wiimote), de -1 à 1 (y positif vers le bas).
void PTDolphinSetStick(int stick, float x, float y);
/// Pointeur de la Wiimote, de -1 à 1 sur l'image (y positif vers le bas).
void PTDolphinSetPointer(float x, float y);

/// Format de l'image en cours (largeur / hauteur : 4:3, 16:9…), ou 0 s'il n'est pas encore connu.
float PTDolphinGetAspectRatio(void);
/// Résolution de rendu (×1 à ×4 celle de la console) et lissage des bords (filtre FXAA). Appliqués à l'image suivante.
void PTDolphinSetImageOptions(int scale, bool smoothing);
/// Capture l'image suivante en PNG à `path` (bloquant, jeu en marche seulement ; ≤ 1 s). Vrai si écrite.
bool PTDolphinCaptureScreen(const char *path);
/// Mémoire rapide (fastmem) disponible ; `largestBlockGB` reçoit le plus grand bloc d'adresses libre mesuré.
bool PTDolphinFastmemStatus(float *largestBlockGB);

/// Sauvegarde et chargement rapides (bloquants : hors du thread principal).
bool PTDolphinSaveState(const char *path);
bool PTDolphinLoadState(const char *path);

/// Dernière erreur signalée par le moteur (copie à libérer par free), ou NULL.
char *PTDolphinCopyLastError(void);

#ifdef __cplusplus
}
#endif
