#!/bin/zsh
# Compile les moteurs d'émulation pour iPhone (arm64) et les range sous forme de
# frameworks dans cores/ios/, prêts à être embarqués dans PlayTendo.
#
#   scripts/build_cores.sh            -> compile tous les moteurs
#   scripts/build_cores.sh mgba bsnes -> compile seulement ceux-là
set -e
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/sources"
OUT="$ROOT/cores/ios"
WORK="$ROOT/build/cores-ios"
LOGS="$ROOT/build/logs"
mkdir -p "$OUT" "$WORK" "$LOGS"

MIN_IOS=15.0
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos -f clang)"
CLANGXX="$(xcrun --sdk iphoneos -f clang++)"
CC_IOS="$CLANG -arch arm64 -isysroot $SDK -miphoneos-version-min=$MIN_IOS"
CXX_IOS="$CLANGXX -arch arm64 -isysroot $SDK -miphoneos-version-min=$MIN_IOS -stdlib=libc++"
JOBS=$(sysctl -n hw.ncpu)

ALL=(mesen bsnes mgba melondsds pcsx_rearmed mupen64plus_next ppsspp)
if (( $# )); then CORES=("$@"); else CORES=($ALL); fi

# Affiche un point toutes les 20 lignes de compilation, pour montrer que ça avance.
progress() { awk '{ n++; if (n % 20 == 0) { printf "."; fflush() } }'; }

run() { # nom-du-log commande...
  local log="$LOGS/$1.log"; shift
  if ! "$@" > >(tee -a "$log" | progress) 2>&1; then
    echo ""
    echo "!!! ECHEC — dernières lignes de $log :"
    tail -40 "$log"
    exit 1
  fi
}

# Transforme une bibliothèque .dylib en framework iOS (format accepté par AltStore).
wrap() { # nom chemin.dylib
  local name=$1 dylib=$2
  local fw="$OUT/$name.framework"
  rm -rf "$fw"; mkdir -p "$fw"
  cp "$dylib" "$fw/$name"
  install_name_tool -id "@rpath/$name.framework/$name" "$fw/$name"
  strip -x "$fw/$name"
  cat > "$fw/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>com.playtendo.core.${name//_/-}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
  <key>MinimumOSVersion</key><string>$MIN_IOS</string>
</dict>
</plist>
EOF
  echo " OK ($(du -h "$fw/$name" | cut -f1 | tr -d ' '))"
}

build_mesen() {
  cd "$SRC/mesen/Libretro"
  sed -i '' 's/version-min=[0-9.]*/version-min='$MIN_IOS'/g' Makefile
  run mesen-ios make -j$JOBS platform=ios-arm64 IOSSDK="$SDK" \
    CC="$CC_IOS" CXX="$CXX_IOS" LD="$CXX_IOS"
  wrap mesen "$SRC/mesen/Libretro/mesen_libretro_ios.dylib"
}

build_bsnes() {
  cd "$SRC/bsnes/bsnes"
  # La version 0.115 lie avec « c++ -marm », une option 32 bits refusée en arm64.
  sed -i '' 's/version-min=11.0/version-min='$MIN_IOS'/g' target-libretro/GNUmakefile
  sed -i '' 's/c++ -arch arm64 -marm -miphoneos-version-min=[0-9.]* -isysroot $(IOSSDK)/$(compiler)/' target-libretro/GNUmakefile
  # libco ne sauvegardait pas les registres d8-d15 : l'app plantait au retour de retro_run.
  python3 "$ROOT/scripts/patch_libco.py" "$SRC/bsnes/libco/aarch64.c" words
  rm -f obj/libco.o
  run bsnes-ios make -j$JOBS target=libretro binary=library platform=ios-arm64 \
    compiler="$CXX_IOS" local=false openmp=false IOSSDK="$SDK"
  wrap bsnes "$SRC/bsnes/bsnes/out/bsnes_libretro_ios.dylib"
}

build_mgba() {
  local b="$WORK/mgba"
  run mgba-ios cmake -S "$SRC/mgba" -B "$b" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_IOS -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_LIBRETRO=ON -DSKIP_LIBRARY=ON -DBUILD_QT=OFF -DBUILD_SDL=OFF \
    -DBUILD_GL=OFF -DBUILD_GLES2=OFF -DBUILD_GLES3=OFF -DBUILD_TEST=OFF -DBUILD_SUITE=OFF \
    -DBUILD_CINEMA=OFF -DBUILD_EXAMPLE=OFF -DBUILD_PYTHON=OFF -DBUILD_UPDATER=OFF \
    -DUSE_FFMPEG=OFF -DUSE_MINIZIP=OFF -DUSE_LIBZIP=OFF -DUSE_PNG=OFF -DUSE_SQLITE3=OFF \
    -DUSE_ELF=OFF -DUSE_LUA=OFF -DUSE_DISCORD_RPC=OFF -DUSE_EDITLINE=OFF -DUSE_EPOXY=OFF \
    -DUSE_JSON_C=OFF -DUSE_LZMA=OFF -DENABLE_SCRIPTING=OFF
  run mgba-ios cmake --build "$b" --target mgba_libretro
  wrap mgba "$b/mgba_libretro.dylib"
}

build_melondsds() {
  local b="$WORK/melondsds"
  run melondsds-ios cmake -S "$SRC/melonds-ds" -B "$b" -G Ninja \
    --toolchain "$SRC/melonds-ds/cmake/toolchain/ios.toolchain.cmake" \
    -DPLATFORM=OS64 -DDEPLOYMENT_TARGET=$MIN_IOS -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_AS_SHARED_LIBRARY=ON -DBUILD_TESTING=OFF
  run melondsds-ios cmake --build "$b"
  wrap melondsds "$(find "$b" -name 'melondsds_libretro*.dylib' | head -1)"
}

build_pcsx_rearmed() {
  cd "$SRC/pcsx_rearmed"
  run pcsx_rearmed-ios make -f Makefile.libretro -j$JOBS platform=ios-arm64 IOSSDK="$SDK" \
    MINVERSION=-miphoneos-version-min=$MIN_IOS CC="$CC_IOS" CXX="$CXX_IOS"
  wrap pcsx_rearmed "$SRC/pcsx_rearmed/pcsx_rearmed_libretro_ios.dylib"
}

build_mupen64plus_next() {
  cd "$SRC/mupen64plus-nx"
  sed -i '' 's/version-min=[0-9.]*/version-min='$MIN_IOS'/g' Makefile
  # La vieille libpng incluse croit être sur un Mac « classique » (années 90) et cherche <fp.h>.
  sed -i '' 's/defined(THINK_C) || defined(__SC__) || defined(TARGET_OS_MAC)$/defined(THINK_C) || defined(__SC__) || (defined(TARGET_OS_MAC) \&\& !defined(__APPLE__))/' \
    custom/dependencies/libpng/pngpriv.h
  # Même chose pour la vieille zlib, qui remplacerait fdopen() par NULL.
  sed -i '' 's/^#if defined(MACOS) || defined(TARGET_OS_MAC)$/#if defined(MACOS) || (defined(TARGET_OS_MAC) \&\& !defined(__APPLE__))/' \
    custom/dependencies/libzlib/zutil.h
  # libco ne sauvegardait pas les registres d8-d15 : l'app plantait au retour de retro_run.
  python3 "$ROOT/scripts/patch_libco.py" libretro-common/libco/aarch64.c asm
  rm -f libretro-common/libco/libco.o
  run mupen64plus_next-ios make -j$JOBS platform=ios-arm64 IOSSDK="$SDK" \
    CC="$CC_IOS" CXX="$CXX_IOS" CC_AS="$CC_IOS"
  wrap mupen64plus_next "$(ls "$SRC"/mupen64plus-nx/mupen64plus_next_libretro*.dylib | head -1)"
}

build_ppsspp() {
  local b="$WORK/ppsspp"
  run ppsspp-ios cmake -S "$SRC/ppsspp" -B "$b" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$SRC/ppsspp/cmake/Toolchains/ios.cmake" -DLIBRETRO=ON \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  run ppsspp-ios cmake --build "$b" --target ppsspp_libretro
  wrap ppsspp "$(find "$b" -name 'ppsspp_libretro*.dylib' | head -1)"
  # Fichiers dont le moteur a besoin (polices de la PSP, tables de calcul, réglages par jeu…),
  # embarqués dans l'app puis copiés dans <dossier système>/PPSSPP.
  local assets="$ROOT/cores/assets/PPSSPP"
  rm -rf "$assets"; mkdir -p "$assets"
  for f in compat.ini compatvr.ini langregion.ini knownfuncs.ini redump.csv \
           ppge_atlas.zim ppge_atlas.meta flash0 vfpu; do
    cp -R "$SRC/ppsspp/assets/$f" "$assets/"
  done
  echo "       fichiers PPSSPP : $(du -sh "$assets" | cut -f1 | tr -d ' ')"
}

i=0
for core in $CORES; do
  i=$((i + 1))
  rm -f "$LOGS/$core-ios.log"
  start=$SECONDS
  printf "[%d/%d] %-13s " $i ${#CORES} "$core"
  build_$core
  echo "       ($((SECONDS - start)) s)"
done
echo ""
echo "=== MOTEURS iOS OK ==="
ls "$OUT"
