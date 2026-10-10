#!/bin/zsh
# Compile le moteur 3DS de PlayTendo (Azahar 2126.1.2, version libretro) pour iPhone → cores/ios/azahar.framework, et
# range MoltenVK (Vulkan traduit en Metal, dont le moteur a besoin pour dessiner) → cores/ios/MoltenVK.framework.
# Le simulateur reprend ces deux frameworks retagués par make_sim_cores.sh, comme les autres moteurs.
# Retouches d'Azahar : scripts/patch_azahar.py (turbo dans la réserve JIT de l'app). Longue la première fois
# (~1500 fichiers), ensuite seuls les fichiers modifiés sont recompilés. Journal complet : build/azahar-ios.log
set -e
setopt pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/sources/azahar"
BUILD="$SRC/build-playtendo-ios"
OUT="$ROOT/cores/ios"
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

python3 "$ROOT/scripts/patch_azahar.py" "$SRC"

echo "=== Préparation du projet ==="
# Mêmes réglages que la version iOS officielle (.github/workflows/libretro.yml), avec Ninja, sans les avertissements
# bloquants (le clang d'Xcode 26 en connaît de nouveaux).
cmake -S "$SRC" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_LIBRETRO=ON -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_C_FLAGS=-DIOS -DCMAKE_CXX_FLAGS=-DIOS -DIOS=ON \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCITRA_USE_PRECOMPILED_HEADERS=OFF -DENABLE_OPT=OFF -DCITRA_WARNINGS_AS_ERRORS=OFF > "$ROOT/build/azahar-cmake.log" 2>&1 \
  || { echo "!!! ÉCHEC de la préparation — fin du journal :"; tail -30 "$ROOT/build/azahar-cmake.log"; exit 1; }

mkdir -p "$ROOT/build"
LOG="$ROOT/build/azahar-ios.log"
echo "=== Compilation (journal : $LOG) ==="
SECONDS=0
# Ninja affiche « [n/total] » : on garde cette progression sur une seule ligne.
if ! ninja -C "$BUILD" citra_libretro 2>&1 | tee "$LOG" | while IFS= read -r line; do
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

DYLIB=$(find "$BUILD" -name "azahar_libretro.dylib" -type f | head -1)
[ -n "$DYLIB" ] || { echo "!!! azahar_libretro.dylib introuvable"; exit 1; }

# Framework du moteur (même forme que ceux de build_cores.sh).
FW="$OUT/azahar.framework"
rm -rf "${FW:?}"; mkdir -p "$FW"
cp "$DYLIB" "$FW/azahar"
install_name_tool -id "@rpath/azahar.framework/azahar" "$FW/azahar"
strip -x "$FW/azahar"
cat > "$FW/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>azahar</string>
  <key>CFBundleIdentifier</key><string>com.playtendo.core.azahar</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>azahar</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>2126.1.2</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
  <key>MinimumOSVersion</key><string>14.0</string>
</dict>
</plist>
PLIST

# MoltenVK 1.4.2 (version iPhone de l'archive officielle).
rm -rf "${OUT:?}/MoltenVK.framework"
cp -R "$ROOT/sources/MoltenVK/MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework/ios-arm64/MoltenVK.framework" "$OUT/"
echo "=== azahar.framework ($(du -sh "$FW" | cut -f1)) et MoltenVK.framework ($(du -sh "$OUT/MoltenVK.framework" | cut -f1)) prêts en $((SECONDS / 60)) min ==="
