#!/usr/bin/env python3
"""Copie rcheevos (succès RetroAchievements, licence MIT) de sources/rcheevos dans l'app (app/PlayTendo/Vendor/rcheevos),
où Xcode le compile avec le reste. Seulement ce que l'app utilise : en-têtes, code C, licence (pas les tests, ni le
validateur, ni RAIntegration qui n'existe que sous Windows, ni les fichiers .natvis de Visual Studio).

Deux retouches :
  1. rc_libretro.h : « #include <libretro.h> » → « #include "libretro.h" » (celui de l'app, Emulation/libretro.h).
  2. rc_client.h : RC_CLIENT_SUPPORTS_HASH défini (identification du jeu par son empreinte, rc_hash).

À relancer après une mise à jour de rcheevos : python3 scripts/vendor_rcheevos.py
"""
import pathlib
import shutil

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "sources" / "rcheevos"
TARGET = ROOT / "app" / "PlayTendo" / "Vendor" / "rcheevos"
SKIPPED = {"rc_client_raintegration.c", "rc_client_raintegration_internal.h"}


def copy() -> None:
    if TARGET.exists():
        shutil.rmtree(TARGET)
    for folder in ("include", "src"):
        for file in sorted((SOURCE / folder).rglob("*")):
            if not file.is_file() or file.suffix not in (".c", ".h") or file.name in SKIPPED:
                continue
            destination = TARGET / file.relative_to(SOURCE)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(file, destination)
    shutil.copy2(SOURCE / "LICENSE", TARGET / "LICENSE.txt")


def patch(relative: str, old: str, new: str) -> None:
    file = TARGET / relative
    text = file.read_text(encoding="utf-8")
    if text.count(old) != 1:
        raise SystemExit(f"Retouche impossible dans {relative} : texte attendu introuvable")
    file.write_text(text.replace(old, new), encoding="utf-8")


def main() -> None:
    if not (SOURCE / "include" / "rc_client.h").exists():
        raise SystemExit("rcheevos absent de sources/rcheevos")
    copy()
    patch("src/rc_libretro.h", "#include <libretro.h>", '#include "libretro.h" /* PlayTendo : Emulation/libretro.h */')
    patch("include/rc_client.h", "#include \"rc_api_request.h\"",
          "/* PlayTendo : identification des jeux par leur empreinte (rc_hash). */\n"
          "#ifndef RC_CLIENT_SUPPORTS_HASH\n#define RC_CLIENT_SUPPORTS_HASH\n#endif\n\n#include \"rc_api_request.h\"")
    count = sum(1 for _ in TARGET.rglob("*.[ch]"))
    print(f"rcheevos copié dans {TARGET.relative_to(ROOT)} : {count} fichiers .c/.h")


if __name__ == "__main__":
    main()
