#!/bin/zsh
# Compile les mêmes moteurs pour le Mac (arm64), uniquement pour les tester ici
# avec le banc d'essai (scripts/test_cores.sh). Rien de tout ça ne va dans l'app.
set -e
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/sources"
OUT="$ROOT/cores/macos"
WORK="$ROOT/build/cores-macos"
LOGS="$ROOT/build/logs"
mkdir -p "$OUT" "$WORK" "$LOGS"
JOBS=$(sysctl -n hw.ncpu)

run() { # nom-du-log commande...
  local log="$LOGS/$1.log"; shift
  if ! "$@" >> "$log" 2>&1; then
    echo "!!! ECHEC — dernières lignes de $log :"; tail -30 "$log"; exit 1
  fi
}

ALL=(mesen bsnes mgba melondsds pcsx_rearmed)
if (( $# )); then CORES=("$@"); else CORES=($ALL); fi

for core in $CORES; do
  rm -f "$LOGS/$core-macos.log"
  printf "%-13s " "$core"
  case $core in
    mesen)
      cd "$SRC/mesen/Libretro"
      run mesen-macos make clean
      run mesen-macos make -j$JOBS platform=osx ARCHFLAGS="-arch arm64"
      cp mesen_libretro.dylib "$OUT/mesen.dylib"
      run mesen-macos make clean ;;
    bsnes)
      cd "$SRC/bsnes/bsnes"
      run bsnes-macos make clean target=libretro
      run bsnes-macos make -j$JOBS target=libretro binary=library platform=macos local=false
      cp out/bsnes_libretro.dylib "$OUT/bsnes.dylib"
      run bsnes-macos make clean target=libretro ;;
    mgba)
      run mgba-macos cmake -S "$SRC/mgba" -B "$WORK/mgba" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_LIBRETRO=ON -DSKIP_LIBRARY=ON -DBUILD_QT=OFF -DBUILD_SDL=OFF \
        -DBUILD_GL=OFF -DBUILD_GLES2=OFF -DBUILD_GLES3=OFF -DBUILD_TEST=OFF -DBUILD_SUITE=OFF -DBUILD_CINEMA=OFF \
        -DBUILD_EXAMPLE=OFF -DBUILD_PYTHON=OFF -DBUILD_UPDATER=OFF -DUSE_FFMPEG=OFF -DUSE_MINIZIP=OFF \
        -DUSE_LIBZIP=OFF -DUSE_PNG=OFF -DUSE_SQLITE3=OFF -DUSE_ELF=OFF -DUSE_LUA=OFF -DUSE_DISCORD_RPC=OFF \
        -DUSE_EDITLINE=OFF -DUSE_EPOXY=OFF -DUSE_JSON_C=OFF -DUSE_LZMA=OFF -DENABLE_SCRIPTING=OFF
      run mgba-macos cmake --build "$WORK/mgba" --target mgba_libretro
      cp "$WORK/mgba/mgba_libretro.dylib" "$OUT/mgba.dylib" ;;
    melondsds)
      run melondsds-macos cmake -S "$SRC/melonds-ds" -B "$WORK/melondsds" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DENABLE_OPENGL=OFF -DENABLE_JIT=OFF -DBUILD_TESTING=OFF
      run melondsds-macos cmake --build "$WORK/melondsds"
      cp "$(find "$WORK/melondsds" -name 'melondsds_libretro*.dylib' | head -1)" "$OUT/melondsds.dylib" ;;
    pcsx_rearmed)
      cd "$SRC/pcsx_rearmed"
      run pcsx_rearmed-macos make -f Makefile.libretro clean platform=osx
      run pcsx_rearmed-macos make -f Makefile.libretro -j$JOBS platform=osx ARCHFLAGS="-arch arm64"
      cp pcsx_rearmed_libretro.dylib "$OUT/pcsx_rearmed.dylib"
      run pcsx_rearmed-macos make -f Makefile.libretro clean platform=osx ;;
  esac
  echo "OK"
done
echo "=== MOTEURS macOS OK ==="
