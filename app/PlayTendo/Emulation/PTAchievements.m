#import "PTAchievements.h"
#import "PTCore.h"
#import "rc_client.h"
#import "rc_consoles.h"
#import "rc_hash.h"
#import "rc_libretro.h"
#import "rc_version.h"
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

@interface PTAchievement ()
- (instancetype)initWithAchievement:(const rc_client_achievement_t *)achievement;
@end

@implementation PTAchievement

- (instancetype)initWithAchievement:(const rc_client_achievement_t *)achievement {
    if ((self = [super init])) {
        _identifier = achievement->id;
        _title = achievement->title ? @(achievement->title) : @"";
        _detail = achievement->description ? @(achievement->description) : @"";
        _points = achievement->points;
        _unlocked = achievement->unlocked != RC_CLIENT_ACHIEVEMENT_UNLOCKED_NONE;
        _progress = @(achievement->measured_progress);
        const char *url = _unlocked ? achievement->badge_url : achievement->badge_locked_url;
        _badgeURL = url ? @(url) : nil;
    }
    return self;
}

@end

static void PTEventHandler(const rc_client_event_t *event, rc_client_t *client);

/// Mémoire de la console lue par rc_client (fil de l'émulation seulement : lectures en arrière-plan interdites).
/// Moteurs libretro : zones rc_libretro ; moteurs autonomes : fonction de lecture du moteur.
static rc_libretro_memory_regions_t gRegions;
static BOOL gRegionsReady;
static PTAchievementReadFunction gExternalRead;

static uint32_t PTReadMemory(uint32_t address, uint8_t *buffer, uint32_t count, rc_client_t *client) {
    if (gExternalRead) return gExternalRead(address, buffer, count);
    return gRegionsReady ? rc_libretro_memory_read(&gRegions, address, buffer, count) : 0;
}

static NSString *PTUserAgent(rc_client_t *client) {
    NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"1.0";
#if TARGET_OS_IPHONE
    NSString *os = [NSString stringWithFormat:@"iOS %@", UIDevice.currentDevice.systemVersion];
#else
    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    NSString *os = [NSString stringWithFormat:@"macOS %ld.%ld", (long)v.majorVersion, (long)v.minorVersion];
#endif
    char clause[64] = "";
    rc_client_get_user_agent_clause(client, clause, sizeof clause);
    return [NSString stringWithFormat:@"PlayTendo/%@ (%@) %s", version, os, clause];
}

/// Requêtes de rc_client vers retroachievements.org (URLSession) ; la réponse est rendue sur le fil de URLSession.
static void PTServerCall(const rc_api_request_t *request, rc_client_server_callback_t callback, void *data, rc_client_t *client) {
    static NSString *agent;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ agent = PTUserAgent(client); });
    NSURL *url = [NSURL URLWithString:@(request->url)];
    if (!url) {
        rc_api_server_response_t response = {NULL, 0, RC_API_SERVER_RESPONSE_CLIENT_ERROR};
        callback(&response, data);
        return;
    }
    NSMutableURLRequest *http = [NSMutableURLRequest requestWithURL:url];
    http.timeoutInterval = 30;
    [http setValue:agent forHTTPHeaderField:@"User-Agent"];
    if (request->post_data) {
        http.HTTPMethod = @"POST";
        http.HTTPBody = [NSData dataWithBytes:request->post_data length:strlen(request->post_data)];
        [http setValue:request->content_type ? @(request->content_type) : @"application/x-www-form-urlencoded"
    forHTTPHeaderField:@"Content-Type"];
    }
    [[NSURLSession.sharedSession dataTaskWithRequest:http completionHandler:^(NSData *body, NSURLResponse *answer, NSError *error) {
        rc_api_server_response_t response;
        response.body = body.bytes;
        response.body_length = body.length;
        response.http_status_code = error ? RC_API_SERVER_RESPONSE_RETRYABLE_CLIENT_ERROR
                                          : (int)((NSHTTPURLResponse *)answer).statusCode;
        callback(&response, data);
    }] resume];
}

static void PTClientLog(const char *message, const rc_client_t *client) {
    PTLogLine([NSString stringWithFormat:@"RetroAchievements : %s", message]);
}

static void PTHashLog(const char *message, const struct rc_hash_iterator *iterator) {
    PTLogLine([NSString stringWithFormat:@"RetroAchievements (empreinte) : %s", message]);
}

@implementation PTAchievements {
    rc_client_t *_client;
    rc_hash_callbacks_t _hashCallbacks;
    __weak PTCore *_core;
    uint32_t _console;
    /// Moteur autonome : réponse à chaque jeu, dernière empreinte demandée.
    PTAchievementGameHandler _externalCompletion;
    NSString *_externalHash;
}

+ (PTAchievements *)shared {
    static PTAchievements *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [PTAchievements new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _client = rc_client_create(PTReadMemory, PTServerCall);
        rc_client_set_userdata(_client, (__bridge void *)self);
        rc_client_enable_logging(_client, RC_CLIENT_LOG_LEVEL_WARN, PTClientLog);
        // Mémoire lue seulement pendant `doFrame` (thread d'émulation), jamais à l'arrivée d'une réponse.
        rc_client_set_allow_background_memory_reads(_client, 0);
        rc_client_set_event_handler(_client, PTEventHandler);
        memset(&_hashCallbacks, 0, sizeof _hashCallbacks);
        _hashCallbacks.error_message = PTHashLog;
        rc_hash_get_default_cdreader(&_hashCallbacks.cdreader);
        rc_client_set_hash_callbacks(_client, &_hashCallbacks);
        rc_client_set_hardcore_enabled(_client, 0);
    }
    return self;
}

#pragma mark Compte

- (BOOL)loggedIn {
    return rc_client_get_user_info(_client) != NULL;
}

- (BOOL)hardcore {
    return rc_client_get_hardcore_enabled(_client) != 0;
}

- (void)setHardcore:(BOOL)hardcore {
    rc_client_set_hardcore_enabled(_client, hardcore ? 1 : 0);
}

static void PTLoginDone(int result, const char *message, rc_client_t *client, void *userdata) {
    PTAchievementLoginHandler completion = (__bridge_transfer PTAchievementLoginHandler)userdata;
    const rc_client_user_t *user = result == RC_OK ? rc_client_get_user_info(client) : NULL;
    NSString *name = user && user->display_name ? @(user->display_name) : nil;
    NSString *token = user && user->token ? @(user->token) : nil;
    NSInteger score = user ? (NSInteger)user->score : 0;
    NSString *error = nil;
    if (!user) {
        error = message ? @(message) : [NSString stringWithFormat:@"erreur %d", result];
        PTLogLine([NSString stringWithFormat:@"RetroAchievements : connexion refusée (%@)", error]);
    } else {
        PTLogLine([NSString stringWithFormat:@"RetroAchievements : connecté (%@, %ld points)", name, (long)score]);
    }
    BOOL rejected = result == RC_INVALID_CREDENTIALS || result == RC_EXPIRED_TOKEN || result == RC_ACCESS_DENIED;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(name, score, token, error, rejected); });
}

- (void)loginWithUser:(NSString *)user password:(NSString *)password completion:(PTAchievementLoginHandler)completion {
    rc_client_begin_login_with_password(_client, user.UTF8String, password.UTF8String, PTLoginDone,
                                        (__bridge_retained void *)[completion copy]);
}

- (void)loginWithUser:(NSString *)user token:(NSString *)token completion:(PTAchievementLoginHandler)completion {
    rc_client_begin_login_with_token(_client, user.UTF8String, token.UTF8String, PTLoginDone,
                                     (__bridge_retained void *)[completion copy]);
}

- (void)logout {
    rc_client_logout(_client);
    PTLogLine(@"RetroAchievements : déconnecté");
}

#pragma mark Jeu

+ (uint32_t)consoleForSystem:(NSString *)system {
    static NSDictionary<NSString *, NSNumber *> *consoles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        consoles = @{
            @"NES": @(RC_CONSOLE_NINTENDO), @"SNES": @(RC_CONSOLE_SUPER_NINTENDO), @"N64": @(RC_CONSOLE_NINTENDO_64),
            @"GB": @(RC_CONSOLE_GAMEBOY), @"GBC": @(RC_CONSOLE_GAMEBOY_COLOR), @"GBA": @(RC_CONSOLE_GAMEBOY_ADVANCE),
            @"DS": @(RC_CONSOLE_NINTENDO_DS), @"PS1": @(RC_CONSOLE_PLAYSTATION), @"PSP": @(RC_CONSOLE_PSP),
            @"PS2": @(RC_CONSOLE_PLAYSTATION_2), @"GC": @(RC_CONSOLE_GAMECUBE), @"Wii": @(RC_CONSOLE_WII),
        };
    });
    return consoles[system].unsignedIntValue;
}

- (void)prepareMemory {
    PTCore *core = _core;
    rc_libretro_memory_destroy(&gRegions);
    gRegionsReady = core && [core fillAchievementMemory:&gRegions console:_console] && gRegions.total_size > 0;
}

static void PTGameLoaded(int result, const char *message, rc_client_t *client, void *userdata) {
    PTAchievementGameHandler completion = (__bridge_transfer PTAchievementGameHandler)userdata;
    const rc_client_game_t *game = result == RC_OK ? rc_client_get_game_info(client) : NULL;
    NSString *title = game && game->title ? @(game->title) : nil;
    rc_client_user_game_summary_t summary = {0};
    if (game) rc_client_get_user_game_summary(client, &summary);
    BOOL hardcore = game && rc_client_get_hardcore_enabled(client) && summary.num_core_achievements > 0;
    NSString *error = nil;
    if (!game) {
        error = message ? @(message) : [NSString stringWithFormat:@"erreur %d", result];
        PTLogLine([NSString stringWithFormat:@"RetroAchievements : jeu non chargé (%@)", error]);
    } else {
        PTLogLine([NSString stringWithFormat:@"RetroAchievements : %@ (n° %u), %u succès sur %u%@", title, game->id,
                   summary.num_unlocked_achievements, summary.num_core_achievements, hardcore ? @", Hardcore" : @""]);
    }
    NSUInteger unlocked = summary.num_unlocked_achievements, total = summary.num_core_achievements;
    BOOL unknown = result == RC_NO_GAME_LOADED;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(title, unlocked, total, hardcore, error, unknown); });
}

- (void)beginGameAtPath:(NSString *)path console:(uint32_t)console core:(PTCore *)core
             completion:(PTAchievementGameHandler)completion {
    rc_client_unload_game(_client);
    _core = core;
    _console = console;
    [self prepareMemory];
    if (!gRegionsReady) PTLogLine(@"RetroAchievements : mémoire du jeu pas encore lisible (nouvel essai à la première image)");
    rc_client_begin_identify_and_load_game(_client, console, path.fileSystemRepresentation, NULL, 0, PTGameLoaded,
                                           (__bridge_retained void *)[completion copy]);
}

- (void)attachCore:(PTCore *)core {
    _core = core;
    [self prepareMemory];
}

- (BOOL)gameLoaded {
    return rc_client_is_game_loaded(_client) != 0;
}

- (BOOL)hardcoreActive {
    return rc_client_is_game_loaded(_client) && rc_client_get_hardcore_enabled(_client) && rc_client_has_achievements(_client);
}

- (void)leaveHardcore {
    rc_client_set_hardcore_enabled(_client, 0);
}

- (void)doFrame {
    if (!gRegionsReady && _core) [self prepareMemory];
    rc_client_do_frame(_client);
}

- (void)idle {
    rc_client_idle(_client);
}

- (void)reset {
    rc_client_reset(_client);
}

- (void)endGame {
    rc_client_unload_game(_client);
    rc_libretro_memory_destroy(&gRegions);
    gRegionsReady = NO;
    gExternalRead = NULL;
    _core = nil;
    @synchronized (self) {
        _externalCompletion = nil;
        _externalHash = nil;
    }
}

#pragma mark Moteurs autonomes

- (void)prepareExternalConsole:(uint32_t)console read:(PTAchievementReadFunction)read
                    completion:(PTAchievementGameHandler)completion {
    rc_client_unload_game(_client);
    rc_libretro_memory_destroy(&gRegions);
    gRegionsReady = NO;
    _core = nil;
    _console = console;
    gExternalRead = read;
    @synchronized (self) {
        _externalCompletion = [completion copy];
        _externalHash = nil;
    }
}

- (void)loadExternalGameHash:(NSString *)hash {
    PTAchievementGameHandler completion;
    @synchronized (self) {
        if (!_externalCompletion || [hash ?: @"" isEqualToString:_externalHash ?: @""]) return;
        _externalHash = [hash copy];
        completion = _externalCompletion;
    }
    rc_client_unload_game(_client);
    if (hash.length == 0) {
        PTLogLine(@"RetroAchievements : plus de jeu");
        return;
    }
    PTLogLine([NSString stringWithFormat:@"RetroAchievements : jeu d'empreinte %@", hash]);
    rc_client_begin_load_game(_client, hash.UTF8String, PTGameLoaded, (__bridge_retained void *)[completion copy]);
}

void PTAchievementsFrame(void) {
    PTAchievements *achievements = PTAchievements.shared;
    if (gExternalRead) rc_client_do_frame(achievements->_client);
}

void PTAchievementsGameHash(const char *hash) {
    [PTAchievements.shared loadExternalGameHash:hash ? @(hash) : nil];
}

- (NSData *)progress {
    if (!rc_client_is_game_loaded(_client)) return nil;
    size_t size = rc_client_progress_size(_client);
    if (size == 0) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:size];
    return rc_client_serialize_progress_sized(_client, data.mutableBytes, size) == RC_OK ? data : nil;
}

- (void)restoreProgress:(NSData *)data {
    if (!rc_client_is_game_loaded(_client)) return;
    rc_client_deserialize_progress_sized(_client, data.bytes, data.length);
}

- (NSArray<PTAchievement *> *)achievements {
    NSMutableArray *result = [NSMutableArray array];
    rc_client_achievement_list_t *list = rc_client_create_achievement_list(_client, RC_CLIENT_ACHIEVEMENT_CATEGORY_CORE,
                                                                          RC_CLIENT_ACHIEVEMENT_LIST_GROUPING_PROGRESS);
    if (!list) return result;
    for (uint32_t b = 0; b < list->num_buckets; b++) {
        const rc_client_achievement_bucket_t *bucket = &list->buckets[b];
        for (uint32_t i = 0; i < bucket->num_achievements; i++) {
            [result addObject:[[PTAchievement alloc] initWithAchievement:bucket->achievements[i]]];
        }
    }
    rc_client_destroy_achievement_list(list);
    return result;
}

- (NSUInteger)unlockedCount {
    rc_client_user_game_summary_t summary = {0};
    rc_client_get_user_game_summary(_client, &summary);
    return summary.num_unlocked_achievements;
}

- (NSUInteger)totalCount {
    rc_client_user_game_summary_t summary = {0};
    rc_client_get_user_game_summary(_client, &summary);
    return summary.num_core_achievements;
}

#pragma mark Évènements

static void PTEventHandler(const rc_client_event_t *event, rc_client_t *client) {
    PTAchievements *achievements = (__bridge PTAchievements *)rc_client_get_userdata(client);
    PTAchievementEventHandler handler = achievements.eventHandler;
    if (!handler) return;
    PTAchievementEvent kind;
    PTAchievement *achievement = nil;
    NSString *message = nil;
    switch (event->type) {
        case RC_CLIENT_EVENT_ACHIEVEMENT_TRIGGERED:
            kind = PTAchievementEventUnlocked;
            achievement = [[PTAchievement alloc] initWithAchievement:event->achievement];
            PTLogLine([NSString stringWithFormat:@"RetroAchievements : succès débloqué « %@ » (%u points)",
                       achievement.title, achievement.points]);
            break;
        case RC_CLIENT_EVENT_GAME_COMPLETED:
            kind = PTAchievementEventMastered;
            break;
        case RC_CLIENT_EVENT_LEADERBOARD_STARTED:
            kind = PTAchievementEventLeaderboardStarted;
            message = event->leaderboard->title ? @(event->leaderboard->title) : nil;
            break;
        case RC_CLIENT_EVENT_LEADERBOARD_FAILED:
            kind = PTAchievementEventLeaderboardFailed;
            message = event->leaderboard->title ? @(event->leaderboard->title) : nil;
            break;
        case RC_CLIENT_EVENT_LEADERBOARD_SUBMITTED:
            kind = PTAchievementEventLeaderboardSubmitted;
            message = [NSString stringWithFormat:@"%s : %s", event->leaderboard->title ?: "",
                       event->leaderboard->tracker_value ?: ""];
            break;
        case RC_CLIENT_EVENT_DISCONNECTED:
            kind = PTAchievementEventDisconnected;
            break;
        case RC_CLIENT_EVENT_RECONNECTED:
            kind = PTAchievementEventReconnected;
            break;
        case RC_CLIENT_EVENT_SERVER_ERROR:
            kind = PTAchievementEventServerError;
            message = event->server_error->error_message ? @(event->server_error->error_message) : nil;
            PTLogLine([NSString stringWithFormat:@"RetroAchievements : erreur du serveur (%s) %@",
                       event->server_error->api ?: "?", message ?: @""]);
            break;
        case RC_CLIENT_EVENT_RESET:
            kind = PTAchievementEventResetRequested;
            break;
        default:
            return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ handler(kind, achievement, message); });
}

@end
