// PTVitaHost.cpp — pilote du moteur PS Vita de PlayTendo (Vita3K build 4135, GPL-2.0+).
//
// Remplace l'interface de Vita3K (Qt sur ordinateur, Java sur Android) : PlayTendo garde sa fenêtre et place
// lui-même la vue (couche Metal, PTVitaView.mm) où Vita3K dessine avec Vulkan (MoltenVK). Calqué sur la version
// Android (vita3k/android/jni : native_bootstrap.cpp, main_android.cpp, native_install.cpp, input_overlay.cpp) : même
// contrôleur de partie (app::AppSessionController), même manette virtuelle SDL pour les boutons. Compilé dans
// VitaCore.framework par scripts/build_vita3k.sh ; l'app y accède par dlopen/dlsym
// (app/PlayTendo/Emulation/PTVitaEngine.m).

#include "PTVita.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <dlfcn.h>
#include <exception>
#include <filesystem>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

#include "archive.h"
#include <app/functions.h>
#include <app/session_controller.h>
#include <compat/functions.h>
#include <compat/state.h>
#include <config/functions.h>
#include <config/settings.h>
#include <config/state.h>
#include <config/version.h>
#include <ctrl/functions.h>
#include <emuenv/state.h>
#include <modules/module_parent.h>
#include <packages/functions.h>
#include <packages/sfo.h>
#include <renderer/frame_host.h>
#include <renderer/functions.h>
#include <touch/functions.h>
#include <util/fs.h>
#include <util/log.h>
#include <util/sysinfo.h>
#include <util/system.h>

#include <SDL3/SDL.h>
// L'app a son propre point d'entrée : SDL ne doit pas le remplacer (SDL_main), seulement le savoir (SDL_SetMainReady).
#define SDL_MAIN_HANDLED
#include <SDL3/SDL_main.h>

#define PTVITA_EXPORT extern "C" __attribute__((visibility("default")))

// PTVitaView.mm (UIKit).
extern "C" void *PTVitaCreateView(void);
extern "C" void *PTVitaViewLayer(void);
extern "C" int PTVitaViewPixelWidth(void);
extern "C" int PTVitaViewPixelHeight(void);
extern "C" void *PTVitaVkGetInstanceProcAddr(void);

// MARK: - État

static std::unique_ptr<EmuEnvState> s_emuenv;
static std::unique_ptr<app::AppSessionController> s_session;
static std::atomic<int> s_state{ PTVitaStateStopped };
static std::atomic<bool> s_stopRequested{ false };
static std::atomic<bool> s_pauseRequested{ false };
/// Précision du rendu demandée (réglage PRÉCISION de PlayTendo), lue au lancement de chaque jeu.
static std::atomic<bool> s_highAccuracy{ false };
static std::thread s_thread;
/// Les installations et les parties ne se chevauchent pas (même mémoire de console).
static std::mutex s_busy;

static std::mutex s_errorMutex;
static std::string s_lastError;

static SDL_Joystick *s_joystick;
static std::mutex s_touchMutex;
static std::deque<SDL_TouchFingerEvent> s_touches;

static void PTVitaSetError(const std::string &message) {
    LOG_ERROR("[PlayTendo] {}", message);
    // Écrit tout de suite dans vita3k.log (sinon une erreur au démarrage n'y apparaît jamais).
    spdlog::apply_all([](const std::shared_ptr<spdlog::logger> &logger) { logger->flush(); });
    std::lock_guard<std::mutex> lock(s_errorMutex);
    s_lastError = message;
}

// MARK: - Son

/// Compteur du son de la partie (ajouté le 2026-10-10 : pas de son au premier essai de Gravity Rush, iPhone en mode
/// silencieux) : ce que le jeu envoie (sdl_audio.cpp, audio_output) et ce que SDL donne vraiment à l'appareil (mélange
/// final), avec le niveau le plus fort (0 = silence). Noté dans vita3k.log 20 s après le démarrage et à la fin.
static std::atomic<uint64_t> s_audioSentMicroseconds{ 0 };
static std::atomic<int> s_audioSentPeak{ 0 }; // 0 à 32767
static std::atomic<uint64_t> s_audioPlayedFrames{ 0 };
static std::atomic<int> s_audioPlayedRate{ 0 };
static std::atomic<int> s_audioPlayedPeak{ 0 }; // 0 à 32767

static void PTVitaRaisePeak(std::atomic<int> &peak, int value) {
    int current = peak.load(std::memory_order_relaxed);
    while (value > current && !peak.compare_exchange_weak(current, value, std::memory_order_relaxed)) {
    }
}

extern "C" void PTVitaAudioQueued(const void *buffer, int bytes, uint64_t microseconds) {
    const auto *samples = static_cast<const int16_t *>(buffer);
    int peak = 0;
    for (int i = 0; i < bytes / 2; ++i)
        peak = std::max(peak, std::abs(static_cast<int>(samples[i])));
    s_audioSentMicroseconds.fetch_add(microseconds, std::memory_order_relaxed);
    PTVitaRaisePeak(s_audioSentPeak, std::min(peak, 32767));
}

extern "C" void SDLCALL PTVitaAudioPostmix(void *, const SDL_AudioSpec *spec, float *buffer, int buflen) {
    if (!spec || spec->channels <= 0 || spec->freq <= 0 || buflen <= 0)
        return;
    const int count = buflen / static_cast<int>(sizeof(float));
    float peak = 0;
    for (int i = 0; i < count; ++i)
        peak = std::max(peak, std::fabs(buffer[i]));
    s_audioPlayedFrames.fetch_add(count / spec->channels, std::memory_order_relaxed);
    s_audioPlayedRate.store(spec->freq, std::memory_order_relaxed);
    PTVitaRaisePeak(s_audioPlayedPeak, static_cast<int>(std::lround(std::min(peak, 1.f) * 32767)));
}

static void PTVitaResetAudioCounters() {
    s_audioSentMicroseconds.store(0);
    s_audioSentPeak.store(0);
    s_audioPlayedFrames.store(0);
    s_audioPlayedPeak.store(0);
}

static void PTVitaLogAudio(const char *when) {
    const int rate = s_audioPlayedRate.load();
    const double played = rate > 0 ? static_cast<double>(s_audioPlayedFrames.load()) / rate : 0;
    LOG_INFO("[PlayTendo] Son ({}) : le jeu a envoyé {:.1f} s (toutes ses pistes additionnées, niveau max {:.1f} %), "
             "l'appareil a joué {:.1f} s (niveau max {:.1f} %)",
        when, s_audioSentMicroseconds.load() / 1e6, s_audioSentPeak.load() / 327.67, played,
        s_audioPlayedPeak.load() / 327.67);
}

// MARK: - Fenêtre

/// Fenêtre du jeu vue par Vita3K (comme AndroidFrameHost de main_android.cpp, mais avec la couche Metal de l'app).
class PTVitaFrameHost final : public renderer::FrameHost {
public:
    renderer::DisplayHandle handle() const override {
        return renderer::MacOSDisplayHandle{ PTVitaViewLayer() };
    }

    int drawable_width() const override {
        return PTVitaViewPixelWidth();
    }

    int drawable_height() const override {
        return PTVitaViewPixelHeight();
    }

    std::vector<std::string> font_dirs() const override {
        // Polices des fenêtres de la console (clavier, sauvegardes…) quand le paquet de polices PSP2UPDAT manque :
        // Vita3K cherche « Arial.ttf », qu'iOS range dans WebFonts (sans lui, boutons sans texte, 2026-10-10).
        return { "/System/Library/Fonts/", "/System/Library/Fonts/WebFonts/" };
    }
};

// MARK: - Préparation

/// Manette virtuelle SDL où arrivent les boutons de PlayTendo (tactiles ou manette réelle), comme la manette à
/// l'écran de la version Android (input_overlay.cpp).
static void PTVitaAttachJoystick() {
    SDL_VirtualJoystickDesc desc;
    SDL_INIT_INTERFACE(&desc);
    desc.type = SDL_JOYSTICK_TYPE_GAMEPAD;
    desc.naxes = SDL_GAMEPAD_AXIS_COUNT;
    desc.nbuttons = SDL_GAMEPAD_BUTTON_COUNT;
    desc.name = "PlayTendo";
    const SDL_JoystickID id = SDL_AttachVirtualJoystick(&desc);
    if (id == 0) {
        LOG_ERROR("[PlayTendo] Manette virtuelle impossible : {}", SDL_GetError());
        return;
    }
    s_joystick = SDL_OpenJoystick(id);
    if (!s_joystick)
        LOG_ERROR("[PlayTendo] Manette virtuelle impossible à ouvrir : {}", SDL_GetError());
}

PTVITA_EXPORT void *PTVitaSetup(const char *storageDir, const char *assetsDir) {
    if (s_emuenv)
        return PTVitaCreateView();

    try {
        // SDL ne sert qu'au son et à la manette virtuelle : PlayTendo garde la fenêtre. Les vraies manettes
        // passent par PlayTendo (GamepadManager), pas par SDL.
        SDL_SetMainReady();
        SDL_SetHint(SDL_HINT_JOYSTICK_MFI, "0");
        SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI, "0");
        // Muet en mode silencieux, comme les autres consoles.
        SDL_SetHint(SDL_HINT_AUDIO_CATEGORY, "ambient");
        SDL_SetAppMetadata(window_title, app_version, "com.playtendo.vita");
        if (!SDL_Init(SDL_INIT_AUDIO | SDL_INIT_GAMEPAD)) {
            PTVitaSetError(std::string("SDL n'a pas pu démarrer : ") + SDL_GetError());
            return nullptr;
        }

        // Dossiers : comme native_bootstrap.cpp (Android), tout dans `storageDir`.
        const fs::path storage = fs_utils::utf8_to_path(storageDir) / "";
        Root root_paths;
        root_paths.set_static_assets_path(fs_utils::utf8_to_path(assetsDir) / "");
        root_paths.set_vita_fs_path(storage / "vita" / "");
        root_paths.set_log_path(storage);
        root_paths.set_config_path(storage);
        root_paths.set_shared_path(storage);
        root_paths.set_cache_path(storage / "cache" / "");
        root_paths.set_patch_path(storage / "patch" / "");
        fs::create_directories(root_paths.get_vita_fs_path());
        fs::create_directories(root_paths.get_cache_path());
        fs::create_directories(root_paths.get_log_path() / "shaderlog");
        fs::create_directories(root_paths.get_log_path() / "texturelog");
        fs::create_directories(root_paths.get_patch_path());
        fs::create_directories(root_paths.get_shared_path() / "textures");

        if (logging::init(root_paths, true) != Success)
            return nullptr;
        // Les erreurs graves du moteur deviennent la « dernière erreur » montrée par l'app s'il s'arrête.
        logging::set_log_callback([](std::string message, int level) {
            if (level < spdlog::level::critical)
                return;
            while (!message.empty() && (message.back() == '\n' || message.back() == '\r'))
                message.pop_back();
            std::lock_guard<std::mutex> lock(s_errorMutex);
            s_lastError = message;
        });

        LOG_INFO("{} — PlayTendo (iPhone/iPad)", window_title);
        LOG_INFO("CPU: {}", util::get_system_info());
        LOG_INFO("Available ram memory: {} MiB", SDL_GetSystemRAM());

        if (!PTVitaVkGetInstanceProcAddr()) {
            PTVitaSetError("MoltenVK (affichage Vulkan) est introuvable dans l'app.");
            return nullptr;
        }

        auto emuenv = std::make_unique<EmuEnvState>();
        Config cfg{};
        char arg0[] = "vita3k";
        char *argv[] = { arg0, nullptr };
        if (config::init_config(cfg, 1, argv, root_paths, false) != Success) {
            PTVitaSetError("Les réglages du moteur n'ont pas pu être lus.");
            return nullptr;
        }
        // Le chemin de la mémoire de la console est enregistré en absolu dans config.yml (« pref-path ») : iOS change
        // l'adresse du dossier de l'app à une réinstallation, l'ancienne n'est plus accessible (create_directories :
        // « Operation not permitted », 2026-10-08). Il est donc remis à l'adresse actuelle à chaque ouverture.
        cfg.set_vita_fs_path(root_paths.get_vita_fs_path());
        // Console en français, journal sans les détails de chaque appel système, aucune recherche de mise à jour.
        cfg.sys_lang = static_cast<int>(SCE_SYSTEM_PARAM_LANG_FRENCH);
        cfg.log_level = static_cast<int>(spdlog::level::info);
        logging::set_level(spdlog::level::info);
        cfg.check_for_updates = false;
        fs::create_directories(cfg.get_vita_fs_path());

        if (!app::init(*emuenv, cfg, root_paths)) {
            PTVitaSetError("La mémoire de la console n'a pas pu être préparée.");
            return nullptr;
        }

        emuenv->vulkan_device_info = std::make_unique<renderer::VulkanDeviceInfo>(renderer::enumerate_vulkan_devices());

        if (emuenv->cfg.controller_binds.empty() || emuenv->cfg.controller_binds.size() != 15
            || emuenv->cfg.controller_axis_binds.empty() || emuenv->cfg.controller_axis_binds.size() != 6) {
            app::reset_controller_binding(*emuenv);
        }

        init_libraries(*emuenv);

        if (!app::init_apps_list(*emuenv))
            LOG_WARN("[PlayTendo] Aucun jeu installé pour l'instant.");

        app::load_users(*emuenv);
        if (!app::ensure_current_user(*emuenv)) {
            PTVitaSetError("Le profil de la console n'a pas pu être créé.");
            return nullptr;
        }
        compat::load_from_disk(emuenv->compat, std::filesystem::path(emuenv->cache_path.string()));

        s_emuenv = std::move(emuenv);
        s_session = std::make_unique<app::AppSessionController>(*s_emuenv);

        PTVitaAttachJoystick();
        refresh_controllers(s_emuenv->ctrl, *s_emuenv);

        LOG_INFO("[PlayTendo] Moteur prêt (firmware : {})", app::has_firmware_installed(*s_emuenv) ? "installé" : "absent");
        return PTVitaCreateView();
    } catch (const std::exception &error) {
        PTVitaSetError(std::string("Le moteur PS Vita n'a pas pu démarrer : ") + error.what());
        return nullptr;
    }
}

// MARK: - Installation

PTVITA_EXPORT int PTVitaGetFirmware(void) {
    if (!s_emuenv)
        return 0;
    const app::FirmwareState state = app::get_firmware_state(*s_emuenv);
    return (state.main_firmware ? PTVitaFirmwareMain : 0) | (state.font_package ? PTVitaFirmwareFonts : 0);
}

PTVITA_EXPORT char *PTVitaInstallFirmware(const char *pupPath, PTVitaProgress progress, void *context) {
    if (!s_emuenv)
        return nullptr;
    std::lock_guard<std::mutex> busy(s_busy);
    try {
        LOG_INFO("[PlayTendo] Installation du firmware : {}", pupPath);
        const std::string version = install_pup(s_emuenv->vita_fs_path, fs_utils::utf8_to_path(pupPath),
            [&](uint32_t percent) {
                if (progress)
                    progress(std::min(percent, 100u) / 100.f, context);
            });
        if (version.empty()) {
            PTVitaSetError("Le firmware n'a pas pu être installé (fichier .PUP abîmé ou non officiel ?).");
            return nullptr;
        }
        app::scan_apps(*s_emuenv);
        LOG_INFO("[PlayTendo] Firmware {} installé", version);
        return strdup(version.c_str());
    } catch (const std::exception &error) {
        PTVitaSetError(std::string("Installation du firmware impossible : ") + error.what());
        return nullptr;
    }
}

PTVITA_EXPORT char *PTVitaInstallGame(const char *path, PTVitaProgress progress, void *context) {
    if (!s_emuenv)
        return nullptr;
    std::lock_guard<std::mutex> busy(s_busy);
    try {
        const fs::path source = fs_utils::utf8_to_path(path);
        std::string title_id;
        LOG_INFO("[PlayTendo] Installation du jeu : {}", path);
        if (fs::is_directory(source)) {
            // Dossier extrait d'une Vita (app/PCSA00011 : copié dans ux0, puis déchiffré avec work.bin s'il le faut).
            if (install_contents(*s_emuenv, source) == 0) {
                PTVitaSetError("Le jeu n'a pas pu être installé (dossier incomplet ou licence work.bin absente ?).");
                return nullptr;
            }
            title_id = s_emuenv->app_info.app_title_id;
        } else {
            // Archive .vpk ou .zip.
            const auto contents = install_archive(*s_emuenv, source,
                [&](ArchiveContents state) {
                    if (!progress)
                        return;
                    float value = 0;
                    if (state.progress)
                        value = *state.progress / 100.f;
                    else if (state.count && state.current && *state.count > 0)
                        value = *state.current / *state.count;
                    progress(std::clamp(value, 0.f, 1.f), context);
                },
                [](const std::string &, const std::string &) { return true; });
            for (const auto &content : contents) {
                if (!content.state)
                    continue;
                if (title_id.empty() || content.category.starts_with("gd"))
                    title_id = content.title_id;
            }
            if (title_id.empty()) {
                PTVitaSetError("Le jeu n'a pas pu être installé (archive .vpk abîmée ?).");
                return nullptr;
            }
        }
        app::scan_apps(*s_emuenv);
        LOG_INFO("[PlayTendo] Jeu {} installé", title_id);
        return strdup(title_id.c_str());
    } catch (const std::exception &error) {
        PTVitaSetError(std::string("Installation du jeu impossible : ") + error.what());
        return nullptr;
    }
}

PTVITA_EXPORT bool PTVitaIsInstalled(const char *titleID) {
    if (!s_emuenv || !titleID || !*titleID)
        return false;
    return fs::exists(s_emuenv->vita_fs_path / "ux0/app" / titleID / "sce_sys/param.sfo");
}

// MARK: - Partie

/// Partie sur son propre thread, comme SDL_main de la version Android : démarrage, boucle d'événements (manette
/// virtuelle, touchers), relancement dans le même processus si le jeu en lance un autre, arrêt.
static void PTVitaRunSession(std::string title_id) {
    std::lock_guard<std::mutex> busy(s_busy);
    auto &emuenv = *s_emuenv;
    auto &controller = *s_session;
    AppLaunchRequest request{ .app_path = title_id };
    bool relaunch = false;
    PTVitaResetAudioCounters();

    do {
        relaunch = false;
        PTVitaFrameHost frame_host;
        refresh_controllers(emuenv.ctrl, emuenv);
        // Précision : relue par Vita3K à chaque lancement (begin_launch → set_current_config).
        emuenv.cfg.high_accuracy = s_highAccuracy.load();
        emuenv.cfg.disable_surface_sync = !s_highAccuracy.load();
        // Mémoire mappée (retouche 15 de patch_vita3k.py) : sans elle, pas de synchro des surfaces.
        emuenv.cfg.memory_mapping = "double-buffer";
        LOG_INFO("[PlayTendo] Précision du rendu : {}", s_highAccuracy.load() ? "haute" : "normale");
        LOG_INFO("[PlayTendo] Démarrage de {}", request.app_path);

        if (!controller.begin_launch(request, request.reason != AppLaunchReason::LoadExec)) {
            PTVitaSetError("Jeu introuvable dans la mémoire de la console (" + request.app_path + ").");
            controller.stop(app::AppSessionStopReason::LaunchFailure);
            break;
        }
        if (!controller.initialize_renderer(frame_host)) {
            PTVitaSetError("L'affichage (Vulkan) n'a pas pu démarrer.");
            controller.stop(app::AppSessionStopReason::LaunchFailure);
            break;
        }
        if (!controller.initialize_runtime()) {
            PTVitaSetError("Le système de la console n'a pas pu démarrer (firmware installé ?).");
            controller.stop(app::AppSessionStopReason::LaunchFailure);
            break;
        }
        if (!controller.load_and_run()) {
            PTVitaSetError("Le jeu n'a pas pu être chargé.");
            controller.stop(app::AppSessionStopReason::LaunchFailure);
            break;
        }

        LOG_INFO("[PlayTendo] Jeu démarré : {} ({})", emuenv.current_app_title, request.app_path);
        if (s_pauseRequested.load())
            controller.set_pause_reason(app::AppSessionPauseReason::User, true);
        s_state.store(s_pauseRequested.load() ? PTVitaStatePaused : PTVitaStateRunning);

        std::optional<AppLaunchRequest> pending = emuenv.take_app_launch_request();
        bool running = !pending.has_value();
        const Uint64 audio_check = SDL_GetTicks() + 20'000;
        bool audio_logged = false;
        while (running) {
            if (!audio_logged && SDL_GetTicks() >= audio_check) {
                audio_logged = true;
                PTVitaLogAudio("20 s après le démarrage");
            }
            SDL_Event event;
            while (SDL_PollEvent(&event)) {
                if (event.type == SDL_EVENT_GAMEPAD_ADDED || event.type == SDL_EVENT_GAMEPAD_REMOVED)
                    refresh_controllers(emuenv.ctrl, emuenv);
            }
            {
                std::lock_guard<std::mutex> lock(s_touchMutex);
                while (!s_touches.empty()) {
                    SDL_TouchFingerEvent finger = s_touches.front();
                    s_touches.pop_front();
                    handle_touch_event(emuenv.touch, finger);
                }
            }
            if (s_stopRequested.load())
                running = false;
            if (!pending) {
                if (auto next = emuenv.take_app_launch_request()) {
                    pending = std::move(next);
                    running = false;
                }
            }
            if (!controller.is_running())
                running = false;
            if (running)
                SDL_Delay(8);
        }

        if (pending && !s_stopRequested.load()) {
            request = std::move(*pending);
            relaunch = true;
            LOG_INFO("[PlayTendo] Le jeu en lance un autre : {}", request.app_path);
        }
        s_state.store(PTVitaStateStarting);
        controller.stop(relaunch ? app::AppSessionStopReason::Relaunch : app::AppSessionStopReason::UserRequest);
    } while (relaunch);

    {
        std::lock_guard<std::mutex> lock(s_touchMutex);
        s_touches.clear();
    }
    PTVitaLogAudio("fin de la partie");
    LOG_INFO("[PlayTendo] Partie terminée");
    spdlog::apply_all([](const std::shared_ptr<spdlog::logger> &logger) { logger->flush(); });
    s_state.store(PTVitaStateStopped);
}

PTVITA_EXPORT bool PTVitaBoot(const char *titleID) {
    if (!s_emuenv || !titleID || !*titleID || s_state.load() != PTVitaStateStopped)
        return false;
    if (s_thread.joinable())
        s_thread.join();
    {
        std::lock_guard<std::mutex> lock(s_errorMutex);
        s_lastError.clear();
    }
    s_stopRequested.store(false);
    s_pauseRequested.store(false);
    s_state.store(PTVitaStateStarting);
    s_thread = std::thread(PTVitaRunSession, std::string(titleID));
    return true;
}

PTVITA_EXPORT void PTVitaSetHighAccuracy(bool high) {
    s_highAccuracy.store(high);
}

PTVITA_EXPORT PTVitaState PTVitaGetState(void) {
    return static_cast<PTVitaState>(s_state.load());
}

PTVITA_EXPORT void PTVitaSetPaused(bool paused) {
    s_pauseRequested.store(paused);
    if (!s_session || !s_session->is_running())
        return;
    s_session->set_pause_reason(app::AppSessionPauseReason::User, paused);
    const int state = s_state.load();
    if (state == PTVitaStateRunning || state == PTVitaStatePaused)
        s_state.store(paused ? PTVitaStatePaused : PTVitaStateRunning);
}

PTVITA_EXPORT void PTVitaStop(void) {
    s_stopRequested.store(true);
    // Une partie en pause doit reprendre pour que ses threads puissent s'arrêter.
    if (s_session && s_session->is_running())
        s_session->set_pause_reason(app::AppSessionPauseReason::User, false);
}

// MARK: - Commandes

PTVITA_EXPORT void PTVitaSetButton(int retroPadButton, bool pressed) {
    if (!s_joystick)
        return;
    // Gâchettes L2/R2 : axes de la manette SDL.
    if (retroPadButton == 12 || retroPadButton == 13) {
        SDL_SetJoystickVirtualAxis(s_joystick, retroPadButton == 12 ? SDL_GAMEPAD_AXIS_LEFT_TRIGGER : SDL_GAMEPAD_AXIS_RIGHT_TRIGGER,
            pressed ? SDL_JOYSTICK_AXIS_MAX : 0);
        return;
    }
    // Numéros RetroPad de PlayTendo (PTButton) → boutons de manette SDL, par position.
    static const int buttons[16] = {
        SDL_GAMEPAD_BUTTON_SOUTH, // B (bas) = ✕
        SDL_GAMEPAD_BUTTON_WEST, // Y (gauche) = □
        SDL_GAMEPAD_BUTTON_BACK, // Select
        SDL_GAMEPAD_BUTTON_START, // Start
        SDL_GAMEPAD_BUTTON_DPAD_UP,
        SDL_GAMEPAD_BUTTON_DPAD_DOWN,
        SDL_GAMEPAD_BUTTON_DPAD_LEFT,
        SDL_GAMEPAD_BUTTON_DPAD_RIGHT,
        SDL_GAMEPAD_BUTTON_EAST, // A (droite) = ○
        SDL_GAMEPAD_BUTTON_NORTH, // X (haut) = △
        SDL_GAMEPAD_BUTTON_LEFT_SHOULDER, // L
        SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER, // R
        -1,
        -1,
        SDL_GAMEPAD_BUTTON_LEFT_STICK,
        SDL_GAMEPAD_BUTTON_RIGHT_STICK,
    };
    if (retroPadButton < 0 || retroPadButton >= 16 || buttons[retroPadButton] < 0)
        return;
    SDL_SetJoystickVirtualButton(s_joystick, buttons[retroPadButton], pressed);
}

PTVITA_EXPORT void PTVitaSetStick(int stick, float x, float y) {
    if (!s_joystick || stick < 0 || stick > 1)
        return;
    const auto axis = [](float value) {
        return static_cast<Sint16>(std::lround(std::clamp(value, -1.f, 1.f) * SDL_JOYSTICK_AXIS_MAX));
    };
    SDL_SetJoystickVirtualAxis(s_joystick, stick == 0 ? SDL_GAMEPAD_AXIS_LEFTX : SDL_GAMEPAD_AXIS_RIGHTX, axis(x));
    SDL_SetJoystickVirtualAxis(s_joystick, stick == 0 ? SDL_GAMEPAD_AXIS_LEFTY : SDL_GAMEPAD_AXIS_RIGHTY, axis(y));
}

PTVITA_EXPORT void PTVitaTouch(long finger, int phase, float x, float y) {
    if (s_state.load() == PTVitaStateStopped)
        return;
    SDL_TouchFingerEvent event{};
    event.type = phase == 0 ? SDL_EVENT_FINGER_DOWN : (phase == 1 ? SDL_EVENT_FINGER_MOTION : SDL_EVENT_FINGER_UP);
    event.timestamp = SDL_GetTicksNS();
    event.touchID = 1;
    event.fingerID = static_cast<SDL_FingerID>(finger) + 1;
    event.x = std::clamp(x, 0.f, 1.f);
    event.y = std::clamp(y, 0.f, 1.f);
    event.pressure = phase == 2 ? 0.f : 1.f;
    std::lock_guard<std::mutex> lock(s_touchMutex);
    if (s_touches.size() < 256)
        s_touches.push_back(event);
}

PTVITA_EXPORT char *PTVitaCopyLastError(void) {
    std::lock_guard<std::mutex> lock(s_errorMutex);
    return s_lastError.empty() ? nullptr : strdup(s_lastError.c_str());
}
