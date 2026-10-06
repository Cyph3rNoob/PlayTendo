#import "PTJIT.h"
#import "PTCore.h"

#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <dlfcn.h>
#import <libkern/OSCacheControl.h>
#import <mach/mach.h>
#import <os/lock.h>
#import <signal.h>
#import <stdatomic.h>
#import <sys/mman.h>
#import <sys/sysctl.h>
#import <unistd.h>

// Réserve JIT de PlayTendo.
//
// Sur iOS 26 avec TXM (puces A15 et suivantes), une page n'est exécutable que si un débogueur l'a
// préparée. StikJIT (dans l'extension d'aide, ou l'app StikDebug) attache un débogueur qui exécute le
// script « universal.js » : l'app lui parle par des instructions `brk #0xf00d`, x16 donnant l'ordre
// (1 = préparer une zone, 0 = se détacher). On demande une seule grande zone au démarrage du JIT,
// on la voit aussi en écriture par vm_remap, puis le débogueur se détache : la zone reste utilisable
// jusqu'à la fermeture de l'app. Les moteurs y prennent leurs blocs (PTJITAlloc).

#define CS_OPS_STATUS 0
#define CS_DEBUGGED 0x10000000
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

#define PT_JIT_GRANULE ((size_t)16 * 1024)
#define PT_JIT_MAX_BLOCKS 256
/// Encodage de `brk #0xf00d`.
#define PT_JIT_BRK 0xD43E01A0u

#pragma mark - État du processus

bool PTJITIsDebugged(void) {
    uint32_t flags = 0;
    return csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) == 0 && (flags & CS_DEBUGGED) != 0;
}

bool PTJITIsTraced(void) {
    struct kinfo_proc info;
    size_t size = sizeof(info);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) return false;
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

bool PTJITHasGetTaskAllow(void) {
    // Fonctions de Security.framework non publiées sur iOS : retrouvées par dlsym.
    dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY);
    typedef void *(*CreateFromSelf)(CFAllocatorRef);
    typedef CFTypeRef (*CopyEntitlement)(void *, CFStringRef, CFErrorRef *);
    CreateFromSelf create = (CreateFromSelf)dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    CopyEntitlement copy = (CopyEntitlement)dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    if (!create || !copy) return false;
    void *task = create(NULL);
    if (!task) return false;
    CFTypeRef value = copy(task, CFSTR("get-task-allow"), NULL);
    bool result = value == kCFBooleanTrue;
    if (value) CFRelease(value);
    CFRelease((CFTypeRef)task);
    return result;
}

#pragma mark - Protocole universel (iOS 26)

__attribute__((noinline, optnone, naked))
static void JIT26Detach(void) {
    __asm__("mov x16, #0\n"
            "brk #0xf00d\n"
            "ret\n");
}

__attribute__((noinline, optnone, naked))
static void *JIT26PrepareRegion(__unused void *address, __unused size_t length) {
    __asm__("mov x16, #1\n"
            "brk #0xf00d\n"
            "ret\n");
}

// Filet de sécurité : si aucun débogueur ne répond à un `brk #0xf00d`, iOS envoie SIGTRAP au lieu de
// le confier au script ; on renvoie alors 0 au lieu de laisser l'app planter.
static struct sigaction gPreviousTrap;

static void PTJITTrapHandler(int signal, siginfo_t *info, void *context) {
    ucontext_t *uc = context;
    uint64_t pc = uc->uc_mcontext->__ss.__pc;
    if (*(const uint32_t *)pc == PT_JIT_BRK) {
        uc->uc_mcontext->__ss.__x[0] = 0;
        uc->uc_mcontext->__ss.__pc = pc + 4;
        return;
    }
    // Autre point d'arrêt : comportement d'origine.
    sigaction(SIGTRAP, &gPreviousTrap, NULL);
}

static void PTJITArmTrap(bool armed) {
    if (armed) {
        struct sigaction action;
        memset(&action, 0, sizeof(action));
        action.sa_sigaction = PTJITTrapHandler;
        action.sa_flags = SA_SIGINFO;
        sigemptyset(&action.sa_mask);
        sigaction(SIGTRAP, &action, &gPreviousTrap);
    } else {
        sigaction(SIGTRAP, &gPreviousTrap, NULL);
    }
}

#pragma mark - Réserve

typedef struct {
    size_t offset;
    size_t size;
    bool used;
} PTJITBlock;

static uint8_t *gExecutable;
static uint8_t *gWritable;
static size_t gPoolSize;
static atomic_bool gActive;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static PTJITBlock gBlocks[PT_JIT_MAX_BLOCKS];
static int gBlockCount;

static void PTJITSetError(char *error, size_t errorSize, NSString *message) {
    PTLogLine([@"JIT : " stringByAppendingString:message]);
    if (error && errorSize) strlcpy(error, message.UTF8String, errorSize);
}

static size_t PTJITRound(size_t size) {
    return (size + PT_JIT_GRANULE - 1) & ~(PT_JIT_GRANULE - 1);
}

/// Crée la vue en écriture d'une zone déjà exécutable. 0 en cas d'échec.
static vm_address_t PTJITMapWritable(void *executable, size_t size, NSString **failure) {
    vm_address_t writable = 0;
    vm_prot_t current = 0, maximum = 0;
    kern_return_t kr = vm_remap(mach_task_self(), &writable, size, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
                                (vm_address_t)executable, FALSE, &current, &maximum, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        *failure = [NSString stringWithFormat:@"vue en écriture impossible (vm_remap : %s)", mach_error_string(kr)];
        return 0;
    }
    kr = vm_protect(mach_task_self(), writable, size, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        vm_deallocate(mach_task_self(), writable, size);
        *failure = [NSString stringWithFormat:@"vue en écriture impossible (vm_protect : %s)", mach_error_string(kr)];
        return 0;
    }
    return writable;
}

/// Écrit « renvoie 42 » dans la réserve et l'exécute.
static bool PTJITSelfTest(uint8_t *executable, uint8_t *writable) {
    static const uint32_t code[] = {
        0xD2800540, // mov x0, #42
        0xD65F03C0, // ret
    };
    memcpy(writable, code, sizeof(code));
    sys_icache_invalidate(executable, sizeof(code));
    long result = ((long (*)(void))executable)();
    memset(writable, 0, sizeof(code));
    return result == 42;
}

static void PTJITActivate(uint8_t *executable, uint8_t *writable, size_t size) {
    os_unfair_lock_lock(&gLock);
    gExecutable = executable;
    gWritable = writable;
    gPoolSize = size;
    gBlocks[0] = (PTJITBlock){0, size, false};
    gBlockCount = 1;
    os_unfair_lock_unlock(&gLock);
    atomic_store(&gActive, true);
    PTLogLine([NSString stringWithFormat:@"JIT actif : réserve de %zu Mo", size >> 20]);
}

bool PTJITPreparePool(size_t size, char *error, size_t errorSize) {
    if (atomic_load(&gActive)) return true;
    size = PTJITRound(size);
    if (!PTJITIsTraced()) {
        PTJITSetError(error, errorSize, @"aucun débogueur n'est attaché à l'app.");
        return false;
    }

    PTLogLine([NSString stringWithFormat:@"JIT : préparation de %zu Mo par le débogueur…", size >> 20]);
    PTJITArmTrap(true);
    void *executable = JIT26PrepareRegion(NULL, size);
    if (!executable) {
        JIT26Detach();
        PTJITArmTrap(false);
        PTJITSetError(error, errorSize, @"le débogueur n'a pas préparé la mémoire (script JIT absent ou interrompu).");
        return false;
    }
    NSString *failure = nil;
    vm_address_t writable = PTJITMapWritable(executable, size, &failure);
    JIT26Detach();
    PTJITArmTrap(false);
    if (!writable) {
        PTJITSetError(error, errorSize, failure);
        return false;
    }

    // Si TXM refusait la zone, ce test fermerait l'app : la ligne doit être écrite avant.
    PTLogLine(@"JIT : débogueur détaché, essai d'exécution…");
    PTLogFlush();
    if (!PTJITSelfTest(executable, (uint8_t *)writable)) {
        PTJITSetError(error, errorSize, @"le code préparé ne s'exécute pas correctement.");
        return false;
    }
    PTJITActivate(executable, (uint8_t *)writable, size);
    return true;
}

bool PTJITPrepareSimulatedPool(size_t size, char *error, size_t errorSize) {
#if TARGET_OS_SIMULATOR
    if (atomic_load(&gActive)) return true;
    size = PTJITRound(size);
    void *executable = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (executable == MAP_FAILED) {
        PTJITSetError(error, errorSize, @"mémoire indisponible.");
        return false;
    }
    NSString *failure = nil;
    vm_address_t writable = PTJITMapWritable(executable, size, &failure);
    if (!writable || mprotect(executable, size, PROT_READ | PROT_EXEC) != 0) {
        PTJITSetError(error, errorSize, failure ?: @"zone exécutable refusée.");
        return false;
    }
    if (!PTJITSelfTest(executable, (uint8_t *)writable)) {
        PTJITSetError(error, errorSize, @"le code ne s'exécute pas correctement.");
        return false;
    }
    PTLogLine(@"JIT simulé (simulateur)");
    PTJITActivate(executable, (uint8_t *)writable, size);
    return true;
#else
    PTJITSetError(error, errorSize, @"réserve simulée réservée au simulateur.");
    return false;
#endif
}

#pragma mark - Allocation pour les moteurs

__attribute__((visibility("default"), used))
bool PTJITIsActive(void) {
    return atomic_load(&gActive);
}

__attribute__((visibility("default"), used))
void *PTJITAlloc(size_t size, void **executable) {
    if (!atomic_load(&gActive) || size == 0) return NULL;
    size = PTJITRound(size);
    size_t offset = SIZE_MAX;
    os_unfair_lock_lock(&gLock);
    for (int i = 0; i < gBlockCount; i++) {
        PTJITBlock *block = &gBlocks[i];
        if (block->used || block->size < size) continue;
        if (block->size > size && gBlockCount < PT_JIT_MAX_BLOCKS) {
            memmove(&gBlocks[i + 2], &gBlocks[i + 1], (size_t)(gBlockCount - i - 1) * sizeof(PTJITBlock));
            gBlocks[i + 1] = (PTJITBlock){block->offset + size, block->size - size, false};
            gBlockCount++;
            block->size = size;
        }
        block->used = true;
        offset = block->offset;
        break;
    }
    os_unfair_lock_unlock(&gLock);
    if (offset == SIZE_MAX) {
        PTLogLine([NSString stringWithFormat:@"JIT : réserve pleine (%zu Ko demandés)", size >> 10]);
        return NULL;
    }
    if (executable) *executable = gExecutable + offset;
    return gWritable + offset;
}

__attribute__((visibility("default"), used))
void PTJITFree(void *writable) {
    if (!writable || !atomic_load(&gActive)) return;
    size_t offset = (size_t)((uint8_t *)writable - gWritable);
    os_unfair_lock_lock(&gLock);
    for (int i = 0; i < gBlockCount; i++) {
        if (gBlocks[i].offset != offset || !gBlocks[i].used) continue;
        gBlocks[i].used = false;
        // Fusion avec le bloc libre suivant, puis avec le précédent.
        if (i + 1 < gBlockCount && !gBlocks[i + 1].used) {
            gBlocks[i].size += gBlocks[i + 1].size;
            memmove(&gBlocks[i + 1], &gBlocks[i + 2], (size_t)(gBlockCount - i - 2) * sizeof(PTJITBlock));
            gBlockCount--;
        }
        if (i > 0 && !gBlocks[i - 1].used) {
            gBlocks[i - 1].size += gBlocks[i].size;
            memmove(&gBlocks[i], &gBlocks[i + 1], (size_t)(gBlockCount - i - 1) * sizeof(PTJITBlock));
            gBlockCount--;
        }
        break;
    }
    os_unfair_lock_unlock(&gLock);
}
