#!/usr/bin/env python3
"""Retouches de melonDS DS 1.4.0 (et de melonDS, qu'il télécharge) pour son rendu OpenGL sur l'iPhone (PlayTendo).

melonDS ne dessine en résolution augmentée qu'avec son rendu OpenGL, écrit pour OpenGL 3.2 (ordinateurs) ; melonDS DS
le coupe sur iPhone. Ces retouches le compilent pour OpenGL ES 3.0, avec la couche d'adaptation de PlayTendo
(ds/PTGLESCompat.h/.cpp). Appelé par build_cores.sh (avant et après la préparation CMake, qui télécharge melonDS).
Une retouche déjà faite est sautée : relancer le script ne change rien.

    patch_melonds.py <sources/melonds-ds> [<dossier source de melonDS (_deps/melonds-src)>]

melonDS DS :
1. CMakeLists.txt : OpenGL ES accepté (melonDS DS l'interdit : « melonDS does not support OpenGL ES yet »).
2. cmake/ConfigureFeatures.cmake : sur iPhone, OpenGL ES 3 = OpenGLES.framework (le module de recherche de CMake ne
   connaît que les en-têtes GLES3/ d'Android et de Linux).
3. src/libretro/CMakeLists.txt : PTGLESCompat.cpp compilé avec le reste.
4. PlatformOGLPrivate.h : PTGLESCompat.h inclus à la fin (ses macros remplacent les fonctions absentes d'OpenGL ES).
5. glsym_private.cpp : son glDrawBuffer pour OpenGL ES laisse la place à celui de PlayTendo.
6. render/opengl.cpp : contexte OpenGL ES 3.0 demandé à l'app au lieu d'OpenGL 3.2 ; pas de résolution des
   fonctions d'OpenGL 1.x (OpenGL ES est lié directement) ; pas de texture « tampon » libérée (absente d'OpenGL ES).
7. glsl/melondsds.vert : « fpos.y *= -1; » → « -1.0 » (OpenGL ES ne convertit pas un entier en nombre à virgule).
melonDS :
8. OpenGLSupport.cpp : shaders convertis pour OpenGL ES (PTGLESCompat), sorties des shaders numérotées dans le texte
   (« layout(location = n) ») puisque glBindFragDataLocation n'existe pas en OpenGL ES.
9. OpenGL_shaders/*.glsl : remplacés par ceux de ds/shaders, les mêmes avec les conversions d'entiers en nombres à
   virgule écrites (« 2 » → « 2.0 », « float(…) ») qu'OpenGL ES exige (vérifiés avec glslangValidator), la couleur
   de bord des fonds 2D calculée dans 2DCompositorFS (pas de GL_CLAMP_TO_BORDER en OpenGL ES) et ses 192 lignes de
   réglages coupées en deux blocs de 96 (un bloc est limité à 16 Ko en OpenGL ES ; 30 Ko sinon).
10. GPU2D_OpenGL.cpp : les deux moitiés du tampon de ces lignes liées aux deux blocs.
"""
import os
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DS = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "sources", "melonds-ds")
MELONDS = sys.argv[2] if len(sys.argv) > 2 else None


def patch(base, relative, replacements):
    path = os.path.join(base, relative)
    text = open(path, encoding="utf-8").read()
    done = 0
    for old, new in replacements:
        if new in text:
            continue
        if text.count(old) != 1:
            sys.exit(f"!!! {relative} : passage introuvable ou ambigu :\n{old}")
        text = text.replace(old, new)
        done += 1
    if done:
        open(path, "w", encoding="utf-8").write(text)
    print(f"{relative} : {done} retouche(s) faite(s), {len(replacements) - done} déjà là")


# Couche d'adaptation de PlayTendo, à côté des fichiers de melonDS DS.
for name in ("PTGLESCompat.h", "PTGLESCompat.cpp"):
    source = os.path.join(ROOT, "ds", name)
    target = os.path.join(DS, "src", "libretro", name)
    if not os.path.exists(target) or open(source, "rb").read() != open(target, "rb").read():
        shutil.copyfile(source, target)
        print(f"src/libretro/{name} : copié")

patch(DS, "CMakeLists.txt", [
    ('if (ENABLE_OPENGL AND (NOT OPENGL_PROFILE STREQUAL "OpenGL"))\n'
     '    message(FATAL_ERROR "melonDS does not support OpenGL ES yet")\n',
     'if (ENABLE_OPENGL AND (NOT OPENGL_PROFILE STREQUAL "OpenGL"))\n'
     '    # PlayTendo : OpenGL ES 3.0 sur iPhone, avec la couche d\'adaptation PTGLESCompat.\n'
     '    message(STATUS "OpenGL ES : rendu OpenGL de melonDS adapté par PlayTendo")\n'),
])

patch(DS, "cmake/ConfigureFeatures.cmake", [
    ('    elseif (OPENGL_PROFILE STREQUAL "OpenGLES3")\n'
     '        find_package(OpenGLES OPTIONAL_COMPONENTS V3)\n',
     '    elseif (OPENGL_PROFILE STREQUAL "OpenGLES3" AND IOS)\n'
     '        # PlayTendo : OpenGL ES 3 de l\'iPhone = OpenGLES.framework (en-têtes <OpenGLES/ES3/gl.h>).\n'
     '        set(OpenGLES_V3_FOUND ON)\n'
     '        set(OpenGLES_V3_INCLUDE_DIR "${CMAKE_BINARY_DIR}")\n'
     '        if (NOT TARGET OpenGLES::OpenGLESv3)\n'
     '            add_library(OpenGLES::OpenGLESv3 INTERFACE IMPORTED)\n'
     '            set_target_properties(OpenGLES::OpenGLESv3 PROPERTIES INTERFACE_LINK_LIBRARIES "-framework OpenGLES")\n'
     '        endif ()\n'
     '    elseif (OPENGL_PROFILE STREQUAL "OpenGLES3")\n'
     '        find_package(OpenGLES OPTIONAL_COMPONENTS V3)\n'),
])

patch(DS, "src/libretro/CMakeLists.txt", [
    ("    glsym_private.cpp\n    glsym_private.h\n",
     "    glsym_private.cpp\n    glsym_private.h\n"
     "    PTGLESCompat.cpp\n    PTGLESCompat.h\n"),
])

patch(DS, "src/libretro/PlatformOGLPrivate.h", [
    ("#endif //MELONDS_DS_PLATFORMOGLPRIVATE_H",
     "#if defined(HAVE_OPENGLES3) && defined(IOS)\n"
     "// PlayTendo : fonctions d'OpenGL 3.2 absentes d'OpenGL ES 3.0, remplacées (PTGLESCompat.h).\n"
     "#include \"PTGLESCompat.h\"\n"
     "#endif\n"
     "\n"
     "#endif //MELONDS_DS_PLATFORMOGLPRIVATE_H"),
])

patch(DS, "src/libretro/glsym_private.cpp", [
    ("#ifdef HAVE_OPENGLES\n\nvoid glDrawBuffer(GLenum buf)",
     "#if defined(HAVE_OPENGLES) && !defined(PT_GLES_COMPAT) // PlayTendo : le sien est dans PTGLESCompat.cpp\n\n"
     "void glDrawBuffer(GLenum buf)"),
])

patch(DS, "src/libretro/render/opengl.cpp", [
    ("    _hw_render.context_destroy = HardwareContextDestroyed;\n",
     "    _hw_render.context_destroy = HardwareContextDestroyed;\n"
     "#ifdef PT_GLES_COMPAT\n"
     "    // PlayTendo : OpenGL ES 3.0 de l'iPhone, le rendu OpenGL de melonDS étant adapté (PTGLESCompat.h).\n"
     "    _hw_render.context_type = RETRO_HW_CONTEXT_OPENGLES3;\n"
     "    _hw_render.version_major = 3;\n"
     "    _hw_render.version_minor = 0;\n"
     "#endif\n"),
    ("    rglgen_resolve_symbols_custom(\n",
     "#ifndef PT_GLES_COMPAT // PlayTendo : OpenGL ES de l'iPhone lié directement, rien à résoudre ici\n"
     "    rglgen_resolve_symbols_custom(\n"),
    ("    // Now resolve everything else that glsym knows about\n",
     "#endif\n"
     "    // Now resolve everything else that glsym knows about\n"),
    ("        glBindTexture(GL_TEXTURE_BUFFER, 0);\n",
     "#ifndef PT_GLES_COMPAT // PlayTendo : pas de textures « tampon » en OpenGL ES 3.0\n"
     "        glBindTexture(GL_TEXTURE_BUFFER, 0);\n"
     "#endif\n"),
])

patch(DS, "src/libretro/glsl/melondsds.vert", [
    ("fpos.y *= -1;", "fpos.y *= -1.0;"),
])

if MELONDS:
    shaders = os.path.join(ROOT, "ds", "shaders")
    copied = 0
    for name in sorted(os.listdir(shaders)):
        if not name.endswith(".glsl"):
            continue
        source = os.path.join(shaders, name)
        target = os.path.join(MELONDS, "src", "OpenGL_shaders", name)
        if not os.path.exists(target):
            sys.exit(f"!!! OpenGL_shaders/{name} absent de melonDS : shader à revoir")
        if open(source, "rb").read() != open(target, "rb").read():
            shutil.copyfile(source, target)
            copied += 1
    print(f"OpenGL_shaders : {copied} shader(s) remplacé(s)")

    patch(MELONDS, "src/GPU2D_OpenGL.cpp", [
        ('    glUniformBlockBinding(CompositorShader, uniloc, 22);\n',
         '    glUniformBlockBinding(CompositorShader, uniloc, 22);\n'
         '#ifdef PT_GLES_COMPAT\n'
         '    // PlayTendo : seconde moitié des 192 lignes (2DCompositorFS de ds/shaders).\n'
         '    uniloc = glGetUniformBlockIndex(CompositorShader, "ubScanlineConfigBottom");\n'
         '    glUniformBlockBinding(CompositorShader, uniloc, 25);\n'
         '#endif\n'),
        ('    glBindBufferBase(GL_UNIFORM_BUFFER, 22, ScanlineConfigUBO);\n',
         '#ifdef PT_GLES_COMPAT\n'
         '    // PlayTendo : OpenGL ES limite un bloc à 16 Ko : les lignes 0-95 et 96-191, deux moitiés du même tampon.\n'
         '    glBindBufferRange(GL_UNIFORM_BUFFER, 22, ScanlineConfigUBO, 0, 96 * sizeof(sScanlineConfig::sScanline));\n'
         '    glBindBufferRange(GL_UNIFORM_BUFFER, 25, ScanlineConfigUBO, 96 * sizeof(sScanlineConfig::sScanline),\n'
         '                      96 * sizeof(sScanlineConfig::sScanline));\n'
         '#else\n'
         '    glBindBufferBase(GL_UNIFORM_BUFFER, 22, ScanlineConfigUBO);\n'
         '#endif\n'),
    ])

    patch(MELONDS, "src/OpenGLSupport.cpp", [
        ('#include <assert.h>\n',
         '#include <assert.h>\n'
         '\n'
         '#ifdef PT_GLES_COMPAT\n'
         '#include <cstdlib>\n'
         '#include <regex>\n'
         '#endif\n'),
        ('    const char* sourceC = source.c_str();\n'
         '    int len = source.length();\n',
         '#ifdef PT_GLES_COMPAT\n'
         '    // PlayTendo : shader converti pour OpenGL ES 3.0 (PTGLESCompat).\n'
         '    char* adapted = ptgl_AdaptShaderSource(source.c_str());\n'
         '    std::string adaptedSource(adapted);\n'
         '    free(adapted);\n'
         '    const char* sourceC = adaptedSource.c_str();\n'
         '    int len = adaptedSource.length();\n'
         '#else\n'
         '    const char* sourceC = source.c_str();\n'
         '    int len = source.length();\n'
         '#endif\n'),
        ('bool CompileVertexFragmentProgram(GLuint& result,\n',
         '#ifdef PT_GLES_COMPAT\n'
         '// PlayTendo : pas de glBindFragDataLocation en OpenGL ES : chaque sortie du shader reçoit son numéro dans le texte\n'
         '// (« layout(location = n) out vec4 oColor; »).\n'
         'static std::string PTLocateOutputs(const std::string& fs, const std::initializer_list<AttributeTarget>& outputs)\n'
         '{\n'
         '    std::string located = fs;\n'
         '    for (const AttributeTarget& target : outputs)\n'
         '    {\n'
         '        const std::regex declaration(std::string("(^|\\\\n)[ \\\\t]*out[ \\\\t]+(\\\\w+)[ \\\\t]+") + target.Name + "[ \\\\t]*;");\n'
         '        located = std::regex_replace(located, declaration,\n'
         '            std::string("$1layout(location = ") + std::to_string(target.Location) + ") out $2 " + target.Name + ";");\n'
         '    }\n'
         '    return located;\n'
         '}\n'
         '#endif\n'
         '\n'
         'bool CompileVertexFragmentProgram(GLuint& result,\n'),
        ('    if (!CompilerShader(shaders[1], fs, name, "fragment"))\n',
         '#ifdef PT_GLES_COMPAT\n'
         '    if (!CompilerShader(shaders[1], PTLocateOutputs(fs, fragmentOutAttrs), name, "fragment"))\n'
         '#else\n'
         '    if (!CompilerShader(shaders[1], fs, name, "fragment"))\n'
         '#endif\n'),
    ])
