#!/usr/bin/env python3
"""Retouche de PPSSPP pour l'app PlayTendo du Mac (rendu OpenGL « core » 4.1 de macOS).

Le contexte « OpenGL core » de la version libretro de PPSSPP ne prévient pas PPSSPP qu'il est « core »
(SetGLCoreContext, que les versions de PPSSPP pour ordinateur appellent) : ses shaders partent alors sans ligne
« #version », que les pilotes d'Apple exigent (« #version required and missing », image noire). Sans effet sur
iPhone, qui utilise le contexte OpenGL ES.

  patch_ppsspp_mac.py <dossier source de PPSSPP>

Sans effet si le fichier est déjà corrigé.
"""
import pathlib
import sys

path = pathlib.Path(sys.argv[1]) / "libretro" / "LibretroGLCoreContext.cpp"
text = path.read_text()
if "PlayTendo" in text:
    print("déjà corrigé : libretro/LibretroGLCoreContext.cpp")
    sys.exit(0)
anchor = "\t\tglewInitDone = true;\n\t\tCheckGLExtensions();\n"
if text.count(anchor) != 1:
    sys.exit("repère introuvable dans libretro/LibretroGLCoreContext.cpp")
text = text.replace(anchor, "\t\tglewInitDone = true;\n"
                            "\t\t// PlayTendo : contexte « core » (Mac) ; les shaders reçoivent leur #version, exigée par Apple.\n"
                            "\t\tSetGLCoreContext(true);\n"
                            "\t\tCheckGLExtensions();\n")
path.write_text(text)
print("corrigé : libretro/LibretroGLCoreContext.cpp")
