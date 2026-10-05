// PTGLContext : contexte OpenGL ES 3 dans lequel dessinent les moteurs 3D (N64, PSP).
// Le moteur dessine dans un « framebuffer » dont l'image est stockée dans un CVPixelBuffer
// partagé avec Metal : l'app l'affiche sans aucune copie. Trois images tournent pour que
// l'affichage lise l'une pendant que le moteur dessine une autre. Si le partage est refusé
// (simulateur), l'image est recopiée à chaque fois.

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PTGLContext : NSObject

- (nullable instancetype)initWithWidth:(unsigned)width height:(unsigned)height;

/// Identifiant OpenGL du framebuffer dans lequel le moteur doit dessiner.
@property (nonatomic, readonly) unsigned framebuffer;
@property (nonatomic, readonly) unsigned width;
@property (nonatomic, readonly) unsigned height;

- (void)makeCurrent;

/// Agrandit les images si le moteur annonce une résolution plus grande (même framebuffer).
- (BOOL)ensureWidth:(unsigned)width height:(unsigned)height;

/// Termine l'image en cours (`width`×`height` utiles), la renvoie et fait dessiner l'image
/// suivante dans un autre tampon.
- (CVPixelBufferRef)finishFrameWithWidth:(unsigned)width height:(unsigned)height CF_RETURNS_NOT_RETAINED;

@end

NS_ASSUME_NONNULL_END
