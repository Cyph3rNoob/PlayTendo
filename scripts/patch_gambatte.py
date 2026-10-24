#!/usr/bin/env python3
"""Retouches de Gambatte (libretro) pour PlayTendo. Appelé par build_cores.sh et build_cores_macos.sh ; une retouche
déjà faite est sautée.

1. net_serial.cpp (2026-10-24, audit de sécurité) : en hôte du câble link, Gambatte écoutait sur toutes les interfaces
   (INADDR_ANY) : n'importe qui sur le même réseau pouvait se brancher à la partie sans passer par PlayTendo. Il
   n'écoute plus que l'appareil lui-même (127.0.0.1) ; PlayTendo relaie l'autre appareil, après accord du joueur.

Usage : python3 scripts/patch_gambatte.py <sources/gambatte>
"""
import pathlib
import sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent / "sources" / "gambatte")
path = root / "libgambatte" / "libretro" / "net_serial.cpp"
text = path.read_text(encoding="utf-8")
old = "\t\tserver_addr.sin_addr.s_addr = INADDR_ANY;"
new = "\t\tserver_addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK); // PlayTendo : l'appareil seulement"
if new in text:
    print("net_serial.cpp : déjà retouché")
elif text.count(old) == 1:
    path.write_text(text.replace(old, new), encoding="utf-8")
    print("net_serial.cpp : câble link limité à l'appareil")
else:
    raise SystemExit("net_serial.cpp : retouche impossible (le fichier a changé)")
