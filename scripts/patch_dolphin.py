#!/usr/bin/env python3
"""Retouches de DolphiniOS 5.0.0b6 pour en faire le moteur GameCube/Wii de PlayTendo (DolphinCore.framework).

Appelé par build_dolphin.sh. Une retouche déjà faite est sautée : relancer le script ne change rien.

1. Source/iOS/Library/CMakeLists.txt : avec -DPLAYTENDO_DOLPHIN_HOST=<fichier>, la bibliothèque « dolphin »
   (le cœur Dolphin, sans l'interface de DolphiniOS) reçoit le pilote dolphin/PTDolphinHost.mm.
2. FileUtil.cpp : le dossier Sys de Dolphin est cherché à côté du moteur (DolphinCore.framework/Sys) et non
   dans l'app.
3. MemoryUtil_iOS_LuckTXM.cpp : la mémoire du turbo (JIT) est prise dans la réserve de PlayTendo (PTJIT.m),
   préparée en un seul passage de StikDebug pour toutes les consoles, au lieu de la demander au débogueur
   (« brk #0x69 », il serait déjà parti).
4. MTLUtil.mm : au simulateur seulement, pas de lecture de l'image en cours dans les shaders (« framebuffer
   fetch ») : son Metal se dit « GPU Apple » mais ne la fait pas, et des surfaces sortaient sans texture.
5. Memmap.cpp : sur iPhone, la « mémoire rapide » (fastmem) réserve 8 Go d'adresses au lieu de 14 : les zones de
   garde de 2 Go ne servent qu'au recompilateur x86-64 (le commentaire de Dolphin le dit), et iOS limite les
   adresses d'une app sans le droit « extended-virtual-addressing » (réservé aux comptes développeur payants).
6. FrameDumper.h : capture d'écran attendue (`SaveScreenshotAndWait`), pour la vignette « Continuer ».
Mac (app PlayTendo pour Mac, build_dolphin.sh mac, avec -DPLAYTENDO_DOLPHIN_HOST) :
7. CMakeLists.txt et Source/CMakeLists.txt : PLAYTENDO_MAC défini, bibliothèque « dolphin » (Source/iOS/Library) aussi
   compilée pour le Mac, avec GameController et CoreHaptics.
8. InputCommon : le module de commandes de DolphiniOS (ControllerInterface/iOS : « écran tactile » que PlayTendo
   remplit, manettes MFi) aussi sur Mac, à la place du module clavier/souris de Dolphin (Quartz) : PlayTendo lit
   lui-même le clavier et la souris, et donne les boutons comme sur iPhone.
   (FileUtil.cpp, retouche 2 : aussi sur Mac, dossier Sys dans DolphinCore.framework/Resources/Sys.)
Les deux :
9. HostQueue.mm : `DOLHostQueueRunSync` attendait la fin d'une commande avec un Common::Event posé sur la pile de
   l'appelant ; le fil de la file pouvait encore y écrire (verrou, réveil) après le retour de l'appelant, donc dans
   ce que l'appelant mettait ensuite à cet endroit. Plantage de l'app Mac au lancement d'un jeu Wii après un jeu
   GameCube (2026-10-13 : un bit changé dans une valeur du fil de PlayTendo) ; essai à part : l'ancienne façon se
   bloque en moins de 200 000 commandes, la nouvelle (sémaphore de libdispatch, gardé en vie par le bloc) jamais.
"""
import os
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "sources", "dolphin-ios")


def patch(relative, replacements):
    path = os.path.join(ROOT, relative)
    text = open(path, encoding="utf-8").read()
    done = 0
    for old, new in replacements:
        if new in text:
            continue
        if text.count(old) != 1:
            sys.exit(f"!!! {relative} : passage introuvable ou ambigu :\n{old}")
        text = text.replace(old, new)
        done += 1
    if done:
        open(path, "w", encoding="utf-8").write(text)
    print(f"{relative} : {done} retouche(s) faite(s), {len(replacements) - done} déjà là")


patch("Source/iOS/Library/CMakeLists.txt", [
    ("target_link_libraries(dolphin\n",
     "if(PLAYTENDO_DOLPHIN_HOST)\n"
     "  # PlayTendo : pilote du moteur (fonctions PTDolphin* appelées par l'app).\n"
     "  target_sources(dolphin PRIVATE ${PLAYTENDO_DOLPHIN_HOST})\n"
     "  target_include_directories(dolphin PRIVATE ${PLAYTENDO_INCLUDE} ${CMAKE_CURRENT_SOURCE_DIR})\n"
     "  if(IOS)\n"
     "    target_link_libraries(dolphin PRIVATE \"-framework UIKit\" \"-framework MetalKit\" \"-framework AVFoundation\"\n"
     "      \"-framework CoreGraphics\")\n"
     "  else()\n"
     "    target_link_libraries(dolphin PRIVATE \"-framework AppKit\" \"-framework MetalKit\" \"-framework CoreGraphics\")\n"
     "  endif()\n"
     "endif()\n"
     "\n"
     "target_link_libraries(dolphin\n"),
])

patch("Source/Core/Common/FileUtil.cpp", [
    ("static std::string CreateSysDirectoryPath()\n{\n",
     "#if defined(IPHONEOS) || defined(PLAYTENDO_MAC)\n"
     "// PlayTendo : moteur dans DolphinCore.framework, avec son dossier Sys (sinon : l'app, comme DolphiniOS).\n"
     "static std::string GetCoreDirectory()\n"
     "{\n"
     "  Dl_info info;\n"
     "  if (dladdr(reinterpret_cast<const void*>(&GetCoreDirectory), &info) && info.dli_fname)\n"
     "  {\n"
     "    const std::string path = info.dli_fname;\n"
     "    const size_t slash = path.find_last_of('/');\n"
     "    if (path.find(\".framework/\") != std::string::npos && slash != std::string::npos)\n"
     "      return path.substr(0, slash);\n"
     "  }\n"
     "  return GetBundleDirectory();\n"
     "}\n"
     "#endif\n"
     "\n"
     "static std::string CreateSysDirectoryPath()\n{\n"),
    ("#if defined(__APPLE__)\n  const std::string sys_directory = GetBundleDirectory() + DIR_SEP SYSDATA_DIR DIR_SEP;\n",
     "#if defined(IPHONEOS)\n  const std::string sys_directory = GetCoreDirectory() + DIR_SEP SYSDATA_DIR DIR_SEP;\n"
     "#elif defined(PLAYTENDO_MAC)\n"
     "  // PlayTendo (Mac) : dossier Sys rangé dans les ressources de DolphinCore.framework.\n"
     "  const std::string sys_directory = GetCoreDirectory() + DIR_SEP \"Resources\" DIR_SEP \"Sys\" DIR_SEP;\n"
     "#elif defined(__APPLE__)\n  const std::string sys_directory = GetBundleDirectory() + DIR_SEP SYSDATA_DIR DIR_SEP;\n"),
    ("#include \"Common/FileUtil.h\"\n",
     "#include \"Common/FileUtil.h\"\n\n#if defined(IPHONEOS) || defined(PLAYTENDO_MAC)\n#include <dlfcn.h>\n#endif\n"),
])

patch("Source/Core/Common/MemoryUtil_iOS_LuckTXM.cpp", [
    ("static u8* g_rx_region = nullptr;\nstatic ptrdiff_t g_rw_region_diff = 0;\n",
     "static u8* g_rx_region = nullptr;\nstatic ptrdiff_t g_rw_region_diff = 0;\n"
     "\n"
     "// PlayTendo : réserve JIT de l'app (PTJIT.m). Fournisseur posé par dolphin/PTDolphinHost.mm : PTJITAlloc\n"
     "// (renvoie l'adresse d'écriture, place l'adresse d'exécution dans `executable`) et PTJITFree. Toute la\n"
     "// réserve a le même écart entre ses deux vues.\n"
     "static void* (*s_pt_alloc)(size_t size, void** executable) = nullptr;\n"
     "static void (*s_pt_free)(void* writable) = nullptr;\n"
     "\n"
     "extern \"C\" void DolphinPlayTendoSetCodeProvider(void* (*alloc)(size_t, void**), void (*release)(void*))\n"
     "{\n"
     "  s_pt_alloc = alloc;\n"
     "  s_pt_free = release;\n"
     "}\n"),
    ("void AllocateExecutableMemoryRegion_LuckTXM()\n{\n",
     "void AllocateExecutableMemoryRegion_LuckTXM()\n{\n"
     "  if (s_pt_alloc)  // PlayTendo : la réserve de l'app est déjà prête\n"
     "    return;\n\n"),
    ("void* AllocateExecutableMemory_LuckTXM(size_t size)\n{\n",
     "void* AllocateExecutableMemory_LuckTXM(size_t size)\n{\n"
     "  if (s_pt_alloc)\n"
     "  {\n"
     "    void* rx = nullptr;\n"
     "    u8* const rw = static_cast<u8*>(s_pt_alloc(size, &rx));\n"
     "    if (!rw || !rx)\n"
     "    {\n"
     "      PanicAlertFmt(\"AllocateExecutableMemory failed!\\nPlayTendo JIT pool full ({} bytes)\", size);\n"
     "      return nullptr;\n"
     "    }\n"
     "    g_rw_region_diff = rw - static_cast<u8*>(rx);\n"
     "    return rx;\n"
     "  }\n\n"),
    ("void FreeExecutableMemory_LuckTXM(void* ptr)\n{\n",
     "void FreeExecutableMemory_LuckTXM(void* ptr)\n{\n"
     "  if (s_pt_alloc)  // PlayTendo : un pointeur hors de la réserve est ignoré par PTJITFree\n"
     "  {\n"
     "    if (ptr && s_pt_free)\n"
     "      s_pt_free(static_cast<u8*>(ptr) + g_rw_region_diff);\n"
     "    return;\n"
     "  }\n\n"),
])

patch("Source/Core/Core/HW/Memmap.cpp", [
    ("  constexpr size_t guard_size = 0x8000'0000;\n",
     "#if defined(IPHONEOS) && defined(_M_ARM_64)\n"
     "  // PlayTendo : le recompilateur ARM64 calcule toujours base + adresse sur 32 bits (voir plus haut) : pas\n"
     "  // besoin de zones de garde, et iOS n'accorde pas 14 Go d'adresses d'un bloc à une app ordinaire.\n"
     "  constexpr size_t guard_size = 0;\n"
     "#else\n"
     "  constexpr size_t guard_size = 0x8000'0000;\n"
     "#endif\n"),
])

patch("Source/Core/VideoCommon/FrameDumper.h", [
    ("  void SaveScreenshot(std::string filename);\n",
     "  void SaveScreenshot(std::string filename);\n"
     "\n"
     "  // PlayTendo : demande une capture (prise à l'image suivante) et attend qu'elle soit écrite. Faux si le\n"
     "  // délai passe (jeu en pause ou sans nouvelle image).\n"
     "  bool SaveScreenshotAndWait(std::string filename, std::chrono::milliseconds timeout)\n"
     "  {\n"
     "    m_screenshot_completed.Reset();\n"
     "    SaveScreenshot(std::move(filename));\n"
     "    return m_screenshot_completed.WaitFor(timeout);\n"
     "  }\n"),
])

patch("Source/Core/VideoBackends/Metal/MTLUtil.mm", [
    ("  backend_info->bSupportsFramebufferFetch = [device supportsFamily:MTLGPUFamilyApple1];\n",
     "  backend_info->bSupportsFramebufferFetch = [device supportsFamily:MTLGPUFamilyApple1];\n"
     "#if TARGET_OS_SIMULATOR\n"
     "  // PlayTendo : le Metal du simulateur se dit « GPU Apple » mais ne lit pas l'image en cours dans un shader.\n"
     "  backend_info->bSupportsFramebufferFetch = false;\n"
     "#endif\n"),
])

# --- Mac ---------------------------------------------------------------------------------------------------------

patch("CMakeLists.txt", [
    ("if(ENABLE_HEADLESS)\n",
     "if(PLAYTENDO_DOLPHIN_HOST AND APPLE AND NOT IOS)\n"
     "  # PlayTendo : moteur de l'app Mac (bibliothèque « dolphin » de DolphiniOS, commandes données par l'app).\n"
     "  message(STATUS \"PlayTendo : moteur GameCube/Wii pour Mac\")\n"
     "  add_definitions(-DPLAYTENDO_MAC)\n"
     "  find_library(COREHAPTICS_LIBRARY CoreHaptics)\n"
     "  find_library(GAMECONTROLLER_LIBRARY GameController)\n"
     "endif()\n"
     "\n"
     "if(ENABLE_HEADLESS)\n"),
])

patch("Source/CMakeLists.txt", [
    ("if (IOS)\n  add_subdirectory(iOS/Library)\n",
     "if (IOS OR PLAYTENDO_DOLPHIN_HOST)  # PlayTendo : aussi sur Mac\n  add_subdirectory(iOS/Library)\n"),
])

patch("Source/Core/InputCommon/CMakeLists.txt", [
    ("    ControllerInterface/Quartz/QuartzKeyboardAndMouse.mm\n  )\n",
     "    ControllerInterface/Quartz/QuartzKeyboardAndMouse.mm\n  )\n"
     "  if(PLAYTENDO_DOLPHIN_HOST)\n"
     "    # PlayTendo : module de commandes de DolphiniOS (écran tactile rempli par l'app, manettes MFi).\n"
     "    target_sources(inputcommon PRIVATE\n"
     "      ControllerInterface/iOS/MFiController.mm\n"
     "      ControllerInterface/iOS/MFiControllerScanner.mm\n"
     "      ControllerInterface/iOS/MFiKeyboard.mm\n"
     "      ControllerInterface/iOS/Motor.mm\n"
     "      ControllerInterface/iOS/iOS.mm\n"
     "      ControllerInterface/iOS/StateManager.cpp\n"
     "      ControllerInterface/iOS/Touchscreen.mm\n"
     "    )\n"
     "    target_link_libraries(inputcommon PRIVATE ${COREHAPTICS_LIBRARY} ${GAMECONTROLLER_LIBRARY})\n"
     "  endif()\n"),
])

patch("Source/Core/InputCommon/ControllerInterface/ControllerInterface.h", [
    ("#if defined(__APPLE__) && !defined(IPHONEOS)\n#define CIFACE_USE_OSX\n#endif\n#ifdef IPHONEOS\n#define CIFACE_USE_IOS\n#endif\n",
     "// PlayTendo (Mac) : commandes de DolphiniOS (données par l'app) au lieu du clavier et de la souris de Dolphin.\n"
     "#if defined(__APPLE__) && !defined(IPHONEOS) && !defined(PLAYTENDO_MAC)\n#define CIFACE_USE_OSX\n#endif\n"
     "#if defined(IPHONEOS) || defined(PLAYTENDO_MAC)\n#define CIFACE_USE_IOS\n#endif\n"),
])

patch("Source/iOS/Library/HostQueue.mm", [
    ("""  if (!Core::IsHostThread())
  {
    Common::Event sync_event;
    Common::Event* sync_event_ptr = &sync_event;

    dispatch_async(DOLHostQueueGetUnderlyingQueue(), ^{
      DOLHostQueueExecuteBlock(block);

      sync_event_ptr->Set();
    });

    sync_event.Wait();
  }
""", """  if (!Core::IsHostThread())
  {
    // PlayTendo : sémaphore gardé en vie par le bloc, au lieu d'un Common::Event sur la pile : le fil de la file
    // y écrivait parfois encore après le retour de l'appelant (pile de l'appelant abîmée).
    dispatch_semaphore_t done = dispatch_semaphore_create(0);

    dispatch_async(DOLHostQueueGetUnderlyingQueue(), ^{
      DOLHostQueueExecuteBlock(block);

      dispatch_semaphore_signal(done);
    });

    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
#if !__has_feature(objc_arc)
    dispatch_release(done);
#endif
  }
"""),
])
