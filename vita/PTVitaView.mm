// PTVitaView.mm — partie UIKit / AppKit du pilote du moteur PS Vita de PlayTendo (voir PTVitaHost.cpp) : la vue où
// Vita3K dessine et l'accès au MoltenVK de l'app. À part parce que les en-têtes d'Apple (MacTypes.h : `typedef char
// *Ptr`) et ceux de Vita3K (`template <class T> class Ptr`) ne peuvent pas cohabiter dans un même fichier. ARC.

#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CATransaction.h>
#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else
#import <AppKit/AppKit.h>
#endif

#include <atomic>
#include <cmath>
#include <dlfcn.h>

#define PTVITA_EXPORT extern "C" __attribute__((visibility("default")))

static std::atomic<void *> s_layer{ nullptr };
static std::atomic<int> s_width{ 0 };
static std::atomic<int> s_height{ 0 };

/// Vue où Vita3K dessine (une seule pour toute la vie de l'app). Elle porte, pour chaque partie, une CAMetalLayer
/// neuve donnée au moteur pour la surface Vulkan (MoltenVK) : une même couche réutilisée par la partie suivante
/// n'affichait plus rien (on voyait la dernière image de la précédente, 2026-10-13). La couche est retirée à la fin
/// de la partie : le fond noir se voit jusqu'à la première image de la suivante. Sa taille en pixels est lue par le
/// moteur depuis son propre thread.
#if TARGET_OS_IPHONE
@interface PTVitaView : UIView
#else
@interface PTVitaView : NSView
#endif
@property (nonatomic, strong, nullable) CAMetalLayer *metalLayer;
@end

@implementation PTVitaView

#if TARGET_OS_IPHONE
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.blackColor;
        self.opaque = YES;
        // Les touchers passent par PlayTendo (écran tactile avant : PTVitaTouch).
        self.userInteractionEnabled = NO;
    }
    return self;
}

- (CGFloat)pixelScale {
    return self.window ? self.window.screen.nativeScale : UIScreen.mainScreen.nativeScale;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self updateDrawableSize];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self updateDrawableSize];
}
#else
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        self.layer.opaque = YES;
    }
    return self;
}

- (CGFloat)pixelScale {
    return self.window ? self.window.backingScaleFactor : NSScreen.mainScreen.backingScaleFactor;
}

/// Les clics passent par PlayTendo (écran tactile avant : PTVitaTouch), comme sur iPhone.
- (NSView *)hitTest:(NSPoint)point {
    return nil;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self updateDrawableSize];
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [self updateDrawableSize];
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self updateDrawableSize];
}
#endif

/// Couche Metal neuve pour une nouvelle partie (sur le fil principal).
- (void)installMetalLayer {
    [self removeMetalLayer];
    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.opaque = YES;
    layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self.layer addSublayer:layer];
    [CATransaction commit];
    self.metalLayer = layer;
    s_layer.store((__bridge void *)layer);
    [self updateDrawableSize];
}

/// Fin de la partie : la couche part avec sa dernière image (sur le fil principal).
- (void)removeMetalLayer {
    if (!self.metalLayer)
        return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self.metalLayer removeFromSuperlayer];
    [CATransaction commit];
    self.metalLayer = nil;
}

- (void)updateDrawableSize {
    const CGFloat scale = [self pixelScale];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.metalLayer.frame = self.layer.bounds;
    self.metalLayer.contentsScale = scale;
    [CATransaction commit];
    s_width.store((int)std::lround(self.bounds.size.width * scale));
    s_height.store((int)std::lround(self.bounds.size.height * scale));
}

@end

static PTVitaView *s_view;

/// Exécute `block` sur le fil principal et attend qu'il soit fini (appelé depuis le fil de la partie ou de l'app).
static void PTVitaOnMain(void (^block)(void)) {
    if (NSThread.isMainThread)
        block();
    else
        dispatch_sync(dispatch_get_main_queue(), block);
}

/// Crée la vue (une seule pour toute la vie de l'app), sur le thread principal.
extern "C" void *PTVitaCreateView(void) {
    if (!s_view)
        s_view = [[PTVitaView alloc] initWithFrame:CGRectMake(0, 0, 960, 544)];
    return (__bridge void *)s_view;
}

/// Nouvelle partie : couche Metal neuve, donnée au moteur par PTVitaViewLayer.
extern "C" void PTVitaPrepareLayer(void) {
    PTVitaOnMain(^{
        [s_view installMetalLayer];
    });
}

/// Fin de la partie : la couche et sa dernière image sont retirées.
extern "C" void PTVitaReleaseLayer(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [s_view removeMetalLayer];
        s_layer.store(nullptr);
    });
}

extern "C" void *PTVitaViewLayer(void) {
    return s_layer.load();
}

/// Essai sans interface : la couche de la partie en cours montre-t-elle une image ?
PTVITA_EXPORT bool PTVitaViewHasContents(void) {
    CAMetalLayer *layer = (__bridge CAMetalLayer *)s_layer.load();
    return layer && layer.contents != nil;
}

extern "C" int PTVitaViewPixelWidth(void) {
    return s_width.load();
}

extern "C" int PTVitaViewPixelHeight(void) {
    return s_height.load();
}

/// vkGetInstanceProcAddr du MoltenVK.framework de l'app (partagé avec la 3DS) : appelé par le moteur de rendu de
/// Vita3K (renderer.cpp, retouché par scripts/patch_vita3k.py).
PTVITA_EXPORT void *PTVitaVkGetInstanceProcAddr(void) {
    static void *const proc = []() -> void * {
        NSString *path = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"MoltenVK.framework/MoltenVK"];
        void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (!handle) {
            NSLog(@"[PlayTendo] MoltenVK introuvable : %s", dlerror());
            return nullptr;
        }
        return dlsym(handle, "vkGetInstanceProcAddr");
    }();
    return proc;
}
