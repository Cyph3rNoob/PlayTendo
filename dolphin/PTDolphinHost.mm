// PTDolphinHost.mm — pilote du moteur GameCube/Wii de PlayTendo (tiré de DolphiniOS 5.0.0b6, GPL-2.0+).
//
// Remplace l'interface de DolphiniOS (services de démarrage, écran de jeu, commandes tactiles) : PlayTendo
// garde sa fenêtre et place lui-même la vue Metal où Dolphin dessine. Le cœur Dolphin et la file « hôte » de
// DolphiniOS (Source/iOS/Library : Host.mm, HostQueue.mm) sont repris tels quels. Compilé dans
// DolphinCore.framework par scripts/build_dolphin.sh ; l'app y accède par dlopen/dlsym
// (app/PlayTendo/Emulation/PTDolphinEngine.m). Compilé avec ARC, comme tout DolphiniOS.

#include "PTDolphin.h"

#import <AVFoundation/AVFoundation.h>
#import <MetalKit/MetalKit.h>
#import <UIKit/UIKit.h>

#include <dlfcn.h>
#include <mach/mach.h>
#include <mutex>
#include <string>

#include "Common/FileUtil.h"
#include "Common/IniFile.h"
#include "Common/MemoryUtil.h"
#include "Common/MsgHandler.h"
#include "Common/WindowSystemInfo.h"
#include "Core/Boot/Boot.h"
#include "Core/BootManager.h"
#include "Core/Config/GraphicsSettings.h"
#include "Core/Config/MainSettings.h"
#include "Core/Config/UISettings.h"
#include "Core/Core.h"
#include "Core/DolphinAnalytics.h"
#include "Core/HW/GCPad.h"
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
#include "VideoCommon/Present.h"
#include "VideoCommon/VideoConfig.h"

#include "HostQueue.h"

#define PTDOLPHIN_EXPORT extern "C" __attribute__((visibility("default")))

// MemoryUtil_iOS_LuckTXM.cpp (retouché par scripts/patch_dolphin.py).
extern "C" void DolphinPlayTendoSetCodeProvider(void* (*alloc)(size_t, void**), void (*release)(void*));

using ciface::iOS::ButtonType;
using ciface::iOS::StateManager;

/// Vue où Dolphin dessine (couche Metal). Prévient Dolphin quand sa taille change.
@interface PTDolphinView : MTKView
@end

@implementation PTDolphinView
- (void)layoutSubviews {
  [super layoutSubviews];
  if (g_presenter)
    g_presenter->ResizeSurface();
}
@end

static PTDolphinView* s_view;
static CGFloat s_scale = 2;
static std::mutex s_errorMutex;
static std::string s_lastError;

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

/// Journal du moteur (User/Logs/dolphin.log) : démarrage, cœur, image, son, recompilateur.
static void PTDolphinWriteLoggerConfig()
{
  const std::string path = File::GetUserPath(F_LOGGERCONFIG_IDX);
  if (File::Exists(path))
    return;
  File::WriteStringToFile(path, "[Options]\nVerbosity = 4\nWriteToFile = True\nWriteToConsole = False\n"
                                "[Logs]\nBOOT = True\nCOMMON = True\nCORE = True\nVIDEO = True\n"
                                "Host GPU = True\nDVD = True\nPOWERPC = True\nDYNA_REC = True\n"
                                "Audio = True\nEXI = True\nIOS = True\nSI = True\n");
}

/// Profils tactiles de DolphiniOS (Sys/Profiles/…/Touchscreen.ini) : manette GameCube 1 et télécommande Wii 1
/// lues sur les « appareils » tactiles iOS/0 et iOS/4, que PlayTendo remplit (PTDolphinSetButton/Stick).
static void PTDolphinImportProfile(InputConfig* config)
{
  ControllerEmu::EmulatedController* controller = config->GetController(0);
  Common::IniFile ini;
  ini.Load(config->GetSysProfileDirectoryPath() + "Touchscreen.ini");
  controller->LoadConfig(ini.GetOrCreateSection("Profile"));
  controller->UpdateReferences(g_controller_interface);
  config->SaveConfig();
}

/// Fastmem : Dolphin veut 16 Go d'adresses d'un seul bloc (sans quoi il émule plus lentement la mémoire).
static bool PTDolphinFastmemAvailable()
{
  constexpr vm_size_t size = 0x400000000;
  vm_address_t address = 0;
  if (vm_allocate(mach_task_self(), &address, size, VM_FLAGS_ANYWHERE) != KERN_SUCCESS)
    return false;
  vm_deallocate(mach_task_self(), address, size);
  return true;
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

  // Son : comme le reste de PlayTendo (respecte le bouton silencieux, se mélange aux autres apps).
  AVAudioSession* session = [AVAudioSession sharedInstance];
  [session setCategory:AVAudioSessionCategoryAmbient error:nil];
  [session setActive:YES error:nil];

  const bool fastmem = PTDolphinFastmemAvailable();
  DOLHostQueueRunSync(^{
    UICommon::SetUserDirectory(user);
    UICommon::CreateDirectories();
    PTDolphinWriteLoggerConfig();
    UICommon::Init();
    Common::RegisterMsgAlertHandler(PTDolphinAlert);

    Config::SetBase(Config::MAIN_GFX_BACKEND, "Metal");
    Config::SetBase(Config::MAIN_USE_GAME_COVERS, false);
    Config::SetBase(Config::MAIN_CONFIRM_ON_STOP, false);
    Config::SetBase(Config::MAIN_FASTMEM, fastmem);
    Config::SetBase(Config::MAIN_FASTMEM_ARENA, fastmem);
    // Sauvegardes visibles dans Fichiers : cartes mémoire GameCube (un fichier .gci par sauvegarde, dans un
    // dossier par région) et mémoire interne de la Wii.
    Config::SetBase(Config::MAIN_GCI_FOLDER_A_PATH, gcSaves);
    Config::SetBase(Config::MAIN_FS_PATH, wiiSaves);

    WindowSystemInfo wsi;
    wsi.type = WindowSystemType::iOS;
    UICommon::InitControllers(wsi);
    PTDolphinImportProfile(Pad::GetConfig());
    PTDolphinImportProfile(Wiimote::GetConfig());

    // N'envoie rien (statistiques désactivées) mais doit être fait avant tout jeu Wii (DolphiniOS).
    DolphinAnalytics::Instance().ReportDolphinStart("ios");
    Config::Save();
  });

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
  [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                    object:nil
                                                     queue:nil
                                                usingBlock:^(NSNotification*) {
                                                  DOLHostQueueRunSync(^{
                                                    Config::Save();
                                                  });
                                                }];
  return (__bridge void*)s_view;
}

// MARK: - Partie

PTDOLPHIN_EXPORT bool PTDolphinBoot(const char* path, bool jit)
{
  if (!s_view || !path)
    return false;
  PTDolphinClearError();
  const std::string file = path;
  CAMetalLayer* layer = (CAMetalLayer*)s_view.layer;
  const CGFloat scale = s_scale;
  __block bool started = false;
  DOLHostQueueRunSync(^{
    auto& system = Core::System::GetInstance();
    if (Core::IsRunningOrStarting(system))
      return;
    // Turbo : recompilateur ARM64 dans la réserve de l'app. Sinon interpréteur « en cache » (très lent).
    Config::SetBase(Config::MAIN_CPU_CORE, jit ? PowerPC::CPUCore::JITARM64 : PowerPC::CPUCore::CachedInterpreter);
    Config::SetBase(Config::GFX_VERTEX_LOADER_TYPE, jit ? VertexLoaderType::Native : VertexLoaderType::Software);
    Config::SetCurrent(Config::MAIN_EMULATION_SPEED, 1.0f);
    NSLog(@"[PlayTendo] Démarrage GameCube/Wii %s", jit ? "avec JIT" : "sans JIT (interpréteur)");

    WindowSystemInfo wsi;
    wsi.type = WindowSystemType::iOS;
    wsi.render_surface = (__bridge void*)layer;
    wsi.render_surface_scale = scale;
    std::unique_ptr<BootParameters> boot = BootParameters::GenerateFromFile(file);
    if (!boot)
      return;
    started = BootManager::BootCore(system, std::move(boot), wsi);
  });
  return started;
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

static void PTDolphinSetTrigger(ButtonType trigger, bool pressed)
{
  StateManager::GetInstance()->SetAxisValue(0, trigger, pressed ? 1.0f : 0.0f);
}

PTDOLPHIN_EXPORT void PTDolphinSetButton(int retroPadButton, bool pressed)
{
  // Par position, comme les manettes de PlayTendo : bas = A (le gros bouton vert), gauche = B, droite = X,
  // haut = Y ; R1 = Z ; L1/L2 = gâchette L, R2 = gâchette R.
  StateManager* state = StateManager::GetInstance();
  switch (retroPadButton)
  {
  case 0: state->SetButtonPressed(0, ButtonType::BUTTON_A, pressed); break;      // B (bas)
  case 1: state->SetButtonPressed(0, ButtonType::BUTTON_B, pressed); break;      // Y (gauche)
  case 3: state->SetButtonPressed(0, ButtonType::BUTTON_START, pressed); break;  // Start
  case 4: state->SetButtonPressed(0, ButtonType::BUTTON_UP, pressed); break;
  case 5: state->SetButtonPressed(0, ButtonType::BUTTON_DOWN, pressed); break;
  case 6: state->SetButtonPressed(0, ButtonType::BUTTON_LEFT, pressed); break;
  case 7: state->SetButtonPressed(0, ButtonType::BUTTON_RIGHT, pressed); break;
  case 8: state->SetButtonPressed(0, ButtonType::BUTTON_X, pressed); break;      // A (droite)
  case 9: state->SetButtonPressed(0, ButtonType::BUTTON_Y, pressed); break;      // X (haut)
  case 11: state->SetButtonPressed(0, ButtonType::BUTTON_Z, pressed); break;     // R1
  case 10:                                                                       // L1
  case 12: PTDolphinSetTrigger(ButtonType::TRIGGER_L, pressed); break;           // L2
  case 13: PTDolphinSetTrigger(ButtonType::TRIGGER_R, pressed); break;           // R2
  default: break;
  }
}

PTDOLPHIN_EXPORT void PTDolphinSetStick(int stick, float x, float y)
{
  // Comme les sticks tactiles de DolphiniOS : une valeur par direction (négative vers le haut et la gauche).
  StateManager* state = StateManager::GetInstance();
  const bool main = stick == 0;
  state->SetAxisValue(0, main ? ButtonType::STICK_MAIN_UP : ButtonType::STICK_C_UP, std::min(y, 0.0f));
  state->SetAxisValue(0, main ? ButtonType::STICK_MAIN_DOWN : ButtonType::STICK_C_DOWN, std::max(y, 0.0f));
  state->SetAxisValue(0, main ? ButtonType::STICK_MAIN_LEFT : ButtonType::STICK_C_LEFT, std::min(x, 0.0f));
  state->SetAxisValue(0, main ? ButtonType::STICK_MAIN_RIGHT : ButtonType::STICK_C_RIGHT, std::max(x, 0.0f));
}

// MARK: - Sauvegardes rapides

PTDOLPHIN_EXPORT bool PTDolphinSaveState(const char* path)
{
  if (!path)
    return false;
  const std::string file = path;
  File::Delete(file);
  DOLHostQueueRunSync(^{
    auto& system = Core::System::GetInstance();
    if (Core::IsRunning(system))
      State::SaveAs(system, file, true);
  });
  return File::Exists(file) && File::GetSize(file) > 0;
}

PTDOLPHIN_EXPORT bool PTDolphinLoadState(const char* path)
{
  if (!path || !File::Exists(path))
    return false;
  const std::string file = path;
  __block bool loaded = false;
  DOLHostQueueRunSync(^{
    auto& system = Core::System::GetInstance();
    if (!Core::IsRunning(system))
      return;
    State::LoadAs(system, file);
    loaded = true;
  });
  return loaded;
}
