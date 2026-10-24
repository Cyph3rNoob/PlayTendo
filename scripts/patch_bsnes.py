#!/usr/bin/env python3
"""bsnes v115 (libretro) : la mémoire de travail de la Super Nintendo (WRAM, 128 Ko) est rendue visible par
retro_get_memory_data(RETRO_MEMORY_SYSTEM_RAM), où RetroAchievements lit les succès. La version d'origine ne donne
aucune mémoire (nullptr), ce qui rendait les succès impossibles. La mémoire de sauvegarde reste gérée par bsnes.

libretro.cpp ne voit pas l'intérieur de la console (SuperFamicom::cpu) : une petite fonction est ajoutée à la fin de
sfc/cpu/cpu.cpp, et libretro.cpp l'appelle.

Usage : python3 scripts/patch_bsnes.py <sources/bsnes/bsnes>  (sans effet si déjà fait)
"""
import pathlib
import sys

ROOT = pathlib.Path(sys.argv[1])

CPU_ADD = """
// PlayTendo : mémoire de travail (WRAM) pour RetroAchievements, lue par target-libretro.
auto playtendoWorkRAM() -> unsigned char* { return SuperFamicom::cpu.wram; }
auto playtendoWorkRAMSize() -> unsigned long { return sizeof(SuperFamicom::cpu.wram); }
"""

OLD = """RETRO_API void *retro_get_memory_data(unsigned id)
{
	return nullptr;
}

RETRO_API size_t retro_get_memory_size(unsigned id)
{
	return 0;
}"""

NEW = """// PlayTendo : mémoire de travail pour RetroAchievements (sfc/cpu/cpu.cpp).
auto playtendoWorkRAM() -> unsigned char*;
auto playtendoWorkRAMSize() -> unsigned long;

RETRO_API void *retro_get_memory_data(unsigned id)
{
	if (id == RETRO_MEMORY_SYSTEM_RAM)
		return playtendoWorkRAM();
	return nullptr;
}

RETRO_API size_t retro_get_memory_size(unsigned id)
{
	if (id == RETRO_MEMORY_SYSTEM_RAM)
		return playtendoWorkRAMSize();
	return 0;
}"""

# Première version de cette retouche (appel direct de SuperFamicom::cpu, impossible depuis libretro.cpp).
FIRST = """RETRO_API void *retro_get_memory_data(unsigned id)
{
	// PlayTendo : mémoire de travail pour RetroAchievements.
	if (id == RETRO_MEMORY_SYSTEM_RAM)
		return SuperFamicom::cpu.wram;
	return nullptr;
}

RETRO_API size_t retro_get_memory_size(unsigned id)
{
	if (id == RETRO_MEMORY_SYSTEM_RAM)
		return sizeof(SuperFamicom::cpu.wram);
	return 0;
}"""

cpu = ROOT / "sfc" / "cpu" / "cpu.cpp"
text = cpu.read_text(encoding="utf-8")
if "playtendoWorkRAM" not in text:
    cpu.write_text(text.rstrip("\n") + "\n" + CPU_ADD, encoding="utf-8")

front = ROOT / "target-libretro" / "libretro.cpp"
text = front.read_text(encoding="utf-8")
if NEW in text:
    print("bsnes : mémoire de travail déjà visible")
else:
    for old in (OLD, FIRST):
        if text.count(old) == 1:
            front.write_text(text.replace(old, NEW), encoding="utf-8")
            print("bsnes : mémoire de travail rendue visible (RetroAchievements)")
            break
    else:
        raise SystemExit("bsnes : retouche impossible (libretro.cpp a changé)")
