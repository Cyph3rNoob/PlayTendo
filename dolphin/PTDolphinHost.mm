// PTDolphinHost.mm — pilote du moteur GameCube/Wii de PlayTendo (tiré de DolphiniOS 5.0.0b6, GPL-2.0+).
//
// Remplace l'interface de DolphiniOS (services de démarrage, écran de jeu, commandes tactiles) : PlayTendo
// garde sa fenêtre et place lui-même la vue Metal où Dolphin dessine. Le cœur Dolphin et la file « hôte » de
// DolphiniOS (Source/iOS/Library : Host.mm, HostQueue.mm) sont repris tels quels. Compilé dans
// DolphinCore.framework par scripts/build_dolphin.sh ; l'app y accède par dlopen/dlsym
// (app/PlayTendo/Emulation/PTDolphinEngine.m). Compilé avec ARC, comme tout DolphiniOS.
//
// Le même fichier sert à l'app Mac (build_dolphin.sh mac) : vue AppKit, son par Cubeb (celui de Dolphin pour Mac),
// turbo par la mémoire MAP_JIT de Dolphin (l'app Mac n'a pas besoin de la réserve à deux vues de l'iPhone).

#include "PTDolphin.h"

#import <MetalKit/MetalKit.h>
#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#else
#import <AppKit/AppKit.h>
#endif

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <dlfcn.h>
#include <initializer_list>
#include <mach/mach.h>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "Common/FileUtil.h"
#include "Common/IniFile.h"
#include "Common/Logging/Log.h"
#include "Common/MemoryUtil.h"
#include "Common/MsgHandler.h"
#include "Common/WindowSystemInfo.h"
#include "Core/ARDecrypt.h"
#include "Core/ActionReplay.h"
#include "Core/Boot/Boot.h"
#include "Core/BootManager.h"
#include "Core/Config/GraphicsSettings.h"
#include "Core/Config/MainSettings.h"
#include "Core/Config/WiimoteSettings.h"
#include "Core/Config/UISettings.h"
#include "Core/ConfigManager.h"
#include "Core/Core.h"
#include "Core/DolphinAnalytics.h"
#include "Core/GeckoCode.h"
#include "Core/GeckoCodeConfig.h"
#include "Core/HW/DVD/DVDInterface.h"
#include "Core/HW/GCPad.h"
#include "Core/HW/SI/SI.h"
#include "Core/HW/SI/SI_Device.h"
#include "Core/HW/ProcessorInterface.h"
#include "Core/HW/Wiimote.h"
#include "Core/PowerPC/PowerPC.h"
#include "Core/State.h"
#include "Core/System.h"
#include "InputCommon/ControllerEmu/ControllerEmu.h"
#include "InputCommon/ControllerInterface/ControllerInterface.h"
#include "InputCommon/ControllerInterface/iOS/StateManager.h"
#include "InputCommon/InputConfig.h"
#include "UICommon/UICommon.h"
#include "VideoCommon/FrameDumper.h"
#include "VideoCommon/PerformanceMetrics.h"
#include "VideoCommon/Present.h"
#include "VideoCommon/VideoConfig.h"
#include "VideoCommon/VideoEvents.h"

#include "HostQueue.h"

#define PTDOLPHIN_EXPORT extern "C" __attribute__((visibility("default")))

// MemoryUtil_iOS_LuckTXM.cpp (retouché par scripts/patch_dolphin.py).
extern "C" void DolphinPlayTendoSetCodeProvider(void* (*alloc)(size_t, void**), void (*release)(void*));

// State.cpp (retouche 10 de scripts/patch_dolphin.py) : le dernier LoadAs a-t-il vraiment chargé l'état ?
namespace State
{
extern bool g_playtendo_state_loaded;
}

using ciface::iOS::ButtonType;
using ciface::iOS::StateManager;

/// Vue où Dolphin dessine (couche Metal). Prévient Dolphin quand sa taille change.
@interface PTDolphinView : MTKView
@end

@implementation PTDolphinView
#if TARGET_OS_IOS
- (void)layoutSubviews {
  [super layoutSubviews];
  if (g_presenter)
    g_presenter->ResizeSurface();
}
#else
- (void)layout {
  [super layout];
  if (g_presenter)
    g_presenter->ResizeSurface();
}

/// La souris et le clavier vont à l'écran de jeu de PlayTendo, posé par-dessus.
- (NSView*)hitTest:(NSPoint)point {
  return nil;
}
#endif
@end

static PTDolphinView* s_view;
static CGFloat s_scale = 2;
static std::mutex s_errorMutex;
static std::string s_lastError;
/// Format de l'image du jeu (largeur / hauteur), relevé à chaque image par Dolphin ; 0 = pas encore connu.
static std::atomic<float> s_aspectRatio{0};
/// Relevé du format à chaque image. Jamais détruit à la sortie du programme : son événement (et son verrou) l'est
/// peut-être déjà à ce moment-là (plantage « recursive_mutex lock failed » en quittant l'app Mac).
static Common::EventHook& s_presentHook = *new Common::EventHook();
/// Mémoire rapide : disponible, et plus grand bloc d'adresses libre mesuré au démarrage (en Go).
static bool s_fastmem = false;
static float s_largestBlockGB = 0;

// MARK: - Erreurs

/// Alertes de Dolphin (PanicAlert…) : notées pour PlayTendo, qui affiche la dernière en cas d'échec. Une
/// question « oui / non » reçoit « oui » (continuer), comme le ferait le joueur le plus souvent.
static bool PTDolphinAlert(const char* caption, const char* text, bool yes_no, Common::MsgType style)
{
  NSLog(@"[Dolphin] %s : %s", caption ? caption : "", text ? text : "");
  if (style != Common::MsgType::Information)
  {
    std::lock_guard<std::mutex> lock(s_errorMutex);
    s_lastError = text ? text : "";
  }
  return true;
}

static void PTDolphinClearError()
{
  std::lock_guard<std::mutex> lock(s_errorMutex);
  s_lastError.clear();
}

PTDOLPHIN_EXPORT char* PTDolphinCopyLastError(void)
{
  std::lock_guard<std::mutex> lock(s_errorMutex);
  return s_lastError.empty() ? nullptr : strdup(s_lastError.c_str());
}

// MARK: - Préparation

/// Journal du moteur (User/Logs/dolphin.log) : démarrage, cœur, image, son, recompilateur. Sans les lectures du
/// disque (DVD : une ligne par lecture, 98 % du journal). Dolphin complète ce fichier sans jamais le vider : il
/// repart à zéro à chaque lancement de l'app, celui d'avant gardé dans dolphin-precedent.log. Réglage réécrit à
/// chaque lancement (remplace celui des versions précédentes).
static void PTDolphinWriteLoggerConfig()
{
  const std::string log = File::GetUserPath(F_MAINLOG_IDX);
  if (File::Exists(log))
    File::Rename(log, log.substr(0, log.rfind('.')) + "-precedent.log");
  File::WriteStringToFile(File::GetUserPath(F_LOGGERCONFIG_IDX),
                          "[Options]\nVerbosity = 4\nWriteToFile = True\nWriteToConsole = False\n"
                          "[Logs]\nBOOT = True\nCOMMON = True\nCORE = True\nVIDEO = True\n"
                          "Host GPU = True\nDVD = False\nPOWERPC = True\nDYNA_REC = True\n"
                          "Audio = True\nEXI = True\nIOS = True\nSI = True\n");
}

/// Profils tactiles de DolphiniOS (Sys/Profiles/…/Touchscreen.ini) : manettes GameCube 1 et 2 et télécommandes Wii 1
/// et 2 lues sur les « appareils » tactiles iOS/0, iOS/1, iOS/4 et iOS/5, que PlayTendo remplit (PTDolphinSetButton/Stick/Pointer).
/// Wiimote : sans les capteurs de mouvement de l'iPhone (DolphiniOS les lit, pas PlayTendo) — branchés mais
/// jamais remplis, ils diraient au jeu que la télécommande tombe et figeraient le pointeur.
static void PTDolphinImportProfile(InputConfig* config, bool wiimote, int player)
{
  ControllerEmu::EmulatedController* controller = config->GetController(player);
  Common::IniFile ini;
  ini.Load(config->GetSysProfileDirectoryPath() + "Touchscreen.ini");
  Common::IniFile::Section* profile = ini.GetOrCreateSection("Profile");
  // Joueur 2 : son propre appareil tactile (iOS/1 pour la manette GameCube, iOS/5 pour la Wiimote).
  profile->Set("Device", "iOS/" + std::to_string((wiimote ? 4 : 0) + player) + "/Touchscreen");
  if (wiimote)
  {
    std::vector<std::string> motion;
    for (const auto& [key, value] : profile->GetValues())
    {
      if (key.starts_with("IMU") || key.starts_with("Nunchuk/IMU"))
        motion.push_back(key);
    }
    for (const std::string& key : motion)
      profile->Delete(key);
  }
  controller->LoadConfig(profile);
  controller->UpdateReferences(g_controller_interface);
  config->SaveConfig();
}

static bool PTDolphinCanReserve(vm_size_t size)
{
  vm_address_t address = 0;
  if (vm_allocate(mach_task_self(), &address, size, VM_FLAGS_ANYWHERE) != KERN_SUCCESS)
    return false;
  vm_deallocate(mach_task_self(), address, size);
  return true;
}

/// Plus grand bloc d'adresses libre (réservé puis rendu aussitôt, sans mémoire réelle), à 256 Mo près.
static vm_size_t PTDolphinLargestFreeBlock()
{
  vm_size_t low = 0;
  vm_size_t high = 64ull << 30;
  while (high - low > (256ull << 20))
  {
    const vm_size_t middle = (low + (high - low) / 2) & ~vm_size_t(0xFFFF);
    if (PTDolphinCanReserve(middle))
      low = middle;
    else
      high = middle;
  }
  return low;
}

/// Fastmem : Dolphin veut un bloc d'adresses d'un seul tenant (8 Go sur iPhone, voir la retouche de Memmap.cpp
/// dans scripts/patch_dolphin.py) ; sans lui, il émule la mémoire de la console plus lentement.
static bool PTDolphinFastmemAvailable()
{
#if defined(__aarch64__)
  constexpr vm_size_t size = 0x200000000;
#else
  constexpr vm_size_t size = 0x380000000;
#endif
  return PTDolphinCanReserve(size);
}

PTDOLPHIN_EXPORT void* PTDolphinSetup(const char* userDir, const char* gcSaveDir, const char* wiiSaveDir)
{
  if (s_view)
    return (__bridge void*)s_view;
  if (!userDir || !gcSaveDir || !wiiSaveDir)
    return nullptr;
  const std::string user = userDir;
  const std::string gcSaves = gcSaveDir;
  const std::string wiiSaves = wiiSaveDir;

#if TARGET_OS_IOS
  // Son : comme le reste de PlayTendo (respecte le bouton silencieux, se mélange aux autres apps).
  AVAudioSession* session = [AVAudioSession sharedInstance];
  [session setCategory:AVAudioSessionCategoryAmbient error:nil];
  [session setActive:YES error:nil];
#endif

  const bool fastmem = PTDolphinFastmemAvailable();
  const vm_size_t largest = PTDolphinLargestFreeBlock();
  s_fastmem = fastmem;
  s_largestBlockGB = static_cast<float>(largest) / float(1ull << 30);
  DOLHostQueueRunSync(^{
    UICommon::SetUserDirectory(user);
    UICommon::CreateDirectories();
    PTDolphinWriteLoggerConfig();
    UICommon::Init();
    Common::RegisterMsgAlertHandler(PTDolphinAlert);

    Config::SetBase(Config::MAIN_GFX_BACKEND, "Metal");
    Config::SetBase(Config::MAIN_USE_GAME_COVERS, false);
    Config::SetBase(Config::MAIN_CONFIRM_ON_STOP, false);
    // Pas de messages de Dolphin sur l'image (en anglais : « Saved state… », « Screenshot saved… »).
    Config::SetBase(Config::MAIN_OSD_MESSAGES, false);
    Config::SetBase(Config::MAIN_FASTMEM, fastmem);
    Config::SetBase(Config::MAIN_FASTMEM_ARENA, fastmem);
    // Sauvegardes visibles dans Fichiers : cartes mémoire GameCube (un fichier .gci par sauvegarde, dans un
    // dossier par région) et mémoire interne de la Wii.
    Config::SetBase(Config::MAIN_GCI_FOLDER_A_PATH, gcSaves);
    Config::SetBase(Config::MAIN_FS_PATH, wiiSaves);

    WindowSystemInfo wsi;
    wsi.type = WindowSystemType::iOS;
    UICommon::InitControllers(wsi);
    for (int player = 0; player < 2; ++player)
    {
      PTDolphinImportProfile(Pad::GetConfig(), false, player);
      PTDolphinImportProfile(Wiimote::GetConfig(), true, player);
    }

    // N'envoie rien (statistiques désactivées) mais doit être fait avant tout jeu Wii (DolphiniOS).
#if TARGET_OS_IOS
    DolphinAnalytics::Instance().ReportDolphinStart("ios");
#else
    DolphinAnalytics::Instance().ReportDolphinStart("macos");
#endif
    Config::Save();
    NOTICE_LOG_FMT(CORE, "[PlayTendo] Mémoire rapide (fastmem) : {} — plus grand bloc d'adresses libre : {:.2f} Go",
                   fastmem ? "oui" : "non", static_cast<double>(largest) / double(1ull << 30));
  });

  // Format de l'image (4:3, 16:9…), pour que PlayTendo donne au jeu la bonne place à l'écran.
  s_presentHook = AfterPresentEvent::Register(
      [](PresentInfo&) {
        if (g_presenter)
          s_aspectRatio = g_presenter->CalculateDrawAspectRatio();
      },
      "PlayTendo");

#if TARGET_OS_IOS
  // Mémoire du turbo : la réserve JIT de l'app (PTJIT.m), exportée par l'exécutable de PlayTendo.
  auto jitAlloc = reinterpret_cast<void* (*)(size_t, void**)>(dlsym(RTLD_DEFAULT, "PTJITAlloc"));
  auto jitFree = reinterpret_cast<void (*)(void*)>(dlsym(RTLD_DEFAULT, "PTJITFree"));
  if (jitAlloc && jitFree)
  {
    DolphinPlayTendoSetCodeProvider(jitAlloc, jitFree);
    Common::SetJitType(Common::JitType::LuckTXM);
  }

  s_scale = UIScreen.mainScreen.scale;
  s_view = [[PTDolphinView alloc] initWithFrame:CGRectZero device:MTLCreateSystemDefaultDevice()];
  s_view.paused = YES;  // Dolphin présente lui-même ses images dans la couche
  s_view.enableSetNeedsDisplay = NO;
  s_view.backgroundColor = UIColor.blackColor;
  s_view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

  // Passage en arrière-plan : réglages écrits (iOS peut fermer l'app sans prévenir).
  NSNotificationName saveMoment = UIApplicationDidEnterBackgroundNotification;
#else
  // Mac : Dolphin prend sa mémoire exécutable lui-même (MAP_JIT, permis à l'app signée localement).
  s_scale = NSScreen.mainScreen.backingScaleFactor;
  s_view = [[PTDolphinView alloc] initWithFrame:NSZeroRect device:MTLCreateSystemDefaultDevice()];
  s_view.paused = YES;  // Dolphin présente lui-même ses images dans la couche
  s_view.enableSetNeedsDisplay = NO;
  s_view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

  // Fermeture de l'app : réglages écrits.
  NSNotificationName saveMoment = NSApplicationWillTerminateNotification;
#endif
  [[NSNotificationCenter defaultCenter] addObserverForName:saveMoment
                                                    object:nil
                                                     queue:nil
                                                usingBlock:^(NSNotification*) {
                                                  DOLHostQueueRunSync(^{
                                                    Config::Save();
                                                  });
                                                }];
  return (__bridge void*)s_view;
}

/// Fermeture de l'app : Dolphin arrêté en règle (manettes, réglages, journal). Sans cela, à la sortie du programme,
/// ses fils encore actifs se heurtent à des objets déjà détruits (« recursive_mutex lock failed » : plantage en
/// quittant l'app Mac). Comme DolphiniOS (applicationWillTerminate) : partie arrêtée et attendue, puis
/// Core::Shutdown rejoint le fil d'émulation ; après une partie il reste « joignable » même fini, et le détruire
/// à la sortie du programme sans l'avoir rejoint appelle std::terminate (plantage en quittant après une partie).
PTDOLPHIN_EXPORT void PTDolphinShutdown(void)
{
  if (!s_view)
    return;
  DOLHostQueueRunSync(^{
    auto& system = Core::System::GetInstance();
    if (Core::IsRunningOrStarting(system))
      Core::Stop(system);
    // Au plus 5 s : un fil d'émulation bloqué ne doit pas empêcher l'app de se fermer.
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (Core::GetState(system) != Core::State::Uninitialized && std::chrono::steady_clock::now() < deadline)
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    if (Core::GetState(system) == Core::State::Uninitialized)
      Core::Shutdown(system);
    Config::Save();
    UICommon::ShutdownControllers();
    UICommon::Shutdown();
  });
  s_presentHook.reset();
  s_view = nil;
}

// MARK: - Partie

// Disques du jeu en cours s'il en a plusieurs (PTDolphinBootDiscs), sinon vide.
static std::vector<std::string> s_discs;
// Reprise automatique du prochain démarrage (PTDolphinSetBootState) : le jeu démarre directement dessus.
static std::string s_bootState;

// Démarre le jeu : un fichier, ou les disques d'un jeu qui en a plusieurs (Dolphin met le premier, puis passe tout
// seul au suivant quand le jeu ouvre le couvercle : « changement de disque automatique »).
static bool PTDolphinBootFiles(std::vector<std::string> files, bool jit)
{
  if (!s_view || files.empty())
    return false;
  PTDolphinClearError();
  s_discs = files.size() > 1 ? files : std::vector<std::string>{};
  CAMetalLayer* layer = (CAMetalLayer*)s_view.layer;
#if !TARGET_OS_IOS
  // Mac : l'écran de la fenêtre (Retina ou non) ; la vue est déjà dans la fenêtre à ce moment-là.
  if (s_view.window)
    s_scale = s_view.window.backingScaleFactor;
#endif
  const CGFloat scale = s_scale;
  __block bool started = false;
  DOLHostQueueRunSync(^{
    auto& system = Core::System::GetInstance();
    if (Core::IsRunningOrStarting(system))
      return;
    // Turbo : recompilateur ARM64 (iPhone : dans la réserve de l'app ; Mac : mémoire MAP_JIT de Dolphin). Sinon
    // interpréteur « en cache » (très lent).
    Config::SetBase(Config::MAIN_CPU_CORE, jit ? PowerPC::CPUCore::JITARM64 : PowerPC::CPUCore::CachedInterpreter);
    Config::SetBase(Config::GFX_VERTEX_LOADER_TYPE, jit ? VertexLoaderType::Native : VertexLoaderType::Software);
    Config::SetCurrent(Config::MAIN_EMULATION_SPEED, 1.0f);
    Config::SetBase(Config::MAIN_AUTO_DISC_CHANGE, files.size() > 1);
    // Codes de triche : ceux de PlayTendo (PTDolphinSetCheats), donnés une fois le jeu lancé.
    Config::SetBase(Config::MAIN_ENABLE_CHEATS, true);
    NSLog(@"[PlayTendo] Démarrage GameCube/Wii %s", jit ? "avec JIT" : "sans JIT (interpréteur)");
    s_aspectRatio = 0;

    WindowSystemInfo wsi;
    wsi.type = WindowSystemType::iOS;
    wsi.render_surface = (__bridge void*)layer;
    wsi.render_surface_scale = scale;
    // Reprise automatique : chargée par Dolphin au démarrage (comme « Démarrer avec cette sauvegarde » de DolphinQt).
    std::optional<std::string> state;
    if (!s_bootState.empty())
      state = s_bootState;
    s_bootState.clear();
    std::unique_ptr<BootParameters> boot = BootParameters::GenerateFromFile(
        files, BootSessionData(std::move(state), DeleteSavestateAfterBoot::No));
    if (!boot)
      return;
    started = BootManager::BootCore(system, std::move(boot), wsi);
  });
  return started;
}

PTDOLPHIN_EXPORT bool PTDolphinBoot(const char* path, bool jit)
{
  return path && PTDolphinBootFiles({path}, jit);
}

PTDOLPHIN_EXPORT bool PTDolphinBootDiscs(const char* const* paths, int count, bool jit)
{
  if (!paths || count < 1)
    return false;
  std::vector<std::string> files;
  for (int i = 0; i < count; i++)
  {
    if (paths[i])
      files.emplace_back(paths[i]);
  }
  return PTDolphinBootFiles(std::move(files), jit);
}

PTDOLPHIN_EXPORT int PTDolphinGetDisc(void)
{
  auto& system = Core::System::GetInstance();
  if (s_discs.size() < 2 || !Core::IsRunning(system))
    return -1;
  // Retouche 11 de patch_dolphin.py : rang du disque inséré dans la liste du changement automatique.
  return static_cast<int>(system.GetDVDInterface().PlayTendoDiscIndex());
}

PTDOLPHIN_EXPORT bool PTDolphinChangeDisc(int index)
{
  if (index < 0 || static_cast<size_t>(index) >= s_discs.size())
    return false;
  const std::string path = s_discs[index];
  __block bool changed = false;
  DOLHostQueueRunSync(^{
    auto& system = Core::System::GetInstance();
    if (!Core::IsRunning(system))
      return;
    // Comme « Changer de disque » de Dolphin (DolphinQt, MainWindow::ChangeDisc) : fil de la console tenu, couvercle
    // ouvert, disque inséré une seconde (de la console) plus tard ; marche aussi jeu en pause.
    Core::CPUThreadGuard guard(system);
    system.GetDVDInterface().ChangeDisc(guard, path);
    changed = true;
  });
  return changed;
}

PTDOLPHIN_EXPORT PTDolphinState PTDolphinGetState(void)
{
  switch (Core::GetState(Core::System::GetInstance()))
  {
  case Core::State::Running:
    return PTDolphinStateRunning;
  case Core::State::Paused:
    return PTDolphinStatePaused;
  case Core::State::Starting:
  case Core::State::Stopping:
    return PTDolphinStateStarting;
  default:
    return PTDolphinStateStopped;
  }
}

PTDOLPHIN_EXPORT void PTDolphinSetPaused(bool paused)
{
  DOLHostQueueRunSync(^{
    auto& system = Core::System::GetInstance();
    if (Core::IsRunning(system))
      Core::SetState(system, paused ? Core::State::Paused : Core::State::Running);
  });
}

PTDOLPHIN_EXPORT void PTDolphinStop(void)
{
  DOLHostQueueRunSync(^{
    auto& system = Core::System::GetInstance();
    if (Core::IsRunningOrStarting(system))
      Core::Stop(system);
  });
}

PTDOLPHIN_EXPORT void PTDolphinReset(void)
{
  DOLHostQueueRunSync(^{
    auto& system = Core::System::GetInstance();
    if (Core::IsRunning(system))
      system.GetProcessorInterface().ResetButton_Tap();
  });
}

PTDOLPHIN_EXPORT void PTDolphinSetTurbo(bool enabled)
{
  Config::SetCurrent(Config::MAIN_EMULATION_SPEED, enabled ? 3.0f : 1.0f);
}

// MARK: - Commandes

// Les boutons arrivent avec les numéros RetroPad de PlayTendo (par position, comme ses manettes) : ceux enfoncés
// sont gardés ici, puis traduits pour la manette GameCube du joueur (appareils tactiles iOS/0, iOS/1) ou pour sa
// Wiimote avec son Nunchuk (iOS/4, iOS/5). Un même bouton de la console peut venir de deux boutons RetroPad.
static constexpr int kPad = 0;
static constexpr int kWiimote = 4;
static constexpr int kPlayers = 2;
static std::mutex s_inputMutex;
static uint32_t s_pressed[kPlayers] = {};  // un bit par bouton RetroPad
static bool s_wiimoteMode = false;
static bool s_pointerStickActive[kPlayers] = {};

static bool PTDolphinHeld(int player, std::initializer_list<int> buttons)
{
  for (int button : buttons)
  {
    if (s_pressed[player] & (1u << button))
      return true;
  }
  return false;
}

/// Manette GameCube : bas = A (le gros bouton vert), gauche = B, droite = X, haut = Y ; R1 = Z ; L1/L2 =
/// gâchette L, R2 = gâchette R (pressées à fond).
static void PTDolphinApplyPad(int player)
{
  StateManager* state = StateManager::GetInstance();
  const int pad = kPad + player;
  state->SetButtonPressed(pad, ButtonType::BUTTON_A, PTDolphinHeld(player, {0}));
  state->SetButtonPressed(pad, ButtonType::BUTTON_B, PTDolphinHeld(player, {1}));
  state->SetButtonPressed(pad, ButtonType::BUTTON_X, PTDolphinHeld(player, {8}));
  state->SetButtonPressed(pad, ButtonType::BUTTON_Y, PTDolphinHeld(player, {9}));
  state->SetButtonPressed(pad, ButtonType::BUTTON_START, PTDolphinHeld(player, {3}));
  state->SetButtonPressed(pad, ButtonType::BUTTON_Z, PTDolphinHeld(player, {11}));
  state->SetButtonPressed(pad, ButtonType::BUTTON_UP, PTDolphinHeld(player, {4}));
  state->SetButtonPressed(pad, ButtonType::BUTTON_DOWN, PTDolphinHeld(player, {5}));
  state->SetButtonPressed(pad, ButtonType::BUTTON_LEFT, PTDolphinHeld(player, {6}));
  state->SetButtonPressed(pad, ButtonType::BUTTON_RIGHT, PTDolphinHeld(player, {7}));
  state->SetAxisValue(pad, ButtonType::TRIGGER_L, PTDolphinHeld(player, {10, 12}) ? 1.0f : 0.0f);
  state->SetAxisValue(pad, ButtonType::TRIGGER_R, PTDolphinHeld(player, {13}) ? 1.0f : 0.0f);
}

/// Wiimote + Nunchuk : bas = A, droite et R2 = B (la gâchette), gauche = 1, haut = 2, Start = +, Select = −,
/// R3 = Home ; L1 = C et L2 = Z (Nunchuk) ; R1 = secouer la télécommande.
static void PTDolphinApplyWiimote(int player)
{
  StateManager* state = StateManager::GetInstance();
  const int remote = kWiimote + player;
  state->SetButtonPressed(remote, ButtonType::WIIMOTE_BUTTON_A, PTDolphinHeld(player, {0}));
  state->SetButtonPressed(remote, ButtonType::WIIMOTE_BUTTON_B, PTDolphinHeld(player, {8, 13}));
  state->SetButtonPressed(remote, ButtonType::WIIMOTE_BUTTON_1, PTDolphinHeld(player, {1}));
  state->SetButtonPressed(remote, ButtonType::WIIMOTE_BUTTON_2, PTDolphinHeld(player, {9}));
  state->SetButtonPressed(remote, ButtonType::WIIMOTE_BUTTON_PLUS, PTDolphinHeld(player, {3}));
  state->SetButtonPressed(remote, ButtonType::WIIMOTE_BUTTON_MINUS, PTDolphinHeld(player, {2}));
  state->SetButtonPressed(remote, ButtonType::WIIMOTE_BUTTON_HOME, PTDolphinHeld(player, {15}));
  state->SetButtonPressed(remote, ButtonType::WIIMOTE_UP, PTDolphinHeld(player, {4}));
  state->SetButtonPressed(remote, ButtonType::WIIMOTE_DOWN, PTDolphinHeld(player, {5}));
  state->SetButtonPressed(remote, ButtonType::WIIMOTE_LEFT, PTDolphinHeld(player, {6}));
  state->SetButtonPressed(remote, ButtonType::WIIMOTE_RIGHT, PTDolphinHeld(player, {7}));
  state->SetButtonPressed(remote, ButtonType::NUNCHUK_BUTTON_C, PTDolphinHeld(player, {10}));
  state->SetButtonPressed(remote, ButtonType::NUNCHUK_BUTTON_Z, PTDolphinHeld(player, {12}));
  const bool shake = PTDolphinHeld(player, {11});
  state->SetButtonPressed(remote, ButtonType::WIIMOTE_SHAKE_X, shake);
  state->SetButtonPressed(remote, ButtonType::WIIMOTE_SHAKE_Y, shake);
  state->SetButtonPressed(remote, ButtonType::WIIMOTE_SHAKE_Z, shake);
}

/// Une valeur par direction (négative vers le haut et la gauche), comme les sticks tactiles de DolphiniOS.
static void PTDolphinSetAxes(int controller, ButtonType up, ButtonType down, ButtonType left, ButtonType right,
                             float x, float y)
{
  StateManager* state = StateManager::GetInstance();
  state->SetAxisValue(controller, up, std::min(y, 0.0f));
  state->SetAxisValue(controller, down, std::max(y, 0.0f));
  state->SetAxisValue(controller, left, std::min(x, 0.0f));
  state->SetAxisValue(controller, right, std::max(x, 0.0f));
}

static void PTDolphinSetPointerAxes(int player, float x, float y)
{
  PTDolphinSetAxes(kWiimote + player, ButtonType::WIIMOTE_IR_UP, ButtonType::WIIMOTE_IR_DOWN,
                   ButtonType::WIIMOTE_IR_LEFT, ButtonType::WIIMOTE_IR_RIGHT, std::clamp(x, -1.0f, 1.0f),
                   std::clamp(y, -1.0f, 1.0f));
}

/// Relâche tout, sur les manettes des deux joueurs (le pointeur revient au centre).
static void PTDolphinReleaseAll()
{
  for (int player = 0; player < kPlayers; ++player)
  {
    s_pressed[player] = 0;
    s_pointerStickActive[player] = false;
    PTDolphinApplyPad(player);
    PTDolphinApplyWiimote(player);
    PTDolphinSetAxes(kPad + player, ButtonType::STICK_MAIN_UP, ButtonType::STICK_MAIN_DOWN,
                     ButtonType::STICK_MAIN_LEFT, ButtonType::STICK_MAIN_RIGHT, 0, 0);
    PTDolphinSetAxes(kPad + player, ButtonType::STICK_C_UP, ButtonType::STICK_C_DOWN, ButtonType::STICK_C_LEFT,
                     ButtonType::STICK_C_RIGHT, 0, 0);
    PTDolphinSetAxes(kWiimote + player, ButtonType::NUNCHUK_STICK_UP, ButtonType::NUNCHUK_STICK_DOWN,
                     ButtonType::NUNCHUK_STICK_LEFT, ButtonType::NUNCHUK_STICK_RIGHT, 0, 0);
    PTDolphinSetPointerAxes(player, 0, 0);
  }
}

PTDOLPHIN_EXPORT void PTDolphinSetWiimote(bool enabled)
{
  std::lock_guard<std::mutex> lock(s_inputMutex);
  s_wiimoteMode = enabled;
  PTDolphinReleaseAll();
}

/// Bouton RetroPad du joueur `player` (0 ou 1).
PTDOLPHIN_EXPORT void PTDolphinSetPadButton(int player, int retroPadButton, bool pressed)
{
  if (player < 0 || player >= kPlayers || retroPadButton < 0 || retroPadButton >= 16)
    return;
  std::lock_guard<std::mutex> lock(s_inputMutex);
  if (pressed)
    s_pressed[player] |= 1u << retroPadButton;
  else
    s_pressed[player] &= ~(1u << retroPadButton);
  if (s_wiimoteMode)
    PTDolphinApplyWiimote(player);
  else
    PTDolphinApplyPad(player);
}

PTDOLPHIN_EXPORT void PTDolphinSetButton(int retroPadButton, bool pressed)
{
  PTDolphinSetPadButton(0, retroPadButton, pressed);
}

/// Stick 0 (gauche) ou 1 (droit) du joueur `player`.
PTDOLPHIN_EXPORT void PTDolphinSetPadStick(int player, int stick, float x, float y)
{
  if (player < 0 || player >= kPlayers)
    return;
  std::lock_guard<std::mutex> lock(s_inputMutex);
  if (!s_wiimoteMode)
  {
    if (stick == 0)
      PTDolphinSetAxes(kPad + player, ButtonType::STICK_MAIN_UP, ButtonType::STICK_MAIN_DOWN,
                       ButtonType::STICK_MAIN_LEFT, ButtonType::STICK_MAIN_RIGHT, x, y);
    else
      PTDolphinSetAxes(kPad + player, ButtonType::STICK_C_UP, ButtonType::STICK_C_DOWN, ButtonType::STICK_C_LEFT,
                       ButtonType::STICK_C_RIGHT, x, y);
    return;
  }
  if (stick == 0)
  {
    PTDolphinSetAxes(kWiimote + player, ButtonType::NUNCHUK_STICK_UP, ButtonType::NUNCHUK_STICK_DOWN,
                     ButtonType::NUNCHUK_STICK_LEFT, ButtonType::NUNCHUK_STICK_RIGHT, x, y);
    return;
  }
  // Stick droit d'une manette : il vise. Au repos (petite zone morte), le pointeur revient une seule fois au
  // centre, pour ne pas gêner la visée au doigt.
  if (std::hypot(x, y) > 0.15f)
  {
    s_pointerStickActive[player] = true;
    PTDolphinSetPointerAxes(player, x, y);
  }
  else if (s_pointerStickActive[player])
  {
    s_pointerStickActive[player] = false;
    PTDolphinSetPointerAxes(player, 0, 0);
  }
}

PTDOLPHIN_EXPORT void PTDolphinSetStick(int stick, float x, float y)
{
  PTDolphinSetPadStick(0, stick, x, y);
}

PTDOLPHIN_EXPORT void PTDolphinSetPointer(float x, float y)
{
  std::lock_guard<std::mutex> lock(s_inputMutex);
  PTDolphinSetPointerAxes(0, x, y);
}

/// Deuxième manette branchée ou retirée : manette GameCube 2 (port 2) et, en mode Wiimote, télécommande 2, pour ce
/// jeu et les suivants. Sans deuxième manette, rien n'est branché pour le joueur 2 (un jeu Wii afficherait son
/// pointeur au milieu de l'écran).
PTDOLPHIN_EXPORT void PTDolphinSetSecondPlayer(bool connected)
{
  DOLHostQueueRunSync(^{
    const auto pad = connected ? SerialInterface::SIDEVICE_GC_CONTROLLER : SerialInterface::SIDEVICE_NONE;
    const bool remote = connected && s_wiimoteMode;
    if (Config::Get(Config::GetInfoForSIDevice(1)) != pad)
    {
      Config::SetBase(Config::GetInfoForSIDevice(1), pad);
      auto& system = Core::System::GetInstance();
      if (Core::IsRunning(system))
        system.GetSerialInterface().ChangeDevice(pad, 1);
    }
    // Dolphin branche ou débranche la télécommande de lui-même quand ce réglage change (Wiimote::RefreshConfig).
    Config::SetBase(Config::GetInfoForWiimoteSource(1), remote ? WiimoteSource::Emulated : WiimoteSource::None);
  });
}

// MARK: - Image

PTDOLPHIN_EXPORT float PTDolphinGetAspectRatio(void)
{
  return s_aspectRatio.load();
}

PTDOLPHIN_EXPORT void PTDolphinSetImageOptions(int scale, bool smoothing)
{
  const int efbScale = std::clamp(scale, 1, 4);
  // Lissage = filtre FXAA de Dolphin (Sys/Shaders/FXAA.glsl), appliqué à l'image finale. Pas de MSAA : ses
  // textures « multi-échantillons en tableau » sont refusées par le Metal du simulateur (abandon du moteur).
  DOLHostQueueRunSync(^{
    Config::SetBase(Config::GFX_EFB_SCALE, efbScale);
    Config::SetBase(Config::GFX_MSAA, 1u);
    Config::SetBase(Config::GFX_SSAA, false);
    Config::SetBase(Config::GFX_ENHANCE_POST_SHADER, std::string(smoothing ? "FXAA" : ""));
  });
}

PTDOLPHIN_EXPORT void PTDolphinSetBootState(const char* path)
{
  s_bootState = path ? path : "";
}

/// Écran large forcé : jeux GameCube en 16:9 au lieu de 4:3. Comme dans DolphinQt, il faut les deux réglages : le
/// « Widescreen Hack » élargit le champ de vision du jeu jusqu'au format d'affichage, qui doit donc être 16:9 (seul,
/// il ne changeait rien). Quelques objets peuvent apparaître tard sur les bords. Appliqué à l'image suivante.
PTDOLPHIN_EXPORT void PTDolphinSetWidescreen(bool enabled)
{
  DOLHostQueueRunSync(^{
    Config::SetBase(Config::GFX_WIDESCREEN_HACK, enabled);
    Config::SetBase(Config::GFX_ASPECT_RATIO, enabled ? AspectMode::ForceWide : AspectMode::Auto);
  });
}

/// Codes séparés par une ligne vide, une instruction par ligne.
static std::vector<std::vector<std::string>> PTDolphinCheatBlocks(const std::string& text)
{
  std::vector<std::vector<std::string>> blocks(1);
  size_t start = 0;
  while (start <= text.size())
  {
    size_t end = text.find('\n', start);
    if (end == std::string::npos)
      end = text.size();
    std::string line = text.substr(start, end - start);
    while (!line.empty() && (line.back() == '\r' || line.back() == ' '))
      line.pop_back();
    if (line.empty())
    {
      if (!blocks.back().empty())
        blocks.emplace_back();
    }
    else
    {
      blocks.back().push_back(line);
    }
    start = end + 1;
  }
  if (blocks.back().empty())
    blocks.pop_back();
  return blocks;
}

/// Codes de triche du jeu en cours (menu pause › Codes de triche) : Action Replay (chiffrés « XXXX-XXXX-XXXXX »,
/// déchiffrés ici comme dans DolphinQt, ou en clair) et Gecko. Remplacent les codes actifs, tout de suite.
PTDOLPHIN_EXPORT void PTDolphinSetCheats(const char* actionReplay, const char* gecko)
{
  const std::string arText = actionReplay ? actionReplay : "";
  const std::string geckoText = gecko ? gecko : "";
  DOLHostQueueRunSync(^{
    std::vector<ActionReplay::ARCode> arCodes;
    for (const auto& block : PTDolphinCheatBlocks(arText))
    {
      ActionReplay::ARCode code;
      code.name = "PlayTendo " + std::to_string(arCodes.size() + 1);
      code.enabled = code.user_defined = true;
      std::vector<std::string> encrypted;
      for (const std::string& line : block)
      {
        auto parsed = ActionReplay::DeserializeLine(line);
        if (auto* entry = std::get_if<ActionReplay::AREntry>(&parsed))
          code.ops.push_back(*entry);
        else if (auto* line_encrypted = std::get_if<ActionReplay::EncryptedLine>(&parsed))
          encrypted.push_back(*line_encrypted);
      }
      if (!encrypted.empty())
        ActionReplay::DecryptARCode(encrypted, &code.ops);
      if (!code.ops.empty())
        arCodes.push_back(std::move(code));
    }
    std::vector<Gecko::GeckoCode> geckoCodes;
    for (const auto& block : PTDolphinCheatBlocks(geckoText))
    {
      Gecko::GeckoCode code;
      code.name = "PlayTendo " + std::to_string(geckoCodes.size() + 1);
      code.enabled = code.user_defined = true;
      for (const std::string& line : block)
      {
        if (auto parsed = Gecko::DeserializeLine(line))
          code.codes.push_back(*parsed);
      }
      if (!code.codes.empty())
        geckoCodes.push_back(std::move(code));
    }
    const SConfig& config = SConfig::GetInstance();
    ActionReplay::ApplyCodes(arCodes, config.GetGameID(), config.GetRevision());
    Gecko::SetActiveCodes(geckoCodes, config.GetGameID(), config.GetRevision());
    NSLog(@"[PlayTendo] Codes de triche : %zu Action Replay, %zu Gecko", arCodes.size(), geckoCodes.size());
  });
}

/// Affichage des performances de PlayTendo : images par seconde du jeu et vitesse en %. Faux hors partie.
PTDOLPHIN_EXPORT bool PTDolphinGetPerformance(double* fps, double* speed)
{
  if (Core::GetState(Core::System::GetInstance()) != Core::State::Running)
    return false;
  if (fps)
    *fps = g_perf_metrics.GetFPS();
  if (speed)
    *speed = g_perf_metrics.GetSpeed() * 100.0;
  return true;
}

// Vibrations des manettes GameCube et de la Wiimote : retouche 12 de patch_dolphin.py.
namespace Pad
{
extern void (*g_playtendo_rumble)(int pad, double strength);
}

/// PlayTendo reçoit les vibrations (manette, force de 0 à 1) et fait vibrer sa manette.
PTDOLPHIN_EXPORT void PTDolphinSetRumbleHandler(void (*handler)(int pad, double strength))
{
  Pad::g_playtendo_rumble = handler;
}

PTDOLPHIN_EXPORT bool PTDolphinCaptureScreen(const char* path)
{
  if (!path)
    return false;
  const std::string file = path;
  File::Delete(file);
  if (Core::GetState(Core::System::GetInstance()) != Core::State::Running || !g_frame_dumper)
    return false;
  g_frame_dumper->SaveScreenshotAndWait(file, std::chrono::milliseconds(1000));
  return File::Exists(file);
}

PTDOLPHIN_EXPORT bool PTDolphinFastmemStatus(float* largestBlockGB)
{
  if (largestBlockGB)
    *largestBlockGB = s_largestBlockGB;
  return s_fastmem;
}

// MARK: - Sauvegardes rapides

PTDOLPHIN_EXPORT bool PTDolphinSaveState(const char* path)
{
  if (!path)
    return false;
  // Écrite à côté, puis mise à la place de l'ancienne seulement si elle est là : un échec (iPhone plein…) garde la
  // sauvegarde rapide précédente.
  const std::string file = path;
  const std::string written = file + ".nouvelle";
  File::Delete(written);
  DOLHostQueueRunSync(^{
    auto& system = Core::System::GetInstance();
    if (Core::IsRunning(system))
      State::SaveAs(system, written, true);
  });
  if (!File::Exists(written) || File::GetSize(written) == 0)
  {
    File::Delete(written);
    std::lock_guard<std::mutex> lock(s_errorMutex);
    s_lastError = "sauvegarde rapide non écrite";
    return false;
  }
  return File::Rename(written, file);
}

PTDOLPHIN_EXPORT bool PTDolphinLoadState(const char* path)
{
  if (!path || !File::Exists(path))
    return false;
  const std::string file = path;
  __block bool loaded = false;
  // Une alerte de Dolphin pendant le chargement (« State header corrupted »…) devient la raison de l'échec.
  PTDolphinClearError();
  DOLHostQueueRunSync(^{
    auto& system = Core::System::GetInstance();
    if (!Core::IsRunning(system))
      return;
    State::LoadAs(system, file);
    // Refusée (autre jeu, autre version de Dolphin, fichier abîmé) : Dolphin a gardé la partie en cours.
    loaded = State::g_playtendo_state_loaded;
  });
  if (!loaded)
  {
    std::lock_guard<std::mutex> lock(s_errorMutex);
    if (s_lastError.empty())
      s_lastError = "sauvegarde rapide refusée par le moteur (autre jeu ou fichier abîmé ?)";
  }
  return loaded;
}
