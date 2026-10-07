#ifndef PTJIT_H
#define PTJIT_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Le processus a été débogué au moins une fois (CS_DEBUGGED, l'indicateur reste ensuite).
bool PTJITIsDebugged(void);
/// Un débogueur est attaché en ce moment (P_TRACED).
bool PTJITIsTraced(void);
/// L'app est signée « déboguable » (get-task-allow), condition pour qu'un débogueur s'y attache.
bool PTJITHasGetTaskAllow(void);

/// Protocole iOS 26 (TXM) avec le script universel de StikJIT, débogueur attaché : demande une zone
/// exécutable de `size` octets, crée sa vue en écriture, détache le débogueur et vérifie qu'un petit
/// bout de code s'exécute. Bloquant, hors du thread principal. En cas d'échec, `error` explique.
bool PTJITPreparePool(size_t size, char *error, size_t errorSize);

/// Simulateur uniquement : même réserve à deux vues, sans débogueur (pour tester les moteurs).
bool PTJITPrepareSimulatedPool(size_t size, char *error, size_t errorSize);

// Exportées pour les moteurs (PPSSPP les retrouve par dlsym, voir scripts/patch_ppsspp_jit.py).

/// La réserve JIT est prête.
bool PTJITIsActive(void);
/// Réserve `size` octets : renvoie l'adresse où écrire le code et place dans `executable` l'adresse
/// où l'exécuter (même mémoire). NULL si la réserve est absente ou pleine.
void *PTJITAlloc(size_t size, void **executable);
/// Rend un bloc obtenu par PTJITAlloc (adresse d'écriture).
void PTJITFree(void *writable);

/// Plus grande place libre d'un seul tenant dans la réserve (0 sans réserve).
size_t PTJITLargestFree(void);
/// Demandes refusées faute de place depuis le lancement de l'app (un moteur a alors démarré sans turbo).
unsigned PTJITFailureCount(void);

#ifdef __cplusplus
}
#endif

#endif
