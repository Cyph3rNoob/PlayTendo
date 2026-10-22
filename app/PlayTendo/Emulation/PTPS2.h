// PTPS2.h — interface entre PlayTendo et son moteur PS2 (PS2Core.framework, tiré d'ARMSX2).
// Le moteur exporte ces fonctions (ps2/PTPS2Host.mm) ; l'app les trouve par dlsym (PTPS2Engine.m).
#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// État du moteur.
typedef enum {
    PTPS2StateStopped = 0,   ///< aucun jeu
    PTPS2StateStarting = 1,  ///< jeu en cours de démarrage (ou d'arrêt)
    PTPS2StateRunning = 2,
    PTPS2StatePaused = 3,
} PTPS2State;

/// Prépare le moteur, une seule fois, sur le thread principal. `dataRoot` : réglages et fichiers internes
/// (journal du moteur : `logs/emulog.txt`) ; `biosDir` : BIOS ; `memcardDir` : cartes mémoire.
/// Renvoie la vue Metal (UIView) où la PS2 dessine, ou NULL en cas d'échec.
void *PTPS2Setup(const char *dataRoot, const char *biosDir, const char *memcardDir);

/// Choisit un BIOS PS2 valide dans le dossier des BIOS (le dernier utilisé s'il existe encore).
/// Renvoie son nom (copie à libérer par free) ou NULL s'il n'y en a aucun.
char *PTPS2PickBIOS(void);

/// Démarre un jeu (chemin complet d'un .iso, .chd, .cso…). Faux sans BIOS.
bool PTPS2Boot(const char *path);
/// Prochain démarrage : reprise automatique sur laquelle commencer (ou NULL), démarrage rapide (sans le logo PS2).
void PTPS2SetBootOptions(const char *statePath, bool fastBoot);
/// Reprise du dernier démarrage : -1 aucune, 1 chargée, 0 illisible (jeu démarré du début).
int PTPS2GetBootStateResult(void);
PTPS2State PTPS2GetState(void);
void PTPS2SetPaused(bool paused);
/// Demande l'arrêt du jeu ; l'état repasse à « arrêté » quand c'est fait.
void PTPS2Stop(void);
void PTPS2Reset(void);
/// Arrête la console PS2 en veille entre deux parties pour rendre sa mémoire (plusieurs Go d'adresses
/// réservées, dont celles que PPSSPP veut pour la PSP). À appeler avant de lancer une autre console.
/// Bloquant, sans effet pendant une partie PS2. La console est recréée au prochain jeu PS2.
void PTPS2ReleaseMemory(void);
/// Fermeture de l'app (Mac) : arrêt de la partie et du thread de la console. Facultative : absente des moteurs iPhone.
void PTPS2Shutdown(void);
/// Avance rapide (vitesse « turbo » de PCSX2).
void PTPS2SetTurbo(bool enabled);

/// Bouton de la manette, avec les numéros RetroPad de PlayTendo (PTButton) : B = Croix, A = Rond,
/// Y = Carré, X = Triangle, L/R = L1/R1.
void PTPS2SetButton(int retroPadButton, bool pressed);
/// Stick 0 (gauche) ou 1 (droit), de -1 à 1 (y positif vers le bas).
void PTPS2SetStick(int stick, float x, float y);

/// Sauvegarde rapide dans un fichier (bloquant : à appeler hors du thread principal).
bool PTPS2SaveState(const char *path);
bool PTPS2LoadState(const char *path);

/// Image : définition en multiple de celle de la PS2 (1 à 4), lissage des bords (FXAA) et écran large (correctifs
/// 16:9 des jeux qui en ont un). Gardés dans les réglages du moteur, appliqués tout de suite pendant une partie.
void PTPS2SetImageOptions(int upscale, bool smoothing, bool widescreen);
/// Codes de triche du jeu en cours (texte .pnach : lignes « patch=… »), appliqués tout de suite et gardés pour ses
/// prochains lancements ; texte vide : plus aucun. À appeler jeu démarré. Facultative : absente des moteurs d'avant.
void PTPS2SetCheats(const char *pnach);
/// Format de l'image affichée (largeur / hauteur : 4:3, ou 16:9 avec un correctif écran large), 0 si inconnu.
float PTPS2GetAspectRatio(void);
/// Image du jeu en cours, en 640×480 pixels RGBA (copie à libérer par free), ou NULL. Bloquant : hors du
/// thread principal.
void *PTPS2CopySnapshot(int *width, int *height);

/// Dernière erreur signalée par le moteur (copie à libérer par free), ou NULL.
char *PTPS2CopyLastError(void);

#ifdef __cplusplus
}
#endif
