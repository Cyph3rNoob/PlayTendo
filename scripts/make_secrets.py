#!/usr/bin/env python3
"""Clés de service embarquées dans PlayTendo, jamais en clair : lancé avant chaque compilation (étape « Clés masquées »
du projet). Lit secrets/steamgriddb.key (déposé par l'utilisateur, exclu de git) et écrit
build/generated/PTSecrets.generated.h : la clé mélangée (ordre aléatoire) et masquée (XOR avec des octets aléatoires),
avec un masque et un ordre différents à chaque compilation. PTSecrets.m la reconstitue à la demande.
Sans fichier de clé, l'en-tête dit « pas de clé » et l'app n'interroge pas SteamGridDB."""
import os
import secrets
import sys

root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
key_file = os.path.join(root, "secrets", "steamgriddb.key")
out_dir = os.path.join(root, "build", "generated")
out_file = os.path.join(out_dir, "PTSecrets.generated.h")

key = b""
if os.path.isfile(key_file):
    key = open(key_file, "rb").read().strip()
    if not key.isascii() or any(c < 0x21 or c > 0x7E for c in key):
        sys.exit("secrets/steamgriddb.key : la clé doit être une seule ligne de caractères simples")

n = len(key)
mask = secrets.token_bytes(n)
order = list(range(n))
secrets.SystemRandom().shuffle(order)
mixed = bytes(key[order[i]] ^ mask[i] for i in range(n))


def array(name, values):
    body = ", ".join(f"0x{v:02x}" for v in values) if values else "0"
    return f"static const unsigned char {name}[{max(n, 1)}] = {{{body}}};\n"


os.makedirs(out_dir, exist_ok=True)
text = ("// Généré à chaque compilation par scripts/make_secrets.py : ne pas modifier, ne pas versionner.\n"
        f"#define PT_STEAMGRIDDB_KEY_LENGTH {n}\n"
        + array("PTSteamGridDBMask", mask) + array("PTSteamGridDBMixed", mixed) + array("PTSteamGridDBOrder", order))
with open(out_file, "w") as handle:
    handle.write(text)
print(f"Clés masquées : SteamGridDB {'présente' if n else 'absente (secrets/steamgriddb.key)'}")
