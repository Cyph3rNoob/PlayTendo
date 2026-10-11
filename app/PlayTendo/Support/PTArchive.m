#import "PTArchive.h"

#import <copyfile.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>
#import <xlocale.h>

#import "archive.h"
#import "archive_entry.h"

NSErrorDomain const PTArchiveErrorDomain = @"PlayTendo.Archive";

/// Au plus dix nouvelles de l'avancement par seconde.
static const CFAbsoluteTime PTProgressInterval = 0.1;

static NSError *PTArchiveMakeError(PTArchiveError code, NSString *description, NSString *_Nullable detail) {
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
    if (detail.length > 0) info[NSDebugDescriptionErrorKey] = detail;
    return [NSError errorWithDomain:PTArchiveErrorDomain code:code userInfo:info];
}

static NSError *PTArchiveWriteError(int number) {
    NSString *description = number == ENOSPC || number == EDQUOT
        ? @"plus assez de place sur l'appareil"
        : [NSString stringWithFormat:@"écriture impossible (%s)", strerror(number)];
    return PTArchiveMakeError(PTArchiveErrorWrite, description, [NSString stringWithFormat:@"errno %d", number]);
}

static NSError *PTArchiveCancelledError(void) {
    return PTArchiveMakeError(PTArchiveErrorCancelled, @"annulé", nil);
}

/// libarchive lit les noms des fichiers selon la langue du programme : celle d'une app iOS est « C » (ASCII), où
/// les noms accentués ne passent pas. Chaque appel se fait donc en UTF-8, pour ce fil d'exécution seulement.
static locale_t PTUTF8Locale(void) {
    static locale_t locale;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        locale = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", NULL);
    });
    return locale;
}

#define PT_UTF8_BEGIN locale_t previousLocale = PTUTF8Locale() ? uselocale(PTUTF8Locale()) : NULL;
#define PT_UTF8_END if (previousLocale) uselocale(previousLocale);

@implementation PTArchiveReader {
    struct archive *_archive;
    BOOL _entryEncrypted;
}

- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error {
    if (!(self = [super init])) return nil;
    struct stat info;
    _archiveSize = stat(url.fileSystemRepresentation, &info) == 0 ? info.st_size : 0;
    _entryPath = @"";
    _entrySize = -1;
    _archive = archive_read_new();
    if (!_archive) {
        if (error) *error = PTArchiveWriteError(ENOMEM);
        return nil;
    }
    archive_read_support_format_zip(_archive);
    archive_read_support_format_7zip(_archive);
    archive_read_support_format_rar(_archive);
    archive_read_support_format_rar5(_archive);
    PT_UTF8_BEGIN
    int result = archive_read_open_filename(_archive, url.fileSystemRepresentation, 1 << 20);
    NSError *failure = result == ARCHIVE_OK ? nil : [self currentError];
    PT_UTF8_END
    if (failure) {
        if (error) *error = failure;
        return nil;
    }
    return self;
}

- (void)dealloc {
    if (_archive) archive_read_free(_archive);
}

- (NSString *)formatName {
    const char *name = archive_format_name(_archive);
    return name ? @(name) : @"?";
}

- (int64_t)bytesRead {
    return archive_filter_bytes(_archive, -1);
}

/// Erreur de libarchive traduite : son message (en anglais) est gardé pour le journal.
- (NSError *)currentError {
    const char *raw = archive_error_string(_archive);
    NSString *detail = raw ? @(raw) : @"erreur inconnue";
    NSString *lower = detail.lowercaseString;
    int number = archive_errno(_archive);
    if (number == ENOSPC || number == EDQUOT) return PTArchiveWriteError(number);
    if ([lower containsString:@"unrecognized archive format"]) {
        return PTArchiveMakeError(PTArchiveErrorNotAnArchive, @"ce n'est pas une archive lisible", detail);
    }
    if ([lower containsString:@"encrypt"] || [lower containsString:@"passphrase"] || [lower containsString:@"password"]) {
        return PTArchiveMakeError(PTArchiveErrorEncrypted,
                                  @"archive protégée par un mot de passe (décompresse-la d'abord sur ton ordinateur)",
                                  detail);
    }
    if ([lower containsString:@"unsupported"] || [lower containsString:@"not supported"]) {
        return PTArchiveMakeError(PTArchiveErrorUnsupported, @"méthode de compression non prise en charge", detail);
    }
    return PTArchiveMakeError(PTArchiveErrorDamaged, @"archive abîmée ou incomplète", detail);
}

- (BOOL)nextEntry:(NSError **)error {
    PT_UTF8_BEGIN
    BOOL found = NO;
    while (YES) {
        struct archive_entry *entry = NULL;
        int result = archive_read_next_header(_archive, &entry);
        if (result == ARCHIVE_EOF) break;
        // ARCHIVE_WARN : nom mal converti, par exemple ; le fichier reste lisible.
        if (result < ARCHIVE_WARN) {
            if (error) *error = [self currentError];
            break;
        }
        if (archive_entry_filetype(entry) != AE_IFREG) continue;
        _entryPath = [self pathOfEntry:entry];
        _entrySize = archive_entry_size_is_set(entry) ? archive_entry_size(entry) : -1;
        _entryEncrypted = archive_entry_is_data_encrypted(entry) != 0;
        found = YES;
        break;
    }
    PT_UTF8_END
    return found;
}

/// Nom en UTF-8 ; sinon (archive faite sous Windows), les octets du nom lus en page de code DOS 437.
- (NSString *)pathOfEntry:(struct archive_entry *)entry {
    const char *utf8 = archive_entry_pathname_utf8(entry);
    if (utf8) {
        NSString *path = [NSString stringWithUTF8String:utf8];
        if (path) return path;
    }
    const char *raw = archive_entry_pathname(entry);
    if (!raw) return @"?";
    NSString *path = [NSString stringWithUTF8String:raw];
    if (path) return path;
    NSStringEncoding dos = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingDOSLatinUS);
    return [NSString stringWithCString:raw encoding:dos] ?: [NSString stringWithCString:raw encoding:NSISOLatin1StringEncoding] ?: @"?";
}

- (nullable NSError *)encryptedError {
    if (!_entryEncrypted) return nil;
    return PTArchiveMakeError(PTArchiveErrorEncrypted,
                              @"archive protégée par un mot de passe (décompresse-la d'abord sur ton ordinateur)",
                              @"entry is encrypted");
}

- (BOOL)extractEntryToURL:(NSURL *)destination
                 progress:(BOOL (NS_NOESCAPE ^)(int64_t written))progress
                    error:(NSError **)error {
    NSError *failure = [self encryptedError];
    if (failure) {
        if (error) *error = failure;
        return NO;
    }
    const char *path = destination.fileSystemRepresentation;
    int file = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (file < 0) {
        if (error) *error = PTArchiveWriteError(errno);
        return NO;
    }
    PT_UTF8_BEGIN
    int64_t written = 0;
    CFAbsoluteTime lastReport = CFAbsoluteTimeGetCurrent();
    while (YES) {
        const void *buffer = NULL;
        size_t size = 0;
        la_int64_t offset = 0;
        int result = archive_read_data_block(_archive, &buffer, &size, &offset);
        if (result == ARCHIVE_EOF) break;
        // Un ARCHIVE_WARN ici veut dire une somme de contrôle fausse : le jeu serait abîmé.
        if (result != ARCHIVE_OK) {
            failure = [self currentError];
            break;
        }
        // Écrit à la position donnée (les trous d'un fichier « creux » ne sont pas écrits).
        const char *bytes = buffer;
        size_t left = size;
        off_t position = offset;
        while (left > 0) {
            ssize_t count = pwrite(file, bytes, left, position);
            if (count < 0) {
                if (errno == EINTR) continue;
                failure = PTArchiveWriteError(errno);
                break;
            }
            bytes += count;
            left -= (size_t)count;
            position += count;
        }
        if (failure) break;
        if (offset + (int64_t)size > written) written = offset + (int64_t)size;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - lastReport >= PTProgressInterval) {
            lastReport = now;
            if (!progress(written)) {
                failure = PTArchiveCancelledError();
                break;
            }
        }
    }
    PT_UTF8_END
    // Fichier qui finit par un trou : il garde sa taille.
    if (!failure && _entrySize > written && ftruncate(file, _entrySize) != 0) failure = PTArchiveWriteError(errno);
    if (close(file) != 0 && !failure) failure = PTArchiveWriteError(errno);
    if (failure) {
        unlink(path);
        if (error) *error = failure;
        return NO;
    }
    progress(MAX(written, _entrySize));
    return YES;
}

- (nullable NSData *)readEntryWithLimit:(int64_t)limit error:(NSError **)error {
    NSError *failure = [self encryptedError];
    if (!failure && _entrySize > limit) {
        failure = PTArchiveMakeError(PTArchiveErrorTooLarge, @"fichier trop gros", nil);
    }
    if (failure) {
        if (error) *error = failure;
        return nil;
    }
    NSMutableData *data = [NSMutableData data];
    uint8_t buffer[64 * 1024];
    PT_UTF8_BEGIN
    while (YES) {
        la_ssize_t count = archive_read_data(_archive, buffer, sizeof buffer);
        if (count == 0) break;
        if (count < 0) {
            failure = [self currentError];
            break;
        }
        if ((int64_t)data.length + count > limit) {
            failure = PTArchiveMakeError(PTArchiveErrorTooLarge, @"fichier trop gros", nil);
            break;
        }
        [data appendBytes:buffer length:(NSUInteger)count];
    }
    PT_UTF8_END
    if (failure) {
        if (error) *error = failure;
        return nil;
    }
    return data;
}

@end

typedef struct {
    __unsafe_unretained BOOL (^progress)(int64_t, int64_t);
    int64_t total;
    CFAbsoluteTime lastReport;
    BOOL cancelled;
} PTCopyContext;

static int PTCopyStatus(int what, int stage, copyfile_state_t state, const char *source, const char *destination,
                        void *context) {
    PTCopyContext *copy = context;
    if (what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - copy->lastReport >= PTProgressInterval) {
            copy->lastReport = now;
            off_t copied = 0;
            copyfile_state_get(state, COPYFILE_STATE_COPIED, &copied);
            if (!copy->progress(copied, copy->total)) {
                copy->cancelled = YES;
                return COPYFILE_QUIT;
            }
        }
    }
    return COPYFILE_CONTINUE;
}

@implementation PTFileCopy

+ (BOOL)copyItemAtURL:(NSURL *)source
                toURL:(NSURL *)destination
             progress:(BOOL (NS_NOESCAPE ^)(int64_t copied, int64_t total))progress
                error:(NSError **)error {
    struct stat info;
    int64_t total = stat(source.fileSystemRepresentation, &info) == 0 ? info.st_size : 0;
    PTCopyContext context = { progress, total, CFAbsoluteTimeGetCurrent(), NO };
    copyfile_state_t state = copyfile_state_alloc();
    copyfile_state_set(state, COPYFILE_STATE_STATUS_CB, (const void *)&PTCopyStatus);
    copyfile_state_set(state, COPYFILE_STATE_STATUS_CTX, &context);
    // Clonage d'abord (instantané et sans place en plus sur le même disque), copie ordinaire sinon.
    int result = copyfile(source.fileSystemRepresentation, destination.fileSystemRepresentation, state, COPYFILE_CLONE);
    int number = errno;
    copyfile_state_free(state);
    if (result != 0) {
        // Échec avant toute écriture (la destination existait déjà) : rien à effacer.
        if (number != EEXIST) unlink(destination.fileSystemRepresentation);
        if (error) *error = context.cancelled ? PTArchiveCancelledError() : PTArchiveWriteError(number);
        return NO;
    }
    progress(total, total);
    return YES;
}

@end
