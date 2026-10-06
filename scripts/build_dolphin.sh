#!/bin/zsh
# Compile le moteur GameCube/Wii de PlayTendo (DolphinCore.framework) à partir de DolphiniOS 5.0.0b6
# (sources/dolphin-ios) : le cœur Dolphin et son pilote dolphin/PTDolphinHost.mm, sans l'interface de DolphiniOS.
#   scripts/build_dolphin.sh sim   → cores/sim/DolphinCore.framework (simulateur)
#   scripts/build_dolphin.sh ios   → cores/ios/DolphinCore.framework (iPhone)
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
  *) echo "usage : $0 sim|ios"; exit 1 ;;
esac
BUILD="$SRC/build-playtendo-$PLATFORM"

python3 "$ROOT/scripts/patch_dolphin.py" "$SRC"

echo "=== Préparation du projet ($PLATFORM) ==="
# Mêmes réglages que DolphiniOS (Source/iOS/App/Project/Scripts/BuildCore.sh), plus le pilote de PlayTendo.
# FMT_CONSTEVAL vide : fmt 10.2.1 (Externals) ne compile pas avec le clang d'Xcode 26 (« call to consteval
# function … is not a constant expression » dans chrono.h) ; seules les vérifications à la compilation des
# chaînes de format sautent, le résultat est le même.
cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$SRC/Externals/ios-cmake/ios.toolchain.cmake" -DPLATFORM=$TOOLCHAIN_PLATFORM \
  -DDEPLOYMENT_TARGET=14.0 -DENABLE_VISIBILITY=ON -DENABLE_BITCODE=OFF -DENABLE_ARC=ON \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS="-fPIC -DFMT_CONSTEVAL=" -DIOS=ON -DENABLE_ANALYTICS=NO \
  -DUSE_SYSTEM_LIBS=OFF -DENABLE_TESTS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DPLAYTENDO_DOLPHIN_HOST="$ROOT/dolphin/PTDolphinHost.mm" \
  -DPLAYTENDO_INCLUDE="$ROOT/app/PlayTendo/Emulation" > /dev/null

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
rm -rf "$OUT"
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
