#import "PTSecrets.h"

#import <string.h>

// En-tête écrit à chaque compilation par scripts/make_secrets.py (build/generated, jamais versionné).
#if __has_include("PTSecrets.generated.h")
#import "PTSecrets.generated.h"
#endif
#ifndef PTSteamGridDB_LENGTH
#define PTSteamGridDB_LENGTH 0
#endif
#ifndef PTScreenScraperDevID_LENGTH
#define PTScreenScraperDevID_LENGTH 0
#endif
#ifndef PTScreenScraperDevPassword_LENGTH
#define PTScreenScraperDevPassword_LENGTH 0
#endif

/// Reconstitue une clé : octet `index` du mélange, démasqué, remis à sa place `order[index]`. Lus à travers des
/// pointeurs « volatile » : le compilateur ne peut pas calculer la clé d'avance et l'écrire en clair dans l'app.
static NSString *PTUnmask(const unsigned char *volatile mask, const unsigned char *volatile mixed,
                          const unsigned char *volatile order, int length) {
    if (length <= 0) return nil;
    char key[length];
    for (int index = 0; index < length; index++) {
        key[order[index]] = (char)(mixed[index] ^ mask[index]);
    }
    NSString *result = [[NSString alloc] initWithBytes:key length:(NSUInteger)length encoding:NSASCIIStringEncoding];
    memset_s(key, (rsize_t)length, 0, (rsize_t)length);
    return result;
}

#define PT_SECRET(function, prefix) \
    NSString *_Nullable function(void) { \
        return PTUnmask(prefix##Mask, prefix##Mixed, prefix##Order, prefix##_LENGTH); \
    }

#if PTSteamGridDB_LENGTH > 0
PT_SECRET(PTSteamGridDBKey, PTSteamGridDB)
#else
NSString *_Nullable PTSteamGridDBKey(void) { return nil; }
#endif

#if PTScreenScraperDevID_LENGTH > 0
PT_SECRET(PTScreenScraperDevID, PTScreenScraperDevID)
#else
NSString *_Nullable PTScreenScraperDevID(void) { return nil; }
#endif

#if PTScreenScraperDevPassword_LENGTH > 0
PT_SECRET(PTScreenScraperDevPassword, PTScreenScraperDevPassword)
#else
NSString *_Nullable PTScreenScraperDevPassword(void) { return nil; }
#endif
