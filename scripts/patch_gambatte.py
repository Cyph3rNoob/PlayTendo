#!/usr/bin/env python3
"""Retouches de Gambatte (libretro) pour PlayTendo. Appelé par build_cores.sh et build_cores_macos.sh ; une retouche
déjà faite est sautée.

1. net_serial.cpp (2026-10-24, audit de sécurité) : en hôte du câble link, Gambatte écoutait sur toutes les interfaces
   (INADDR_ANY) : n'importe qui sur le même réseau pouvait se brancher à la partie sans passer par PlayTendo. Il
   n'écoute plus que l'appareil lui-même (127.0.0.1) ; PlayTendo relaie l'autre appareil, après accord du joueur.
2. net_serial.cpp (2026-10-25) : port de l'hôte réutilisable tout de suite (SO_REUSEADDR) : rebrancher juste après une
   coupure échouait tant que l'ancienne liaison restait en attente de fermeture (TIME_WAIT).

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
    print("net_serial.cpp : déjà limité à l'appareil")
elif text.count(old) == 1:
    text = text.replace(old, new)
    print("net_serial.cpp : câble link limité à l'appareil")
else:
    raise SystemExit("net_serial.cpp : retouche impossible (le fichier a changé)")

old = "\t\tif (bind(fd, (struct sockaddr *)&server_addr, sizeof(server_addr)) < 0) {"
new = ("\t\tint reuse = 1; // PlayTendo : port réutilisable tout de suite après une coupure\n"
       "\t\tsetsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (const char *)&reuse, sizeof(reuse));\n" + old)
if new in text:
    print("net_serial.cpp : port déjà réutilisable")
elif text.count(old) == 1:
    text = text.replace(old, new)
    print("net_serial.cpp : port réutilisable")
else:
    raise SystemExit("net_serial.cpp : retouche 2 impossible (le fichier a changé)")
path.write_text(text, encoding="utf-8")
