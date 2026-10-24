// Banc d'essai : fait tourner un moteur sur le Mac avec la même couche PTCore que l'app.
//
//   harness <moteur.dylib> <jeu> <images> <capture.png> [options]
//     --press a:60-120     maintient un bouton entre deux images
//     --touch 0.5,0.8:30-40  touche l'écran (DS) entre deux images
//     --probe 100          affiche la couleur du centre de l'image à l'image 100
//     --opt cle=valeur     réglage du moteur
//     --system dossier     dossier système donné au moteur (fichiers de PPSSPP…)
//     --jit 1              prépare la réserve JIT de l'app et la propose au moteur (PSP)
//     --achievements 7     RetroAchievements : mémoire vue par rcheevos (console n° 7 = NES…) et empreinte du jeu
//   Dans --sequence, en plus des boutons : sup/sdown/sleft/sright (stick gauche), cup/cdown/cleft/cright (stick
//   droit, boutons C de la N64). Les images 3D (OpenGL) sont lues comme les autres.

#import "PTCore.h"
#import "PTJIT.h"
#import "rc_hash.h"
#import "rc_libretro.h"
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

typedef struct { PTButton button; int from, to; } Press;
typedef struct { double x, y; int from, to; } Touch;
typedef struct { unsigned stick; int16_t x, y; int from, to; } Stick;

/// Direction d'un stick nommée dans --sequence (stick 0 = gauche, 1 = droit), ou NO.
static BOOL StickNamed(NSString *name, Stick *stick) {
    NSDictionary<NSString *, NSArray<NSNumber *> *> *map = @{
        @"sup": @[@0, @0, @-32767], @"sdown": @[@0, @0, @32767], @"sleft": @[@0, @-32767, @0], @"sright": @[@0, @32767, @0],
        @"cup": @[@1, @0, @-32767], @"cdown": @[@1, @0, @32767], @"cleft": @[@1, @-32767, @0], @"cright": @[@1, @32767, @0],
    };
    NSArray<NSNumber *> *v = map[name];
    if (!v) return NO;
    stick->stick = v[0].unsignedIntValue;
    stick->x = (int16_t)v[1].intValue;
    stick->y = (int16_t)v[2].intValue;
    return YES;
}

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

/// Nombre de fois où `pattern` paraît dans `data` (codes de triche : la valeur écrite par le code).
static NSUInteger Occurrences(NSData *data, NSData *pattern) {
    if (!data || !pattern.length) return 0;
    NSUInteger count = 0;
    NSRange range = NSMakeRange(0, data.length);
    while (range.length >= pattern.length) {
        NSRange found = [data rangeOfData:pattern options:0 range:range];
        if (found.location == NSNotFound) break;
        count++;
        range = NSMakeRange(found.location + 1, data.length - found.location - 1);
    }
    return count;
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
        NSMutableArray<NSValue *> *sticks = [NSMutableArray array];
        NSString *systemOverride = nil;
        BOOL jit = NO;
        NSMutableSet<NSNumber *> *probes = [NSMutableSet set];
        NSMutableDictionary<NSString *, NSString *> *options = [NSMutableDictionary dictionary];
        NSArray<NSString *> *sequence = @[];
        NSMutableArray<NSNumber *> *peeks = [NSMutableArray array];
        NSMutableDictionary<NSNumber *, NSMutableDictionary *> *updates = [NSMutableDictionary dictionary];
        // Codes de triche : envoyés à une image donnée (« --cheat 60:code1|code2 », au format du moteur, voir
        // Cheats.swift) ; « --find 42EF » cherche ces octets dans la mémoire (ou la sauvegarde rapide) avant et après.
        NSMutableDictionary<NSNumber *, NSArray<NSString *> *> *cheats = [NSMutableDictionary dictionary];
        NSData *findPattern = nil;
        unsigned device = 0;   // « --device 0x205 » : manette DualShock de la PS1
        uint32_t achievementConsole = 0;
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
            } else if ([flag isEqualToString:@"--cheat"]) {
                NSRange colon = [value rangeOfString:@":"];
                cheats[@([[value substringToIndex:colon.location] intValue])] =
                    [[value substringFromIndex:colon.location + 1] componentsSeparatedByString:@"|"];
            } else if ([flag isEqualToString:@"--find"]) {
                NSMutableData *bytes = [NSMutableData data];
                for (NSUInteger k = 0; k + 1 < value.length; k += 2) {
                    uint8_t byte = (uint8_t)strtoul([value substringWithRange:NSMakeRange(k, 2)].UTF8String, NULL, 16);
                    [bytes appendBytes:&byte length:1];
                }
                findPattern = bytes;
            } else if ([flag isEqualToString:@"--device"]) {
                device = (unsigned)strtoul(value.UTF8String, NULL, 0);
            } else if ([flag isEqualToString:@"--opt"]) {
                NSArray *kv = [value componentsSeparatedByString:@"="];
                options[kv[0]] = kv[1];
            } else if ([flag isEqualToString:@"--system"]) {
                systemOverride = value;
            } else if ([flag isEqualToString:@"--jit"]) {
                jit = [value boolValue];
            } else if ([flag isEqualToString:@"--achievements"]) {
                achievementConsole = (uint32_t)[value intValue];
            }
        }

        NSString *work = [NSTemporaryDirectory() stringByAppendingPathComponent:@"playtendo-harness"];
        NSString *system = systemOverride ?: [work stringByAppendingPathComponent:@"BIOS"];
        NSString *saves = [work stringByAppendingPathComponent:@"Sauvegardes"];
        [[NSFileManager defaultManager] createDirectoryAtPath:system withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:saves withIntermediateDirectories:YES attributes:nil error:nil];

        NSError *error = nil;
        PTCore *core = [[PTCore alloc] initWithLibraryPath:corePath error:&error];
        if (!core) { printf("ECHEC chargement moteur : %s\n", error.localizedDescription.UTF8String); return 1; }
        if (jit) {
            char reason[256] = {0};
            BOOL ready = PTJITPrepareSimulatedPool((size_t)352 << 20, reason, sizeof reason);
            printf("JIT      : %s\n", ready ? "réserve prête" : reason);
            core.allowsJIT = ready;
        }

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
        // Image 3D (OpenGL) : tampon BGRA partagé, lu ligne à ligne (remis à l'endroit) comme une image XRGB8888.
        core.hardwareVideoHandler = ^(CVPixelBufferRef buffer, unsigned w, unsigned h, BOOL flipped) {
            CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
            const uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
            size_t rowBytes = CVPixelBufferGetBytesPerRow(buffer);
            [frame setLength:(NSUInteger)w * h * 4];
            uint8_t *out = frame.mutableBytes;
            for (unsigned y = 0; y < h; y++) {
                memcpy(out + (size_t)y * w * 4, base + (size_t)(flipped ? h - 1 - y : y) * rowBytes, (size_t)w * 4);
            }
            CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
            fw = w; fh = h; fpitch = (size_t)w * 4; fformat = PTPixelFormatXRGB8888;
            videoFrames++;
        };
        core.audioHandler = ^(const int16_t *samples, size_t count) { audioFrames += count; };

        core.controllerDevice = device;
        if (![core loadGameAtPath:gamePath systemDirectory:system saveDirectory:saves options:options error:&error]) {
            printf("ECHEC chargement jeu : %s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        printf("moteur   : %s %s\n", core.libraryName.UTF8String, core.libraryVersion.UTF8String);
        printf("cadence  : %.3f img/s, son %.0f Hz, format %.3f\n", core.framesPerSecond, core.sampleRate, core.aspectRatio);

        for (NSUInteger s = 0; s < sequence.count; s++) {
            int from = sequenceStart + (int)s * 30;
            [probes addObject:@(from + 15)];
            Stick stick = {0};
            if ([sequence[s] isEqualToString:@"touch"]) {
                Touch t = {0.5, 0.75, from, from + 20};
                [touches addObject:[NSValue valueWithBytes:&t objCType:@encode(Touch)]];
            } else if (StickNamed(sequence[s], &stick)) {
                stick.from = from;
                stick.to = from + 20;
                [sticks addObject:[NSValue valueWithBytes:&stick objCType:@encode(Stick)]];
            } else {
                Press p = {ButtonNamed(sequence[s]), from, from + 20};
                [presses addObject:[NSValue valueWithBytes:&p objCType:@encode(Press)]];
            }
        }
        if (sequence.count) frames = MAX(frames, sequenceStart + (int)sequence.count * 30 + 10);

        NSData *ramBefore = nil, *stateBefore = nil;
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        for (int i = 1; i <= frames; i++) {
            if (cheats[@(i)]) {
                ramBefore = [core systemRAM];
                stateBefore = [core saveState];
                [core setCheats:cheats[@(i)]];
                printf("codes    : image %d → %s\n", i, [cheats[@(i)] componentsJoinedByString:@" | "].UTF8String);
            }
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
            for (NSValue *v in sticks) {
                Stick st; [v getValue:&st];
                if (i == st.from) [core setAnalogStick:st.stick x:st.x y:st.y port:0];
                if (i == st.to) [core setAnalogStick:st.stick x:0 y:0 port:0];
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

        if (achievementConsole) {
            rc_libretro_memory_regions_t regions = {0};
            BOOL ok = [core fillAchievementMemory:&regions console:achievementConsole];
            printf("succès   : mémoire %s, %u zone(s), %zu octets\n", ok ? "prête" : "ABSENTE", regions.count, regions.total_size);
            for (uint32_t r = 0; r < regions.count; r++) {
                printf("           zone %u : %zu octets%s\n", r, regions.size[r], regions.data[r] ? "" : " (vide)");
            }
            uint8_t bytes[8] = {0};
            uint32_t read = rc_libretro_memory_read(&regions, 0, bytes, 8);
            printf("           adresse 0 : %u octet(s) lus : %02X %02X %02X %02X\n", read, bytes[0], bytes[1], bytes[2], bytes[3]);
            NSData *system = [core systemRAM];
            if (system.length >= 8) {
                const uint8_t *b = system.bytes;
                printf("           mémoire système : %02X %02X %02X %02X (%s)\n", b[0], b[1], b[2], b[3],
                       memcmp(b, bytes, 4) == 0 ? "identique" : "différente");
            }
            char hash[33] = "";
            rc_hash_iterator_t iterator;
            rc_hash_initialize_iterator(&iterator, argv[2], NULL, 0);
            rc_hash_get_default_cdreader(&iterator.callbacks.cdreader);
            int hashed = rc_hash_generate(hash, achievementConsole, &iterator);
            rc_hash_destroy_iterator(&iterator);
            printf("           empreinte : %s\n", hashed ? hash : "IMPOSSIBLE");
        }

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
        if (findPattern) {
            NSData *stateAfter = [core saveState];
            printf("cherche  : mémoire avant %lu, après %lu ; sauvegarde rapide avant %lu, après %lu\n",
                   (unsigned long)Occurrences(ramBefore, findPattern), (unsigned long)Occurrences(ram, findPattern),
                   (unsigned long)Occurrences(stateBefore, findPattern), (unsigned long)Occurrences(stateAfter, findPattern));
        }
        NSData *state = [core saveState];
        BOOL restored = state ? [core loadState:state] : NO;
        printf("état     : %lu octets, rechargement %s\n", (unsigned long)state.length, restored ? "OK" : "ECHEC");
        printf("SRAM     : %lu octets\n", (unsigned long)[core saveRAM].length);

        if (jit) printf("JIT      : %zu Mo libres sur 352 dans la réserve\n", PTJITLargestFree() >> 20);
        if (fw > 0) WritePNG(frame, fw, fh, fpitch, fformat, pngPath);
        [core unloadGame];
        printf("RESULTAT : %s\n", (videoFrames > 0 && fw > 0) ? "OK" : "PAS D'IMAGE");
    }
    return 0;
}
