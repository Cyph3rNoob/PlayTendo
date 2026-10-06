#!/usr/bin/env python3
"""Retouches d'ARMSX2 iOS 2.6.0 pour en faire le moteur PS2 de PlayTendo (PS2Core.framework).

Appelé par build_ps2.sh. Une retouche déjà faite est sautée : relancer le script ne change rien.

1. CMakeLists.txt : avec -DPLAYTENDO_PS2CORE=ON, la cible ARMSX2iOS devient un framework « PS2Core » sans
   l'interface SwiftUI d'ARMSX2 ni son main() (AppDelegate.mm), avec le pilote ps2/PTPS2Host.mm. Les fichiers
   propres à l'app ARMSX2 (icônes, thèmes, sons de menu, habillages de manette…) ne sont pas embarqués.
2. HostImpls.mm : la PS2 dessine dans sa vue Metal même sans fenêtre SDL (PlayTendo garde sa fenêtre) ;
   les erreurs du moteur sont transmises à PlayTendo.
3. ios_main.mm : les dossiers BIOS et cartes mémoire de PlayTendo (chemins absolus réécrits à chaque
   lancement) ne sont pas « réparés » vers le dossier du moteur.
4. SceneDelegate.mm : le lien vers l'interface Swift d'ARMSX2 (liens armsx2://) est retiré sans elle ;
   ARMSX2_PlayTendoReleaseVMThread() arrête le thread permanent de la console pour rendre sa mémoire (sa
   réserve d'adresses empêchait PPSSPP de placer la mémoire de la PSP après une partie PS2).
5. DarwinMisc.cpp + Memory.cpp : la zone de code des recompilateurs (305 Mo) est prise dans la réserve JIT de
   PlayTendo (PTJIT.m), préparée en un seul passage de StikDebug pour toutes les consoles, au lieu qu'ARMSX2
   rappelle le débogueur lui-même (il serait déjà parti). Au simulateur : la réserve si elle est prête, sinon
   MAP_JIT comme avant.
"""
import os
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "sources", "armsx2")
CPP = os.path.join(ROOT, "platforms", "ios", "app", "src", "main", "cpp")


def patch(relative, replacements, base=CPP):
    path = os.path.join(base, relative)
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


patch("CMakeLists.txt", [
    ("\tadd_executable(ARMSX2iOS ${IOS_RUNTIME_SOURCES} ARMSX2Bridge.mm ${SWIFT_SOURCES})\n",
     "\tif(PLAYTENDO_PS2CORE)\n"
     "\t\t# PlayTendo : le moteur seul, en framework chargé par l'app (sans l'interface ARMSX2 ni main()).\n"
     "\t\tlist(REMOVE_ITEM IOS_RUNTIME_SOURCES IOS/AppDelegate.mm)\n"
     "\t\tset_source_files_properties(${PLAYTENDO_PS2_HOST} PROPERTIES COMPILE_FLAGS \"-fobjc-arc\")\n"
     "\t\tadd_library(ARMSX2iOS SHARED ${IOS_RUNTIME_SOURCES} ARMSX2Bridge.mm ${PLAYTENDO_PS2_HOST})\n"
     "\telse()\n"
     "\t\tadd_executable(ARMSX2iOS ${IOS_RUNTIME_SOURCES} ARMSX2Bridge.mm ${SWIFT_SOURCES})\n"
     "\tendif()\n"),
    ("\t\tset(BOOT_SPLASH_VIDEO ",
     "\tif(PLAYTENDO_PS2CORE)\n"
     "\t\tset_target_properties(ARMSX2iOS PROPERTIES\n"
     "\t\t\tFRAMEWORK TRUE\n"
     "\t\t\tOUTPUT_NAME \"PS2Core\"\n"
     "\t\t\tMACOSX_FRAMEWORK_IDENTIFIER \"com.playtendo.ps2core\"\n"
     "\t\t\tMACOSX_FRAMEWORK_BUNDLE_VERSION \"${ARMSX2_BUILD_NUMBER}\"\n"
     "\t\t\tMACOSX_FRAMEWORK_SHORT_VERSION_STRING \"${ARMSX2_VERSION}\"\n"
     "\t\t\tXCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER \"com.playtendo.ps2core\"\n"
     "\t\t\tXCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS \"\"\n"
     "\t\t\tXCODE_ATTRIBUTE_DYLIB_INSTALL_NAME_BASE \"@rpath\"\n"
     "\t\t\tXCODE_ATTRIBUTE_LD_RUNPATH_SEARCH_PATHS \"@executable_path/Frameworks @loader_path/Frameworks\"\n"
     "\t\t\tXCODE_ATTRIBUTE_SKIP_INSTALL \"YES\"\n"
     "\t\t)\n"
     "\t\ttarget_include_directories(ARMSX2iOS PRIVATE ${PLAYTENDO_INCLUDE})\n"
     "\tendif()\n"
     "\tif(NOT PLAYTENDO_PS2CORE)\n"
     "\t\tset(BOOT_SPLASH_VIDEO "),
    ("\tset(ARMSX2_APPLE_FRAMEWORKS\n",
     "\tendif() # NOT PLAYTENDO_PS2CORE\n\n"
     "\tset(ARMSX2_APPLE_FRAMEWORKS\n"),
    ("\ttarget_sources(ARMSX2iOS PRIVATE ${METAL_SHADERS} ${FONTS} ${IOS_SHADER_RESOURCES})\n",
     "\tif(PLAYTENDO_PS2CORE)\n"
     "\t\tlist(FILTER IOS_TOP_LEVEL_RESOURCES EXCLUDE REGEX \"(Localizable\\\\.xcstrings|armsx2-theme\\\\.json)$\")\n"
     "\tendif()\n"
     "\ttarget_sources(ARMSX2iOS PRIVATE ${METAL_SHADERS} ${FONTS} ${IOS_SHADER_RESOURCES})\n"),
])

patch("IOS/HostImpls.mm", [
    ("        if (!g_sdl_window) {\n"
     "            Console.Error(\"Host::AcquireRenderWindow: g_sdl_window is NULL\");",
     "        // PlayTendo : pas de fenêtre SDL, la vue Metal (g_gameRenderView) suffit.\n"
     "        if (!g_sdl_window && !g_gameRenderView) {\n"
     "            Console.Error(\"Host::AcquireRenderWindow: g_sdl_window is NULL\");"),
    ("            if (window) {\n"
     "                // Use dedicated game render view if available (sized for portrait).",
     "            if (window || g_gameRenderView) {\n"
     "                // Use dedicated game render view if available (sized for portrait)."),
    ("    void ReportErrorAsync(std::string_view title, std::string_view msg) {\n"
     "        Console.Error(\"Host::ReportErrorAsync: %s - %s\", std::string(title).c_str(), std::string(msg).c_str());\n",
     "    extern \"C\" void PTPS2RecordError(const char* title, const char* message); // PlayTendo (PTPS2Host.mm)\n"
     "    void ReportErrorAsync(std::string_view title, std::string_view msg) {\n"
     "        Console.Error(\"Host::ReportErrorAsync: %s - %s\", std::string(title).c_str(), std::string(msg).c_str());\n"
     "        PTPS2RecordError(std::string(title).c_str(), std::string(msg).c_str());\n"),
])

patch("ios_main.mm", [
    ("void ARMSX2IOSSanitizeFolderSettings(SettingsInterface* si, const std::string& dataRoot, const char* reason)\n"
     "{\n"
     "    if (!si)\n"
     "        return;\n",
     "void ARMSX2IOSSanitizeFolderSettings(SettingsInterface* si, const std::string& dataRoot, const char* reason)\n"
     "{\n"
     "    extern bool g_ptps2Host; // PlayTendo (PTPS2Host.mm) : dossiers réécrits à chaque lancement\n"
     "    if (!si || g_ptps2Host)\n"
     "        return;\n"),
])

patch("IOS/SceneDelegate.mm", [
    ("        [DeepLinkBridge handle:url];\n",
     "#if ARMSX2_HAS_SWIFTUI // PlayTendo : sans l'interface Swift d'ARMSX2\n"
     "        [DeepLinkBridge handle:url];\n"
     "#endif\n"),
    ("@implementation ARMSX2ExternalDisplaySceneDelegate\n",
     "// PlayTendo : arrête le thread permanent de la console (CPUThreadShutdown rend sa mémoire) ; il sera\n"
     "// recréé au prochain jeu. Sans effet si une partie est en cours. Appelé par PTPS2Host.mm.\n"
     "extern \"C\" void ARMSX2_PlayTendoReleaseVMThread(void)\n"
     "{\n"
     "    std::unique_lock<std::mutex> lk(s_vmMutex);\n"
     "    if (!s_vmThreadCreated || s_vmThreadActive.load(std::memory_order_acquire))\n"
     "        return;\n"
     "    s_requestVMBoot.store(false);\n"
     "    s_vmThreadShouldExit.store(true);\n"
     "    s_vmCV.notify_all();\n"
     "    s_vmCV.wait(lk, [] { return !s_vmThreadCreated; });\n"
     "}\n\n"
     "@implementation ARMSX2ExternalDisplaySceneDelegate\n"),
])

ARMSX2 = ROOT

patch("common/Darwin/DarwinMisc.cpp", [
    ("void* DarwinMisc::MmapCodeDualMap(size_t size)\n"
     "{\n"
     "#if !TARGET_OS_IPHONE || TARGET_OS_SIMULATOR\n",
     "// PlayTendo : la zone de code des recompilateurs est prise dans la réserve JIT de l'app (PTJIT.m), préparée\n"
     "// en un seul passage de StikDebug pour toutes les consoles. Fournisseur posé par PTPS2Host.mm : PTJITAlloc\n"
     "// (renvoie l'adresse d'écriture, place l'adresse d'exécution dans `executable`) et PTJITFree.\n"
     "static void* (*s_pt_code_alloc)(size_t size, void** executable) = nullptr;\n"
     "static void (*s_pt_code_free)(void* writable) = nullptr;\n"
     "static void* s_pt_code_rx = nullptr;\n"
     "\n"
     "extern \"C\" void ARMSX2_PlayTendoSetCodeProvider(void* (*alloc)(size_t, void**), void (*release)(void*))\n"
     "{\n"
     "\ts_pt_code_alloc = alloc;\n"
     "\ts_pt_code_free = release;\n"
     "}\n"
     "\n"
     "// Zone de code tirée de la réserve de PlayTendo, ou nullptr (pas de fournisseur, réserve absente ou pleine).\n"
     "extern \"C\" void* ARMSX2_PlayTendoMmapCode(size_t size)\n"
     "{\n"
     "\tvoid* rx = nullptr;\n"
     "\tvoid* const rw = s_pt_code_alloc ? s_pt_code_alloc(size, &rx) : nullptr;\n"
     "\tif (!rw || !rx)\n"
     "\t{\n"
     "\t\tif (s_pt_code_alloc)\n"
     "\t\t\tConsole.Warning(\"[PlayTendo] Pas de place dans la réserve JIT de l'app pour le code PS2 (ou réserve absente)\");\n"
     "\t\treturn nullptr;\n"
     "\t}\n"
     "\t{\n"
     "\t\tstd::lock_guard<std::mutex> validation_lock(s_jit_validation_mutex);\n"
     "\t\tDarwinMisc::g_code_rw_offset = static_cast<u8*>(rw) - static_cast<u8*>(rx);\n"
     "\t\tDarwinMisc::g_code_rw_base = reinterpret_cast<uintptr_t>(rw);\n"
     "\t\tDarwinMisc::g_code_rw_size = size;\n"
     "\t\ts_pt_code_rx = rx;\n"
     "\t}\n"
     "\tConsole.WriteLn(\"[PlayTendo] Code PS2 dans la réserve JIT de l'app : %zu Mo (exécution %p, écriture %p)\",\n"
     "\t\tsize >> 20, rx, rw);\n"
     "\treturn rx;\n"
     "}\n"
     "\n"
     "void* DarwinMisc::MmapCodeDualMap(size_t size)\n"
     "{\n"
     "\t// PlayTendo : le débogueur est déjà reparti, seule la réserve de l'app peut servir.\n"
     "\tif (s_pt_code_alloc)\n"
     "\t\treturn ARMSX2_PlayTendoMmapCode(size);\n"
     "#if !TARGET_OS_IPHONE || TARGET_OS_SIMULATOR\n"),
    ("\tconst ptrdiff_t rw_offset = g_code_rw_offset;\n",
     "\tconst ptrdiff_t rw_offset = g_code_rw_offset;\n"
     "\tif (s_pt_code_rx && rx_ptr == s_pt_code_rx) // PlayTendo : rendue à la réserve de l'app\n"
     "\t{\n"
     "\t\tg_code_rw_offset = 0;\n"
     "\t\tg_code_rw_base = 0;\n"
     "\t\tg_code_rw_size = 0;\n"
     "\t\ts_pt_code_rx = nullptr;\n"
     "\t\tif (s_pt_code_free && rw_base)\n"
     "\t\t\ts_pt_code_free(reinterpret_cast<void*>(rw_base));\n"
     "\t\treturn;\n"
     "\t}\n"),
], base=ARMSX2)

patch("pcsx2/Memory.cpp", [
    ("bool SysMemory::AllocateMemoryMap()\n",
     "#ifdef __APPLE__\n"
     "extern \"C\" void* ARMSX2_PlayTendoMmapCode(size_t size); // PlayTendo (DarwinMisc.cpp)\n"
     "#endif\n"
     "\n"
     "bool SysMemory::AllocateMemoryMap()\n"),
    ("\telse if (force_dual_map && std::atoi(force_dual_map) == 1)\n",
     "\telse if ((s_code_memory = static_cast<u8*>(ARMSX2_PlayTendoMmapCode(HostMemoryMap::CodeSize))) != nullptr)\n"
     "\t{\n"
     "\t\t// PlayTendo (simulateur) : réserve JIT de l'app quand elle est prête, sinon MAP_JIT ci-dessous.\n"
     "\t}\n"
     "\telse if (force_dual_map && std::atoi(force_dual_map) == 1)\n"),
], base=ARMSX2)
