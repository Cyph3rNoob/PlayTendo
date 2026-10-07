#!/usr/bin/env python3
"""Retouches d'Azahar 2126.1.2 (moteur 3DS, libretro) pour PlayTendo. Appelé par build_azahar.sh ; une retouche déjà
faite est sautée : relancer le script ne change rien.

Turbo (JIT) : sur iPhone avec iOS 26 (puce A15 : « TXM »), une app ne peut plus rendre exécutable sa propre mémoire
(mprotect) ; seule la réserve JIT préparée par l'app en un passage de StikDebug (PTJIT.m, partagée par toutes les
consoles) peut exécuter du code. Elle est vue deux fois : une adresse pour écrire, une autre pour exécuter.
1. oaknut (code_block.hpp) : sur iPhone, le bloc de code vient de cette réserve (PTJITAlloc/PTJITFree, trouvées par
   dlsym dans l'app) quand elle est prête ; `wptr()` donne l'adresse d'écriture, `ptr()` celle d'exécution.
2. dynarmic (recompilateur ARM) : écrit par `wptr()` (il gère déjà deux adresses séparées).
3. dynarmic (verrou ARM64) : créé au premier usage plutôt qu'au chargement du moteur (la réserve n'est peut-être
   pas encore prête à ce moment-là).
4. JIT des shaders : copie le code par l'adresse d'écriture.
5. arm_dynarmic.cpp : 32 Mo de code par cœur au lieu de 128 (jusqu'à 4 cœurs en mode New 3DS).
"""
import os
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "sources", "azahar")


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


patch("externals/oaknut/include/oaknut/code_block.hpp", [
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

patch("externals/dynarmic/src/dynarmic/backend/arm64/address_space.cpp", [
    ("        , code(mem.ptr(), mem.ptr())\n", "        , code(mem.wptr(), mem.ptr())\n"),
    ("        CodeGenerator c{mem.ptr(), mem.ptr()};\n", "        CodeGenerator c{mem.wptr(), mem.ptr()};\n", 2),
])

patch("externals/dynarmic/src/dynarmic/common/spin_lock_arm64.cpp", [
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

patch("src/video_core/shader/shader_jit_a64_compiler.cpp", [
    ("    std::memcpy(code_mem->ptr(), code_vec.data(), code_vec.size() * sizeof(u32));\n",
     "    std::memcpy(code_mem->wptr(), code_vec.data(), code_vec.size() * sizeof(u32)); // PlayTendo : écriture\n"),
])

patch("src/core/arm/dynarmic/arm_dynarmic.cpp", [
    ("    config.define_unpredictable_behaviour = true;\n",
     "    config.define_unpredictable_behaviour = true;\n"
     "#if defined(IOS)\n"
     "    // PlayTendo : 32 Mo de code par cœur (128 par défaut), pris dans la réserve JIT partagée de l'app.\n"
     "    config.code_cache_size = 32 * 1024 * 1024;\n"
     "#endif\n"),
])
