// PTVitaView.mm — partie UIKit du pilote du moteur PS Vita de PlayTendo (voir PTVitaHost.cpp) : la vue où Vita3K
// dessine et l'accès au MoltenVK de l'app. À part parce que les en-têtes d'Apple (MacTypes.h : `typedef char *Ptr`)
// et ceux de Vita3K (`template <class T> class Ptr`) ne peuvent pas cohabiter dans un même fichier. ARC.

#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>

#include <atomic>
#include <cmath>
#include <dlfcn.h>

#define PTVITA_EXPORT extern "C" __attribute__((visibility("default")))

static std::atomic<void *> s_layer{ nullptr };
static std::atomic<int> s_width{ 0 };
static std::atomic<int> s_height{ 0 };

/// Vue où Vita3K dessine : sa couche est une CAMetalLayer, donnée au moteur pour la surface Vulkan (MoltenVK).
/// Sa taille en pixels est lue par le moteur depuis son propre thread.
@interface PTVitaView : UIView
@end

@implementation PTVitaView

+ (Class)layerClass {
    return CAMetalLayer.class;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.blackColor;
        self.opaque = YES;
        // Les touchers passent par PlayTendo (écran tactile avant : PTVitaTouch).
        self.userInteractionEnabled = NO;
        self.layer.opaque = YES;
    }
    return self;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) {
        const CGFloat scale = self.window.screen.nativeScale;
        self.contentScaleFactor = scale;
        self.layer.contentsScale = scale;
    }
    [self updateDrawableSize];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self updateDrawableSize];
}

- (void)updateDrawableSize {
    const CGFloat scale = self.contentScaleFactor;
    s_width.store((int)std::lround(self.bounds.size.width * scale));
    s_height.store((int)std::lround(self.bounds.size.height * scale));
}

@end

static PTVitaView *s_view;

/// Crée la vue (une seule pour toute la vie de l'app), sur le thread principal.
extern "C" void *PTVitaCreateView(void) {
    if (!s_view) {
        s_view = [[PTVitaView alloc] initWithFrame:CGRectMake(0, 0, 960, 544)];
        s_layer.store((__bridge void *)s_view.layer);
    }
    return (__bridge void *)s_view;
}

extern "C" void *PTVitaViewLayer(void) {
    return s_layer.load();
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
