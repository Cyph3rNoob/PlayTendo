#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const PTArchiveErrorDomain;

typedef NS_ERROR_ENUM(PTArchiveErrorDomain, PTArchiveError) {
    PTArchiveErrorNotAnArchive = 1,
    PTArchiveErrorEncrypted,
    PTArchiveErrorUnsupported,
    PTArchiveErrorDamaged,
    PTArchiveErrorWrite,
    PTArchiveErrorCancelled,
    PTArchiveErrorTooLarge,
};

/// Lecture d'une archive (.zip, ZIP64 compris, .7z, .rar et .rar5) par libarchive (libs/libarchive), fichier après
/// fichier, dans l'ordre où ils y sont rangés (une archive « solide » ne se lit que dans cet ordre). Les messages
/// d'erreur sont en français ; celui de libarchive est gardé dans NSDebugDescriptionErrorKey (pour le journal).
@interface PTArchiveReader : NSObject

- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;

/// Passe au fichier suivant (dossiers et liens sautés) ; NO à la fin de l'archive.
- (BOOL)nextEntry:(NSError **)error __attribute__((swift_error(nonnull_error)));

/// Chemin du fichier courant dans l'archive.
@property (nonatomic, readonly, copy) NSString *entryPath;
/// Taille du fichier courant une fois décompressé, -1 si l'archive ne la donne pas.
@property (nonatomic, readonly) int64_t entrySize;
/// Taille au-delà de laquelle l'extraction s'arrête (erreur « trop gros ») : une archive piégée peut annoncer peu et
/// écrire beaucoup plus, jusqu'à remplir l'appareil. Par défaut, aucune limite.
@property (nonatomic) int64_t maximumEntrySize;
/// Format reconnu par libarchive (« ZIP 2.0 (deflation) », « 7-Zip », « RAR5 »…), connu après le premier fichier.
@property (nonatomic, readonly, copy) NSString *formatName;
/// Octets de l'archive lus jusqu'ici, et sa taille.
@property (nonatomic, readonly) int64_t bytesRead;
@property (nonatomic, readonly) int64_t archiveSize;

/// Décompresse le fichier courant. `progress` reçoit les octets écrits (au plus dix fois par seconde, puis une
/// dernière fois à la fin) et renvoie NO pour annuler. En cas d'échec ou d'annulation, le fichier commencé est effacé.
- (BOOL)extractEntryToURL:(NSURL *)destination
                 progress:(BOOL (NS_NOESCAPE ^)(int64_t written))progress
                    error:(NSError **)error;

/// Contenu du fichier courant, s'il fait au plus `limit` octets.
- (nullable NSData *)readEntryWithLimit:(int64_t)limit error:(NSError **)error;

@end

/// Copie d'un fichier avec son avancement : clonage instantané quand c'est possible (même disque), sinon copie.
@interface PTFileCopy : NSObject

/// `progress` reçoit les octets copiés et la taille totale (au plus dix fois par seconde) et renvoie NO pour annuler.
/// La destination ne doit pas exister ; en cas d'échec ou d'annulation, la copie commencée est effacée.
+ (BOOL)copyItemAtURL:(NSURL *)source
                toURL:(NSURL *)destination
             progress:(BOOL (NS_NOESCAPE ^)(int64_t copied, int64_t total))progress
                error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
