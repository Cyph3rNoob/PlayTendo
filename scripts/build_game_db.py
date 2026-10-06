#!/usr/bin/env python3
"""Fabrique les bases de jeux embarquées dans l'app (cores/assets/Bases/<CONSOLE>.tsv) à partir
des fichiers No-Intro / Redump de libretro-database (téléchargés par fetch_sources.sh).

Une ligne par jeu : nom officiel <TAB> CRC32 des fichiers <TAB> identifiants (séparés par des virgules ;
la NES a souvent deux CRC : fichier avec et sans en-tête iNES).
Le nom officiel est aussi celui des jaquettes de libretro-thumbnails. Les identifiants sont écrits
sans tiret ni espace, en majuscules (« UCES-01401 » → « UCES01401 »).
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "sources", "libretro-database")
OUT = os.path.join(ROOT, "cores", "assets", "Bases")

# Dossier de la console dans l'app → fichiers de la base. Pour les disques (PS1, PSP, PS2), le CRC n'est
# pas utilisé (fichiers trop gros pour être relus) : seul l'identifiant du disque compte.
SOURCES = {
    "NES": (["no-intro/Nintendo - Nintendo Entertainment System.dat"], True),
    "SNES": (["no-intro/Nintendo - Super Nintendo Entertainment System.dat"], True),
    "N64": (["no-intro/Nintendo - Nintendo 64.dat"], True),
    "GB": (["no-intro/Nintendo - Game Boy.dat"], True),
    "GBC": (["no-intro/Nintendo - Game Boy Color.dat"], True),
    "GBA": (["no-intro/Nintendo - Game Boy Advance.dat"], True),
    "DS": (["no-intro/Nintendo - Nintendo DS.dat"], True),
    "PS1": (["redump/Sony - PlayStation.dat"], False),
    "PSP": (["redump/Sony - PlayStation Portable.dat", "no-intro/Sony - PlayStation Portable.dat"], False),
    "PS2": (["redump/Sony - PlayStation 2.dat"], False),
    "GameCube": (["redump/Nintendo - GameCube.dat"], False),
    "Wii": (["redump/Nintendo - Wii.dat"], False),
}

# GameCube / Wii : l'app lit le code du jeu dans l'en-tête du disque (« GZLP » dans « GZLP01 ») ; la base
# Redump le donne au milieu de l'identifiant (« DL-DOL-GZLP-EUR », « RVL-RSBP-EUR-B0 »).
NINTENDO_DISC = re.compile(r"(?:DOL|RVL)-([A-Z0-9]{4})(?:-|$)")
# Révision du disque (octet 7 de l'en-tête) : « GZLP » + « R1 » pour « (Rev 1) », pour ne pas confondre les
# versions d'un même jeu (l'app cherche d'abord le code avec révision, puis le code seul).
REVISION = re.compile(r"\(Rev (\d+)\)")

GAME = re.compile(r'^game \($(.*?)^\)$', re.S | re.M)
NAME = re.compile(r'^\s*name "(.*)"$', re.M)
SERIAL = re.compile(r'serial "([^"]+)"')
CRC = re.compile(r'\bcrc ([0-9A-Fa-f]{8})\b')


def clean_serial(serial):
    return re.sub(r"[^0-9A-Z]", "", serial.upper())


def parse(path, with_crc):
    text = open(path, encoding="utf-8", errors="replace").read()
    for block in GAME.findall(text):
        name = NAME.search(block)
        if not name:
            continue
        serials = []
        for raw in SERIAL.findall(block):
            # Certains disques ont plusieurs identifiants : « SLES-02380, SLES-12380 ».
            for part in re.split(r"[,/]", raw):
                disc = NINTENDO_DISC.search(part.strip().upper())
                serial = disc.group(1) if disc else clean_serial(part)
                if serial and serial not in serials:
                    serials.append(serial)
        crcs = CRC.findall(block) if with_crc else []
        crc = crcs[0].lower() if len(crcs) == 1 else ""      # un seul fichier : le CRC identifie le jeu
        yield name.group(1), crc, serials


os.makedirs(OUT, exist_ok=True)
for folder, (files, with_crc) in SOURCES.items():
    games = {}                                           # nom → (CRC, identifiants), dans l'ordre
    for relative in files:
        for name, crc, serials in parse(os.path.join(SRC, relative), with_crc):
            if "\t" in name:
                continue
            revision = REVISION.search(name) if folder in ("GameCube", "Wii") else None
            if revision:
                serials = [f"{serial}R{revision.group(1)}" for serial in serials]
            crcs, known = games.setdefault(name, ([], []))
            if crc and crc not in crcs:
                crcs.append(crc)
            known.extend(s for s in serials if s not in known)
    lines = [f"{name}\t{','.join(crcs)}\t{','.join(serials)}" for name, (crcs, serials) in games.items()]
    lines.sort(key=str.lower)
    path = os.path.join(OUT, f"{folder}.tsv")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(f"{folder:5s} {len(lines):6d} jeux  {os.path.getsize(path) // 1024:5d} Ko")
