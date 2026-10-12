// PTVita.h — interface entre PlayTendo et son moteur PS Vita (VitaCore.framework, tiré de Vita3K). Le moteur exporte
// ces fonctions (vita/PTVitaHost.cpp) ; l'app les trouve par dlsym (PTVitaEngine.m).
#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// État du moteur.
typedef enum {
    PTVitaStateStopped = 0,   ///< aucun jeu
    PTVitaStateStarting = 1,  ///< jeu en cours de démarrage (ou d'arrêt)
    PTVitaStateRunning = 2,
    PTVitaStatePaused = 3,
} PTVitaState;

/// Parties du système de la console installées (masque).
typedef enum {
    PTVitaFirmwareMain = 1 << 0,   ///< firmware (PSVUPDAT.PUP) : obligatoire
    PTVitaFirmwareFonts = 1 << 1,  ///< polices (PSP2UPDAT.PUP) : recommandées
} PTVitaFirmware;

/// Avancement d'une installation, de 0 à 1 (appelé depuis le thread de l'installation).
typedef void (*PTVitaProgress)(float progress, void *context);

/// Prépare le moteur, une seule fois, sur le thread principal. `storageDir` : mémoire de la console (ux0, vs0…),
/// réglages, caches et journal du moteur (`vita3k.log`) ; `assetsDir` : fichiers fixes du moteur (shaders, polices
/// de secours), dans VitaCore.framework. Renvoie la vue (couche Metal) où le jeu est dessiné, ou NULL.
void *PTVitaSetup(const char *storageDir, const char *assetsDir);

/// Masque PTVitaFirmware de ce qui est installé.
int PTVitaGetFirmware(void);
/// Installe un fichier de mise à jour officiel (.PUP). Bloquant (dizaines de secondes) : hors du thread principal.
/// Renvoie la version installée (copie à libérer par free) ou NULL.
char *PTVitaInstallFirmware(const char *pupPath, PTVitaProgress progress, void *context);

/// Installe un jeu : dossier extrait (avec sce_sys/param.sfo ; licence sce_sys/package/work.bin pour un jeu
/// chiffré NoNpDrm) ou archive .vpk/.zip. Bloquant (minutes pour un gros jeu) : hors du thread principal. Renvoie
/// l'identifiant du jeu (« PCSA00011 », copie à libérer par free) ou NULL.
char *PTVitaInstallGame(const char *path, PTVitaProgress progress, void *context);
/// Jeu déjà installé dans la mémoire de la console.
bool PTVitaIsInstalled(const char *titleID);

/// Démarre un jeu installé (identifiant). Faux si le démarrage n'a pas pu être lancé. Le turbo (réserve JIT de
/// l'app) est obligatoire : Vita3K n'a pas d'interpréteur.
bool PTVitaBoot(const char *titleID);
PTVitaState PTVitaGetState(void);
void PTVitaSetPaused(bool paused);
/// Demande l'arrêt du jeu ; l'état repasse à « arrêté » quand c'est fait.
void PTVitaStop(void);
/// Mac : arrêt complet avant la sortie du programme (partie arrêtée, son fil rattaché). Sans lui, la sortie du
/// programme restait bloquée après une partie (essai sans interface, 2026-10-12).
void PTVitaShutdown(void);

/// Bouton RetroPad de PlayTendo (PTButton), placé par position : bas = ✕, droite = ○, gauche = □, haut = △,
/// L1/R1 = L/R, Start, Select, croix ; L2/R2/L3/R3 pour les manettes (PS TV).
void PTVitaSetButton(int retroPadButton, bool pressed);
/// Stick 0 (gauche) ou 1 (droit), de -1 à 1 (y positif vers le bas).
void PTVitaSetStick(int stick, float x, float y);
/// Écran tactile avant. `phase` : 0 posé, 1 déplacé, 2 levé. x, y de 0 à 1 sur la vue du jeu.
void PTVitaTouch(long finger, int phase, float x, float y);

/// Dernière erreur signalée par le moteur (copie à libérer par free), ou NULL.
char *PTVitaCopyLastError(void);

#ifdef __cplusplus
}
#endif
