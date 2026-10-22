#!/bin/zsh
# Compile le moteur GameCube/Wii de PlayTendo (DolphinCore.framework) à partir de DolphiniOS 5.0.0b6
# (sources/dolphin-ios) : le cœur Dolphin et son pilote dolphin/PTDolphinHost.mm, sans l'interface de DolphiniOS.
#   scripts/build_dolphin.sh sim   → cores/sim/DolphinCore.framework (simulateur)
#   scripts/build_dolphin.sh ios   → cores/ios/DolphinCore.framework (iPhone)
#   scripts/build_dolphin.sh mac   → cores/mac/DolphinCore.framework (app Mac : Apple Silicon, macOS 14)
# Toujours en Release (Dolphin en Debug est beaucoup trop lent). Longue la première fois (~1300 fichiers),
# ensuite seuls les fichiers modifiés sont recompilés. Journal complet : build/dolphin-<plateforme>.log
set -e
setopt pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLATFORM="${1:-sim}"
SRC="$ROOT/sources/dolphin-ios"
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

case "$PLATFORM" in
  sim) TOOLCHAIN_PLATFORM=SIMULATORARM64 ;;
  ios) TOOLCHAIN_PLATFORM=OS64 ;;
  mac) ;;
  *) echo "usage : $0 sim|ios|mac"; exit 1 ;;
esac
BUILD="$SRC/build-playtendo-$PLATFORM"

python3 "$ROOT/scripts/patch_dolphin.py" "$SRC"

echo "=== Préparation du projet ($PLATFORM) ==="
# Mêmes réglages que DolphiniOS (Source/iOS/App/Project/Scripts/BuildCore.sh), plus le pilote de PlayTendo.
# FMT_CONSTEVAL vide : fmt 10.2.1 (Externals) ne compile pas avec le clang d'Xcode 26 (« call to consteval
# function … is not a constant expression » dans chrono.h) ; seules les vérifications à la compilation des
# chaînes de format sautent, le résultat est le même.
# Seules les fonctions PTDolphin* (cherchées par l'app avec dlsym) restent visibles : le lieur retire le code jamais
# appelé (-dead_strip) et la table des 21 000 symboles publics. Moteur plus léger, même comportement. En _RELEASE :
# la chaîne d'outils iOS écrase CMAKE_SHARED_LINKER_FLAGS (rpath).
DOLPHIN_LINK="-Wl,-exported_symbols_list,$ROOT/dolphin/DolphinCore.exports -Wl,-dead_strip"
if [ "$PLATFORM" = mac ]; then
  # Mac : le Dolphin d'origine pour macOS (Metal, son Cubeb, turbo MAP_JIT), sans son interface Qt ni rien qui
  # demanderait un téléchargement (Vulkan/MoltenVK, SDL, FFmpeg, LLVM) ; seulement les bibliothèques incluses
  # (Homebrew ignoré). Retouches « Mac » de patch_dolphin.py : bibliothèque de DolphiniOS et ses commandes.
  cmake -S "$SRC" -B "$BUILD" -G Ninja \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS="-fPIC -DFMT_CONSTEVAL=" -DENABLE_ANALYTICS=NO \
    -DUSE_SYSTEM_LIBS=OFF -DENABLE_TESTS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DENABLE_QT=OFF -DENABLE_NOGUI=OFF -DENABLE_CLI_TOOL=OFF -DENABLE_VULKAN=OFF -DENABLE_SDL=OFF \
    -DENABLE_LLVM=OFF -DENCODE_FRAMEDUMPS=OFF -DUSE_UPNP=OFF -DUSE_DISCORD_PRESENCE=OFF -DENABLE_AUTOUPDATE=OFF \
    "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local" \
    -DPLAYTENDO_DOLPHIN_HOST="$ROOT/dolphin/PTDolphinHost.mm" \
    -DCMAKE_SHARED_LINKER_FLAGS= "-DCMAKE_SHARED_LINKER_FLAGS_RELEASE=$DOLPHIN_LINK" \
    -DPLAYTENDO_INCLUDE="$ROOT/app/PlayTendo/Emulation" > /dev/null
else
  cmake -S "$SRC" -B "$BUILD" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$SRC/Externals/ios-cmake/ios.toolchain.cmake" -DPLATFORM=$TOOLCHAIN_PLATFORM \
    -DDEPLOYMENT_TARGET=14.0 -DENABLE_VISIBILITY=ON -DENABLE_BITCODE=OFF -DENABLE_ARC=ON \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS="-fPIC -DFMT_CONSTEVAL=" -DIOS=ON -DENABLE_ANALYTICS=NO \
    -DUSE_SYSTEM_LIBS=OFF -DENABLE_TESTS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DPLAYTENDO_DOLPHIN_HOST="$ROOT/dolphin/PTDolphinHost.mm" \
    -DCMAKE_SHARED_LINKER_FLAGS= "-DCMAKE_SHARED_LINKER_FLAGS_RELEASE=$DOLPHIN_LINK" \
    -DPLAYTENDO_INCLUDE="$ROOT/app/PlayTendo/Emulation" > /dev/null
fi

mkdir -p "$ROOT/build"
LOG="$ROOT/build/dolphin-$PLATFORM.log"
echo "=== Compilation (journal : $LOG) ==="
SECONDS=0
# Ninja affiche « [n/total] » : on garde cette progression sur une seule ligne.
if ! ninja -C "$BUILD" dolphin 2>&1 | tee "$LOG" | while IFS= read -r line; do
  case "$line" in
    \[*/*\]*)
      printf "\r  %s fichiers — %d min %02d s   " "${${line%%\]*}#\[}" $((SECONDS / 60)) $((SECONDS % 60)) ;;
    *"error:"*|FAILED*) printf "\n%s\n" "$line" ;;
  esac
done; then
  echo ""
  echo "!!! ÉCHEC de la compilation — erreurs :"
  grep -E "error:" "$LOG" | sort -u | head -20
  exit 1
fi
echo ""

# Framework : la bibliothèque du cœur + le dossier Sys de Dolphin (sans les thèmes de l'interface Qt).
OUT="$ROOT/cores/$PLATFORM/DolphinCore.framework"
rm -rf "${OUT:?}"
if [ "$PLATFORM" = mac ]; then
  # Mac : framework à Versions/A (format exigé par la signature), Sys dans ses ressources (retouche de FileUtil.cpp).
  mkdir -p "$OUT/Versions/A/Resources"
  cp "$BUILD/Source/iOS/Library/libdolphin.dylib" "$OUT/Versions/A/DolphinCore"
  install_name_tool -id @rpath/DolphinCore.framework/Versions/A/DolphinCore "$OUT/Versions/A/DolphinCore"
  rsync -a --exclude Themes "$SRC/Data/Sys/" "$OUT/Versions/A/Resources/Sys/"
  cat > "$OUT/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>DolphinCore</string>
  <key>CFBundleIdentifier</key><string>com.playtendo.dolphincore</string>
  <key>CFBundleName</key><string>DolphinCore</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>5.0.0b6</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
  ln -s A "$OUT/Versions/Current"
  ln -s Versions/Current/DolphinCore "$OUT/DolphinCore"
  ln -s Versions/Current/Resources "$OUT/Resources"
  codesign --force --sign - "$OUT" > /dev/null 2>&1
  echo "=== DolphinCore.framework prêt : $(du -sh "$OUT" | cut -f1) en $((SECONDS / 60)) min ==="
  exit 0
fi
mkdir -p "$OUT"
cp "$BUILD/Source/iOS/Library/libdolphin.dylib" "$OUT/DolphinCore"
install_name_tool -id @rpath/DolphinCore.framework/DolphinCore "$OUT/DolphinCore"
rsync -a --exclude Themes "$SRC/Data/Sys/" "$OUT/Sys/"
cat > "$OUT/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>DolphinCore</string>
  <key>CFBundleIdentifier</key><string>com.playtendo.dolphincore</string>
  <key>CFBundleName</key><string>DolphinCore</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>5.0.0b6</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
if [ "$PLATFORM" = sim ]; then
  codesign --force --sign - "$OUT" > /dev/null 2>&1
fi
echo "=== DolphinCore.framework prêt : $(du -sh "$OUT" | cut -f1) en $((SECONDS / 60)) min ==="
