// Types de l'interface propres à chaque système, pour le code Objective-C partagé entre l'iPhone (UIKit) et le Mac
// (AppKit). Des macros plutôt que des typedef : Swift voit directement UIView / NSView.
#import <TargetConditionals.h>

#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#define PTPlatformView UIView
#define PTPlatformImage UIImage
#else
#import <AppKit/AppKit.h>
#define PTPlatformView NSView
#define PTPlatformImage NSImage
#endif

/// Image de l'interface faite d'une image Core Graphics (un pixel = un point).
static inline PTPlatformImage *PTPlatformImageWithCGImage(CGImageRef image) {
#if TARGET_OS_IOS
    return [UIImage imageWithCGImage:image];
#else
    return [[NSImage alloc] initWithCGImage:image size:NSMakeSize(CGImageGetWidth(image), CGImageGetHeight(image))];
#endif
}
