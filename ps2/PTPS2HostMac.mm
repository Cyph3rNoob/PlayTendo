// PTPS2HostMac.mm — pilote du moteur PS2 de l'app PlayTendo pour Mac (cœur PCSX2 d'ARMSX2 2.6.0, GPL-3.0).
//
// Sur iPhone, le moteur reprend la couche iOS d'ARMSX2 (UIKit, ps2/PTPS2Host.mm). Sur Mac, il n'en garde que le cœur
// PCSX2, qui sait déjà tourner sur macOS (affichage Metal, son Cubeb, recompilateurs ARM64 avec MAP_JIT), et ce
// fichier joue le rôle de l'interface : les fonctions « Host:: » que le cœur appelle (calquées sur pcsx2-sdl/Main.cpp
// d'ARMSX2), le thread de la console et les fonctions PTPS2* de PlayTendo (mêmes que sur iPhone, PTPS2.h).
// Compilé dans PS2Core.framework par scripts/build_ps2.sh mac ; l'app y accède par dlopen/dlsym (PTPS2Engine.m).
// Compilé avec ARC.

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>
#include <sys/stat.h>

#include "common/Console.h"
#include "common/Error.h"
#include "common/FileSystem.h"
#include "common/Path.h"
#include "common/ProgressCallback.h"
#include "common/SmallString.h"
#include "common/Threading.h"
#include "common/WindowInfo.h"
#include "pcsx2/Achievements.h"
#include "pcsx2/CDVD/CDVD.h"
#include "pcsx2/Config.h"
#include "pcsx2/GS.h"
#include "pcsx2/GameList.h"
#include "pcsx2/Host.h"
#include "pcsx2/INISettingsInterface.h"
#include "pcsx2/ImGui/FullscreenUI.h"
#include "pcsx2/ImGui/ImGuiFullscreen.h"
#include "pcsx2/ImGui/ImGuiManager.h"
#include "pcsx2/Input/InputManager.h"
#include "pcsx2/MTGS.h"
#include "pcsx2/SIO/Memcard/MemoryCardFile.h"
#include "pcsx2/SIO/Pad/Pad.h"
#include "pcsx2/SIO/Pad/PadDualshock2.h"
#include "pcsx2/SIO/Sio.h"
#include "pcsx2/VMManager.h"
#include "pcsx2/ps2/BiosTools.h"

#import <AppKit/AppKit.h>

#include "PTPS2.h"

#define PTPS2_EXPORT extern "C" __attribute__((visibility("default")))

// MARK: - État

/// Vue où la PS2 dessine : le cœur y pose sa couche Metal (GSDeviceMTL, AttachSurfaceOnMainThread). PlayTendo la
/// place dans son écran de jeu ; la souris et le clavier vont à l'écran de jeu posé par-dessus.
@interface PTPS2View : NSView
@end

static PTPS2View* s_view;
static std::unique_ptr<INISettingsInterface> s_settings;
static std::unique_ptr<INISettingsInterface> s_secrets;

/// Fenêtre donnée au cœur : la vue, en pixels (mise à jour sur le thread principal quand la vue change de taille).
static std::mutex s_windowMutex;
static WindowInfo s_windowInfo;

// Thread de la console : permanent une fois lancé (le cœur n'aime pas être réinitialisé), il démarre les jeux
// demandés et exécute les commandes de PlayTendo (Host::RunOnCPUThread).
static std::atomic<std::thread::id> s_cpuThreadId{};
static std::mutex s_queueMutex;
static std::condition_variable s_queueCV;
static std::deque<std::function<void()>> s_queue;
static std::optional<VMBootParameters> s_pendingBoot;  // sous s_queueMutex
static std::atomic<bool> s_booting{false};
// Prochain démarrage (PTPS2SetBootOptions) : reprise automatique à charger, démarrage rapide (sans le logo PS2).
static std::string s_bootState;
static bool s_fastBoot = false;
// Reprise du dernier démarrage : -1 aucune, 1 chargée, 0 illisible (jeu démarré du début).
static std::atomic<int> s_bootStateResult{-1};
/// Fermeture de l'app : le thread de la console s'arrête (PTPS2Shutdown) avant la sortie du programme.
static std::atomic<bool> s_quit{false};
static std::atomic<bool> s_cpuThreadDone{false};

static std::mutex s_errorMutex;
static std::string s_lastError;

static void PTPS2RecordError(const std::string_view title, const std::string_view message)
{
    std::lock_guard<std::mutex> lock(s_errorMutex);
    s_lastError = std::string(title) + (title.empty() || message.empty() ? "" : " : ") + std::string(message);
}

static void PTPS2ClearError()
{
    std::lock_guard<std::mutex> lock(s_errorMutex);
    s_lastError.clear();
}

// MARK: - Vue

@implementation PTPS2View

- (BOOL)isFlipped
{
    return YES;
}

/// La souris et le clavier vont à l'écran de jeu de PlayTendo, posé par-dessus.
- (NSView*)hitTest:(NSPoint)point
{
    return nil;
}

- (void)updateWindowInfo
{
    const CGFloat scale = self.window ? self.window.backingScaleFactor : NSScreen.mainScreen.backingScaleFactor;
    const NSSize size = self.bounds.size;
    const u32 width = static_cast<u32>(std::max<CGFloat>(1, size.width * scale));
    const u32 height = static_cast<u32>(std::max<CGFloat>(1, size.height * scale));
    {
        std::lock_guard<std::mutex> lock(s_windowMutex);
        if (s_windowInfo.surface_width == width && s_windowInfo.surface_height == height &&
            s_windowInfo.surface_scale == static_cast<float>(scale))
            return;
        s_windowInfo.surface_width = width;
        s_windowInfo.surface_height = height;
        s_windowInfo.surface_scale = static_cast<float>(scale);
    }
    if (VMManager::HasValidVM() && MTGS::IsOpen())
        MTGS::ResizeDisplayWindow(width, height, static_cast<float>(scale));
}

- (void)layout
{
    [super layout];
    [self updateWindowInfo];
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    [self updateWindowInfo];
}

- (void)viewDidChangeBackingProperties
{
    [super viewDidChangeBackingProperties];
    [self updateWindowInfo];
}

@end

// MARK: - Réglages

/// Réglages imposés par PlayTendo (repris du pilote iPhone, adaptés au Mac).
static void PTPS2ApplyFixedSettings(INISettingsInterface* si, const char* biosDir, const char* memcardDir)
{
    si->SetStringValue("Folders", "Bios", biosDir);
    si->SetStringValue("Folders", "MemoryCards", memcardDir);
    si->SetStringValue("Folders", "Logs", "logs");
    // Recompilateurs ARM64 (le cœur prend sa mémoire exécutable avec MAP_JIT, permis à l'app signée localement).
    si->SetIntValue("EmuCore/CPU", "CoreType", 2);
    si->SetBoolValue("EmuCore/CPU", "UseArm64Dynarec", true);
    si->SetBoolValue("EmuCore/CPU/Recompiler", "EnableEE", true);
    si->SetBoolValue("EmuCore/CPU/Recompiler", "EnableIOP", true);
    si->SetBoolValue("EmuCore/CPU/Recompiler", "EnableVU0", true);
    si->SetBoolValue("EmuCore/CPU/Recompiler", "EnableVU1", true);
    si->SetBoolValue("EmuCore/CPU/Recompiler", "EnableFastmem", true);
    si->SetIntValue("EmuCore/GS", "Renderer", static_cast<int>(GSRendererType::Metal));
    // Son par Cubeb (CoreAudio), comme PCSX2 sur Mac.
    si->SetStringValue("SPU2/Output", "Backend", "Cubeb");
    // Avance rapide du menu pause : ×3, comme les autres consoles de PlayTendo.
    si->SetFloatValue("Framerate", "TurboScalar", 3.0f);
    // Manettes et clavier : lus par PlayTendo et transmis à la manette PS2 (PTPS2SetButton/Stick). Sans les sources
    // du moteur, rien n'est lu deux fois.
    si->SetBoolValue("InputSources", "SDL", false);
    // Pas de messages du moteur sur l'image (en anglais) : PlayTendo affiche les siens et les erreurs du moteur.
    si->SetIntValue("EmuCore/GS", "OsdMessagesPos", static_cast<int>(OsdOverlayPos::None));
    si->SetBoolValue("EmuCore", "EnableFastBoot", false);
    si->SetBoolValue("Achievements", "Enabled", false);
    si->SetBoolValue("Achievements", "ChallengeMode", false);
    // Jamais de reprise automatique : PlayTendo a sa propre sauvegarde rapide.
    si->SetBoolValue("EmuCore", "SaveStateOnShutdown", false);
}

/// Police de l'affichage du moteur (ImGui), comme pcsx2-sdl.
static bool PTPS2LoadFonts()
{
    const std::string roboto = EmuFolders::GetOverridableResourcePath("fonts" FS_OSPATH_SEPARATOR_STR "Roboto-Regular.ttf");
    const auto data = FileSystem::MapBinaryFileForRead(roboto.c_str());
    if (data.empty())
    {
        Console.ErrorFmt("[PlayTendo] Police introuvable : {}", roboto);
        return false;
    }
    std::vector<ImGuiManager::FontInfo> fonts;
    ImGuiManager::FontInfo font{};
    font.data = data;
    fonts.push_back(font);
    ImGuiManager::SetFonts(std::move(fonts));
    return true;
}

// MARK: - BIOS

static bool PTPS2IsBIOS(const std::string& path)
{
    u32 version = 0, region = 0;
    std::string description, zone;
    return IsBIOS(path.c_str(), version, description, region, zone);
}

/// BIOS retenu : celui des réglages s'il est toujours là, sinon le premier valide du dossier (ordre alphabétique,
/// comme la liste de Réglages › BIOS PS2).
static std::string PTPS2ChooseBIOS()
{
    if (!s_settings || EmuFolders::Bios.empty())
        return {};
    const std::string current = s_settings->GetStringValue("Filenames", "BIOS", "");
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
        {
            auto lock = Host::GetSettingsLock();
            s_settings->SetStringValue("Filenames", "BIOS", file.UTF8String);
            s_settings->Save();
        }
        EmuConfig.BaseFilenames.Bios = file.UTF8String;
        Console.WriteLn("PlayTendo : BIOS PS2 choisi %s", file.UTF8String);
        return file.UTF8String;
    }
    EmuConfig.BaseFilenames.Bios.clear();
    return {};
}

// MARK: - Thread de la console

static void PTPS2DrainQueue()
{
    for (;;)
    {
        std::function<void()> function;
        {
            std::lock_guard<std::mutex> lock(s_queueMutex);
            if (s_queue.empty())
                return;
            function = std::move(s_queue.front());
            s_queue.pop_front();
        }
        function();
    }
}

static void PTPS2CPUThreadMain()
{
    Threading::SetNameOfCurrentThread("PS2 (PlayTendo)");
    s_cpuThreadId.store(std::this_thread::get_id(), std::memory_order_release);
    if (!VMManager::Internal::CPUThreadInitialize())
    {
        PTPS2RecordError("PS2", "le thread de la console n'a pas pu démarrer");
        Console.Error("[PlayTendo] CPUThreadInitialize a échoué");
        VMManager::Internal::CPUThreadShutdown();
        s_cpuThreadId.store(std::thread::id{}, std::memory_order_release);
        return;
    }
    VMManager::ApplySettings();

    while (!s_quit.load(std::memory_order_acquire))
    {
        PTPS2DrainQueue();
        switch (VMManager::GetState())
        {
            case VMState::Initializing:
                continue;
            case VMState::Running:
                VMManager::Execute();
                continue;
            case VMState::Resetting:
                VMManager::Reset();
                continue;
            case VMState::Stopping:
                VMManager::Shutdown(false);
                continue;
            case VMState::Paused:
            case VMState::Shutdown:
            default:
            {
                std::optional<VMBootParameters> boot;
                {
                    std::unique_lock<std::mutex> lock(s_queueMutex);
                    if (!s_pendingBoot.has_value() && s_queue.empty())
                        s_queueCV.wait_for(lock, std::chrono::milliseconds(16));
                    if (VMManager::GetState() != VMState::Paused || !VMManager::HasValidVM())
                        boot.swap(s_pendingBoot);
                }
                if (boot.has_value())
                {
                    Error error;
                    VMBootResult result = VMManager::Initialize(*boot, &error);
                    if (result != VMBootResult::StartupSuccess && !boot->save_state.empty())
                    {
                        // Reprise illisible (autre version du moteur, fichier abîmé) : le jeu démarre du début plutôt
                        // que pas du tout.
                        Console.ErrorFmt("[PlayTendo] Reprise illisible ({}), démarrage normal", error.GetDescription());
                        s_bootStateResult.store(0);
                        boot->save_state.clear();
                        error = Error();
                        result = VMManager::Initialize(*boot, &error);
                    }
                    else if (result == VMBootResult::StartupSuccess && !boot->save_state.empty())
                    {
                        s_bootStateResult.store(1);
                    }
                    if (result == VMBootResult::StartupSuccess)
                    {
                        VMManager::SetState(VMState::Running);
                    }
                    else
                    {
                        Console.ErrorFmt("[PlayTendo] Démarrage du jeu impossible ({}) : {}", static_cast<int>(result),
                            error.GetDescription());
                        if (!error.GetDescription().empty())
                            PTPS2RecordError("Démarrage", error.GetDescription());
                    }
                    s_booting.store(false, std::memory_order_release);
                }
                continue;
            }
        }
    }

    // Fermeture : partie arrêtée (cartes mémoire écrites), puis le cœur rend tout.
    if (VMManager::HasValidVM())
        VMManager::Shutdown(false);
    VMManager::Internal::CPUThreadShutdown();
    s_cpuThreadId.store(std::thread::id{}, std::memory_order_release);
    {
        std::lock_guard<std::mutex> lock(s_queueMutex);
        s_cpuThreadDone.store(true, std::memory_order_release);
    }
    s_queueCV.notify_all();
}

static void PTPS2EnsureCPUThread()
{
    static std::once_flag started;
    std::call_once(started, []() { std::thread(PTPS2CPUThreadMain).detach(); });
}

// MARK: - Host

void Host::CommitBaseSettingChanges()
{
    if (!s_settings)
        return;
    Error error;
    if (!s_settings->Save(&error))
        Console.ErrorFmt("Failed to save settings: {}", error.GetDescription());
}

void Host::LoadSettings(SettingsInterface& si, std::unique_lock<std::mutex>& lock) {}
void Host::CheckForSettingsChanges(const Pcsx2Config& old_config) {}
bool Host::RequestResetSettings(bool folders, bool core, bool controllers, bool hotkeys, bool ui) { return false; }
void Host::SetDefaultUISettings(SettingsInterface& si) {}
bool Host::LocaleCircleConfirm() { return false; }

std::unique_ptr<ProgressCallback> Host::CreateHostProgressCallback()
{
    return ProgressCallback::CreateNullProgressCallback();
}

void Host::ReportInfoAsync(const std::string_view title, const std::string_view message)
{
    if (!message.empty())
        INFO_LOG("{}: {}", title, message);
}

/// Erreurs du moteur : notées pour PlayTendo, qui affiche la dernière en cas d'échec.
void Host::ReportErrorAsync(const std::string_view title, const std::string_view message)
{
    if (!message.empty())
        ERROR_LOG("{}: {}", title, message);
    PTPS2RecordError(title, message);
}

void Host::OpenURL(const std::string_view url) {}
bool Host::CopyTextToClipboard(const std::string_view text) { return false; }
std::string Host::GetTextFromClipboard() { return {}; }
void Host::BeginTextInput() {}
void Host::EndTextInput() {}

std::optional<WindowInfo> Host::GetTopLevelWindowInfo()
{
    std::lock_guard<std::mutex> lock(s_windowMutex);
    return s_windowInfo;
}

void Host::OnInputDeviceConnected(const std::string_view identifier, const std::string_view device_name) {}
void Host::OnInputDeviceDisconnected(const InputBindingKey key, const std::string_view identifier) {}
void Host::SetMouseMode(bool relative_mode, bool hide_cursor) {}
void Host::SetMouseLock(bool state) {}

std::optional<WindowInfo> Host::AcquireRenderWindow(bool recreate_window)
{
    std::lock_guard<std::mutex> lock(s_windowMutex);
    if (!s_windowInfo.window_handle)
        return std::nullopt;
    return s_windowInfo;
}

void Host::ReleaseRenderWindow() {}
void Host::BeginPresentFrame() {}
void Host::RequestResizeHostDisplay(s32 width, s32 height) {}
void Host::OnVMStarting() {}
void Host::OnVMStarted() {}
void Host::OnVMDestroyed() {}
void Host::OnVMPaused() {}
void Host::OnVMResumed() {}

void Host::OnGameChanged(const std::string& title, const std::string& elf_override, const std::string& disc_path,
    const std::string& disc_serial, u32 disc_crc, u32 current_crc)
{
    if (!title.empty())
        INFO_LOG("Game changed: {} (serial {}, CRC {:08X})", title, disc_serial, current_crc);
}

void Host::OnPerformanceMetricsUpdated() {}
void Host::OnSaveStateLoading(const std::string_view filename) {}
void Host::OnSaveStateLoaded(const std::string_view filename, bool was_successful) {}
void Host::OnSaveStateSaved(const std::string_view filename) {}

void Host::PumpMessagesOnCPUThread()
{
    PTPS2DrainQueue();
}

void Host::RunOnCPUThread(std::function<void()> function, bool block)
{
    if (block && s_cpuThreadId.load(std::memory_order_acquire) == std::this_thread::get_id())
    {
        function();
        return;
    }
    if (!block)
    {
        {
            std::lock_guard<std::mutex> lock(s_queueMutex);
            s_queue.emplace_back(std::move(function));
        }
        s_queueCV.notify_all();
        return;
    }
    auto done = std::make_shared<std::pair<std::mutex, std::condition_variable>>();
    auto finished = std::make_shared<bool>(false);
    {
        std::lock_guard<std::mutex> lock(s_queueMutex);
        s_queue.emplace_back([&function, done, finished]() {
            function();
            std::lock_guard<std::mutex> lock(done->first);
            *finished = true;
            done->second.notify_all();
        });
    }
    s_queueCV.notify_all();
    std::unique_lock<std::mutex> lock(done->first);
    done->second.wait(lock, [finished]() { return *finished; });
}

void Host::RefreshGameListAsync(bool invalidate_cache) {}
void Host::CancelGameListRefresh() {}
bool Host::IsFullscreen() { return false; }
void Host::SetFullscreen(bool enabled) {}
void Host::RequestExitApplication(bool allow_confirm) {}
void Host::RequestExitBigPicture() {}

void Host::RequestVMShutdown(bool allow_confirm, bool allow_save_state, bool default_save_state)
{
    if (VMManager::HasValidVM())
        VMManager::SetState(VMState::Stopping);
}

void Host::OnAchievementsLoginSuccess(const char* username, u32 points, u32 sc_points, u32 unread_messages) {}
void Host::OnAchievementsLoginRequested(Achievements::LoginRequestReason reason) {}
void Host::OnAchievementsHardcoreModeChanged(bool enabled) {}
bool Host::HasNativeAchievementNotifications() { return false; }
void Host::OnAchievementNotification(const char*, float, const char*, const char*, const char*) {}
void Host::OnAchievementsRefreshed() {}
void Host::OnCoverDownloaderOpenRequested() {}
void Host::OnCreateMemoryCardOpenRequested() {}
bool Host::InBatchMode() { return false; }
bool Host::InNoGUIMode() { return true; }
bool Host::ShouldPreferHostFileSelector() { return false; }

void Host::OpenHostFileSelectorAsync(std::string_view title, bool select_directory, FileSelectorCallback callback,
    FileSelectorFilters filters, std::string_view initial_directory)
{
    callback(std::string());
}

int Host::LocaleSensitiveCompare(std::string_view lhs, std::string_view rhs)
{
    const int result = std::strncmp(lhs.data(), rhs.data(), std::min(lhs.size(), rhs.size()));
    if (result != 0)
        return result;
    return lhs.size() > rhs.size() ? 1 : (lhs.size() < rhs.size() ? -1 : 0);
}

s32 Host::Internal::GetTranslatedStringImpl(
    const std::string_view context, const std::string_view msg, char* tbuf, size_t tbuf_space)
{
    if (msg.size() > tbuf_space)
        return -1;
    if (msg.empty())
        return 0;
    std::memcpy(tbuf, msg.data(), msg.size());
    return static_cast<s32>(msg.size());
}

std::string Host::TranslatePluralToString(const char* context, const char* msg, const char* disambiguation, int count)
{
    TinyString count_str = TinyString::from_format("{}", count);
    std::string result(msg);
    for (std::string::size_type pos; (pos = result.find("%n")) != std::string::npos;)
        result.replace(pos, 2, count_str.view());
    return result;
}

std::optional<u32> InputManager::ConvertHostKeyboardStringToCode(const std::string_view str) { return std::nullopt; }
std::optional<std::string> InputManager::ConvertHostKeyboardCodeToString(u32 code) { return std::nullopt; }
const char* InputManager::ConvertHostKeyboardCodeToIcon(u32 code) { return nullptr; }

BEGIN_HOTKEY_LIST(g_host_hotkeys)
END_HOTKEY_LIST()

// MARK: - Préparation

PTPS2_EXPORT void* PTPS2Setup(const char* dataRoot, const char* biosDir, const char* memcardDir)
{
    if (s_view)
        return (__bridge void*)s_view;
    if (!dataRoot || !biosDir || !memcardDir)
        return nullptr;

    const std::string root = dataRoot;
    mkdir(root.c_str(), 0755);
    for (const char* dir : {"logs", "sstates", "snaps", "cheats", "patches", "cache", "covers", "gamesettings",
                            "textures", "inputprofiles", "inis", "videos"})
        mkdir(Path::Combine(root, dir).c_str(), 0755);
    mkdir(biosDir, 0755);
    mkdir(memcardDir, 0755);

    // Fichiers du moteur (GameIndex, polices, shaders Metal…) : dans les ressources de PS2Core.framework.
    NSString* resources = [NSBundle bundleForClass:[PTPS2View class]].resourcePath;
    EmuFolders::AppRoot = resources.UTF8String;
    EmuFolders::Resources = resources.UTF8String;
    EmuFolders::DataRoot = root;
    EmuFolders::Settings = Path::Combine(root, "inis");
    EmuFolders::Bios = biosDir;
    EmuFolders::MemoryCards = memcardDir;
    EmuFolders::Logs = Path::Combine(root, "logs");

    // Journal du moteur, remis à zéro à chaque lancement (comme sur iPhone : logs/emulog.txt).
    Log::SetFileOutputLevel(LOGLEVEL_INFO, Path::Combine(EmuFolders::Logs, "emulog.txt"));
    Log::SetConsoleOutputLevel(LOGLEVEL_NONE);

    const char* hardwareError = nullptr;
    if (!VMManager::PerformEarlyHardwareChecks(&hardwareError))
    {
        PTPS2RecordError("PS2", hardwareError ? hardwareError : "vérification du matériel refusée");
        return nullptr;
    }
    PTPS2LoadFonts();

    // Réglages (même nom de fichier que sur iPhone : Réglages › BIOS PS2 y lit le BIOS utilisé).
    const std::string iniPath = Path::Combine(root, "PCSX2-iOS.ini");
    s_settings = std::make_unique<INISettingsInterface>(iniPath);
    Host::Internal::SetBaseSettingsLayer(s_settings.get());
    if (!s_settings->Load() || !VMManager::Internal::CheckSettingsVersion())
    {
        Console.WriteLn("PlayTendo : nouveaux réglages PS2 %s", iniPath.c_str());
        VMManager::SetDefaultSettings(*s_settings, true, true, true, true, true);
    }
    s_secrets = std::make_unique<INISettingsInterface>(Path::Combine(root, "PCSX2-iOS-secrets.ini"));
    s_secrets->Load();
    Host::Internal::SetSecretsSettingsLayer(s_secrets.get());
    {
        auto lock = Host::GetSettingsLock();
        PTPS2ApplyFixedSettings(s_settings.get(), biosDir, memcardDir);
        s_settings->Save();
    }
    PTPS2ChooseBIOS();
    VMManager::Internal::LoadStartupSettings();

    // Vue de la PS2 (le cœur y pose sa couche Metal au démarrage d'un jeu).
    s_view = [[PTPS2View alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)];
    s_view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    {
        std::lock_guard<std::mutex> lock(s_windowMutex);
        s_windowInfo = WindowInfo();
        s_windowInfo.type = WindowInfo::Type::MacOS;
        s_windowInfo.window_handle = (__bridge void*)s_view;
        s_windowInfo.surface_width = 1280;
        s_windowInfo.surface_height = 960;
        s_windowInfo.surface_scale = 2.0f;
    }

    // Mémoire de la console (adresses réservées une fois), puis son thread.
    SysMemory::ReserveMemory();
    PTPS2EnsureCPUThread();

    Console.WriteLn("PlayTendo : moteur PS2 prêt pour Mac (BIOS : %s)", EmuConfig.BaseFilenames.Bios.c_str());
    return (__bridge void*)s_view;
}

/// Fermeture de l'app : partie arrêtée, puis le thread de la console (sinon il tournerait encore pendant que le
/// programme se termine). Attend au plus 5 s.
PTPS2_EXPORT void PTPS2Shutdown(void)
{
    if (!s_view || s_cpuThreadId.load(std::memory_order_acquire) == std::thread::id{})
        return;
    s_quit.store(true, std::memory_order_release);
    s_queueCV.notify_all();
    std::unique_lock<std::mutex> lock(s_queueMutex);
    s_queueCV.wait_for(lock, std::chrono::seconds(5), []() { return s_cpuThreadDone.load(std::memory_order_acquire); });
}

PTPS2_EXPORT char* PTPS2PickBIOS(void)
{
    const std::string bios = PTPS2ChooseBIOS();
    return bios.empty() ? nullptr : strdup(bios.c_str());
}

// MARK: - Partie

PTPS2_EXPORT bool PTPS2Boot(const char* path)
{
    if (!s_view || !path)
        return false;
    if (PTPS2ChooseBIOS().empty())
        return false;
    PTPS2ClearError();
    [s_view updateWindowInfo];
    VMBootParameters params;
    params.filename = path;
    params.fast_boot = s_fastBoot;
    // Reprise automatique : la console démarre directement sur la partie (ni logo ni son de démarrage).
    params.save_state = std::move(s_bootState);
    s_bootState.clear();
    s_bootStateResult.store(-1);
    {
        std::lock_guard<std::mutex> lock(s_queueMutex);
        s_pendingBoot = std::move(params);
        s_booting.store(true, std::memory_order_release);
    }
    s_queueCV.notify_all();
    Console.WriteLn("[PlayTendo] Démarrage PS2 : %s", path);
    return true;
}

PTPS2_EXPORT void PTPS2SetBootOptions(const char* statePath, bool fastBoot)
{
    s_bootState = statePath ? statePath : "";
    s_fastBoot = fastBoot;
}

PTPS2_EXPORT int PTPS2GetBootStateResult(void)
{
    return s_bootStateResult.load();
}

PTPS2_EXPORT PTPS2State PTPS2GetState(void)
{
    if (s_booting.load(std::memory_order_acquire))
        return PTPS2StateStarting;
    if (!VMManager::HasValidVM())
        return PTPS2StateStopped;
    switch (VMManager::GetState())
    {
        case VMState::Running: return PTPS2StateRunning;
        case VMState::Paused: return PTPS2StatePaused;
        case VMState::Shutdown: return PTPS2StateStopped;
        default: return PTPS2StateStarting;
    }
}

PTPS2_EXPORT void PTPS2SetPaused(bool paused)
{
    Host::RunOnCPUThread([paused]() {
        if (!VMManager::HasValidVM())
            return;
        const VMState state = VMManager::GetState();
        if (paused && state == VMState::Running)
            VMManager::SetPaused(true);
        else if (!paused && state == VMState::Paused)
            VMManager::SetPaused(false);
    }, false);
}

PTPS2_EXPORT void PTPS2Stop(void)
{
    {
        std::lock_guard<std::mutex> lock(s_queueMutex);
        s_pendingBoot.reset();
        s_booting.store(false, std::memory_order_release);
    }
    Host::RunOnCPUThread([]() {
        if (VMManager::HasValidVM())
            VMManager::SetState(VMState::Stopping);
    }, false);
}

/// Mac : rien à rendre (assez d'adresses pour toutes les consoles).
PTPS2_EXPORT void PTPS2ReleaseMemory(void) {}

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

PTPS2_EXPORT void PTPS2SetButton(int retroPadButton, bool pressed)
{
    // Numéros RetroPad (PTButton) → boutons de la manette PS2 (comme ARMSX2Bridge setPadButton sur iPhone).
    static const u32 map[16] = {
        PadDualshock2::Inputs::PAD_CROSS,    // B
        PadDualshock2::Inputs::PAD_SQUARE,   // Y
        PadDualshock2::Inputs::PAD_SELECT,   // Select
        PadDualshock2::Inputs::PAD_START,    // Start
        PadDualshock2::Inputs::PAD_UP,       // Haut
        PadDualshock2::Inputs::PAD_DOWN,     // Bas
        PadDualshock2::Inputs::PAD_LEFT,     // Gauche
        PadDualshock2::Inputs::PAD_RIGHT,    // Droite
        PadDualshock2::Inputs::PAD_CIRCLE,   // A
        PadDualshock2::Inputs::PAD_TRIANGLE, // X
        PadDualshock2::Inputs::PAD_L1,       // L
        PadDualshock2::Inputs::PAD_R1,       // R
        PadDualshock2::Inputs::PAD_L2,
        PadDualshock2::Inputs::PAD_R2,
        PadDualshock2::Inputs::PAD_L3,
        PadDualshock2::Inputs::PAD_R3,
    };
    if (retroPadButton < 0 || retroPadButton >= 16)
        return;
    if (auto* pad = static_cast<PadDualshock2*>(Pad::GetPad(0, 0)))
        pad->Set(map[retroPadButton], pressed ? 1.0f : 0.0f);
}

PTPS2_EXPORT void PTPS2SetStick(int stick, float x, float y)
{
    auto* pad = static_cast<PadDualshock2*>(Pad::GetPad(0, 0));
    if (!pad)
        return;
    const float right = x > 0 ? x : 0.0f;
    const float left = x < 0 ? -x : 0.0f;
    const float down = y > 0 ? y : 0.0f;
    const float up = y < 0 ? -y : 0.0f;
    if (stick == 0)
    {
        pad->Set(PadDualshock2::Inputs::PAD_L_RIGHT, right);
        pad->Set(PadDualshock2::Inputs::PAD_L_LEFT, left);
        pad->Set(PadDualshock2::Inputs::PAD_L_DOWN, down);
        pad->Set(PadDualshock2::Inputs::PAD_L_UP, up);
    }
    else
    {
        pad->Set(PadDualshock2::Inputs::PAD_R_RIGHT, right);
        pad->Set(PadDualshock2::Inputs::PAD_R_LEFT, left);
        pad->Set(PadDualshock2::Inputs::PAD_R_DOWN, down);
        pad->Set(PadDualshock2::Inputs::PAD_R_UP, up);
    }
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
        PTPS2RecordError("Sauvegarde rapide", *error);
    return started && error->empty() && FileSystem::FileExists(target.c_str());
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
        PTPS2RecordError("Chargement", message);
    return loaded;
}

// MARK: - Image

PTPS2_EXPORT void PTPS2SetImageOptions(int upscale, bool smoothing, bool widescreen)
{
    if (!s_settings)
        return;
    {
        auto lock = Host::GetSettingsLock();
        s_settings->SetFloatValue("EmuCore/GS", "upscale_multiplier", static_cast<float>(std::clamp(upscale, 1, 4)));
        s_settings->SetBoolValue("EmuCore/GS", "fxaa", smoothing);
        // Écran large : correctifs de patches.zip (fournis avec le moteur). Un jeu qui en a un passe tout seul en 16:9
        // (format « Auto ») ; les autres restent en 4:3.
        s_settings->SetBoolValue("EmuCore", "EnableWideScreenPatches", widescreen);
        s_settings->SetStringValue("EmuCore/GS", "AspectRatio", "Auto 4:3/3:2");
        s_settings->Save();
    }
    Host::RunOnCPUThread([]() {
        if (!VMManager::HasValidVM())
            return;
        VMManager::ApplySettings();
        if (MTGS::IsOpen())
            MTGS::ApplySettings();
    }, false);
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

PTPS2_EXPORT char* PTPS2CopyLastError(void)
{
    std::lock_guard<std::mutex> lock(s_errorMutex);
    return s_lastError.empty() ? nullptr : strdup(s_lastError.c_str());
}
