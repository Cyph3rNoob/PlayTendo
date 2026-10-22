#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Clé d'accès SteamGridDB (jaquettes de secours), reconstituée à la demande : elle n'est jamais en clair dans l'app
/// (voir scripts/make_secrets.py). nil si l'app a été compilée sans clé.
NSString *_Nullable PTSteamGridDBKey(void);

/// Identifiants développeur ScreenScraper (boîtes 3D des jaquettes), reconstitués de la même façon. nil sans eux.
NSString *_Nullable PTScreenScraperDevID(void);
NSString *_Nullable PTScreenScraperDevPassword(void);

NS_ASSUME_NONNULL_END
