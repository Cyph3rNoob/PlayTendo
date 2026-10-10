#!/usr/bin/env python3
"""Retouches de Vita3K (moteur PS Vita, build 4135, commit 681f695) pour PlayTendo. Appelé par build_vita3k.sh ; une
retouche déjà faite est sautée : relancer le script ne change rien.

Vita3K n'existe pas pour iPhone : on part de sa version Android (une bibliothèque sans l'interface Qt, pilotée de
l'extérieur), que l'app charge comme les moteurs PS2 et GameCube/Wii (VitaCore.framework, pilote vita/PTVitaHost.cpp).
1. CMake : sur iOS (IOS), pas d'interface Qt ; la bibliothèque `vita3k` est faite du cœur et du pilote de PlayTendo
   (PLAYTENDO_VITA_HOST, PLAYTENDO_VITA_VIEW) ; version d'iOS minimale laissée au script ; Objective-C++ activé ; PLAYTENDO_IOS défini.
2. Boost.Filesystem compilé directement par CMake (l'outil b2 de Boost ne sait pas viser l'iPhone ici).
3. OpenSSL : celui compilé pour iPhone par build_vita3k.sh (PLAYTENDO_OPENSSL), sans Homebrew ni téléchargement.
4. MoltenVK : les en-têtes de celui déjà téléchargé pour la 3DS (PLAYTENDO_MOLTENVK_INCLUDE), sans téléchargement ;
   le moteur trouve Vulkan par PTVitaVkGetInstanceProcAddr (pilote), dans le MoltenVK.framework de l'app.
5. curl absent sur iPhone : Vita3K ne s'en sert que pour vérifier ses mises à jour et la liste de compatibilité.
6. Couche Metal (metal_layer.mm) : UIKit au lieu de Cocoa ; le pilote donne directement sa CAMetalLayer.
7. Réseau (macos_net_helper.cpp) : SCDynamicStore n'existe pas sur iPhone.
8. Turbo (JIT) : comme pour la 3DS (patch_azahar.py, même dynarmic/oaknut), le code compilé va dans la réserve JIT de
   l'app (PTJITAlloc/PTJITFree, deux vues : écriture et exécution) ; verrou ARM64 de dynarmic créé au premier usage.
9. dynarmic_cpu.cpp : Vita3K crée un recompilateur par fil d'exécution du jeu (des dizaines), 128 Mo de code chacun
   par défaut → 8 Mo (le minimum de dynarmic) pour tenir dans la réserve de 352 Mo partagée.
10. Son (sdl_audio.cpp) : compteur de PlayTendo (pilote) sur ce que le jeu envoie et sur ce que SDL donne à l'appareil
   (mélange final), noté dans vita3k.log.
11. Pipelines refusés par MoltenVK (pipeline_cache.cpp) : vulkan-hpp signale l'échec par une exception que rien ne
   rattrapait → l'app se fermait (LittleBigPlanet, 2026-10-10, « createGraphicsPipeline: ErrorInitializationFailed »).
   L'effet est sauté (nullptr, comme Vita3K le prévoit), marqué pour ne pas être recompilé à chaque image.
12. Messages de MoltenVK (renderer.cpp) : pas de couche de validation sur iPhone, mais MoltenVK donne la raison de ses
   refus par VK_EXT_debug_utils → branchée sur vita3k.log (« [PlayTendo] MoltenVK : … »).
"""
import os
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "sources", "vita3k")


def patch(relative, replacements):
    """`replacements` : (ancien, nouveau[, nombre attendu d'occurrences])."""
    path = os.path.join(ROOT, relative)
    text = open(path, encoding="utf-8").read()
    done = 0
    for item in replacements:
        old, new = item[0], item[1]
        count = item[2] if len(item) > 2 else 1
        if new in text:
            continue
        if text.count(old) != count:
            sys.exit(f"!!! {relative} : passage introuvable ou ambigu ({text.count(old)} au lieu de {count}) :\n{old}")
        text = text.replace(old, new)
        done += 1
    if done:
        open(path, "w", encoding="utf-8").write(text)
    print(f"{relative} : {done} retouche(s) faite(s), {len(replacements) - done} déjà là")


# 1 et 2. CMake principal.
patch("CMakeLists.txt", [
    ("set(CMAKE_OSX_DEPLOYMENT_TARGET 13.3)\n",
     "if(NOT IOS) # PlayTendo : version d'iOS minimale donnée par build_vita3k.sh\n"
     "\tset(CMAKE_OSX_DEPLOYMENT_TARGET 13.3)\n"
     "endif()\n"),
    ("if(APPLE)\n    enable_language(OBJC)\nendif()\n",
     "if(APPLE)\n    enable_language(OBJC)\n"
     "    # PlayTendo : fichiers Objective-C++ (.mm) de la couche Metal et du pilote iPhone.\n"
     "    enable_language(OBJCXX)\n"
     "endif()\n"
     "if(IOS)\n"
     "    add_compile_definitions(PLAYTENDO_IOS)\n"
     "endif()\n"),
    ("macro(get_boost)\n\tif(NOT VITA3K_FORCE_SYSTEM_BOOST)\n",
     "# PlayTendo : sur iPhone, Boost.Filesystem (seule partie compilée de Boost dont Vita3K a besoin) est compilé\n"
     "# directement, avec les possibilités du système d'Apple que son propre CMake détecterait.\n"
     "macro(playtendo_boost_filesystem)\n"
     "\tset(PT_BOOST_DIR \"${CMAKE_SOURCE_DIR}/external/boost\")\n"
     "\tadd_library(boost_filesystem_playtendo STATIC\n"
     "\t\t${PT_BOOST_DIR}/libs/filesystem/src/codecvt_error_category.cpp\n"
     "\t\t${PT_BOOST_DIR}/libs/filesystem/src/exception.cpp\n"
     "\t\t${PT_BOOST_DIR}/libs/filesystem/src/operations.cpp\n"
     "\t\t${PT_BOOST_DIR}/libs/filesystem/src/directory.cpp\n"
     "\t\t${PT_BOOST_DIR}/libs/filesystem/src/path.cpp\n"
     "\t\t${PT_BOOST_DIR}/libs/filesystem/src/path_traits.cpp\n"
     "\t\t${PT_BOOST_DIR}/libs/filesystem/src/portability.cpp\n"
     "\t\t${PT_BOOST_DIR}/libs/filesystem/src/unique_path.cpp\n"
     "\t\t${PT_BOOST_DIR}/libs/filesystem/src/utf8_codecvt_facet.cpp)\n"
     "\ttarget_include_directories(boost_filesystem_playtendo PUBLIC \"${PT_BOOST_DIR}\")\n"
     "\ttarget_include_directories(boost_filesystem_playtendo PRIVATE \"${PT_BOOST_DIR}/libs/filesystem/src\")\n"
     "\ttarget_compile_definitions(boost_filesystem_playtendo\n"
     "\t\tPUBLIC BOOST_ALL_NO_LIB BOOST_FILESYSTEM_NO_LIB BOOST_FILESYSTEM_STATIC_LINK=1\n"
     "\t\tPRIVATE BOOST_FILESYSTEM_SOURCE BOOST_FILESYSTEM_HAS_STAT_ST_BLKSIZE BOOST_FILESYSTEM_HAS_STAT_ST_MTIMESPEC\n"
     "\t\t\tBOOST_FILESYSTEM_HAS_STAT_ST_BIRTHTIMESPEC BOOST_FILESYSTEM_HAS_DIRENT_D_TYPE\n"
     "\t\t\tBOOST_FILESYSTEM_HAS_CXX20_ATOMIC_REF)\n"
     "\tadd_library(Boost::filesystem ALIAS boost_filesystem_playtendo)\n"
     "\tset(Boost_FOUND TRUE)\n"
     "\t# En-têtes de Boost (dynarmic les cherche aussi, avec find_package).\n"
     "\tset(BOOST_ROOT \"${PT_BOOST_DIR}\")\n"
     "\tset(BOOST_INCLUDEDIR \"${PT_BOOST_DIR}\")\n"
     "\tset(Boost_INCLUDE_DIR \"${PT_BOOST_DIR}\" CACHE PATH \"PlayTendo\" FORCE)\n"
     "\tset(Boost_INCLUDE_DIRS \"${PT_BOOST_DIR}\")\n"
     "\tset(Boost_LIBRARIES boost_filesystem_playtendo)\n"
     "\tset(Boost_FILESYSTEM_LIBRARY boost_filesystem_playtendo)\n"
     "endmacro()\n"
     "\n"
     "macro(get_boost)\n"
     "\tif(IOS)\n"
     "\t\tif(NOT TARGET boost_filesystem_playtendo)\n"
     "\t\t\tplaytendo_boost_filesystem()\n"
     "\t\tendif()\n"
     "\telseif(NOT VITA3K_FORCE_SYSTEM_BOOST)\n"),
])

# 1. CMake du dossier vita3k : sans Qt, bibliothèque partagée avec le pilote de PlayTendo.
patch("vita3k/CMakeLists.txt", [
    ("if(NOT ANDROID)\n\tinclude(${CMAKE_SOURCE_DIR}/cmake/qt6.cmake)\n",
     "if(NOT ANDROID AND NOT IOS) # PlayTendo : pas d'interface Qt sur iPhone\n"
     "\tinclude(${CMAKE_SOURCE_DIR}/cmake/qt6.cmake)\n"),
    ("if(NOT ANDROID)\n\tadd_subdirectory(gui-qt)\n",
     "if(NOT ANDROID AND NOT IOS)\n\tadd_subdirectory(gui-qt)\n"),
    ("if(ANDROID)\n\tadd_library(vita3k SHARED\n",
     "if(IOS)\n"
     "\t# PlayTendo : le cœur et le pilote vita/PTVitaHost.cpp + PTVitaView.mm (à la place de main.cpp et de\n"
     "\t# l'interface Qt).\n"
     "\tadd_library(vita3k SHARED interface.cpp performance.cpp ${PLAYTENDO_VITA_HOST} ${PLAYTENDO_VITA_VIEW})\n"
     "\tset_source_files_properties(${PLAYTENDO_VITA_VIEW} PROPERTIES COMPILE_OPTIONS \"-fobjc-arc\")\n"
     "\ttarget_include_directories(vita3k PRIVATE ${CMAKE_CURRENT_SOURCE_DIR} ${PLAYTENDO_INCLUDE})\n"
     "\ttarget_link_libraries(vita3k PRIVATE SDL3::SDL3 pugixml::pugixml \"-framework UIKit\" \"-framework QuartzCore\"\n"
     "\t\t\"-framework Metal\" \"-framework Foundation\")\n"
     "elseif(ANDROID)\n\tadd_library(vita3k SHARED\n"),
    ("if(NOT ANDROID)\n\ttarget_link_libraries(vita3k PRIVATE gui-qt)\n",
     "if(NOT ANDROID AND NOT IOS)\n\ttarget_link_libraries(vita3k PRIVATE gui-qt)\n"),
    ("if(NOT ANDROID)\n\tfile(GLOB VITA3K_QT_TS_FILES CONFIGURE_DEPENDS\n",
     "if(NOT ANDROID AND NOT IOS)\n\tfile(GLOB VITA3K_QT_TS_FILES CONFIGURE_DEPENDS\n"),
    ("if(APPLE)\n\tadd_custom_command(\n\t\tOUTPUT Vita3K.icns\n",
     "if(APPLE AND NOT IOS) # PlayTendo : paquet d'app macOS\n\tadd_custom_command(\n\t\tOUTPUT Vita3K.icns\n"),
])

# 6. Couche Metal : UIKit sur iPhone.
patch("vita3k/renderer/CMakeLists.txt", [
    ("\ttarget_link_libraries(renderer PRIVATE \"-framework QuartzCore\" \"-framework Cocoa\")\n",
     "\tif(IOS) # PlayTendo\n"
     "\t\ttarget_link_libraries(renderer PRIVATE \"-framework QuartzCore\" \"-framework UIKit\")\n"
     "\telse()\n"
     "\t\ttarget_link_libraries(renderer PRIVATE \"-framework QuartzCore\" \"-framework Cocoa\")\n"
     "\tendif()\n"),
])

patch("vita3k/renderer/src/vulkan/metal_layer.mm", [
    ("#import <Cocoa/Cocoa.h>\n#import <QuartzCore/CAMetalLayer.h>\n\n"
     "extern \"C\" void *get_metal_layer_from_view(void *nsview) {\n"
     "    return (__bridge void *)((__bridge NSView *)nsview).layer;\n}\n",
     "#import <QuartzCore/CAMetalLayer.h>\n#import <TargetConditionals.h>\n\n"
     "#if TARGET_OS_IPHONE\n"
     "// PlayTendo : le pilote iPhone (vita/PTVitaView.mm) donne directement sa CAMetalLayer (ou une UIView).\n"
     "#import <UIKit/UIKit.h>\n\n"
     "extern \"C\" void *get_metal_layer_from_view(void *view) {\n"
     "    id object = (__bridge id)view;\n"
     "    if ([object isKindOfClass:[CAMetalLayer class]])\n"
     "        return view;\n"
     "    if ([object isKindOfClass:[UIView class]])\n"
     "        return (__bridge void *)((UIView *)object).layer;\n"
     "    return nullptr;\n"
     "}\n"
     "#else\n"
     "#import <Cocoa/Cocoa.h>\n\n"
     "extern \"C\" void *get_metal_layer_from_view(void *nsview) {\n"
     "    return (__bridge void *)((__bridge NSView *)nsview).layer;\n}\n"
     "#endif\n"),
])

# 4. Vulkan : MoltenVK de l'app (le chargeur de vulkan.hpp chercherait une bibliothèque libvulkan absente).
patch("vita3k/renderer/src/vulkan/renderer.cpp", [
    ("#ifdef __APPLE__\n#include <MoltenVK/mvk_vulkan.h>\n#endif\n",
     "#ifdef __APPLE__\n#include <MoltenVK/mvk_vulkan.h>\n#endif\n\n"
     "#ifdef PLAYTENDO_IOS\n"
     "// PlayTendo : vkGetInstanceProcAddr du MoltenVK.framework de l'app (vita/PTVitaView.mm).\n"
     "extern \"C\" void *PTVitaVkGetInstanceProcAddr(void);\n"
     "#endif\n"),
    ("#else\n        VULKAN_HPP_DEFAULT_DISPATCHER.init();\n#endif\n",
     "#elif defined(PLAYTENDO_IOS)\n"
     "        VULKAN_HPP_DEFAULT_DISPATCHER.init(reinterpret_cast<PFN_vkGetInstanceProcAddr>(PTVitaVkGetInstanceProcAddr()));\n"
     "#else\n        VULKAN_HPP_DEFAULT_DISPATCHER.init();\n#endif\n"),
    ("#else\n        dispatch.init();\n#endif\n",
     "#elif defined(PLAYTENDO_IOS)\n"
     "        dispatch.init(reinterpret_cast<PFN_vkGetInstanceProcAddr>(PTVitaVkGetInstanceProcAddr()));\n"
     "#else\n        dispatch.init();\n#endif\n"),
])

# 3, 4 et 5. Dépendances externes.
patch("external/CMakeLists.txt", [
    ("endfunction()\n\ncheck_submodules_present()\n",
     "endfunction()\n\n"
     "# PlayTendo : les sous-modules propres à Android (libadrenotools), à Windows (dirent) et à l'interface PC\n"
     "# (nativefiledialog-extended) ne sont pas téléchargés (scripts/fetch_sources.sh).\n"
     "if(NOT IOS)\n\tcheck_submodules_present()\nendif()\n"),
    ("if(NOT ANDROID)\n\t# nativefiledialog-extended\n",
     "if(NOT ANDROID AND NOT IOS) # PlayTendo : fenêtres de choix de fichier de l'interface PC seulement\n"
     "\t# nativefiledialog-extended\n"),
    ("if(APPLE)\n\tif(NOT EXISTS \"${CMAKE_BINARY_DIR}/external/MoltenVK-macos.tar\")\n",
     "if(IOS)\n"
     "\t# PlayTendo : en-têtes du MoltenVK pour iPhone déjà téléchargé (sources/MoltenVK, celui de la 3DS).\n"
     "\ttarget_include_directories(vulkan INTERFACE \"${PLAYTENDO_MOLTENVK_INCLUDE}\")\n"
     "elseif(APPLE)\n\tif(NOT EXISTS \"${CMAKE_BINARY_DIR}/external/MoltenVK-macos.tar\")\n"),
    ("if(APPLE OR NOT FORCE_BUILD_OPENSSL_MAC)\n\texecute_process(\n\t\tCOMMAND brew --prefix openssl\n",
     "if(IOS)\n"
     "\t# PlayTendo : OpenSSL compilé pour iPhone par build_vita3k.sh (sans Homebrew ni téléchargement).\n"
     "\tadd_library(OpenSSL::Crypto STATIC IMPORTED GLOBAL)\n"
     "\tset_target_properties(OpenSSL::Crypto PROPERTIES IMPORTED_LOCATION \"${PLAYTENDO_OPENSSL}/lib/libcrypto.a\"\n"
     "\t\tINTERFACE_INCLUDE_DIRECTORIES \"${PLAYTENDO_OPENSSL}/include\")\n"
     "\tadd_library(OpenSSL::SSL STATIC IMPORTED GLOBAL)\n"
     "\tset_target_properties(OpenSSL::SSL PROPERTIES IMPORTED_LOCATION \"${PLAYTENDO_OPENSSL}/lib/libssl.a\"\n"
     "\t\tINTERFACE_INCLUDE_DIRECTORIES \"${PLAYTENDO_OPENSSL}/include\" INTERFACE_LINK_LIBRARIES OpenSSL::Crypto)\n"
     "\tset(OPENSSL_FOUND TRUE)\n"
     "\tset(OPENSSL_INCLUDE_DIR \"${PLAYTENDO_OPENSSL}/include\")\n"
     "\tset(OPENSSL_CRYPTO_LIBRARY \"${PLAYTENDO_OPENSSL}/lib/libcrypto.a\")\n"
     "\tset(OPENSSL_SSL_LIBRARY \"${PLAYTENDO_OPENSSL}/lib/libssl.a\")\n"
     "\tset(OPENSSL_LIBRARIES \"${OPENSSL_SSL_LIBRARY};${OPENSSL_CRYPTO_LIBRARY}\")\n"
     "elseif(APPLE OR NOT FORCE_BUILD_OPENSSL_MAC)\n\texecute_process(\n\t\tCOMMAND brew --prefix openssl\n"),
    ("if(NOT FORCE_BUILD_OPENSSL_MAC)\n\tfind_package(OpenSSL QUIET)\nendif()\n",
     "if(NOT FORCE_BUILD_OPENSSL_MAC AND NOT IOS)\n\tfind_package(OpenSSL QUIET)\nendif()\n"),
    ("find_package(CURL QUIET)\nif(NOT CURL_FOUND)\n",
     "if(NOT IOS)\n\tfind_package(CURL QUIET)\nendif()\n"
     "if(IOS)\n"
     "\t# PlayTendo : pas de curl sur iPhone (Vita3K ne s'en sert que pour ses mises à jour et sa liste de\n"
     "\t# compatibilité ; net_utils.cpp retouché).\n"
     "\tadd_library(libcurl INTERFACE)\n"
     "elseif(NOT CURL_FOUND)\n"),
])

patch("external/ffmpeg/CMakeLists.txt", [
    ("elseif (APPLE)\n\ttarget_link_libraries(${FFMPEG_CORE_NAME} INTERFACE\n"
     "\t\t\"-framework CoreServices\" \"-framework CoreFoundation\" \"-framework AudioUnit\"\n",
     "elseif (IOS)\n"
     "\t# PlayTendo : sur iPhone, AudioUnit n'est qu'un dossier d'en-têtes (son code est dans AudioToolbox).\n"
     "\ttarget_link_libraries(${FFMPEG_CORE_NAME} INTERFACE\n"
     "\t\t\"-framework CoreServices\" \"-framework CoreFoundation\"\n"
     "\t\t\"-framework AudioToolbox\" \"-framework CoreAudio\" \"-framework CoreMedia\"\n"
     "\t\t\"-framework VideoToolbox\" \"-framework CoreVideo\" \"-framework Security\")\n"
     "elseif (APPLE)\n\ttarget_link_libraries(${FFMPEG_CORE_NAME} INTERFACE\n"
     "\t\t\"-framework CoreServices\" \"-framework CoreFoundation\" \"-framework AudioUnit\"\n"),
])

patch("vita3k/util/src/net_utils.cpp", [
    ("#include <curl/curl.h>\n",
     "#ifndef PLAYTENDO_IOS\n#include <curl/curl.h>\n#endif\n"),
    ("std::string get_web_response(const std::string &url) {\n    auto curl = curl_easy_init();\n",
     "std::string get_web_response(const std::string &url) {\n"
     "#ifdef PLAYTENDO_IOS\n"
     "    return {}; // PlayTendo : rien n'est téléchargé sur iPhone\n"
     "#else\n"
     "    auto curl = curl_easy_init();\n"),
    ("    if (response_code / 100 == 2)\n        return response_string;\n\n    return {};\n}\n",
     "    if (response_code / 100 == 2)\n        return response_string;\n\n    return {};\n#endif\n}\n"),
])

# 7. Réseau : interface principale introuvable sur iPhone (le moteur prend alors une adresse MAC fixe).
patch("vita3k/modules/SceNet/macos_net_helper.cpp", [
    ("#include <SystemConfiguration/SystemConfiguration.h>\n",
     "#include <SystemConfiguration/SystemConfiguration.h>\n#include <TargetConditionals.h>\n"),
    ("bool get_primary_interface_name(char *dest, size_t bufferSize) {\n    bool success = false;\n",
     "bool get_primary_interface_name(char *dest, size_t bufferSize) {\n"
     "#if TARGET_OS_IPHONE\n"
     "    return false; // PlayTendo : SCDynamicStore n'existe pas sur iPhone\n"
     "#else\n"
     "    bool success = false;\n"),
    ("    CFRelease(store);\n    return success;\n}\n",
     "    CFRelease(store);\n    return success;\n#endif\n}\n"),
])

# 8. Turbo : mêmes retouches que pour la 3DS (patch_azahar.py).
patch("external/dynarmic/externals/oaknut/include/oaknut/code_block.hpp", [
    ("#    include <TargetConditionals.h>\n#    include <libkern/OSCacheControl.h>\n",
     "#    include <TargetConditionals.h>\n#    include <dlfcn.h>\n#    include <libkern/OSCacheControl.h>\n"),
    ("    explicit CodeBlock(std::size_t size)\n        : m_size(size)\n    {\n#if defined(_WIN32)\n",
     "    explicit CodeBlock(std::size_t size)\n        : m_size(size)\n    {\n"
     "#if defined(__APPLE__) && TARGET_OS_IPHONE\n"
     "        // PlayTendo : sur iPhone (iOS 26), seule la réserve JIT de l'app peut exécuter du code.\n"
     "        if (PlayTendoAllocate(size))\n"
     "            return;\n"
     "#endif\n"
     "#if defined(_WIN32)\n"),
    ("    ~CodeBlock()\n    {\n        if (m_memory == nullptr)\n            return;\n",
     "    ~CodeBlock()\n    {\n        if (m_memory == nullptr)\n            return;\n"
     "#if defined(__APPLE__) && TARGET_OS_IPHONE\n"
     "        if (m_pooled) {\n"
     "            PlayTendoFree();\n"
     "            return;\n"
     "        }\n"
     "#endif\n"),
    ("    std::uint32_t* ptr() const\n    {\n        return m_memory;\n    }\n",
     "    std::uint32_t* ptr() const\n    {\n        return m_memory;\n    }\n\n"
     "    // PlayTendo : adresse où écrire le code (différente de ptr() pour la réserve JIT de l'app).\n"
     "    std::uint32_t* wptr() const\n    {\n        return m_wmemory ? m_wmemory : m_memory;\n    }\n"),
    ("    void protect()\n    {\n",
     "    void protect()\n    {\n        if (m_pooled)\n            return;\n"),
    ("    void unprotect()\n    {\n",
     "    void unprotect()\n    {\n        if (m_pooled)\n            return;\n"),
    ("protected:\n    std::uint32_t* m_memory;\n    std::size_t m_size = 0;\n",
     "protected:\n    std::uint32_t* m_memory;\n    std::size_t m_size = 0;\n"
     "    // PlayTendo : bloc pris dans la réserve JIT de l'app (deux vues : écriture et exécution).\n"
     "    std::uint32_t* m_wmemory = nullptr;\n"
     "    bool m_pooled = false;\n"
     "\n"
     "#if defined(__APPLE__) && TARGET_OS_IPHONE\n"
     "    bool PlayTendoAllocate(std::size_t size)\n"
     "    {\n"
     "        using IsActiveFn = bool (*)(void);\n"
     "        using AllocFn = void* (*)(std::size_t, void**);\n"
     "        static const IsActiveFn is_active = (IsActiveFn)dlsym(RTLD_DEFAULT, \"PTJITIsActive\");\n"
     "        static const AllocFn alloc = (AllocFn)dlsym(RTLD_DEFAULT, \"PTJITAlloc\");\n"
     "        if (!is_active || !alloc || !is_active())\n"
     "            return false;\n"
     "        void* executable = nullptr;\n"
     "        void* writable = alloc(size, &executable);\n"
     "        if (!writable || !executable)\n"
     "            throw std::bad_alloc{};\n"
     "        m_memory = (std::uint32_t*)executable;\n"
     "        m_wmemory = (std::uint32_t*)writable;\n"
     "        m_pooled = true;\n"
     "        return true;\n"
     "    }\n"
     "\n"
     "    void PlayTendoFree()\n"
     "    {\n"
     "        using FreeFn = void (*)(void*);\n"
     "        static const FreeFn release = (FreeFn)dlsym(RTLD_DEFAULT, \"PTJITFree\");\n"
     "        if (release)\n"
     "            release(m_wmemory);\n"
     "    }\n"
     "#endif\n"),
])

patch("external/dynarmic/src/dynarmic/backend/arm64/address_space.cpp", [
    ("        , code(mem.ptr(), mem.ptr())\n", "        , code(mem.wptr(), mem.ptr())\n"),
    ("        CodeGenerator c{mem.ptr(), mem.ptr()};\n", "        CodeGenerator c{mem.wptr(), mem.ptr()};\n", 2),
])

patch("external/dynarmic/src/dynarmic/common/spin_lock_arm64.cpp", [
    ("        , code{mem.ptr(), mem.ptr()} {}\n", "        , code{mem.wptr(), mem.ptr()} {}\n"),
    ("std::once_flag flag;\nSpinLockImpl impl;\n",
     "std::once_flag flag;\n"
     "// PlayTendo : créé au premier verrou plutôt qu'au chargement du moteur (la réserve JIT de l'app n'est peut-être\n"
     "// pas encore prête à ce moment-là).\n"
     "SpinLockImpl& Impl() {\n"
     "    static SpinLockImpl* impl = new SpinLockImpl();\n"
     "    return *impl;\n"
     "}\n"),
    ("    std::call_once(flag, &SpinLockImpl::Initialize, impl);\n    impl.lock(&storage);\n",
     "    std::call_once(flag, [] { Impl().Initialize(); });\n    Impl().lock(&storage);\n"),
    ("    std::call_once(flag, &SpinLockImpl::Initialize, impl);\n    impl.unlock(&storage);\n",
     "    std::call_once(flag, [] { Impl().Initialize(); });\n    Impl().unlock(&storage);\n"),
])

# 9. Un recompilateur par fil d'exécution du jeu : 8 Mo de code chacun.
patch("vita3k/cpu/src/dynarmic_cpu.cpp", [
    ("    config.enable_cycle_counting = false;\n",
     "    config.enable_cycle_counting = false;\n"
     "#ifdef PLAYTENDO_IOS\n"
     "    // PlayTendo : un recompilateur par fil d'exécution du jeu, pris dans la réserve JIT partagée de l'app (352 Mo) :\n"
     "    // 8 Mo de code chacun (le minimum de dynarmic) au lieu de 128.\n"
     "    config.code_cache_size = 8 * 1024 * 1024;\n"
     "#endif\n"),
])

# 10. Compteur du son (PTVitaAudioQueued et PTVitaAudioPostmix, dans le pilote).
patch("vita3k/audio/src/impl/sdl_audio.cpp", [
    ("#include <SDL3/SDL_hints.h>\n",
     "#include <SDL3/SDL_hints.h>\n"
     "\n"
     "#ifdef PLAYTENDO_IOS\n"
     "// PlayTendo : compteur du son de la partie (vita/PTVitaHost.cpp), noté dans vita3k.log.\n"
     "extern \"C\" void PTVitaAudioQueued(const void *buffer, int bytes, uint64_t microseconds);\n"
     "extern \"C\" void SDLCALL PTVitaAudioPostmix(void *userdata, const SDL_AudioSpec *spec, float *buffer, int buflen);\n"
     "#endif\n"),
    ("    SDL_CHECK_EXT(device_id > 0, false);\n    return true;\n",
     "    SDL_CHECK_EXT(device_id > 0, false);\n"
     "#ifdef PLAYTENDO_IOS\n"
     "    SDL_SetAudioPostmixCallback(device_id, PTVitaAudioPostmix, nullptr);\n"
     "#endif\n"
     "    return true;\n"),
    ("    SDL_CHECK_VOID(SDL_PutAudioStreamData(port.stream.get(), buffer, out_port.len_bytes));\n",
     "#ifdef PLAYTENDO_IOS\n"
     "    PTVitaAudioQueued(buffer, out_port.len_bytes, out_port.len_microseconds);\n"
     "#endif\n"
     "    SDL_CHECK_VOID(SDL_PutAudioStreamData(port.stream.get(), buffer, out_port.len_bytes));\n"),
])

# 11. Pipeline refusé : effet sauté au lieu de fermer l'app. Marqueur « refusé » = celui de « en cours » (~0) : la
# recherche renvoie alors nullptr sans recompiler ; il n'est pas détruit à la fin.
patch("vita3k/renderer/src/vulkan/pipeline_cache.cpp", [
    ("    const auto result = state.device.createGraphicsPipeline(pipeline_cache, pipeline_info);\n"
     "    if (result.result != vk::Result::eSuccess) {\n"
     "        LOG_CRITICAL(\"Failed to create pipeline.\");\n"
     "        return nullptr;\n"
     "    }\n"
     "\n"
     "    return result.value;\n",
     "#ifdef PLAYTENDO_IOS\n"
     "    // PlayTendo : MoltenVK peut refuser un pipeline (shader non traduit en Metal) ; vulkan-hpp le signale par une\n"
     "    // exception que rien ne rattrapait (l'app se fermait). La raison donnée par MoltenVK est au journal juste avant.\n"
     "    try {\n"
     "#endif\n"
     "    const auto result = state.device.createGraphicsPipeline(pipeline_cache, pipeline_info);\n"
     "    if (result.result != vk::Result::eSuccess) {\n"
     "        LOG_CRITICAL(\"Failed to create pipeline.\");\n"
     "        return nullptr;\n"
     "    }\n"
     "\n"
     "    return result.value;\n"
     "#ifdef PLAYTENDO_IOS\n"
     "    } catch (const vk::SystemError &error) {\n"
     "        LOG_ERROR(\"[PlayTendo] Effet graphique refusé par MoltenVK, sauté : {}\", error.what());\n"
     "        return nullptr;\n"
     "    }\n"
     "#endif\n"),
    ("        *request->pipeline = pipeline;\n",
     "#ifdef PLAYTENDO_IOS\n"
     "        // PlayTendo : un pipeline refusé reste marqué « en cours » : sauté, jamais recompilé.\n"
     "        *request->pipeline = pipeline ? pipeline : std::bit_cast<vk::Pipeline, uint64_t>(~0ULL);\n"
     "#else\n"
     "        *request->pipeline = pipeline;\n"
     "#endif\n"),
    ("        it->second = result;\n\n        return result;\n",
     "#ifdef PLAYTENDO_IOS\n"
     "        // PlayTendo : un pipeline refusé reste marqué « en cours » : sauté, pas recompilé à chaque image.\n"
     "        it->second = result ? result : pipeline_compiling;\n"
     "#else\n"
     "        it->second = result;\n"
     "#endif\n"
     "\n"
     "        return result;\n"),
    ("    for (auto &[hash, pipeline] : pipelines)\n        state.device.destroy(pipeline);\n",
     "    for (auto &[hash, pipeline] : pipelines)\n"
     "#ifdef PLAYTENDO_IOS\n"
     "        // PlayTendo : sans les marqueurs « en cours / refusé » (~0), qui ne sont pas de vrais pipelines.\n"
     "        if (pipeline && pipeline != std::bit_cast<vk::Pipeline, uint64_t>(~0ULL))\n"
     "#endif\n"
     "            state.device.destroy(pipeline);\n"),
])

# 12. Messages de MoltenVK dans vita3k.log.
patch("vita3k/renderer/src/vulkan/renderer.cpp", [
    ("static vk::DebugReportCallbackEXT debug_report;\n",
     "#ifdef PLAYTENDO_IOS\n"
     "// PlayTendo : avertissements et erreurs de MoltenVK (raison d'un pipeline refusé…), sans couche de validation.\n"
     "static VKAPI_ATTR VkBool32 VKAPI_CALL playtendo_moltenvk_callback(\n"
     "    vk::DebugUtilsMessageSeverityFlagBitsEXT message_severity,\n"
     "    vk::DebugUtilsMessageTypeFlagsEXT message_type,\n"
     "    const vk::DebugUtilsMessengerCallbackDataEXT *callback_data,\n"
     "    void *pUserData) {\n"
     "    if (callback_data && callback_data->pMessage)\n"
     "        LOG_ERROR(\"[PlayTendo] MoltenVK : {}\", callback_data->pMessage);\n"
     "    return VK_FALSE;\n"
     "}\n"
     "#endif\n"
     "\n"
     "static vk::DebugReportCallbackEXT debug_report;\n"),
    ("                LOG_INFO(\"Disabling Vulkan validation layers (may improve performance but provides limited error messages)\");\n"
     "            }\n"
     "        }\n",
     "                LOG_INFO(\"Disabling Vulkan validation layers (may improve performance but provides limited error messages)\");\n"
     "            }\n"
     "        }\n"
     "#ifdef PLAYTENDO_IOS\n"
     "        bool playtendo_debug_utils = false;\n"
     "        if (!has_validation_layer) {\n"
     "            for (const vk::ExtensionProperties &prop : vk::enumerateInstanceExtensionProperties())\n"
     "                playtendo_debug_utils |= std::string_view(prop.extensionName.data()) == VK_EXT_DEBUG_UTILS_EXTENSION_NAME;\n"
     "            if (playtendo_debug_utils)\n"
     "                instance_extensions.push_back(VK_EXT_DEBUG_UTILS_EXTENSION_NAME);\n"
     "        }\n"
     "#endif\n"),
    ("        instance = vk::createInstance(instance_info);\n        VULKAN_HPP_DEFAULT_DISPATCHER.init(instance);\n",
     "        instance = vk::createInstance(instance_info);\n"
     "        VULKAN_HPP_DEFAULT_DISPATCHER.init(instance);\n"
     "#ifdef PLAYTENDO_IOS\n"
     "        if (playtendo_debug_utils) {\n"
     "            debug_messenger = instance.createDebugUtilsMessengerEXT(vk::DebugUtilsMessengerCreateInfoEXT{\n"
     "                .messageSeverity = vk::DebugUtilsMessageSeverityFlagBitsEXT::eWarning\n"
     "                    | vk::DebugUtilsMessageSeverityFlagBitsEXT::eError,\n"
     "                .messageType = vk::DebugUtilsMessageTypeFlagBitsEXT::eGeneral\n"
     "                    | vk::DebugUtilsMessageTypeFlagBitsEXT::eValidation,\n"
     "                .pfnUserCallback = playtendo_moltenvk_callback });\n"
     "            LOG_INFO(\"[PlayTendo] Messages de MoltenVK branchés sur ce journal\");\n"
     "        }\n"
     "#endif\n"),
])
