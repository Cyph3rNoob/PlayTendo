#!/usr/bin/env python3
"""Corrige libco pour arm64 (Mupen64Plus-Next et bsnes) : en changeant de « fil », libco ne
sauvegardait pas les registres à virgule d8 à d15, que le code appelant a le droit de garder
d'un appel à l'autre. Au retour de retro_run, l'app retrouvait alors des valeurs écrasées
(plantage de PlayTendo sur iPhone dès le lancement d'un jeu N64, en version optimisée).

  patch_libco.py <aarch64.c> asm     — libco de libretro-common (assembleur en texte)
  patch_libco.py <aarch64.c> words   — libco de bsnes (instructions déjà encodées)

Sans effet si le fichier est déjà corrigé.
"""
import sys

path, style = sys.argv[1], sys.argv[2]
source = open(path).read()

if "d8" in source:
    print(f"libco déjà corrigé : {path}")
    sys.exit(0)

if style == "asm":
    save_anchor = '      "  stp x16, x30, [x1, #160]\\n"\n'
    load_anchor = '      "  ldp x16, x17, [x0, #160]\\n"\n'
    save = "".join(f'      "  stp d{r}, d{r + 1}, [x1, #{176 + 16 * i}]\\n"\n' for i, r in enumerate(range(8, 16, 2)))
    load = "".join(f'      "  ldp d{r}, d{r + 1}, [x0, #{176 + 16 * i}]\\n"\n' for i, r in enumerate(range(8, 16, 2)))
elif style == "words":
    save_anchor = "  0xa90a7830,  /* stp x16,x30,[x1,#160] */\n"
    load_anchor = "  0xa94a4410,  /* ldp x16,x17,[x0,#160] */\n"
    # Encodages produits par l'assembleur d'Apple (clang -arch arm64).
    save = ("  0x6d0b2428,  /* stp d8,d9,[x1,#176]   */\n"
            "  0x6d0c2c2a,  /* stp d10,d11,[x1,#192] */\n"
            "  0x6d0d342c,  /* stp d12,d13,[x1,#208] */\n"
            "  0x6d0e3c2e,  /* stp d14,d15,[x1,#224] */\n")
    load = ("  0x6d4b2408,  /* ldp d8,d9,[x0,#176]   */\n"
            "  0x6d4c2c0a,  /* ldp d10,d11,[x0,#192] */\n"
            "  0x6d4d340c,  /* ldp d12,d13,[x0,#208] */\n"
            "  0x6d4e3c0e,  /* ldp d14,d15,[x0,#224] */\n")
else:
    sys.exit(f"style inconnu : {style}")

if source.count(save_anchor) != 1 or source.count(load_anchor) != 1:
    sys.exit(f"!!! libco : code inattendu dans {path}, correctif non appliqué")

source = source.replace(save_anchor, save_anchor + save).replace(load_anchor, load_anchor + load)
open(path, "w").write(source)
print(f"libco corrigé (registres d8-d15) : {path}")
