#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Clé d'accès SteamGridDB (jaquettes de secours), reconstituée à la demande : elle n'est jamais en clair dans l'app
/// (voir scripts/make_secrets.py). nil si l'app a été compilée sans clé.
NSString *_Nullable PTSteamGridDBKey(void);

NS_ASSUME_NONNULL_END
