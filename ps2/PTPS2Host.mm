// PTPS2Host.mm — pilote du moteur PS2 de PlayTendo (tiré d'ARMSX2 iOS 2.6.0, GPL-3.0).
//
// Remplace AppDelegate.mm et la partie « fenêtre » de SceneDelegate.mm d'ARMSX2 : PlayTendo garde sa propre
// fenêtre et place lui-même la vue Metal de la PS2 dans son écran de jeu. Le reste du code iOS d'ARMSX2
// (thread de la console, pont, entrées, son) est repris tel quel. Compilé dans PS2Core.framework par
// scripts/build_ps2.sh ; l'app y accède par dlopen/dlsym (app/PlayTendo/Emulation/PTPS2Engine.m).
// Compilé avec ARC (contrairement aux fichiers d'ARMSX2 qui l'entourent).

#define SDL_MAIN_HANDLED
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <vector>
#include <mutex>
#include <string>
#include <sys/stat.h>

#include "common/Console.h"
#include "common/Darwin/DarwinMisc.h"
#include "common/Error.h"
#include "common/FileSystem.h"
#include "common/Path.h"
#include "pcsx2/CDVD/CDVD.h"
#include "pcsx2/Config.h"
#include "pcsx2/Host.h"
#include "pcsx2/INISettingsInterface.h"
#include "pcsx2/MTGS.h"
#include "pcsx2/SIO/Memcard/MemoryCardFile.h"
#include "pcsx2/SIO/Pad/Pad.h"
#include "pcsx2/SIO/Pad/PadBase.h"
#include "pcsx2/SIO/Sio.h"
#include "pcsx2/VMManager.h"
#include "pcsx2/ps2/BiosTools.h"

#import <UIKit/UIKit.h>

#include "IOS/IOSRuntime.h"
#import "IOS/ARMSX2GameView.h"
#import "IOS/PCSX2SceneDelegate.h"
#import "ARMSX2Bridge.h"

#include "PTPS2.h"

#define PTPS2_EXPORT extern "C" __attribute__((visibility("default")))

// Méthode de SceneDelegate.mm (non déclarée dans son en-tête) qui lance le thread de la console.
@interface PCSX2SceneDelegate (PlayTendo)
- (void)startVMThread;
@end

extern "C" void ARMSX2_PrepareGameRenderViewForCurrentRenderer(const char* reason);
extern "C" void ARMSX2_PlayTendoReleaseVMThread(void);
extern "C" void ARMSX2_PlayTendoSetCodeProvider(void* (*alloc)(size_t, void**), void (*release)(void*));

// Réserve JIT de l'app (PTJIT.m), exportée par l'exécutable de PlayTendo et retrouvée par dlsym : le moteur
// y prend sa zone de code (DarwinMisc.cpp, retouché). Un seul passage de StikDebug sert à toutes les consoles.
static bool (*s_jitIsActive)(void);

/// Lu par ARMSX2IOSSanitizeFolderSettings (ios_main.mm, retouché par scripts/patch_armsx2.py) : les dossiers
/// BIOS et cartes mémoire de PlayTendo sont des chemins absolus hors du dossier du moteur, réécrits à chaque
/// lancement (le chemin du conteneur de l'app change à chaque réinstallation).
bool g_ptps2Host = false;

static PCSX2SceneDelegate* s_launcher;
/// Tests : si le fichier « journal-entrees » existe dans le dossier du moteur, chaque bouton et stick reçu
/// est relu dans la manette PS2 virtuelle et noté dans logs/emulog.txt.
static bool s_logInputs = false;
static std::mutex s_errorMutex;
static std::string s_lastError;

/// Appelé par Host::ReportErrorAsync (HostImpls.mm, retouché) : PlayTendo affiche la dernière erreur.
extern "C" void PTPS2RecordError(const char* title, const char* message)
{
    std::lock_guard<std::mutex> lock(s_errorMutex);
    s_lastError = std::string(title ? title : "") + " : " + (message ? message : "");
}

static void PTPS2ClearError()
{
    std::lock_guard<std::mutex> lock(s_errorMutex);
    s_lastError.clear();
}

// MARK: - Réglages

/// Réglages par défaut d'ARMSX2 pour un nouveau fichier (repris de SceneDelegate.mm).
static void PTPS2WriteDefaults(INISettingsInterface* si)
{
    si->SetIntValue("EmuCore/CPU", "CoreType", 2); // recompilateurs ARM64
    si->SetBoolValue("EmuCore/CPU", "UseArm64Dynarec", true);
    si->SetBoolValue("EmuCore/CPU/Recompiler", "EnableEE", true);
    si->SetBoolValue("EmuCore/CPU/Recompiler", "EnableIOP", true);
    si->SetBoolValue("EmuCore/CPU/Recompiler", "EnableVU0", true);
    si->SetBoolValue("EmuCore/CPU/Recompiler", "EnableVU1", true);
    si->SetBoolValue("EmuCore/CPU/Recompiler", "EnableFastmem", true);
    si->SetBoolValue("EmuCore/CPU", "EnableSparseMemory", true);
    si->SetBoolValue("EmuCore/CPU", "ExtraMemory", false);
    si->SetStringValue("SPU2/Output", "Backend", "SDL");
    si->SetIntValue("EmuCore/GS", "VsyncQueueSize", 8);
    si->SetFloatValue("Framerate", "NominalScalar", 1.0f);
    si->SetBoolValue("GameISO", "FastBoot", false);
    si->SetBoolValue("EmuCore", "EnableFastBoot", false);
    si->SetBoolValue("EmuCore/Speedhacks", "vuThread", ARMSX2ShouldEnableMTVUByDefault(nullptr));
    si->SetBoolValue("Achievements", "Enabled", false);
    si->SetBoolValue("Achievements", "ChallengeMode", false);
    si->SetIntValue("ARMSX2iOS/Gamepad", "MultitapMode", 0);
}

/// Anciens fichiers de réglages : valeurs ajoutées depuis (repris de SceneDelegate.mm).
static void PTPS2FillMissing(INISettingsInterface* si)
{
    if (!si->ContainsValue("SPU2/Output", "Backend"))
        si->SetStringValue("SPU2/Output", "Backend", "SDL");
    if (!si->ContainsValue("EmuCore/CPU", "ExtraMemory"))
        si->SetBoolValue("EmuCore/CPU", "ExtraMemory", false);
    if (!si->ContainsValue("EmuCore/CPU/Recompiler", "EnableFastmem"))
        si->SetBoolValue("EmuCore/CPU/Recompiler", "EnableFastmem", true);
    if (!si->ContainsValue("Achievements", "Enabled"))
        si->SetBoolValue("Achievements", "Enabled", false);
    if (!si->ContainsValue("Achievements", "ChallengeMode"))
        si->SetBoolValue("Achievements", "ChallengeMode", false);
    if (!si->ContainsValue("ARMSX2iOS/Gamepad", "MultitapMode"))
        si->SetIntValue("ARMSX2iOS/Gamepad", "MultitapMode", 0);
}

// MARK: - BIOS

static bool PTPS2IsBIOS(const std::string& path)
{
    u32 version = 0, region = 0;
    std::string description, zone;
    return IsBIOS(path.c_str(), version, description, region, zone);
}

/// BIOS retenu : celui des réglages s'il est toujours là, sinon le premier valide du dossier (ordre alphabétique).
static std::string PTPS2ChooseBIOS()
{
    if (!s_settings_interface || EmuFolders::Bios.empty())
        return {};
    const std::string current = s_settings_interface->GetStringValue("Filenames", "BIOS", "");
    if (!current.empty() && PTPS2IsBIOS(Path::Combine(EmuFolders::Bios, current)))
    {
        EmuConfig.BaseFilenames.Bios = current;
        return current;
    }

    NSArray<NSString*>* files = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:[NSString stringWithUTF8String:EmuFolders::Bios.c_str()] error:nil];
    for (NSString* file in [files sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)])
    {
        NSString* ext = file.pathExtension.lowercaseString;
        if (![ext isEqualToString:@"bin"] && ![ext isEqualToString:@"rom"] && ![ext isEqualToString:@"rom0"])
            continue;
        const std::string path = Path::Combine(EmuFolders::Bios, file.UTF8String);
        FILESYSTEM_STAT_DATA sd;
        // Un BIOS PS2 fait 4 Mo (8 Mo pour certains modèles) : le reste (BIOS PS1, DS…) est ignoré sans le lire.
        if (!FileSystem::StatFile(path.c_str(), &sd) || sd.Size < 2 * 1024 * 1024 || sd.Size > 50 * 1024 * 1024)
            continue;
        if (!PTPS2IsBIOS(path))
            continue;
        [ARMSX2Bridge setDefaultBIOS:file];
        Console.WriteLn("PlayTendo : BIOS PS2 choisi %s", file.UTF8String);
        return file.UTF8String;
    }
    EmuConfig.BaseFilenames.Bios.clear();
    return {};
}

// MARK: - Préparation

PTPS2_EXPORT void* PTPS2Setup(const char* dataRoot, const char* biosDir, const char* memcardDir)
{
    if (g_gameRenderView)
        return (__bridge void*)g_gameRenderView;
    g_ptps2Host = true;

    // SDL vérifie (version de test) que la lecture des événements se fait sur le thread principal, alors que
    // le moteur la fait sur le thread de la console : sans ce réglage, l'émulation se fige sur une alerte
    // (même réglage que pour lancer ARMSX2 en Debug). Sans effet dans la version finale.
    setenv("SDL_ASSERT", "always_ignore", 1);

    // Dossiers (repris d'AppDelegate.mm, dans le dossier du moteur au lieu de Documents).
    const std::string root = dataRoot;
    mkdir(root.c_str(), 0755);
    for (const char* dir : {"logs", "sstates", "snaps", "cheats", "patches", "cache", "covers", "gamesettings",
                            "textures", "inputprofiles", "inis", "resources"})
        mkdir(Path::Combine(root, dir).c_str(), 0755);
    mkdir(biosDir, 0755);
    mkdir(memcardDir, 0755);

    NSString* resources = [NSBundle bundleForClass:[ARMSX2Bridge class]].resourcePath;
    EmuFolders::DataRoot = root;
    EmuFolders::Settings = Path::Combine(root, "inis");
    EmuFolders::AppRoot = resources.UTF8String;
    EmuFolders::Resources = resources.UTF8String;
    EmuFolders::Bios = biosDir;
    EmuFolders::MemoryCards = memcardDir;
    EmuFolders::Logs = Path::Combine(root, "logs");
    s_logInputs = FileSystem::FileExists(Path::Combine(root, "journal-entrees").c_str());

    NSString* caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (caches.length > 0)
        setenv("XDG_CACHE_HOME", caches.UTF8String, 1);

    ARMSX2ConfigureImGuiFonts("playtendo-setup");

    // SDL : seulement le son (ouvert par le moteur lui-même). Pas de fenêtre SDL ni de manettes SDL :
    // PlayTendo garde sa fenêtre et transmet lui-même les manettes et les boutons tactiles.
    SDL_SetMainReady();
    SDL_SetHint(SDL_HINT_AUDIO_CATEGORY, "playback");

    // Réglages (repris de SceneDelegate.mm).
    if (!s_settings_interface)
    {
        const std::string iniPath = Path::Combine(root, "PCSX2-iOS.ini");
        s_settings_interface = new INISettingsInterface(iniPath);
        if (!s_settings_interface->Load())
        {
            Console.WriteLn("PlayTendo : nouveaux réglages PS2 %s", iniPath.c_str());
            PTPS2WriteDefaults(s_settings_interface);
        }
        Host::Internal::SetBaseSettingsLayer(s_settings_interface);
        s_secrets_settings_interface = new INISettingsInterface(Path::Combine(root, "PCSX2-iOS-secrets.ini"));
        s_secrets_settings_interface->Load();
        Host::Internal::SetSecretsSettingsLayer(s_secrets_settings_interface);
        g_p44_settings_interface = s_settings_interface;
        for (int i = 0; i < 16; i++)
        {
            char key[32];
            snprintf(key, sizeof(key), "Button%d", i);
            s_buttonMap[i] = s_settings_interface->GetIntValue("ARMSX2iOS/GamepadMapping", key, s_defaultMap[i]);
        }
    }
    INISettingsInterface* si = s_settings_interface;
    si->SetStringValue("Folders", "Bios", biosDir);
    si->SetStringValue("Folders", "MemoryCards", memcardDir);
    si->SetStringValue("Folders", "Logs", "logs");
    // Avance rapide du menu pause : ×3, comme les autres consoles de PlayTendo.
    si->SetFloatValue("Framerate", "TurboScalar", 3.0f);
    // Manettes : lues par PlayTendo (GamepadManager) et transmises comme les boutons tactiles. Sans la source
    // SDL du moteur, une manette n'est pas lue deux fois.
    si->SetBoolValue("InputSources", "SDL", false);
    // Jamais de reprise automatique d'ARMSX2 : PlayTendo a sa propre sauvegarde rapide.
    si->SetBoolValue("ARMSX2iOS/Boot", "AutomaticLoadLastSaveState", false);
    // Pas de messages du moteur sur l'image (en anglais, ils renvoient aux réglages d'ARMSX2, absents ici, ex.
    // « Recommended Blending Accuracy… ») : PlayTendo affiche les siens et les erreurs du moteur.
    si->SetIntValue("EmuCore/GS", "OsdMessagesPos", static_cast<int>(OsdOverlayPos::None));
#if TARGET_OS_SIMULATOR
    // Le Metal du simulateur se dit « GPU Apple » mais refuse la lecture de l'image en cours dans un shader
    // (framebuffer fetch) : le moteur s'arrêtait au premier effet qui en a besoin. Un vrai iPhone la gère.
    si->SetBoolValue("EmuCore/GS", "DisableFramebufferFetch", true);
#endif
    ARMSX2RepairIOSARM64JITSettings(si, "playtendo-setup");
    ARMSX2MigrateJITScriptProtocolForIOS(si, "playtendo-setup");
    ARMSX2MigratePerGameDeinterlaceBlend(si);
    PTPS2FillMissing(si);
    ARMSX2EnsureIOSSpeedhackDefaults(si, "playtendo-setup");
    ARMSX2SanitizeFrameLimiterConfig("playtendo-setup");
    ARMSX2ApplyIOSMultitapConfig("playtendo-setup");
    si->Save();
    PTPS2ChooseBIOS();

    EmuConfig.GS.Renderer = GSRendererType::Metal;
    si->Save();
    VMManager::Internal::LoadStartupSettings();
    ARMSX2SanitizeFrameLimiterConfig("playtendo-startup-settings");
    ARMSX2ApplyIOSOsdPresetFromConfig("playtendo-startup-settings");
    ARMSX2IOSApplyRetroAchievementsOverlayDefaults(si, "playtendo-startup-settings");
    si->Save();
    VMManager::ApplySettings();

    // Vue Metal de la PS2 : PlayTendo la place dans son écran de jeu.
    ARMSX2_PrepareGameRenderViewForCurrentRenderer("playtendo-setup");
    s_launcher = [PCSX2SceneDelegate new];
    s_jitIsActive = reinterpret_cast<bool (*)(void)>(dlsym(RTLD_DEFAULT, "PTJITIsActive"));
    auto jitAlloc = reinterpret_cast<void* (*)(size_t, void**)>(dlsym(RTLD_DEFAULT, "PTJITAlloc"));
    auto jitFree = reinterpret_cast<void (*)(void*)>(dlsym(RTLD_DEFAULT, "PTJITFree"));
    if (s_jitIsActive && jitAlloc && jitFree)
        ARMSX2_PlayTendoSetCodeProvider(jitAlloc, jitFree);
    else
        Console.Warning("[PlayTendo] Réserve JIT de l'app introuvable : la PS2 n'aura pas de mode turbo sur iPhone");

    // Passage en arrière-plan : réglages de la console (NVRAM) et cartes mémoire écrits tout de suite,
    // comme dans ARMSX2 (iOS peut fermer l'app sans prévenir).
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil
                                                       queue:nil usingBlock:^(NSNotification*) {
        if (s_vmThreadActive.load(std::memory_order_relaxed) && !BiosPath.empty())
            cdvdSaveNVRAM();
        if (VMManager::HasValidVM())
        {
            Host::RunOnCPUThread([]() {
                if (VMManager::HasValidVM())
                    FileMcd_Flush();
            }, false);
        }
    }];

    Console.WriteLn("PlayTendo : moteur PS2 prêt (BIOS : %s)", EmuConfig.BaseFilenames.Bios.c_str());
    return (__bridge void*)g_gameRenderView;
}

PTPS2_EXPORT char* PTPS2PickBIOS(void)
{
    const std::string bios = PTPS2ChooseBIOS();
    return bios.empty() ? nullptr : strdup(bios.c_str());
}

// MARK: - Partie

PTPS2_EXPORT bool PTPS2Boot(const char* path)
{
    if (!s_launcher || !path)
        return false;
    if (PTPS2ChooseBIOS().empty())
        return false;
    PTPS2ClearError();
    [ARMSX2Bridge bootISO:[NSString stringWithUTF8String:path]];
    ARMSX2ApplyIOSMultitapConfig("playtendo-boot");
#if !TARGET_OS_SIMULATOR
    // Recompilateurs si la réserve JIT de l'app est prête (StikDebug est passé), sinon interpréteur (très lent).
    // Le simulateur autorise toujours le JIT : réserve de l'app si elle existe, sinon MAP_JIT.
    DarwinMisc::iPSX2_FORCE_EE_INTERP = (s_jitIsActive && s_jitIsActive()) ? 0 : 1;
    Console.WriteLn("[PlayTendo] Démarrage PS2 %s", DarwinMisc::iPSX2_FORCE_EE_INTERP ? "sans JIT (interpréteur)" : "avec JIT");
#endif
    [s_launcher startVMThread];
    return true;
}

PTPS2_EXPORT PTPS2State PTPS2GetState(void)
{
    if (!s_vmThreadActive.load(std::memory_order_acquire))
        return PTPS2StateStopped;
    switch (VMManager::GetState())
    {
        case VMState::Running: return PTPS2StateRunning;
        case VMState::Paused: return PTPS2StatePaused;
        default: return PTPS2StateStarting;
    }
}

PTPS2_EXPORT void PTPS2SetPaused(bool paused)
{
    [ARMSX2Bridge setVMPaused:paused];
}

PTPS2_EXPORT void PTPS2Stop(void)
{
    [ARMSX2Bridge requestVMStop];
}

PTPS2_EXPORT void PTPS2ReleaseMemory(void)
{
    if (PTPS2GetState() != PTPS2StateStopped)
        return;
    ARMSX2_PlayTendoReleaseVMThread();
    Console.WriteLn("PlayTendo : mémoire de la console PS2 rendue");
}

PTPS2_EXPORT void PTPS2Reset(void)
{
    Host::RunOnCPUThread([]() {
        if (VMManager::HasValidVM())
            VMManager::Reset();
    }, false);
}

PTPS2_EXPORT void PTPS2SetTurbo(bool enabled)
{
    Host::RunOnCPUThread([enabled]() {
        if (VMManager::HasValidVM())
            VMManager::SetLimiterMode(enabled ? LimiterModeType::Turbo : LimiterModeType::Nominal);
    }, false);
}

// MARK: - Entrées

static void PTPS2LogInput(const char* what, int index, float x, float y)
{
    PadBase* pad = Pad::GetPad(0, 0);
    if (!s_logInputs || !pad)
        return;
    const auto [lx, ly] = pad->GetRawLeftAnalog();
    const auto [rx, ry] = pad->GetRawRightAnalog();
    Console.WriteLn("PlayTendo entrée %s %d (%.2f, %.2f) → boutons=%04X gauche=%u,%u droite=%u,%u", what, index, x, y,
        pad->GetButtons(), lx, ly, rx, ry);
}

PTPS2_EXPORT void PTPS2SetButton(int retroPadButton, bool pressed)
{
    // Numéros RetroPad (PTButton) → boutons de la manette PS2.
    static const int map[16] = {
        ARMSX2PadButtonCross,    // B
        ARMSX2PadButtonSquare,   // Y
        ARMSX2PadButtonSelect,   // Select
        ARMSX2PadButtonStart,    // Start
        ARMSX2PadButtonUp,       // Haut
        ARMSX2PadButtonDown,     // Bas
        ARMSX2PadButtonLeft,     // Gauche
        ARMSX2PadButtonRight,    // Droite
        ARMSX2PadButtonCircle,   // A
        ARMSX2PadButtonTriangle, // X
        ARMSX2PadButtonL1,       // L
        ARMSX2PadButtonR1,       // R
        ARMSX2PadButtonL2,
        ARMSX2PadButtonR2,
        ARMSX2PadButtonL3,
        ARMSX2PadButtonR3,
    };
    if (retroPadButton < 0 || retroPadButton >= 16)
        return;
    [ARMSX2Bridge setPadButton:(ARMSX2PadButton)map[retroPadButton] pressed:pressed];
    PTPS2LogInput("bouton", retroPadButton, pressed ? 1 : 0, 0);
}

PTPS2_EXPORT void PTPS2SetStick(int stick, float x, float y)
{
    if (stick == 0)
        [ARMSX2Bridge setLeftStickX:x Y:y];
    else
        [ARMSX2Bridge setRightStickX:x Y:y];
    PTPS2LogInput("stick", stick, x, y);
}

// MARK: - Sauvegardes rapides

PTPS2_EXPORT bool PTPS2SaveState(const char* path)
{
    if (!path || !VMManager::HasValidVM())
        return false;
    const std::string target = path;
    auto error = std::make_shared<std::string>();
    bool started = false;
    VMManager::WaitForSaveStateFlush();
    Host::RunOnCPUThread([&target, &started, error]() {
        if (!VMManager::HasValidVM())
            return;
        // Un état pris pendant que le jeu écrit sur la carte mémoire abîmerait la sauvegarde du jeu.
        if (MemcardBusy::IsBusy())
        {
            *error = "carte mémoire en cours d'écriture, réessayer dans quelques secondes";
            return;
        }
        cdvdSaveNVRAM();
        FileMcd_Flush();
        started = true;
        VMManager::SaveState(target.c_str(), false, false, [error](const std::string& message) { *error = message; });
    }, true);
    VMManager::WaitForSaveStateFlush();
    if (!error->empty())
        PTPS2RecordError("Sauvegarde rapide", error->c_str());
    return started && error->empty() && FileSystem::FileExists(target.c_str());
}

PTPS2_EXPORT void PTPS2SetImageOptions(int upscale, bool smoothing, bool widescreen)
{
    if (!s_settings_interface)
        return;
    {
        auto lock = Host::GetSettingsLock();
        s_settings_interface->SetFloatValue("EmuCore/GS", "upscale_multiplier", static_cast<float>(std::clamp(upscale, 1, 4)));
        s_settings_interface->SetBoolValue("EmuCore/GS", "fxaa", smoothing);
        // Écran large : correctifs de patches.zip (fournis avec le moteur). Un jeu qui en a un passe tout seul en 16:9
        // (format « Auto ») ; les autres restent en 4:3.
        s_settings_interface->SetBoolValue("EmuCore", "EnableWideScreenPatches", widescreen);
        s_settings_interface->SetStringValue("EmuCore/GS", "AspectRatio", "Auto 4:3/3:2");
        s_settings_interface->Save();
    }
    [ARMSX2Bridge applyGraphicsSettingsNow]; // sans effet hors partie
}

PTPS2_EXPORT float PTPS2GetAspectRatio(void)
{
    if (!VMManager::HasValidVM())
        return 0.0f;
    // Comme GSRenderer (CalculateDrawDstRect) : « Auto » = 4:3, ou le format demandé par un correctif écran large.
    switch (EmuConfig.CurrentAspectRatio)
    {
        case AspectRatioType::R4_3:
            return 4.0f / 3.0f;
        case AspectRatioType::R16_9:
            return 16.0f / 9.0f;
        case AspectRatioType::RAuto4_3_3_2:
            return EmuConfig.CurrentCustomAspectRatio > 0.0f ? EmuConfig.CurrentCustomAspectRatio : 4.0f / 3.0f;
        default:
            return 0.0f;
    }
}

PTPS2_EXPORT void* PTPS2CopySnapshot(int* width, int* height)
{
    if (!width || !height || !VMManager::HasValidVM())
        return nullptr;
    u32 w = 0, h = 0;
    std::vector<u32> pixels;
    bool captured = false;
    // Même capture que celle des sauvegardes de PCSX2 (640×480, proportions du jeu), faite par le thread de la console.
    Host::RunOnCPUThread([&]() {
        if (VMManager::HasValidVM() && MTGS::IsOpen())
            captured = MTGS::SaveMemorySnapshot(640, 480, true, false, &w, &h, &pixels);
    }, true);
    if (!captured || w == 0 || h == 0 || pixels.size() < static_cast<size_t>(w) * h)
        return nullptr;
    const size_t bytes = static_cast<size_t>(w) * h * sizeof(u32);
    void* copy = malloc(bytes);
    if (!copy)
        return nullptr;
    memcpy(copy, pixels.data(), bytes);
    *width = static_cast<int>(w);
    *height = static_cast<int>(h);
    return copy;
}

PTPS2_EXPORT bool PTPS2LoadState(const char* path)
{
    if (!path || !VMManager::HasValidVM() || !FileSystem::FileExists(path))
        return false;
    const std::string target = path;
    bool loaded = false;
    std::string message;
    VMManager::WaitForSaveStateFlush();
    Host::RunOnCPUThread([&target, &loaded, &message]() {
        if (!VMManager::HasValidVM())
            return;
        Error error;
        loaded = VMManager::LoadState(target.c_str(), &error);
        if (!loaded)
            message = error.GetDescription();
    }, true);
    if (!loaded)
        PTPS2RecordError("Chargement", message.c_str());
    return loaded;
}

PTPS2_EXPORT char* PTPS2CopyLastError(void)
{
    std::lock_guard<std::mutex> lock(s_errorMutex);
    return s_lastError.empty() ? nullptr : strdup(s_lastError.c_str());
}
