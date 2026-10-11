#import "PTSecrets.h"

#import <string.h>

// En-tête écrit à chaque compilation par scripts/make_secrets.py (build/generated, jamais versionné).
#if __has_include("PTSecrets.generated.h")
#import "PTSecrets.generated.h"
#else
#define PT_STEAMGRIDDB_KEY_LENGTH 0
#endif

NSString *_Nullable PTSteamGridDBKey(void) {
#if PT_STEAMGRIDDB_KEY_LENGTH > 0
    // Lus à travers des pointeurs « volatile » : le compilateur ne peut pas calculer la clé d'avance et l'écrire en
    // clair dans l'app.
    const unsigned char *volatile mask = PTSteamGridDBMask;
    const unsigned char *volatile mixed = PTSteamGridDBMixed;
    const unsigned char *volatile order = PTSteamGridDBOrder;
    char key[PT_STEAMGRIDDB_KEY_LENGTH];
    for (int index = 0; index < PT_STEAMGRIDDB_KEY_LENGTH; index++) {
        key[order[index]] = (char)(mixed[index] ^ mask[index]);
    }
    NSString *result = [[NSString alloc] initWithBytes:key length:sizeof key encoding:NSASCIIStringEncoding];
    memset_s(key, sizeof key, 0, sizeof key);
    return result;
#else
    return nil;
#endif
}
