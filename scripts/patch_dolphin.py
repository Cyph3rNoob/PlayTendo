#!/usr/bin/env python3
"""Retouches de DolphiniOS 5.0.0b6 pour en faire le moteur GameCube/Wii de PlayTendo (DolphinCore.framework).

Appelé par build_dolphin.sh. Une retouche déjà faite est sautée : relancer le script ne change rien.

1. Source/iOS/Library/CMakeLists.txt : avec -DPLAYTENDO_DOLPHIN_HOST=<fichier>, la bibliothèque « dolphin »
   (le cœur Dolphin, sans l'interface de DolphiniOS) reçoit le pilote dolphin/PTDolphinHost.mm.
2. FileUtil.cpp : le dossier Sys de Dolphin est cherché à côté du moteur (DolphinCore.framework/Sys) et non
   dans l'app.
4. MTLUtil.mm : au simulateur seulement, pas de lecture de l'image en cours dans les shaders (« framebuffer
   fetch ») : son Metal se dit « GPU Apple » mais ne la fait pas, et des surfaces sortaient sans texture.
3. MemoryUtil_iOS_LuckTXM.cpp : la mémoire du turbo (JIT) est prise dans la réserve de PlayTendo (PTJIT.m),
   préparée en un seul passage de StikDebug pour toutes les consoles, au lieu de la demander au débogueur
   (« brk #0x69 », il serait déjà parti).
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
     "  target_link_libraries(dolphin PRIVATE \"-framework UIKit\" \"-framework MetalKit\" \"-framework AVFoundation\"\n"
     "    \"-framework CoreGraphics\")\n"
     "endif()\n"
     "\n"
     "target_link_libraries(dolphin\n"),
])

patch("Source/Core/Common/FileUtil.cpp", [
    ("static std::string CreateSysDirectoryPath()\n{\n",
     "#ifdef IPHONEOS\n"
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
     "#elif defined(__APPLE__)\n  const std::string sys_directory = GetBundleDirectory() + DIR_SEP SYSDATA_DIR DIR_SEP;\n"),
    ("#include \"Common/FileUtil.h\"\n",
     "#include \"Common/FileUtil.h\"\n\n#ifdef IPHONEOS\n#include <dlfcn.h>\n#endif\n"),
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

patch("Source/Core/VideoBackends/Metal/MTLUtil.mm", [
    ("  backend_info->bSupportsFramebufferFetch = [device supportsFamily:MTLGPUFamilyApple1];\n",
     "  backend_info->bSupportsFramebufferFetch = [device supportsFamily:MTLGPUFamilyApple1];\n"
     "#if TARGET_OS_SIMULATOR\n"
     "  // PlayTendo : le Metal du simulateur se dit « GPU Apple » mais ne lit pas l'image en cours dans un shader.\n"
     "  backend_info->bSupportsFramebufferFetch = false;\n"
     "#endif\n"),
])
