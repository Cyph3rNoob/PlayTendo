#!/usr/bin/env python3
"""Appuie sur chaque bouton de chaque console (via le banc d'essai) et vérifie
que le mini-jeu affiche la couleur prévue pour ce bouton."""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "scripts", "test"))
HARNESS = os.path.join(ROOT, "build", "test", "harness")
CORES = os.path.join(ROOT, "cores", "macos")
ROMS = os.path.join(ROOT, "build", "test", "roms")

COLORS = {
    "bleu": (0, 0, 255), "rouge": (255, 0, 0), "vert": (0, 255, 0), "jaune": (255, 255, 0),
    "cyan": (0, 255, 255), "orange": (255, 128, 0), "violet": (128, 0, 128),
    "rouge foncé": (128, 0, 0), "violet foncé": (64, 0, 64), "blanc": (255, 255, 255),
    "gris": (128, 128, 128), "rose": (255, 128, 192), "marron": (128, 64, 32),
    "vert foncé": (0, 96, 0), "bleu clair": (96, 160, 255), "noir": (0, 0, 0),
    "olive": (128, 128, 0), "bleu marine": (0, 0, 128), "turquoise": (0, 128, 128), "saumon": (255, 160, 128),
}
COMMON = {"a": "rouge", "b": "vert", "x": "jaune", "y": "cyan", "l": "orange", "r": "violet",
          "l2": "rouge foncé", "r2": "violet foncé", "start": "blanc", "select": "gris",
          "up": "rose", "down": "marron", "left": "vert foncé", "right": "bleu clair", "touch": "noir",
          "sup": "olive", "sdown": "bleu marine", "sleft": "turquoise", "sright": "saumon",
          "cup": "jaune", "cdown": "cyan", "cleft": "gris", "cright": "violet foncé"}
DS_OPTIONS = ["--opt", "melonds_touch_mode=touch", "--opt", "melonds_show_cursor=disabled",
              "--opt", "melonds_number_of_screen_layouts=1", "--opt", "melonds_screen_layout1=top-bottom"]
# N64 et PSP (Mac seulement : rendu 3D par l'OpenGL du Mac), avec les réglages imposés par l'app.
N64_OPTIONS = ["--opt", "mupen64plus-cpucore=cached_interpreter", "--opt", "mupen64plus-rdp-plugin=gliden64",
               "--opt", "mupen64plus-rsp-plugin=hle"]
PSP_SYSTEM = os.path.join(ROOT, "build", "test", "systeme-psp")
PSP_OPTIONS = ["--system", PSP_SYSTEM, "--jit", "1", "--opt", "ppsspp_backend=auto", "--opt", "ppsspp_cpu_core=JIT",
               "--opt", "ppsspp_enable_wlan=disabled", "--opt", "ppsspp_enable_upnp=disabled"]

CONSOLES = [
    ("NES", "mesen", "test.nes", "a b select start up down left right", []),
    ("Super Nintendo", "bsnes", "test.sfc", "a b x y l r select start up down left right", []),
    ("Game Boy Color", "mgba", "test.gb", "a b select start up down left right", []),
    ("Game Boy Advance", "mgba", "test.gba", "a b l r select start up down left right", []),
    ("Nintendo DS", "melondsds", "test.nds", "a b x y l r select start up down left right touch", DS_OPTIONS),
    # Rendu OpenGL de melonDS en x2 (Mac : OpenGL « core »).
    ("DS (OpenGL x2)", "melondsds", "test.nds", "a b x y l r select start up down left right touch",
     DS_OPTIONS + ["--opt", "melonds_render_mode=opengl", "--opt", "melonds_opengl_resolution=2"]),
    ("PlayStation", "pcsx_rearmed", "test.exe", "a b x y l r l2 r2 select start up down left right", []),
    ("Nintendo 64", "mupen64plus_next", "test.z64",
     "b y l2 l r start up down left right cup cdown cleft cright sup sdown sleft sright", N64_OPTIONS),
    ("PSP", "ppsspp", "test.elf", "a b x y l r select start up down left right sup sdown sleft sright", PSP_OPTIONS),
]
NAMES = {"a": "A", "b": "B", "x": "X", "y": "Y", "l": "L", "r": "R", "l2": "L2", "r2": "R2",
         "select": "Select", "start": "Start", "up": "Haut", "down": "Bas", "left": "Gauche",
         "right": "Droite", "touch": "Tactile"}
PS_NAMES = {"a": "○", "b": "✕", "x": "△", "y": "□", "l": "L1", "r": "R1"}
NAMES.update({"sup": "Stick↑", "sdown": "Stick↓", "sleft": "Stick←", "sright": "Stick→",
              "cup": "C↑", "cdown": "C↓", "cleft": "C←", "cright": "C→"})
# N64 : A et B sont reçus sur B et Y, Z sur L2 (comme dans l'app).
N64_NAMES = {"b": "A", "y": "B", "l2": "Z"}
N64_EXPECTED = {"b": "rouge", "y": "vert"}


# La palette NES n'a pas de rouge pur : son « rouge » ($16) tire vers le brique.
OVERRIDES = {"mesen": {"a": "marron"}}


def nearest(rgb):
    return min(COLORS, key=lambda n: sum((a - b) ** 2 for a, b in zip(COLORS[n], rgb)))


# Fichiers de PPSSPP (polices de la PSP…) dans un dossier système à part, comme dans l'app.
if not os.path.isdir(os.path.join(PSP_SYSTEM, "PPSSPP")):
    import shutil
    os.makedirs(PSP_SYSTEM, exist_ok=True)
    shutil.copytree(os.path.join(ROOT, "cores", "assets", "PPSSPP"), os.path.join(PSP_SYSTEM, "PPSSPP"))

STARTS = {"melondsds": 240, "mupen64plus_next": 240, "ppsspp": 360}
failures = 0
for console, core, rom, buttons, extra in CONSOLES:
    if not os.path.exists(os.path.join(CORES, core + ".dylib")):
        print(f"{console:17s} moteur absent ({core}.dylib), sauté")
        continue
    sequence = buttons.split()
    start = STARTS.get(core, 120)
    cmd = [HARNESS, os.path.join(CORES, core + ".dylib"), os.path.join(ROMS, rom), "10",
           os.path.join(ROOT, "build", "test", f"buttons-{core}.png"),
           "--sequence", ",".join(sequence), "--start", str(start), "--probe", str(start - 10)] + extra
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    idle = re.search(r"image\s+\d+ : centre #(\w{6}), quart haut #(\w{6})", out)
    idle_name = nearest(tuple(int(idle.group(2)[i:i + 2], 16) for i in (0, 2, 4))) if idle else "?"
    results = dict(re.findall(r"bouton (\S+)\s+→ #(\w{6})", out))
    line = []
    for b in sequence:
        hexa = results.get(b)
        rgb = tuple(int(hexa[i:i + 2], 16) for i in (0, 2, 4)) if hexa else None
        if rgb and core == "mupen64plus_next":
            # Le mini-jeu N64 laisse le gamma de la console allumé (racine carrée) : couleurs remises à plat.
            rgb = tuple(v * v // 255 for v in rgb)
        got = nearest(rgb) if rgb else "rien"
        expected = N64_EXPECTED.get(b, COMMON[b]) if core == "mupen64plus_next" else COMMON[b]
        ok = got == OVERRIDES.get(core, {}).get(b, expected)
        failures += not ok
        label = (PS_NAMES.get(b, NAMES[b]) if core in ("pcsx_rearmed", "ppsspp")
                 else N64_NAMES.get(b, NAMES[b]) if core == "mupen64plus_next" else NAMES[b])
        line.append(f"{label} {'✓' if ok else '✗ (' + got + ')'}")
    status = "OK" if all("✗" not in x for x in line) and idle_name == "bleu" else "PROBLÈME"
    print(f"{console:17s} repos={idle_name:5s} {status}\n    " + "  ".join(line))
print("\nRÉSULTAT :", "tous les boutons répondent" if failures == 0 else f"{failures} bouton(s) en échec")
