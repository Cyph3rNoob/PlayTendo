// Banc d'essai : fait tourner un moteur sur le Mac avec la même couche PTCore que l'app.
//
//   harness <moteur.dylib> <jeu> <images> <capture.png> [options]
//     --press a:60-120     maintient un bouton entre deux images
//     --touch 0.5,0.8:30-40  touche l'écran (DS) entre deux images
//     --probe 100          affiche la couleur du centre de l'image à l'image 100
//     --opt cle=valeur     réglage du moteur

#import "PTCore.h"
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

typedef struct { PTButton button; int from, to; } Press;
typedef struct { double x, y; int from, to; } Touch;

static PTButton ButtonNamed(NSString *name) {
    NSDictionary *map = @{@"a": @(PTButtonA), @"b": @(PTButtonB), @"x": @(PTButtonX), @"y": @(PTButtonY),
                          @"l": @(PTButtonL), @"r": @(PTButtonR), @"start": @(PTButtonStart),
                          @"select": @(PTButtonSelect), @"up": @(PTButtonUp), @"down": @(PTButtonDown),
                          @"left": @(PTButtonLeft), @"right": @(PTButtonRight),
                          @"l2": @(PTButtonL2), @"r2": @(PTButtonR2)};
    return (PTButton)[map[name.lowercaseString] integerValue];
}

static void PixelAt(NSData *frame, unsigned w, unsigned h, size_t pitch, PTPixelFormat format,
                    double fx, double fy, uint8_t rgb[3]) {
    unsigned x = (unsigned)(fx * (w - 1)), y = (unsigned)(fy * (h - 1));
    const uint8_t *row = (const uint8_t *)frame.bytes + y * pitch;
    if (format == PTPixelFormatXRGB8888) {
        uint32_t p = ((const uint32_t *)row)[x];
        rgb[0] = (p >> 16) & 0xFF; rgb[1] = (p >> 8) & 0xFF; rgb[2] = p & 0xFF;
    } else if (format == PTPixelFormatRGB565) {
        uint16_t p = ((const uint16_t *)row)[x];
        rgb[0] = ((p >> 11) & 0x1F) * 255 / 31; rgb[1] = ((p >> 5) & 0x3F) * 255 / 63; rgb[2] = (p & 0x1F) * 255 / 31;
    } else {
        uint16_t p = ((const uint16_t *)row)[x];
        rgb[0] = ((p >> 10) & 0x1F) * 255 / 31; rgb[1] = ((p >> 5) & 0x1F) * 255 / 31; rgb[2] = (p & 0x1F) * 255 / 31;
    }
}

static void WritePNG(NSData *frame, unsigned w, unsigned h, size_t pitch, PTPixelFormat format, NSString *path) {
    NSMutableData *rgba = [NSMutableData dataWithLength:w * h * 4];
    uint8_t *out = rgba.mutableBytes;
    for (unsigned y = 0; y < h; y++) {
        for (unsigned x = 0; x < w; x++) {
            uint8_t rgb[3];
            PixelAt(frame, w, h, pitch, format, w > 1 ? (double)x / (w - 1) : 0, h > 1 ? (double)y / (h - 1) : 0, rgb);
            uint8_t *p = out + (y * w + x) * 4;
            p[0] = rgb[0]; p[1] = rgb[1]; p[2] = rgb[2]; p[3] = 255;
        }
    }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)rgba);
    CGImageRef image = CGImageCreate(w, h, 8, 32, w * 4, space, kCGImageAlphaNoneSkipLast, provider, NULL, false,
                                     kCGRenderingIntentDefault);
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],
                                                                 CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(dest, image, NULL);
    CGImageDestinationFinalize(dest);
    CFRelease(dest); CGImageRelease(image); CGDataProviderRelease(provider); CGColorSpaceRelease(space);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 5) {
            fprintf(stderr, "usage: harness core.dylib jeu images capture.png [options]\n");
            return 2;
        }
        NSString *corePath = @(argv[1]), *gamePath = @(argv[2]), *pngPath = @(argv[4]);
        int frames = atoi(argv[3]);
        NSMutableArray<NSValue *> *presses = [NSMutableArray array];
        NSMutableArray<NSValue *> *touches = [NSMutableArray array];
        NSMutableSet<NSNumber *> *probes = [NSMutableSet set];
        NSMutableDictionary<NSString *, NSString *> *options = [NSMutableDictionary dictionary];
        NSArray<NSString *> *sequence = @[];
        NSMutableArray<NSNumber *> *peeks = [NSMutableArray array];
        NSMutableDictionary<NSNumber *, NSMutableDictionary *> *updates = [NSMutableDictionary dictionary];
        int sequenceStart = 120;
        for (int i = 5; i + 1 < argc; i += 2) {
            NSString *flag = @(argv[i]), *value = @(argv[i + 1]);
            NSArray *parts = [value componentsSeparatedByString:@":"];
            if ([flag isEqualToString:@"--press"]) {
                NSArray *range = [parts[1] componentsSeparatedByString:@"-"];
                Press p = {ButtonNamed(parts[0]), [range[0] intValue], [range[1] intValue]};
                [presses addObject:[NSValue valueWithBytes:&p objCType:@encode(Press)]];
            } else if ([flag isEqualToString:@"--touch"]) {
                NSArray *xy = [parts[0] componentsSeparatedByString:@","];
                NSArray *range = [parts[1] componentsSeparatedByString:@"-"];
                Touch t = {[xy[0] doubleValue], [xy[1] doubleValue], [range[0] intValue], [range[1] intValue]};
                [touches addObject:[NSValue valueWithBytes:&t objCType:@encode(Touch)]];
            } else if ([flag isEqualToString:@"--probe"]) {
                [probes addObject:@([value intValue])];
            } else if ([flag isEqualToString:@"--sequence"]) {
                sequence = [value componentsSeparatedByString:@","];
            } else if ([flag isEqualToString:@"--update"]) {
                NSArray *kv = [parts[1] componentsSeparatedByString:@"="];
                NSNumber *frame = @([parts[0] intValue]);
                if (!updates[frame]) updates[frame] = [NSMutableDictionary dictionary];
                updates[frame][kv[0]] = kv[1];
            } else if ([flag isEqualToString:@"--peek"]) {
                [peeks addObject:@(strtoul(value.UTF8String, NULL, 0))];
            } else if ([flag isEqualToString:@"--start"]) {
                sequenceStart = [value intValue];
            } else if ([flag isEqualToString:@"--opt"]) {
                NSArray *kv = [value componentsSeparatedByString:@"="];
                options[kv[0]] = kv[1];
            }
        }

        NSString *work = [NSTemporaryDirectory() stringByAppendingPathComponent:@"playtendo-harness"];
        NSString *system = [work stringByAppendingPathComponent:@"BIOS"];
        NSString *saves = [work stringByAppendingPathComponent:@"Sauvegardes"];
        [[NSFileManager defaultManager] createDirectoryAtPath:system withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:saves withIntermediateDirectories:YES attributes:nil error:nil];

        NSError *error = nil;
        PTCore *core = [[PTCore alloc] initWithLibraryPath:corePath error:&error];
        if (!core) { printf("ECHEC chargement moteur : %s\n", error.localizedDescription.UTF8String); return 1; }

        __block NSMutableData *frame = [NSMutableData data];
        __block unsigned fw = 0, fh = 0;
        __block size_t fpitch = 0;
        __block PTPixelFormat fformat = PTPixelFormatRGB565;
        __block NSUInteger videoFrames = 0, audioFrames = 0;
        core.videoHandler = ^(const void *pixels, unsigned w, unsigned h, size_t pitch, PTPixelFormat format) {
            [frame setLength:0];
            [frame appendBytes:pixels length:pitch * h];
            fw = w; fh = h; fpitch = pitch; fformat = format;
            videoFrames++;
        };
        core.audioHandler = ^(const int16_t *samples, size_t count) { audioFrames += count; };

        if (![core loadGameAtPath:gamePath systemDirectory:system saveDirectory:saves options:options error:&error]) {
            printf("ECHEC chargement jeu : %s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        printf("moteur   : %s %s\n", core.libraryName.UTF8String, core.libraryVersion.UTF8String);
        printf("cadence  : %.3f img/s, son %.0f Hz, format %.3f\n", core.framesPerSecond, core.sampleRate, core.aspectRatio);

        for (NSUInteger s = 0; s < sequence.count; s++) {
            int from = sequenceStart + (int)s * 30;
            [probes addObject:@(from + 15)];
            if ([sequence[s] isEqualToString:@"touch"]) {
                Touch t = {0.5, 0.75, from, from + 20};
                [touches addObject:[NSValue valueWithBytes:&t objCType:@encode(Touch)]];
            } else {
                Press p = {ButtonNamed(sequence[s]), from, from + 20};
                [presses addObject:[NSValue valueWithBytes:&p objCType:@encode(Press)]];
            }
        }
        if (sequence.count) frames = MAX(frames, sequenceStart + (int)sequence.count * 30 + 10);

        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        for (int i = 1; i <= frames; i++) {
            for (NSValue *v in presses) {
                Press p; [v getValue:&p];
                if (i == p.from) [core setButton:p.button pressed:YES port:0];
                if (i == p.to) [core setButton:p.button pressed:NO port:0];
            }
            for (NSValue *v in touches) {
                Touch t; [v getValue:&t];
                if (i == t.from) [core setPointerX:(int16_t)((t.x * 2 - 1) * 32767) y:(int16_t)((t.y * 2 - 1) * 32767) pressed:YES];
                if (i == t.to) [core setPointerX:0 y:0 pressed:NO];
            }
            if (updates[@(i)]) [core updateOptions:updates[@(i)]];
            [core runFrame];
            if (updates[@(i - 1)]) printf("réglages changés à l'image %d → image %u×%u, format %.3f\n", i - 1, fw, fh, core.aspectRatio);
            if ([probes containsObject:@(i)] && fw > 0) {
                uint8_t top[3], center[3];
                PixelAt(frame, fw, fh, fpitch, fformat, 0.5, 0.5, center);
                PixelAt(frame, fw, fh, fpitch, fformat, 0.5, 0.25, top);
                int index = (i - sequenceStart - 15) / 30;
                BOOL inSequence = sequence.count && i >= sequenceStart && (i - sequenceStart - 15) % 30 == 0
                                  && index >= 0 && index < (int)sequence.count;
                if (inSequence) {
                    printf("bouton %-6s → #%02X%02X%02X\n", sequence[index].UTF8String, top[0], top[1], top[2]);
                } else {
                    printf("image %4d : centre #%02X%02X%02X, quart haut #%02X%02X%02X\n", i,
                           center[0], center[1], center[2], top[0], top[1], top[2]);
                }
            }
        }
        double elapsed = CFAbsoluteTimeGetCurrent() - start;
        double expectedAudio = frames / core.framesPerSecond * core.sampleRate;
        printf("image    : %lu images reçues, %u×%u, format pixels %ld\n", (unsigned long)videoFrames, fw, fh, (long)fformat);
        printf("son      : %lu échantillons (%.0f %% de l'attendu)\n", (unsigned long)audioFrames,
               expectedAudio > 0 ? audioFrames * 100.0 / expectedAudio : 0);
        printf("vitesse  : %.2f ms par image (%.0f×  le temps réel)\n", elapsed * 1000 / frames,
               (frames / core.framesPerSecond) / elapsed);

        NSData *ram = [core systemRAM];
        for (NSNumber *offset in peeks) {
            NSUInteger o = offset.unsignedIntegerValue;
            if (ram && o + 4 <= ram.length) {
                const uint8_t *b = (const uint8_t *)ram.bytes + o;
                printf("mémoire  : [0x%06lX] = %02X %02X %02X %02X (taille %lu)\n", (unsigned long)o, b[0], b[1], b[2], b[3], (unsigned long)ram.length);
            } else {
                printf("mémoire  : indisponible (taille %lu)\n", (unsigned long)ram.length);
            }
        }
        NSData *state = [core saveState];
        BOOL restored = state ? [core loadState:state] : NO;
        printf("état     : %lu octets, rechargement %s\n", (unsigned long)state.length, restored ? "OK" : "ECHEC");
        printf("SRAM     : %lu octets\n", (unsigned long)[core saveRAM].length);

        if (fw > 0) WritePNG(frame, fw, fh, fpitch, fformat, pngPath);
        [core unloadGame];
        printf("RESULTAT : %s\n", (videoFrames > 0 && fw > 0) ? "OK" : "PAS D'IMAGE");
    }
    return 0;
}
