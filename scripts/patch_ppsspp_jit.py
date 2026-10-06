#!/usr/bin/env python3
"""Branche le JIT de PPSSPP sur la réserve de mémoire préparée par PlayTendo (iOS 26, puces A15 et
plus récentes avec TXM).

Sur ces iPhone, une page ne devient exécutable que si un débogueur l'a « préparée ». PPSSPP, lui,
bascule ses pages entre écriture et exécution avec mprotect, ce que TXM refuse. PlayTendo prépare
donc au lancement une grande zone avec StikJIT, et la présente sous deux vues de la même mémoire :
une pour écrire le code généré, l'autre pour l'exécuter. PPSSPP sait déjà travailler ainsi (c'est
sa méthode sur Switch) : il suffit que chaque bloc de code y prenne sa place.

L'app exporte PTJITIsActive, PTJITAlloc et PTJITFree (Emulation/PTJIT.c), retrouvées ici par dlsym.
Sans réserve active, rien ne change (W^X par mprotect, comme avant).

  patch_ppsspp_jit.py <dossier source de PPSSPP>

Sans effet si les fichiers sont déjà corrigés.
"""
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
MARK = "PlayTendo"


def patch(relative, edits):
    path = root / relative
    text = path.read_text()
    if MARK in text:
        print(f"déjà corrigé : {relative}")
        return
    for anchor, replacement in edits:
        if text.count(anchor) != 1:
            sys.exit(f"repère introuvable ou multiple dans {relative} :\n{anchor}")
        text = text.replace(anchor, replacement)
    path.write_text(text)
    print(f"corrigé : {relative}")


patch("Common/MemoryUtil.h", [(
    "bool PlatformIsWXExclusive();\n",
    """bool PlatformIsWXExclusive();

#if defined(__APPLE__)
// PlayTendo : réserve JIT préparée par l'app (deux vues de la même mémoire : exécution et écriture).
bool PlayTendoJITActive();
bool PlayTendoJITAlloc(size_t size, uint8_t **executable, uint8_t **writable);
void PlayTendoJITFree(uint8_t *writable);
#endif
""")])

patch("Common/MemoryUtil.cpp", [
    ("bool PlatformIsWXExclusive() {\n",
     """#if PPSSPP_PLATFORM(IOS)
#include <dlfcn.h>

// PlayTendo : fonctions exportées par l'app hôte, absentes ailleurs (dlsym renvoie alors NULL).
namespace {
typedef bool (*PTJITIsActiveFn)();
typedef void *(*PTJITAllocFn)(size_t, void **);
typedef void (*PTJITFreeFn)(void *);

template <typename F> F PlayTendoSymbol(const char *name) {
	return reinterpret_cast<F>(dlsym(RTLD_DEFAULT, name));
}
}  // namespace

bool PlayTendoJITActive() {
	static PTJITIsActiveFn active = PlayTendoSymbol<PTJITIsActiveFn>("PTJITIsActive");
	return active && active();
}

bool PlayTendoJITAlloc(size_t size, uint8_t **executable, uint8_t **writable) {
	static PTJITAllocFn alloc = PlayTendoSymbol<PTJITAllocFn>("PTJITAlloc");
	if (!alloc || !PlayTendoJITActive())
		return false;
	void *rx = nullptr;
	void *rw = alloc(size, &rx);
	if (!rw)
		return false;
	*executable = (uint8_t *)rx;
	*writable = (uint8_t *)rw;
	return true;
}

void PlayTendoJITFree(uint8_t *writable) {
	static PTJITFreeFn release = PlayTendoSymbol<PTJITFreeFn>("PTJITFree");
	if (release)
		release(writable);
}
#elif defined(__APPLE__)
bool PlayTendoJITActive() { return false; }
bool PlayTendoJITAlloc(size_t, uint8_t **, uint8_t **) { return false; }
void PlayTendoJITFree(uint8_t *) {}
#endif

bool PlatformIsWXExclusive() {
"""),
    ("#if PPSSPP_PLATFORM(IOS) || PPSSPP_PLATFORM(UWP) || defined(__OpenBSD__)\n\treturn true;\n",
     """#if PPSSPP_PLATFORM(IOS)
	// PlayTendo : avec la réserve à deux vues, le code s'écrit d'un côté et s'exécute de l'autre.
	return !PlayTendoJITActive();
#elif PPSSPP_PLATFORM(UWP) || defined(__OpenBSD__)
	return true;
"""),
])

patch("Common/CodeBlock.h", [
    ("""		// The protection will be set to RW if PlatformIsWXExclusive.
		region = (u8 *)AllocateExecutableMemory(region_size);
		writableRegion = region;
""",
     """#if PPSSPP_PLATFORM(IOS)
		// PlayTendo : réserve JIT préparée par l'app (seule mémoire exécutable sous TXM).
		if (PlayTendoJITActive()) {
			fromPlayTendoPool_ = PlayTendoJITAlloc(region_size, &region, &writableRegion);
			if (!fromPlayTendoPool_)
				ERROR_LOG(Log::JIT, "PlayTendo: JIT pool exhausted (%d bytes requested)", size);
			T::SetCodePointer(region, writableRegion);
			return;
		}
#endif
		// The protection will be set to RW if PlatformIsWXExclusive.
		region = (u8 *)AllocateExecutableMemory(region_size);
		writableRegion = region;
"""),
    ("""	void FreeCodeSpace() {
#if !PPSSPP_PLATFORM(SWITCH)
""",
     """	void FreeCodeSpace() {
#if PPSSPP_PLATFORM(IOS)
		if (fromPlayTendoPool_) {
			PlayTendoJITFree(writableRegion);
			fromPlayTendoPool_ = false;
			region = nullptr;
			writableRegion = nullptr;
			region_size = 0;
			return;
		}
#endif
#if !PPSSPP_PLATFORM(SWITCH)
"""),
    ("""	uint8_t *writableRegion = nullptr;
	size_t writeEstimated_ = 0;
""",
     """	uint8_t *writableRegion = nullptr;
	size_t writeEstimated_ = 0;
	// PlayTendo : bloc pris dans la réserve JIT de l'app.
	bool fromPlayTendoPool_ = false;
"""),
])
