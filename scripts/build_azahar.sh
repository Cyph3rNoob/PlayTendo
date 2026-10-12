#!/bin/zsh
# Compile le moteur 3DS de PlayTendo (Azahar 2126.1.2, version libretro) et range MoltenVK (Vulkan traduit en
# Metal, dont le moteur a besoin pour dessiner) à côté :
#   scripts/build_azahar.sh       → cores/ios/azahar.framework + cores/ios/MoltenVK.framework (iPhone)
#   scripts/build_azahar.sh mac   → cores/mac/azahar.framework + cores/mac/MoltenVK.framework (app Mac : Apple
#                                   Silicon, macOS 14), et cores/macos/azahar.dylib pour le banc d'essai
# Le simulateur reprend les deux frameworks iPhone retagués par make_sim_cores.sh, comme les autres moteurs.
# Retouches d'Azahar : scripts/patch_azahar.py (turbo dans la réserve JIT de l'app, iPhone seulement). Longue la
# première fois (~1500 fichiers), ensuite seuls les fichiers modifiés sont recompilés.
# Journal complet : build/azahar-<plateforme>.log
set -e
setopt pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLATFORM="${1:-ios}"
case "$PLATFORM" in
  ios|mac) ;;
  *) echo "usage : $0 [ios|mac]"; exit 1 ;;
esac
SRC="$ROOT/sources/azahar"
BUILD="$SRC/build-playtendo-$PLATFORM"
OUT="$ROOT/cores/$PLATFORM"
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

if [ "$PLATFORM" = mac ] && [ ! -d "$ROOT/sources/MoltenVK-macos/MoltenVK" ]; then
  echo "!!! MoltenVK pour Mac absent : lancer d'abord scripts/fetch_sources.sh"
  exit 1
fi

python3 "$ROOT/scripts/patch_azahar.py" "$SRC"

mkdir -p "$ROOT/build"
echo "=== Préparation du projet ($PLATFORM) ==="
if [ "$PLATFORM" = mac ]; then
  # Mac : comme la version macOS officielle (.github/workflows/libretro.yml), Apple Silicon seulement, avec Ninja,
  # sans les avertissements bloquants, et seulement les bibliothèques incluses dans les sources (Homebrew ignoré :
  # son OpenSSL ou son zstd ne seraient pas dans l'app).
  cmake -S "$SRC" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_LIBRETRO=ON -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCITRA_USE_PRECOMPILED_HEADERS=OFF -DCITRA_WARNINGS_AS_ERRORS=OFF \
    "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local" > "$ROOT/build/azahar-cmake-mac.log" 2>&1 \
    || { echo "!!! ÉCHEC de la préparation — fin du journal :"; tail -30 "$ROOT/build/azahar-cmake-mac.log"; exit 1; }
else
  # Mêmes réglages que la version iOS officielle (.github/workflows/libretro.yml), avec Ninja, sans les avertissements
  # bloquants (le clang d'Xcode 26 en connaît de nouveaux).
  cmake -S "$SRC" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_LIBRETRO=ON -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_C_FLAGS=-DIOS -DCMAKE_CXX_FLAGS=-DIOS -DIOS=ON \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCITRA_USE_PRECOMPILED_HEADERS=OFF -DENABLE_OPT=OFF -DCITRA_WARNINGS_AS_ERRORS=OFF > "$ROOT/build/azahar-cmake.log" 2>&1 \
    || { echo "!!! ÉCHEC de la préparation — fin du journal :"; tail -30 "$ROOT/build/azahar-cmake.log"; exit 1; }
fi

LOG="$ROOT/build/azahar-$PLATFORM.log"
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

FW="$OUT/azahar.framework"
rm -rf "${FW:?}"
if [ "$PLATFORM" = mac ]; then
  # Mac : framework à Versions/A (format exigé par la signature), comme ceux de build_cores_macos.sh.
  mkdir -p "$FW/Versions/A/Resources"
  cp "$DYLIB" "$FW/Versions/A/azahar"
  install_name_tool -id "@rpath/azahar.framework/Versions/A/azahar" "$FW/Versions/A/azahar"
  strip -x "$FW/Versions/A/azahar"
  cat > "$FW/Versions/A/Resources/Info.plist" <<PLIST
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
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
  ln -s A "$FW/Versions/Current"
  ln -s Versions/Current/azahar "$FW/azahar"
  ln -s Versions/Current/Resources "$FW/Resources"
  # Banc d'essai (scripts/test) : le moteur seul.
  mkdir -p "$ROOT/cores/macos"
  cp "$FW/Versions/A/azahar" "$ROOT/cores/macos/azahar.dylib"

  # MoltenVK 1.4.2 (version Mac de l'archive officielle) : framework de l'xcframework dynamique, Apple Silicon seulement.
  MVK=$(find "$ROOT/sources/MoltenVK-macos/MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework" -maxdepth 2 \
    -name MoltenVK.framework -path "*macos*" | head -1)
  [ -n "$MVK" ] || { echo "!!! MoltenVK.framework (macOS) introuvable dans l'archive"; exit 1; }
  rm -rf "${OUT:?}/MoltenVK.framework"
  cp -R "$MVK" "$OUT/"
  BIN="$OUT/MoltenVK.framework/Versions/A/MoltenVK"
  if lipo -archs "$BIN" | grep -q x86_64; then lipo -thin arm64 "$BIN" -output "$BIN.arm64" && mv "$BIN.arm64" "$BIN"; fi
  # Signature locale : macOS refuse de charger une bibliothèque non signée (celle de l'archive ne l'est pas) ;
  # l'app les re-signe en les intégrant.
  codesign --force --sign - "$OUT/MoltenVK.framework" > /dev/null 2>&1
  codesign --force --sign - "$FW" > /dev/null 2>&1
  codesign --force --sign - "$ROOT/cores/macos/azahar.dylib" > /dev/null 2>&1
  echo "=== azahar.framework ($(du -sh "$FW" | cut -f1)) et MoltenVK.framework ($(du -sh "$OUT/MoltenVK.framework" | cut -f1)) prêts en $((SECONDS / 60)) min ==="
  exit 0
fi

# Framework du moteur (même forme que ceux de build_cores.sh).
mkdir -p "$FW"
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
