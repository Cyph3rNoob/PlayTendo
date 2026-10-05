#!/usr/bin/env python3
"""Prend des captures du simulateur en continu pendant N secondes, puis affiche la suite des
couleurs lues en un point (les répétitions consécutives sont regroupées).

  burst.py <udid> <secondes> <x> <y> [dossier]
"""
import os
import shutil
import subprocess
import sys
import time

udid, seconds, x, y = sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[4]
folder = sys.argv[5] if len(sys.argv) > 5 else "build/test/burst"
shutil.rmtree(folder, ignore_errors=True)
os.makedirs(folder)
end = time.time() + seconds
paths = []
while time.time() < end:
    path = os.path.join(folder, f"{len(paths):04d}.png")
    subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", path], capture_output=True)
    paths.append(path)
here = os.path.dirname(os.path.abspath(__file__))
out = subprocess.run(["swift", os.path.join(here, "pixel.swift"), x, y, *paths], capture_output=True, text=True).stdout
sequence = []
for line in out.split("\n"):
    if not line.strip():
        continue
    color = line.split()[-1]
    if not sequence or sequence[-1][0] != color:
        sequence.append([color, 1])
    else:
        sequence[-1][1] += 1
print(f"{len(paths)} captures")
print(" → ".join(f"{c}×{n}" for c, n in sequence))
