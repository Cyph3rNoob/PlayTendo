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
}
COMMON = {"a": "rouge", "b": "vert", "x": "jaune", "y": "cyan", "l": "orange", "r": "violet",
          "l2": "rouge foncé", "r2": "violet foncé", "start": "blanc", "select": "gris",
          "up": "rose", "down": "marron", "left": "vert foncé", "right": "bleu clair", "touch": "noir"}
DS_OPTIONS = ["--opt", "melonds_touch_mode=touch", "--opt", "melonds_show_cursor=disabled",
              "--opt", "melonds_number_of_screen_layouts=1", "--opt", "melonds_screen_layout1=top-bottom"]

CONSOLES = [
    ("NES", "mesen", "test.nes", "a b select start up down left right", []),
    ("Super Nintendo", "bsnes", "test.sfc", "a b x y l r select start up down left right", []),
    ("Game Boy Color", "mgba", "test.gb", "a b select start up down left right", []),
    ("Game Boy Advance", "mgba", "test.gba", "a b l r select start up down left right", []),
    ("Nintendo DS", "melondsds", "test.nds", "a b x y l r select start up down left right touch", DS_OPTIONS),
    ("PlayStation", "pcsx_rearmed", "test.exe", "a b x y l r l2 r2 select start up down left right", []),
]
NAMES = {"a": "A", "b": "B", "x": "X", "y": "Y", "l": "L", "r": "R", "l2": "L2", "r2": "R2",
         "select": "Select", "start": "Start", "up": "Haut", "down": "Bas", "left": "Gauche",
         "right": "Droite", "touch": "Tactile"}
PS_NAMES = {"a": "○", "b": "✕", "x": "△", "y": "□", "l": "L1", "r": "R1"}


# La palette NES n'a pas de rouge pur : son « rouge » ($16) tire vers le brique.
OVERRIDES = {"mesen": {"a": "marron"}}


def nearest(rgb):
    return min(COLORS, key=lambda n: sum((a - b) ** 2 for a, b in zip(COLORS[n], rgb)))


failures = 0
for console, core, rom, buttons, extra in CONSOLES:
    sequence = buttons.split()
    start = 240 if core == "melondsds" else 120
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
        got = nearest(tuple(int(hexa[i:i + 2], 16) for i in (0, 2, 4))) if hexa else "rien"
        ok = got == OVERRIDES.get(core, {}).get(b, COMMON[b])
        failures += not ok
        label = PS_NAMES.get(b, NAMES[b]) if core == "pcsx_rearmed" else NAMES[b]
        line.append(f"{label} {'✓' if ok else '✗ (' + got + ')'}")
    distinct = len(set(results.values())) == len(sequence) or core in ("pcsx_rearmed",)
    status = "OK" if all("✗" not in x for x in line) and idle_name == "bleu" else "PROBLÈME"
    print(f"{console:17s} repos={idle_name:5s} {status}\n    " + "  ".join(line))
print("\nRÉSULTAT :", "tous les boutons répondent" if failures == 0 else f"{failures} bouton(s) en échec")
