#!/usr/bin/env python3
"""Retouches de Vita3K (moteur PS Vita, build 4135, commit 681f695) pour PlayTendo. Appelé par build_vita3k.sh ; une
retouche déjà faite est sautée : relancer le script ne change rien.

Vita3K n'existe pas pour iPhone : on part de sa version Android (une bibliothèque sans l'interface Qt, pilotée de
l'extérieur), que l'app charge comme les moteurs PS2 et GameCube/Wii (VitaCore.framework, pilote vita/PTVitaHost.cpp).
La même bibliothèque est compilée pour Mac (2026-10-12) : build_vita3k.sh donne `-DPLAYTENDO=ON` dans les deux cas.
Dans le code : `PLAYTENDO` = moteur de PlayTendo (iPhone et Mac), `PLAYTENDO_IOS` = iPhone seulement.
1. CMake : pour PlayTendo (PLAYTENDO), pas d'interface Qt ; la bibliothèque `vita3k` est faite du cœur et du pilote
   (PLAYTENDO_VITA_HOST, PLAYTENDO_VITA_VIEW ; UIKit sur iPhone, AppKit sur Mac) ; version d'iOS minimale laissée au
   script ; Objective-C++ activé ; PLAYTENDO et PLAYTENDO_IOS définis.
2. Boost.Filesystem compilé directement par CMake (l'outil b2 de Boost ne sait pas viser l'iPhone ; sur Mac, pas de
   Boost de Homebrew).
3. OpenSSL : celui compilé par build_vita3k.sh pour iPhone ou Mac (PLAYTENDO_OPENSSL), sans Homebrew ni téléchargement.
4. MoltenVK : les en-têtes de celui déjà téléchargé pour la 3DS (PLAYTENDO_MOLTENVK_INCLUDE), sans téléchargement ;
   le moteur trouve Vulkan par PTVitaVkGetInstanceProcAddr (pilote), dans le MoltenVK.framework de l'app.
5. curl absent : Vita3K ne s'en sert que pour vérifier ses mises à jour et la liste de compatibilité.
6. Couche Metal (metal_layer.mm) : UIKit sur iPhone ; le pilote donne directement sa CAMetalLayer.
7. Réseau (macos_net_helper.cpp) : SCDynamicStore n'existe pas sur iPhone.
8. Turbo (JIT), sur iPhone : comme pour la 3DS (patch_azahar.py, même dynarmic/oaknut), le code compilé va dans la
   réserve JIT de l'app (PTJITAlloc/PTJITFree, deux vues : écriture et exécution) ; verrou ARM64 de dynarmic créé au
   premier usage. Sur Mac, dynarmic prend lui-même sa mémoire exécutable (MAP_JIT).
9. dynarmic_cpu.cpp, sur iPhone : Vita3K crée un recompilateur par fil d'exécution du jeu (des dizaines), 128 Mo de
   code chacun par défaut → 8 Mo (le minimum de dynarmic) pour tenir dans la réserve de 352 Mo partagée.
10. Son (sdl_audio.cpp) : compteur de PlayTendo (pilote) sur ce que le jeu envoie et sur ce que SDL donne à l'appareil
   (mélange final), noté dans vita3k.log.
11. Pipelines refusés par MoltenVK (pipeline_cache.cpp) : vulkan-hpp signale l'échec par une exception que rien ne
   rattrapait → l'app se fermait (LittleBigPlanet, 2026-10-10, « createGraphicsPipeline: ErrorInitializationFailed »).
   L'effet est sauté (nullptr, comme Vita3K le prévoit), marqué pour ne pas être recompilé à chaque image.
12. Messages de MoltenVK (renderer.cpp) : pas de couche de validation, mais MoltenVK donne la raison de ses
   refus par VK_EXT_debug_utils → branchée sur vita3k.log (« [PlayTendo] MoltenVK : … »).
13. Masque de la Vita (scene.cpp) : sans l'émulation de la retouche 14 (appareil sans shader interlock), ses dessins
   sont sautés, comme le fait le rendu OpenGL de Vita3K quand il n'a pas de tampon de masque (gl/draw.cpp).
14. Masque de la Vita émulé en Vulkan (pochoir des menus de Minecraft : « Mask not implemented », seul le texte jaune
   s'affichait, 2026-10-10 ; « On Vulkan the graphics don't render » sur PC), sur le modèle du rendu OpenGL :
   - une image RGBA8 par cible de rendu (creation.cpp), remise au début de chaque scène à la valeur de fond de la
     surface de profondeur (context.cpp, comme gl::sync_mask ; « tout visible » sans surface de profondeur) ;
   - les dessins du masque y écrivent 0 ou 1 (spirv_recompiler.cpp, generate_update_mask_body), sans couleur, ni
     profondeur, ni stencil (pipeline_cache.cpp) ; tous les autres shaders de pixels la lisent et jettent le pixel
     masqué (code déjà prévu par Vita3K, `use_mask_bit`, set 1 binding 1) ;
   - lecture et écriture dans l'ordre de rastérisation : verrou « shader interlock » sur tout le shader de pixels
     (MoltenVK le traduit en raster order groups de Metal), d'où `use_mask_bit` = shader interlock de l'appareil ;
   - le shader de sommets d'un dessin de masque est compilé normalement : Vita3K le compilait « en mode masque »
     (sans position) et le rangeait dans son cache sous le seul identifiant du programme → les dessins normaux qui
     partagent ce programme de sommets ne dessinaient plus rien (menus invisibles même sans masque) ;
   - `use_mask_bit` entre dans la signature du cache des shaders (renderer.cpp) : les shaders déjà enregistrés,
     dont ceux cassés par le point précédent, sont effacés au premier lancement.
15. Mémoire mappée gardée sur Apple (2026-10-12) : Vita3K la coupe sur tous les appareils Apple (renderer.cpp,
   « we need to make a copy of the vertex buffer for moltenvk »), seulement parce que Metal veut des flux de sommets
   au pas multiple de 4. Or sans elle, Vita3K ignore les écritures en mémoire des shaders (« Store opcode is not
   supported without memory mapping ») : textures de Gravity Rush qui clignotaient selon l'angle de la caméra, corrigé
   sur iPhone. MoltenVK a ce qu'il faut (adresses de tampons, lecture de vec4 alignées sur 4 octets : essai sur le Mac
   M3). Méthode « double tampon ».
   - les flux de sommets au pas ou au début non multiple de 4 sont copiés et réalignés à part, comme sans mémoire
     mappée (scene.cpp) ; de même les indices dont le début n'est pas multiple de 4 (leur plus grand indice est
     calculé ici : il fixe la taille des flux de sommets) ; tampons tournants créés aussi dans ce mode (creation.cpp) ;
   - le pilote demande la méthode à chaque partie (PTVitaHost.cpp) ; le cache des shaders change de lui-même
     (`use_memory_mapping` est dans sa signature).
17. interface.cpp (2026-10-24, audit de sécurité) : installation d'un .vpk, une entrée dont le nom remonte (« ../ »)
   ou est absolu sortait du dossier du jeu (« zip slip ») ; sur Mac, l'app n'étant pas isolée, un .vpk piégé aurait pu
   écrire n'importe où dans le dossier de l'utilisateur. Ces entrées sont ignorées.
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
     "    # PlayTendo : fichiers Objective-C++ (.mm) de la couche Metal et du pilote.\n"
     "    enable_language(OBJCXX)\n"
     "endif()\n"
     "if(PLAYTENDO)\n"
     "    add_compile_definitions(PLAYTENDO)\n"
     "endif()\n"
     "if(IOS)\n"
     "    add_compile_definitions(PLAYTENDO_IOS)\n"
     "endif()\n"),
    ("macro(get_boost)\n\tif(NOT VITA3K_FORCE_SYSTEM_BOOST)\n",
     "# PlayTendo : Boost.Filesystem (seule partie compilée de Boost dont Vita3K a besoin) est compilé directement,\n"
     "# avec les possibilités du système d'Apple que son propre CMake détecterait (b2 ne vise pas l'iPhone ; sur Mac,\n"
     "# pas de Boost de Homebrew, absent de l'app).\n"
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
     "\tif(PLAYTENDO)\n"
     "\t\tif(NOT TARGET boost_filesystem_playtendo)\n"
     "\t\t\tplaytendo_boost_filesystem()\n"
     "\t\tendif()\n"
     "\telseif(NOT VITA3K_FORCE_SYSTEM_BOOST)\n"),
])

# 1. CMake du dossier vita3k : sans Qt, bibliothèque partagée avec le pilote de PlayTendo.
patch("vita3k/CMakeLists.txt", [
    ("if(NOT ANDROID)\n\tinclude(${CMAKE_SOURCE_DIR}/cmake/qt6.cmake)\n",
     "if(NOT ANDROID AND NOT PLAYTENDO) # PlayTendo : pas d'interface Qt\n"
     "\tinclude(${CMAKE_SOURCE_DIR}/cmake/qt6.cmake)\n"),
    ("if(NOT ANDROID)\n\tadd_subdirectory(gui-qt)\n",
     "if(NOT ANDROID AND NOT PLAYTENDO)\n\tadd_subdirectory(gui-qt)\n"),
    ("if(ANDROID)\n\tadd_library(vita3k SHARED\n",
     "if(PLAYTENDO)\n"
     "\t# PlayTendo : le cœur et le pilote vita/PTVitaHost.cpp + PTVitaView.mm (à la place de main.cpp et de\n"
     "\t# l'interface Qt).\n"
     "\tadd_library(vita3k SHARED interface.cpp performance.cpp ${PLAYTENDO_VITA_HOST} ${PLAYTENDO_VITA_VIEW})\n"
     "\tset_source_files_properties(${PLAYTENDO_VITA_VIEW} PROPERTIES COMPILE_OPTIONS \"-fobjc-arc\")\n"
     "\ttarget_include_directories(vita3k PRIVATE ${CMAKE_CURRENT_SOURCE_DIR} ${PLAYTENDO_INCLUDE})\n"
     "\tif(IOS)\n"
     "\t\tset(PLAYTENDO_UI_FRAMEWORK \"-framework UIKit\")\n"
     "\telse()\n"
     "\t\tset(PLAYTENDO_UI_FRAMEWORK \"-framework AppKit\")\n"
     "\tendif()\n"
     "\ttarget_link_libraries(vita3k PRIVATE SDL3::SDL3 pugixml::pugixml ${PLAYTENDO_UI_FRAMEWORK} \"-framework QuartzCore\"\n"
     "\t\t\"-framework Metal\" \"-framework Foundation\")\n"
     "elseif(ANDROID)\n\tadd_library(vita3k SHARED\n"),
    ("if(NOT ANDROID)\n\ttarget_link_libraries(vita3k PRIVATE gui-qt)\n",
     "if(NOT ANDROID AND NOT PLAYTENDO)\n\ttarget_link_libraries(vita3k PRIVATE gui-qt)\n"),
    ("if(NOT ANDROID)\n\tfile(GLOB VITA3K_QT_TS_FILES CONFIGURE_DEPENDS\n",
     "if(NOT ANDROID AND NOT PLAYTENDO)\n\tfile(GLOB VITA3K_QT_TS_FILES CONFIGURE_DEPENDS\n"),
    ("if(APPLE)\n\tadd_custom_command(\n\t\tOUTPUT Vita3K.icns\n",
     "if(APPLE AND NOT PLAYTENDO) # PlayTendo : paquet de l'app Vita3K pour Mac, inutile ici\n\tadd_custom_command(\n\t\tOUTPUT Vita3K.icns\n"),
])

# 6. Couche Metal : UIKit sur iPhone ; la couche donnée par le pilote est acceptée telle quelle.
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
     "#import <QuartzCore/CAMetalLayer.h>\n#import <TargetConditionals.h>\n"
     "#if TARGET_OS_IPHONE\n"
     "#import <UIKit/UIKit.h>\n"
     "#define PT_PLATFORM_VIEW UIView\n"
     "#else\n"
     "#import <Cocoa/Cocoa.h>\n"
     "#define PT_PLATFORM_VIEW NSView\n"
     "#endif\n\n"
     "// PlayTendo : le pilote (vita/PTVitaView.mm) donne directement sa CAMetalLayer ; une vue (UIView ou NSView, comme\n"
     "// l'interface de Vita3K) donne la sienne.\n"
     "extern \"C\" void *get_metal_layer_from_view(void *view) {\n"
     "    id object = (__bridge id)view;\n"
     "    if ([object isKindOfClass:[CAMetalLayer class]])\n"
     "        return view;\n"
     "    if ([object isKindOfClass:[PT_PLATFORM_VIEW class]])\n"
     "        return (__bridge void *)((PT_PLATFORM_VIEW *)object).layer;\n"
     "    return nullptr;\n"
     "}\n"),
])

# 4. Vulkan : MoltenVK de l'app (le chargeur de vulkan.hpp chercherait une bibliothèque libvulkan absente).
patch("vita3k/renderer/src/vulkan/renderer.cpp", [
    ("#ifdef __APPLE__\n#include <MoltenVK/mvk_vulkan.h>\n#endif\n",
     "#ifdef __APPLE__\n#include <MoltenVK/mvk_vulkan.h>\n#endif\n\n"
     "#ifdef PLAYTENDO\n"
     "// PlayTendo : vkGetInstanceProcAddr du MoltenVK.framework de l'app (vita/PTVitaView.mm).\n"
     "extern \"C\" void *PTVitaVkGetInstanceProcAddr(void);\n"
     "#endif\n"),
    ("#else\n        VULKAN_HPP_DEFAULT_DISPATCHER.init();\n#endif\n",
     "#elif defined(PLAYTENDO)\n"
     "        VULKAN_HPP_DEFAULT_DISPATCHER.init(reinterpret_cast<PFN_vkGetInstanceProcAddr>(PTVitaVkGetInstanceProcAddr()));\n"
     "#else\n        VULKAN_HPP_DEFAULT_DISPATCHER.init();\n#endif\n"),
    ("#else\n        dispatch.init();\n#endif\n",
     "#elif defined(PLAYTENDO)\n"
     "        dispatch.init(reinterpret_cast<PFN_vkGetInstanceProcAddr>(PTVitaVkGetInstanceProcAddr()));\n"
     "#else\n        dispatch.init();\n#endif\n"),
])

# 3, 4 et 5. Dépendances externes.
patch("external/CMakeLists.txt", [
    ("endfunction()\n\ncheck_submodules_present()\n",
     "endfunction()\n\n"
     "# PlayTendo : les sous-modules propres à Android (libadrenotools), à Windows (dirent) et à l'interface PC\n"
     "# (nativefiledialog-extended) ne sont pas téléchargés (scripts/fetch_sources.sh).\n"
     "if(NOT PLAYTENDO)\n\tcheck_submodules_present()\nendif()\n"),
    ("if(NOT ANDROID)\n\t# nativefiledialog-extended\n",
     "if(NOT ANDROID AND NOT PLAYTENDO) # PlayTendo : fenêtres de choix de fichier de l'interface PC seulement\n"
     "\t# nativefiledialog-extended\n"),
    ("if(APPLE)\n\tif(NOT EXISTS \"${CMAKE_BINARY_DIR}/external/MoltenVK-macos.tar\")\n",
     "if(PLAYTENDO)\n"
     "\t# PlayTendo : en-têtes du MoltenVK déjà téléchargé pour la 3DS (sources/MoltenVK pour iPhone,\n"
     "\t# sources/MoltenVK-macos pour Mac) ; l'app a son MoltenVK.framework.\n"
     "\ttarget_include_directories(vulkan INTERFACE \"${PLAYTENDO_MOLTENVK_INCLUDE}\")\n"
     "elseif(APPLE)\n\tif(NOT EXISTS \"${CMAKE_BINARY_DIR}/external/MoltenVK-macos.tar\")\n"),
    ("if(APPLE OR NOT FORCE_BUILD_OPENSSL_MAC)\n\texecute_process(\n\t\tCOMMAND brew --prefix openssl\n",
     "if(PLAYTENDO)\n"
     "\t# PlayTendo : OpenSSL compilé par build_vita3k.sh pour iPhone ou Mac (sans Homebrew ni téléchargement).\n"
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
     "if(NOT FORCE_BUILD_OPENSSL_MAC AND NOT PLAYTENDO)\n\tfind_package(OpenSSL QUIET)\nendif()\n"),
    ("find_package(CURL QUIET)\nif(NOT CURL_FOUND)\n",
     "if(NOT PLAYTENDO)\n\tfind_package(CURL QUIET)\nendif()\n"
     "if(PLAYTENDO)\n"
     "\t# PlayTendo : pas de curl (Vita3K ne s'en sert que pour ses mises à jour et sa liste de\n"
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
     "#ifndef PLAYTENDO\n#include <curl/curl.h>\n#endif\n"),
    ("std::string get_web_response(const std::string &url) {\n    auto curl = curl_easy_init();\n",
     "std::string get_web_response(const std::string &url) {\n"
     "#ifdef PLAYTENDO\n"
     "    return {}; // PlayTendo : rien n'est téléchargé par le moteur\n"
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
     "#ifdef PLAYTENDO\n"
     "// PlayTendo : compteur du son de la partie (vita/PTVitaHost.cpp), noté dans vita3k.log.\n"
     "extern \"C\" void PTVitaAudioQueued(const void *buffer, int bytes, uint64_t microseconds);\n"
     "extern \"C\" void SDLCALL PTVitaAudioPostmix(void *userdata, const SDL_AudioSpec *spec, float *buffer, int buflen);\n"
     "#endif\n"),
    ("    SDL_CHECK_EXT(device_id > 0, false);\n    return true;\n",
     "    SDL_CHECK_EXT(device_id > 0, false);\n"
     "#ifdef PLAYTENDO\n"
     "    SDL_SetAudioPostmixCallback(device_id, PTVitaAudioPostmix, nullptr);\n"
     "#endif\n"
     "    return true;\n"),
    ("    SDL_CHECK_VOID(SDL_PutAudioStreamData(port.stream.get(), buffer, out_port.len_bytes));\n",
     "#ifdef PLAYTENDO\n"
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
     "#ifdef PLAYTENDO\n"
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
     "#ifdef PLAYTENDO\n"
     "    } catch (const vk::SystemError &error) {\n"
     "        LOG_ERROR(\"[PlayTendo] Effet graphique refusé par MoltenVK, sauté : {}\", error.what());\n"
     "        return nullptr;\n"
     "    }\n"
     "#endif\n"),
    ("        *request->pipeline = pipeline;\n",
     "#ifdef PLAYTENDO\n"
     "        // PlayTendo : un pipeline refusé reste marqué « en cours » : sauté, jamais recompilé.\n"
     "        *request->pipeline = pipeline ? pipeline : std::bit_cast<vk::Pipeline, uint64_t>(~0ULL);\n"
     "#else\n"
     "        *request->pipeline = pipeline;\n"
     "#endif\n"),
    ("        it->second = result;\n\n        return result;\n",
     "#ifdef PLAYTENDO\n"
     "        // PlayTendo : un pipeline refusé reste marqué « en cours » : sauté, pas recompilé à chaque image.\n"
     "        it->second = result ? result : pipeline_compiling;\n"
     "#else\n"
     "        it->second = result;\n"
     "#endif\n"
     "\n"
     "        return result;\n"),
    ("    for (auto &[hash, pipeline] : pipelines)\n        state.device.destroy(pipeline);\n",
     "    for (auto &[hash, pipeline] : pipelines)\n"
     "#ifdef PLAYTENDO\n"
     "        // PlayTendo : sans les marqueurs « en cours / refusé » (~0), qui ne sont pas de vrais pipelines.\n"
     "        if (pipeline && pipeline != std::bit_cast<vk::Pipeline, uint64_t>(~0ULL))\n"
     "#endif\n"
     "            state.device.destroy(pipeline);\n"),
])

# 12. Messages de MoltenVK dans vita3k.log.
patch("vita3k/renderer/src/vulkan/renderer.cpp", [
    ("static vk::DebugReportCallbackEXT debug_report;\n",
     "#ifdef PLAYTENDO\n"
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
     "#ifdef PLAYTENDO\n"
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
     "#ifdef PLAYTENDO\n"
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

# 13. Sans émulation du masque (retouche 14 impossible), ses dessins sont sautés (sinon peints dans l'image).
patch("vita3k/renderer/src/vulkan/scene.cpp", [
    ("    Ptr<void> indices, size_t count, uint32_t instance_count, MemState &mem, const Config &config) {\n"
     "    void *indices_ptr = indices.get(mem);\n",
     "    Ptr<void> indices, size_t count, uint32_t instance_count, MemState &mem, const Config &config) {\n"
     "#ifdef PLAYTENDO\n"
     "    // PlayTendo : sans émulation du masque, son dessin peindrait 0 ou 1 dans l'image (menus de Minecraft recouverts\n"
     "    // de noir). Sauté, comme le rendu OpenGL de Vita3K sans tampon de masque.\n"
     "    if (context.record.is_maskupdate && !context.state.features.use_mask_bit) {\n"
     "        LOG_WARN_ONCE(\"[PlayTendo] Dessins du masque sautés (non gérés en Vulkan)\");\n"
     "        return;\n"
     "    }\n"
     "#endif\n"
     "    void *indices_ptr = indices.get(mem);\n"),
])

# 14. Masque de la Vita émulé en Vulkan (voir l'en-tête).
patch("vita3k/renderer/include/renderer/vulkan/types.h", [
    ("    vk::DescriptorSet rendertarget_set;\n",
     "    vk::DescriptorSet rendertarget_set;\n"
     "#ifdef PLAYTENDO\n"
     "    // PlayTendo : masque à remettre à sa valeur de fond au prochain début de passe (nouvelle scène).\n"
     "    bool playtendo_mask_clear = false;\n"
     "    float playtendo_mask_value = 1.0f;\n"
     "#endif\n"),
    ("    vkutil::Image depthstencil;\n",
     "    vkutil::Image depthstencil;\n"
     "#ifdef PLAYTENDO\n"
     "    // PlayTendo : masque de la Vita (1 = visible), lu et écrit par les shaders de pixels.\n"
     "    vkutil::Image mask;\n"
     "#endif\n"),
])
patch("vita3k/renderer/src/vulkan/creation.cpp", [
    ("    depthstencil.init_image(vk::ImageUsageFlagBits::eDepthStencilAttachment | vk::ImageUsageFlagBits::eTransientAttachment);\n",
     "    depthstencil.init_image(vk::ImageUsageFlagBits::eDepthStencilAttachment | vk::ImageUsageFlagBits::eTransientAttachment);\n"
     "#ifdef PLAYTENDO\n"
     "    // PlayTendo : masque de la Vita, à la taille de la profondeur (doublée en MSAA 4x).\n"
     "    if (state.features.use_mask_bit) {\n"
     "        mask = vkutil::Image(depthstencil.width, depthstencil.height, vk::Format::eR8G8B8A8Unorm);\n"
     "        mask.init_image(vk::ImageUsageFlagBits::eStorage | vk::ImageUsageFlagBits::eTransferDst);\n"
     "    }\n"
     "#endif\n"),
    ("    depthstencil.transition_to_discard(cmd_buffer, vkutil::ImageLayout::DepthStencilAttachment, vkutil::ds_subresource_range);\n",
     "    depthstencil.transition_to_discard(cmd_buffer, vkutil::ImageLayout::DepthStencilAttachment, vkutil::ds_subresource_range);\n"
     "#ifdef PLAYTENDO\n"
     "    if (mask.image) {\n"
     "        // tout visible au départ\n"
     "        mask.transition_to_discard(cmd_buffer, vkutil::ImageLayout::TransferDst);\n"
     "        const vk::ClearColorValue mask_visible{ std::array<float, 4>({ 1.0f, 1.0f, 1.0f, 1.0f }) };\n"
     "        cmd_buffer.clearColorImage(mask.image, vk::ImageLayout::eTransferDstOptimal, mask_visible, vkutil::color_subresource_range);\n"
     "        mask.transition_to(cmd_buffer, vkutil::ImageLayout::StorageImage);\n"
     "    }\n"
     "#endif\n"),
    ("    frame.destroy_queue.add_image(render_target.depthstencil);\n",
     "    frame.destroy_queue.add_image(render_target.depthstencil);\n"
     "#ifdef PLAYTENDO\n"
     "    if (render_target.mask.image)\n"
     "        frame.destroy_queue.add_image(render_target.mask);\n"
     "#endif\n"),
])
patch("vita3k/renderer/src/vulkan/context.cpp", [
    ("    context.render_target = rt;\n",
     "    context.render_target = rt;\n"
     "#ifdef PLAYTENDO\n"
     "    // PlayTendo : nouvelle scène → masque remis à la valeur de fond de la surface de profondeur (comme\n"
     "    // gl::sync_mask) ; « tout visible » sans surface de profondeur (valeur alors non fiable).\n"
     "    {\n"
     "        const auto &ds_surface = context.record.depth_stencil_surface;\n"
     "        const bool has_ds = ds_surface.depth_data.address() != 0 || ds_surface.stencil_data.address() != 0;\n"
     "        context.playtendo_mask_clear = true;\n"
     "        context.playtendo_mask_value = (!has_ds || ds_surface.mask) ? 1.0f : 0.0f;\n"
     "    }\n"
     "#endif\n"),
    ("    descriptor_pool_info.setPoolSizes(pool_size);\n",
     "#ifdef PLAYTENDO\n"
     "    // PlayTendo : plus une image de stockage par jeu de descripteurs pour le masque.\n"
     "    const std::array<vk::DescriptorPoolSize, 2> pool_sizes = { pool_size,\n"
     "        vk::DescriptorPoolSize{ .type = vk::DescriptorType::eStorageImage, .descriptorCount = DESCRIPTOR_PACK_SIZE * MAX_FRAMES_RENDERING } };\n"
     "    descriptor_pool_info.setPoolSizes(pool_sizes);\n"
     "#else\n"
     "    descriptor_pool_info.setPoolSizes(pool_size);\n"
     "#endif\n"),
    ("    render_cmd.beginRenderPass(curr_renderpass_info, vk::SubpassContents::eInline);\n",
     "#ifdef PLAYTENDO\n"
     "    // PlayTendo : remise du masque, hors passe de rendu, au premier début de passe de la scène.\n"
     "    if (playtendo_mask_clear && render_target->mask.image) {\n"
     "        playtendo_mask_clear = false;\n"
     "        const float v = playtendo_mask_value;\n"
     "        const vk::ClearColorValue mask_clear{ std::array<float, 4>({ v, v, v, v }) };\n"
     "        render_target->mask.transition_to(render_cmd, vkutil::ImageLayout::TransferDst);\n"
     "        render_cmd.clearColorImage(render_target->mask.image, vk::ImageLayout::eTransferDstOptimal, mask_clear, vkutil::color_subresource_range);\n"
     "        render_target->mask.transition_to(render_cmd, vkutil::ImageLayout::StorageImage);\n"
     "    }\n"
     "#endif\n"
     "    render_cmd.beginRenderPass(curr_renderpass_info, vk::SubpassContents::eInline);\n"),
    ("    write_descr.setImageInfo(descr_color_info);\n    state.device.updateDescriptorSets(write_descr, {});\n}\n",
     "    write_descr.setImageInfo(descr_color_info);\n"
     "    state.device.updateDescriptorSets(write_descr, {});\n"
     "#ifdef PLAYTENDO\n"
     "    // PlayTendo : masque de la cible de rendu (set 1, binding 1).\n"
     "    if (state.features.use_mask_bit && render_target->mask.view) {\n"
     "        vk::DescriptorImageInfo descr_mask_info{\n"
     "            .sampler = nullptr,\n"
     "            .imageView = render_target->mask.view,\n"
     "            .imageLayout = vk::ImageLayout::eGeneral,\n"
     "        };\n"
     "        vk::WriteDescriptorSet write_mask{\n"
     "            .dstSet = rendertarget_set,\n"
     "            .dstBinding = 1,\n"
     "            .dstArrayElement = 0,\n"
     "            .descriptorType = vk::DescriptorType::eStorageImage,\n"
     "        };\n"
     "        write_mask.setImageInfo(descr_mask_info);\n"
     "        state.device.updateDescriptorSets(write_mask, {});\n"
     "    }\n"
     "#endif\n"
     "}\n"),
])
patch("vita3k/renderer/src/vulkan/pipeline_cache.cpp", [
    ("    if (maskupdate)\n        LOG_WARN_ONCE(\"Mask not implemented in the vulkan renderer!\");\n",
     "    if (maskupdate && !state.features.use_mask_bit) // PlayTendo : émulé si use_mask_bit\n"
     "        LOG_WARN_ONCE(\"Mask not implemented in the vulkan renderer!\");\n"),
    ("    const vk::PipelineShaderStageCreateInfo vertex_shader = retrieve_shader(vertex_program_gxm.program.get(mem), vertex_program.hash, true, fragment_program_gxm.is_maskupdate, mem, hints);\n",
     "#ifdef PLAYTENDO\n"
     "    // PlayTendo : le shader de sommets d'un dessin de masque est un shader ordinaire. Compilé « en mode masque », il\n"
     "    // n'écrivait aucune position et restait en cache sous l'identifiant du programme, cassant les autres dessins.\n"
     "    const vk::PipelineShaderStageCreateInfo vertex_shader = retrieve_shader(vertex_program_gxm.program.get(mem), vertex_program.hash, true, false, mem, hints);\n"
     "#else\n"
     "    const vk::PipelineShaderStageCreateInfo vertex_shader = retrieve_shader(vertex_program_gxm.program.get(mem), vertex_program.hash, true, fragment_program_gxm.is_maskupdate, mem, hints);\n"
     "#endif\n"),
    ("    const vk::PipelineDepthStencilStateCreateInfo ds_info{\n",
     "    // PlayTendo : modifiable pour les dessins du masque\n"
     "    vk::PipelineDepthStencilStateCreateInfo ds_info{\n"),
    ("        .back = convert_op_state(two_sided ? record.back_stencil_state_op : record.front_stencil_state_op)\n    };\n",
     "        .back = convert_op_state(two_sided ? record.back_stencil_state_op : record.front_stencil_state_op)\n"
     "    };\n"
     "#ifdef PLAYTENDO\n"
     "    // PlayTendo : un dessin du masque n'écrit que le masque, sans tests de profondeur ni de stencil (gl/draw.cpp).\n"
     "    const bool playtendo_mask_draw = fragment_program_gxm.is_maskupdate && state.features.use_mask_bit;\n"
     "    if (playtendo_mask_draw) {\n"
     "        ds_info.depthTestEnable = VK_FALSE;\n"
     "        ds_info.depthWriteEnable = VK_FALSE;\n"
     "        ds_info.stencilTestEnable = VK_FALSE;\n"
     "    }\n"
     "#endif\n"),
    ("    if (is_fragment_disabled || frag_has_no_output || use_shader_interlock) {\n",
     "#ifdef PLAYTENDO\n"
     "    if (is_fragment_disabled || frag_has_no_output || use_shader_interlock || playtendo_mask_draw) {\n"
     "#else\n"
     "    if (is_fragment_disabled || frag_has_no_output || use_shader_interlock) {\n"
     "#endif\n"),
])
patch("vita3k/shader/src/spirv_recompiler.cpp", [
    ("    b.createStore(mask_v, out);\n}\n",
     "    b.createStore(mask_v, out);\n"
     "#ifdef PLAYTENDO\n"
     "    // PlayTendo : en Vulkan, la valeur va dans l'image du masque (set 1, binding 1) au pixel courant ; la couleur\n"
     "    // n'est pas écrite (pipeline sans écriture de couleur).\n"
     "    if (translate_state.is_vulkan && translate_state.mask_id != spv::NoResult && translate_state.frag_coord_id != spv::NoResult) {\n"
     "        const spv::Id i32 = b.makeIntegerType(32, true);\n"
     "        spv::Id coord = b.createUnaryOp(spv::OpConvertFToS, b.makeVectorType(i32, 4), b.createLoad(translate_state.frag_coord_id, spv::NoPrecision));\n"
     "        coord = b.createOp(spv::OpVectorShuffle, b.makeVectorType(i32, 2), { { true, coord }, { true, coord }, { false, 0 }, { false, 1 } });\n"
     "        b.createNoResultOp(spv::OpImageWrite, { b.createLoad(translate_state.mask_id, spv::NoPrecision), coord, mask_v });\n"
     "    }\n"
     "#endif\n"
     "}\n"),
    ("    std::vector<spv::Id> empty_args;\n",
     "    std::vector<spv::Id> empty_args;\n"
     "#ifdef PLAYTENDO\n"
     "    bool playtendo_mask_interlock = false;\n"
     "#endif\n"),
    ("            b.createNoResultOp(spv::OpBeginInvocationInterlockEXT);\n        }\n    }\n\n    // Generate parameters\n",
     "            b.createNoResultOp(spv::OpBeginInvocationInterlockEXT);\n"
     "        }\n"
     "#ifdef PLAYTENDO\n"
     "        // PlayTendo : masque en Vulkan, lu (tous les shaders de pixels) ou écrit (dessins du masque) dans l'ordre de\n"
     "        // rastérisation : verrou sur tout le shader (raster order groups de Metal, par MoltenVK).\n"
     "        else if (translation_state.is_vulkan && features.use_mask_bit) {\n"
     "            playtendo_mask_interlock = true;\n"
     "            b.addExecutionMode(spv_func_main, spv::ExecutionModeSampleInterlockOrderedEXT);\n"
     "            b.addExtension(\"SPV_EXT_fragment_shader_interlock\");\n"
     "            b.addCapability(spv::CapabilityFragmentShaderSampleInterlockEXT);\n"
     "            b.createNoResultOp(spv::OpBeginInvocationInterlockEXT);\n"
     "        }\n"
     "#endif\n"
     "    }\n"
     "\n"
     "    // Generate parameters\n"),
    ("        generate_update_mask_body(b, translation_state);\n    }\n    b.leaveFunction();\n",
     "        generate_update_mask_body(b, translation_state);\n"
     "    }\n"
     "#ifdef PLAYTENDO\n"
     "    if (playtendo_mask_interlock)\n"
     "        b.createNoResultOp(spv::OpEndInvocationInterlockEXT);\n"
     "#endif\n"
     "    b.leaveFunction();\n"),
])
patch("vita3k/renderer/src/vulkan/renderer.cpp", [
    ("    bool use_high_accuracy = cfg.current_config.high_accuracy;\n",
     "    bool use_high_accuracy = cfg.current_config.high_accuracy;\n"
     "#ifdef PLAYTENDO\n"
     "    // PlayTendo : masque de la Vita émulé si l'appareil a le shader interlock (lu ici avant d'être coupé en précision\n"
     "    // normale ; l'état du rendu est recréé à chaque lancement).\n"
     "    features.use_mask_bit = features.support_shader_interlock;\n"
     "    LOG_INFO(\"[PlayTendo] Masque de la Vita : {}\", features.use_mask_bit ? \"émulé\" : \"non géré (pas de shader interlock)\");\n"
     "#endif\n"),
    ("            bool use_scaled_attributes : 1;\n",
     "            bool use_scaled_attributes : 1;\n"
     "            bool use_mask_bit : 1; // PlayTendo\n"),
    ("    features_mask.use_scaled_attributes = pipeline_cache.support_scaled_vertex_attribute;\n",
     "    features_mask.use_scaled_attributes = pipeline_cache.support_scaled_vertex_attribute;\n"
     "    features_mask.use_mask_bit = features.use_mask_bit; // PlayTendo : shaders refaits quand le masque change\n"),
])

# 15. Mémoire mappée gardée sur Apple ; sommets et indices mal alignés pour Metal copiés à part.
patch("vita3k/renderer/src/vulkan/renderer.cpp", [
    ("#ifdef __APPLE__\n        // we need to make a copy of the vertex buffer for moltenvk, so disable memory mapping\n"
     "        support_memory_mapping = false;\n#endif\n",
     "#if defined(__APPLE__) && !defined(PLAYTENDO)\n"
     "        // we need to make a copy of the vertex buffer for moltenvk, so disable memory mapping\n"
     "        support_memory_mapping = false;\n"
     "#endif\n"
     "#ifdef PLAYTENDO\n"
     "        // PlayTendo : mémoire mappée gardée (sans elle, pas de synchro des surfaces) ; seuls les sommets et indices\n"
     "        // mal alignés pour Metal sont copiés à part (scene.cpp).\n"
     "        LOG_INFO(\"[PlayTendo] Mémoire mappée possible : {} (adresses de tampons {}, disposition standard {})\",\n"
     "            support_memory_mapping, support_buffer_device_address, support_standard_layout);\n"
     "#endif\n"),
])
patch("vita3k/renderer/src/vulkan/creation.cpp", [
    ("        std::fill_n(vertex_stream_buffers, SCE_GXM_MAX_VERTEX_STREAMS, state.default_buffer.buffer);\n",
     "        std::fill_n(vertex_stream_buffers, SCE_GXM_MAX_VERTEX_STREAMS, state.default_buffer.buffer);\n"
     "#ifdef PLAYTENDO\n"
     "        // PlayTendo : copies des sommets et indices mal alignés pour Metal (scene.cpp).\n"
     "        vertex_stream_ring_buffer.create();\n"
     "        index_stream_ring_buffer.create();\n"
     "#endif\n"),
])
patch("vita3k/renderer/src/vulkan/scene.cpp", [
    ("            if (context.state.features.enable_memory_mapping) {\n"
     "                auto [buffer, offset] = context.state.get_matching_mapping(state.vertex_streams[i].data.cast<void>());\n",
     "#ifdef PLAYTENDO\n"
     "            // PlayTendo : Metal veut un pas et un début de flux multiples de 4 ; sinon copie réalignée, comme sans\n"
     "            // mémoire mappée.\n"
     "            const bool playtendo_aligned = vertex_program.streams[i].stride % 4 == 0 && state.vertex_streams[i].data.address() % 4 == 0;\n"
     "            if (context.state.features.enable_memory_mapping && !playtendo_aligned) {\n"
     "                LOG_INFO_ONCE(\"[PlayTendo] Sommets mal alignés pour Metal copiés à part (pas {}, adresse {})\",\n"
     "                    vertex_program.streams[i].stride, log_hex(state.vertex_streams[i].data.address()));\n"
     "                context.vertex_stream_buffers[i] = context.vertex_stream_ring_buffer.handle();\n"
     "            }\n"
     "            if (context.state.features.enable_memory_mapping && playtendo_aligned) {\n"
     "#else\n"
     "            if (context.state.features.enable_memory_mapping) {\n"
     "#endif\n"
     "                auto [buffer, offset] = context.state.get_matching_mapping(state.vertex_streams[i].data.cast<void>());\n"),
    ("    uint32_t max_index = 0;\n    if (use_memory_mapping) {\n",
     "    uint32_t max_index = 0;\n"
     "#ifdef PLAYTENDO\n"
     "    // PlayTendo : indices au début non multiple de 4 copiés à part pour Metal ; leur plus grand indice (taille des\n"
     "    // flux de sommets) est alors calculé ici.\n"
     "    const bool playtendo_copy_indices = use_memory_mapping && (indices.address() % 4) != 0;\n"
     "    if (playtendo_copy_indices && count > 0) {\n"
     "        LOG_INFO_ONCE(\"[PlayTendo] Indices mal alignés pour Metal copiés à part (adresse {})\", log_hex(indices.address()));\n"
     "        if (format == SCE_GXM_INDEX_FORMAT_U16) {\n"
     "            const uint16_t *data = static_cast<const uint16_t *>(indices_ptr);\n"
     "            max_index = *std::max_element(data, data + count);\n"
     "        } else {\n"
     "            const uint32_t *data = static_cast<const uint32_t *>(indices_ptr);\n"
     "            max_index = *std::max_element(data, data + count);\n"
     "        }\n"
     "    }\n"
     "    if (use_memory_mapping && !playtendo_copy_indices) {\n"
     "#else\n"
     "    if (use_memory_mapping) {\n"
     "#endif\n"),
])

# 16. rePatch (mods pour le plugin rePatch d'une Vita modifiée, 2026-10-13) : un fichier du jeu peut manquer dans
# app/<identifiant> s'il est fourni par rePatch/<identifiant> (AKIBA'S TRIP « Uncensored » : volume.dat retiré de app/,
# remplacé par sa version modifiée, déjà déchiffrée). psvpfsparser exige chaque fichier de la table (files.db) à trois
# étapes : liaison des fichiers, correspondance table de contrôle ↔ fichier, déchiffrement. Le pilote répond à
# PTVitaRePatchProvides (vita/PTVitaHost.cpp) ; le fichier manquant est sauté aux trois étapes (autant de tables
# sans correspondance que de fichiers sautés) et compté au contrôle final du nombre de fichiers, puis l'app copie les
# fichiers de rePatch sur le jeu installé.
patch("external/psvpfstools/psvpfsparser/FilesDbParser.cpp", [
    ("bool is_valid_file_type(sce_ng_pfs_file_types type)\n",
     "// PlayTendo : fichier fourni par le dossier rePatch du jeu (réponse du pilote ; absent hors de PlayTendo).\n"
     "extern \"C\" bool PTVitaRePatchProvides(const char *path) __attribute__((weak));\n"
     "// PlayTendo : nombre de fichiers sautés par la dernière liaison (lu par PfsPageMapper et PfsFilesystem).\n"
     "int g_playtendoRePatchSkipped = 0;\n"
     "\n"
     "bool is_valid_file_type(sce_ng_pfs_file_types type)\n"),
    ("   m_output << \"Linking file paths...\" << std::endl;\n",
     "   m_output << \"Linking file paths...\" << std::endl;\n"
     "   g_playtendoRePatchSkipped = 0;\n"),
    ("      auto it = real_files_map.find(path);\n"
     "      if(it == real_files_map.end())\n"
     "      {\n"
     "         m_output << \"File \" << file.path() << \" does not exist\" << std::endl;\n"
     "         return false;\n"
     "      }\n",
     "      auto it = real_files_map.find(path);\n"
     "      if(it == real_files_map.end())\n"
     "      {\n"
     "         // PlayTendo : remplacé par rePatch, sauté.\n"
     "         if(PTVitaRePatchProvides && PTVitaRePatchProvides(file.path().get_value().string().c_str()))\n"
     "         {\n"
     "            m_output << \"File \" << file.path() << \" is provided by rePatch (skipped)\" << std::endl;\n"
     "            g_playtendoRePatchSkipped++;\n"
     "            continue;\n"
     "         }\n"
     "         m_output << \"File \" << file.path() << \" does not exist\" << std::endl;\n"
     "         return false;\n"
     "      }\n"),
    # Compte final : les fichiers sautés manquent forcément parmi les fichiers présents.
    ("   size_t expectedSize = files.size() + directories.size() - numExtra; // allow extra files to exist\n",
     "   size_t expectedSize = files.size() + directories.size() - numExtra; // allow extra files to exist\n"
     "   expectedSize += g_playtendoRePatchSkipped; // PlayTendo : fichiers fournis par rePatch, absents\n"),
])
patch("external/psvpfstools/psvpfsparser/PfsPageMapper.cpp", [
    ("#include \"PfsPageMapper.h\"\n",
     "#include \"PfsPageMapper.h\"\n\n"
     "// PlayTendo : fichiers sautés car fournis par rePatch (FilesDbParser.cpp).\n"
     "extern int g_playtendoRePatchSkipped;\n"),
    ("   std::vector<std::pair<std::shared_ptr<sce_iftbl_base_t>, std::shared_ptr<merkle_tree<icv> > > > merkleTrees;\n",
     "   std::vector<std::pair<std::shared_ptr<sce_iftbl_base_t>, std::shared_ptr<merkle_tree<icv> > > > merkleTrees;\n"
     "   int playtendoUnmatched = 0; // PlayTendo : tables des fichiers sautés (rePatch)\n"),
    ("         else\n"
     "         {\n"
     "            m_output << \"Match not found: \" << std::hex << t->get_icv_salt() << std::endl;\n"
     "            return -1;\n"
     "         }\n",
     "         else if(playtendoUnmatched < g_playtendoRePatchSkipped)\n"
     "         {\n"
     "            // PlayTendo : table d'un fichier fourni par rePatch, absent du jeu.\n"
     "            playtendoUnmatched++;\n"
     "            m_output << \"Match not found: \" << std::hex << t->get_icv_salt() << \" (file provided by rePatch)\" << std::endl;\n"
     "         }\n"
     "         else\n"
     "         {\n"
     "            m_output << \"Match not found: \" << std::hex << t->get_icv_salt() << std::endl;\n"
     "            return -1;\n"
     "         }\n"),
])
patch("external/psvpfstools/psvpfsparser/PfsFilesystem.cpp", [
    ("static void to_uppercase(std::string &str) {\n",
     "// PlayTendo : fichiers sautés car fournis par rePatch (FilesDbParser.cpp).\n"
     "extern int g_playtendoRePatchSkipped;\n\n"
     "static void to_uppercase(std::string &str) {\n"),
    ("   std::uint64_t processed_bytes = 0;\n",
     "   std::uint64_t processed_bytes = 0;\n"
     "   int playtendoSkipped = 0; // PlayTendo : tables des fichiers fournis par rePatch\n"),
    ("      if(map_entry == pageMap.end())\n"
     "      {\n"
     "         m_output << \"failed to find page \" << t->get_icv_salt() << \" in map\" << std::endl;\n"
     "         return -1;\n"
     "      }\n",
     "      if(map_entry == pageMap.end())\n"
     "      {\n"
     "         if(playtendoSkipped < g_playtendoRePatchSkipped)\n"
     "         {\n"
     "            playtendoSkipped++; // PlayTendo : fichier fourni par rePatch, rien à déchiffrer\n"
     "            continue;\n"
     "         }\n"
     "         m_output << \"failed to find page \" << t->get_icv_salt() << \" in map\" << std::endl;\n"
     "         return -1;\n"
     "      }\n"),
])


# 17. Installation d'un .vpk : pas d'écriture hors du dossier du jeu (« zip slip »).
patch("vita3k/interface.cpp", [
    ("""            std::string replace_filename = m_filename.substr(content_path.size());
            const fs::path file_output = (output_path / fs_utils::utf8_to_path(replace_filename)).generic_path();""",
     """            std::string replace_filename = m_filename.substr(content_path.size());
            // PlayTendo : une entrée dont le nom remonte (« ../ ») ou est absolu sortirait du dossier du jeu.
            const fs::path relative_output = fs_utils::utf8_to_path(replace_filename).lexically_normal();
            if (relative_output.empty() || relative_output.is_absolute() || relative_output.has_root_name()
                || relative_output.has_root_directory() || *relative_output.begin() == "..") {
                LOG_WARN("PlayTendo : entrée d'archive ignorée (chemin hors du jeu) : {}", m_filename);
                continue;
            }
            const fs::path file_output = (output_path / relative_output).generic_path();"""),
])
