#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// Rendu 3D Vulkan d'un moteur libretro (3DS), par MoltenVK (Vulkan traduit en Metal, chargé à la demande depuis
/// Frameworks/MoltenVK.framework). PlayTendo crée l'instance ; le moteur crée son périphérique par l'interface de
/// négociation libretro ; à chaque image, l'image qu'il donne (`set_image`) est copiée dans un CVPixelBuffer BGRA
/// (IOSurface) que l'écran de jeu affiche en Metal, comme pour OpenGL ES (`PTGLContext`).
@interface PTVulkanContext : NSObject

/// Charge MoltenVK et crée l'instance Vulkan. `applicationInfo` : `const VkApplicationInfo *` du moteur, ou NULL.
- (nullable instancetype)initWithMoltenVKPath:(NSString *)path applicationInfo:(nullable const void *)applicationInfo;

/// Crée le périphérique Vulkan, par le moteur si `negotiation` (`retro_hw_render_context_negotiation_interface_vulkan`)
/// le propose, sinon soi-même.
- (BOOL)createDeviceWithNegotiation:(nullable const void *)negotiation;

/// `retro_hw_render_interface_vulkan` à donner au moteur (RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE).
@property (nonatomic, readonly) const void *renderInterface;

/// Copie la dernière image donnée par le moteur ; NULL s'il n'en a pas donné. Le tampon reste valable jusqu'à
/// l'avant-dernière image suivante (trois tampons tournent).
- (nullable CVPixelBufferRef)finishFrameWithWidth:(unsigned)width height:(unsigned)height;

/// Libère tout (périphérique compris) : après `context_destroy` et le déchargement du jeu.
- (void)destroy;

@end

NS_ASSUME_NONNULL_END
