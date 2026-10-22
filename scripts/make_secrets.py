#!/usr/bin/env python3
"""Clés de service embarquées dans PlayTendo, jamais en clair : lancé avant chaque compilation (étape « Clés masquées »
du projet). Lit les fichiers de secrets/ (déposés par l'utilisateur, exclus de git) et écrit
build/generated/PTSecrets.generated.h : chaque clé mélangée (ordre aléatoire) et masquée (XOR avec des octets
aléatoires), avec un masque et un ordre différents à chaque compilation. PTSecrets.m les reconstitue à la demande.
Sans fichier, l'en-tête dit « pas de clé » et l'app n'interroge pas le service.
  secrets/steamgriddb.key            → SteamGridDB (jaquettes de secours)
  secrets/screenscraper_devid        → ScreenScraper, identifiant développeur (boîtes 3D)
  secrets/screenscraper_devpassword  → ScreenScraper, mot de passe développeur"""
import os
import secrets
import sys

root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
out_dir = os.path.join(root, "build", "generated")
out_file = os.path.join(out_dir, "PTSecrets.generated.h")

# (fichier dans secrets/, préfixe dans l'en-tête, nom affiché)
KEYS = [
    ("steamgriddb.key", "PTSteamGridDB", "SteamGridDB"),
    ("screenscraper_devid", "PTScreenScraperDevID", "ScreenScraper (identifiant)"),
    ("screenscraper_devpassword", "PTScreenScraperDevPassword", "ScreenScraper (mot de passe)"),
]


def read_key(name):
    path = os.path.join(root, "secrets", name)
    if not os.path.isfile(path):
        return b""
    key = open(path, "rb").read().strip()
    if not key.isascii() or any(c < 0x21 or c > 0x7E for c in key):
        sys.exit(f"secrets/{name} : la clé doit être une seule ligne de caractères simples")
    return key


def masked(prefix, key):
    n = len(key)
    mask = secrets.token_bytes(n)
    order = list(range(n))
    secrets.SystemRandom().shuffle(order)
    mixed = bytes(key[order[i]] ^ mask[i] for i in range(n))

    def array(name, values):
        body = ", ".join(f"0x{v:02x}" for v in values) if values else "0"
        return f"static const unsigned char {prefix}{name}[{max(n, 1)}] = {{{body}}};\n"

    return f"#define {prefix}_LENGTH {n}\n" + array("Mask", mask) + array("Mixed", mixed) + array("Order", order)


text = "// Généré à chaque compilation par scripts/make_secrets.py : ne pas modifier, ne pas versionner.\n"
status = []
for file_name, prefix, label in KEYS:
    key = read_key(file_name)
    text += masked(prefix, key)
    status.append(f"{label} {'présente' if key else 'absente'}")

os.makedirs(out_dir, exist_ok=True)
with open(out_file, "w") as handle:
    handle.write(text)
print("Clés masquées : " + ", ".join(status))
