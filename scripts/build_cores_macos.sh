#!/bin/zsh
# Compile les moteurs libretro pour le Mac (Apple Silicon, macOS 14 minimum) :
# - cores/mac/<nom>.framework : embarqués dans l'app Mac (phase « Embed cores » de la cible PlayTendo Mac) ;
# - cores/macos/<nom>.dylib : mêmes moteurs pour le banc d'essai (scripts/test/test_buttons.py).
# Même version des sources que pour l'iPhone (scripts/fetch_sources.sh).
#   zsh scripts/build_cores_macos.sh [mesen bsnes mgba melondsds pcsx_rearmed]
set -e
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/sources"
OUT="$ROOT/cores/mac"
TEST_OUT="$ROOT/cores/macos"
WORK="$ROOT/build/cores-macos"
LOGS="$ROOT/build/logs"
mkdir -p "$OUT" "$TEST_OUT" "$WORK" "$LOGS"
JOBS=$(sysctl -n hw.ncpu)
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
# Même version minimale que l'app Mac (MACOSX_DEPLOYMENT_TARGET de la cible PlayTendo Mac) ; lue aussi par clang
# quand les Makefile ne la donnent pas.
MIN_MACOS=14.0
export MACOSX_DEPLOYMENT_TARGET=$MIN_MACOS
CMAKE_MAC=(-DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_MACOS)

run() { # nom-du-log commande...
  local log="$LOGS/$1.log"; shift
  if ! "$@" >> "$log" 2>&1; then
    echo "!!! ECHEC — dernières lignes de $log :"; tail -30 "$log"; exit 1
  fi
}

# Range une bibliothèque .dylib en framework macOS (structure Versions/A, liens Current) : l'app la charge par
# <nom>.framework/<nom>, comme sur iPhone. Copie aussi la bibliothèque pour le banc d'essai.
package() { # nom fichier.dylib
  local name=$1 dylib=$2
  local fw="$OUT/$name.framework"
  rm -rf "${fw:?}"
  mkdir -p "$fw/Versions/A/Resources"
  cp "$dylib" "$fw/Versions/A/$name"
  install_name_tool -id "@rpath/$name.framework/Versions/A/$name" "$fw/Versions/A/$name"
  cat > "$fw/Versions/A/Resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>com.playtendo.core.$name</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
</dict>
</plist>
EOF
  ln -s A "$fw/Versions/Current"
  ln -s "Versions/Current/$name" "$fw/$name"
  ln -s Versions/Current/Resources "$fw/Resources"
  cp "$dylib" "$TEST_OUT/$name.dylib"
  local minos=$(vtool -show-build "$fw/Versions/A/$name" | awk '/minos/ {print $2}')
  printf "OK (macOS %s, %d Ko) " "$minos" $(( $(stat -f %z "$fw/Versions/A/$name") / 1024 ))
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
      package mesen mesen_libretro.dylib
      run mesen-macos make clean ;;
    bsnes)
      cd "$SRC/bsnes/bsnes"
      run bsnes-macos make clean target=libretro
      run bsnes-macos make -j$JOBS target=libretro binary=library platform=macos local=false
      package bsnes out/bsnes_libretro.dylib
      run bsnes-macos make clean target=libretro ;;
    mgba)
      rm -rf "${WORK:?}/mgba"
      run mgba-macos cmake -S "$SRC/mgba" -B "$WORK/mgba" -G Ninja -DCMAKE_BUILD_TYPE=Release "${CMAKE_MAC[@]}" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_LIBRETRO=ON -DSKIP_LIBRARY=ON -DBUILD_QT=OFF -DBUILD_SDL=OFF \
        -DBUILD_GL=OFF -DBUILD_GLES2=OFF -DBUILD_GLES3=OFF -DBUILD_TEST=OFF -DBUILD_SUITE=OFF -DBUILD_CINEMA=OFF \
        -DBUILD_EXAMPLE=OFF -DBUILD_PYTHON=OFF -DBUILD_UPDATER=OFF -DUSE_FFMPEG=OFF -DUSE_MINIZIP=OFF \
        -DUSE_LIBZIP=OFF -DUSE_PNG=OFF -DUSE_SQLITE3=OFF -DUSE_ELF=OFF -DUSE_LUA=OFF -DUSE_DISCORD_RPC=OFF \
        -DUSE_EDITLINE=OFF -DUSE_EPOXY=OFF -DUSE_JSON_C=OFF -DUSE_LZMA=OFF -DENABLE_SCRIPTING=OFF
      run mgba-macos cmake --build "$WORK/mgba" --target mgba_libretro
      package mgba "$WORK/mgba/mgba_libretro.dylib" ;;
    melondsds)
      # Rendu logiciel pour l'instant (le rendu OpenGL viendra avec la N64 et la PSP).
      rm -rf "${WORK:?}/melondsds"
      run melondsds-macos cmake -S "$SRC/melonds-ds" -B "$WORK/melondsds" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        "${CMAKE_MAC[@]}" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DENABLE_OPENGL=OFF -DENABLE_JIT=OFF -DBUILD_TESTING=OFF
      run melondsds-macos cmake --build "$WORK/melondsds"
      package melondsds "$(find "$WORK/melondsds" -name 'melondsds_libretro*.dylib' | head -1)" ;;
    pcsx_rearmed)
      cd "$SRC/pcsx_rearmed"
      run pcsx_rearmed-macos make -f Makefile.libretro clean platform=osx
      run pcsx_rearmed-macos make -f Makefile.libretro -j$JOBS platform=osx ARCHFLAGS="-arch arm64"
      package pcsx_rearmed pcsx_rearmed_libretro.dylib
      run pcsx_rearmed-macos make -f Makefile.libretro clean platform=osx ;;
  esac
  echo
done
echo "=== MOTEURS macOS OK ==="
