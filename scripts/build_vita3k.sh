#!/bin/zsh
# Compile le moteur PS Vita de PlayTendo (Vita3K build 4135, sources/vita3k) pour iPhone → cores/ios/VitaCore.framework :
# le cœur de Vita3K et son pilote (vita/PTVitaHost.cpp, PTVitaView.mm), sans l'interface de Vita3K. Le rendu passe par Vulkan, donc par
# le MoltenVK.framework de l'app (celui de la 3DS) : pas de version simulateur (MoltenVK y plante).
# Étapes : retouches (scripts/patch_vita3k.py), OpenSSL 4.0.3 pour iPhone (sources/openssl → build/openssl-ios, une
# seule fois), puis Vita3K. La préparation du projet télécharge le FFmpeg pour iPhone précompilé par l'équipe Vita3K
# (ffmpeg-core, 9,8 Mo). Longue la première fois, ensuite seuls les fichiers modifiés sont recompilés.
# Journaux complets : build/openssl-ios.log, build/vita3k-cmake.log, build/vita3k-ios.log
set -e
setopt pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/sources/vita3k"
BUILD="$SRC/build-playtendo-ios"
OSSL_SRC="$ROOT/sources/openssl"
OSSL_BUILD="$ROOT/build/openssl-ios-build"
OSSL_OUT="$ROOT/build/openssl-ios"
IOS_MIN=18.0
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
mkdir -p "$ROOT/build"
SECONDS=0

python3 "$ROOT/scripts/patch_vita3k.py" "$SRC"

# OpenSSL : bibliothèques statiques pour iPhone (arm64), sans programmes, tests ni documentation.
if [ ! -f "$OSSL_OUT/lib/libcrypto.a" ] || [ ! -f "$OSSL_OUT/lib/libssl.a" ]; then
  echo "=== OpenSSL pour iPhone (journal : build/openssl-ios.log) ==="
  rm -rf "$OSSL_BUILD" "$OSSL_OUT"
  mkdir -p "$OSSL_BUILD"
  (
    cd "$OSSL_BUILD"
    perl "$OSSL_SRC/Configure" ios64-xcrun no-shared no-tests no-apps no-docs no-ui-console no-dso no-module \
      --prefix="$OSSL_OUT" --openssldir="$OSSL_OUT/ssl" -mios-version-min=$IOS_MIN
    make -j"$(sysctl -n hw.ncpu)" build_libs
    make install_dev
  ) > "$ROOT/build/openssl-ios.log" 2>&1 \
    || { echo "!!! ÉCHEC d'OpenSSL — fin du journal :"; tail -30 "$ROOT/build/openssl-ios.log"; exit 1; }
  echo "OK  OpenSSL prêt en $((SECONDS / 60)) min $((SECONDS % 60)) s"
fi

echo "=== Préparation du projet ==="
# Sans Discord (module non libre) ; SDL intégré au moteur (pas de bibliothèque à part) ; capstone pour arm64
# seulement (il viserait aussi les Mac Intel) ; cubeb sans sortie AudioUnit (celle-ci est faite pour macOS) : le son
# passe par SDL.
cmake -S "$SRC" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_MIN -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DUSE_DISCORD_RICH_PRESENCE=OFF -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST_LIBRARY=OFF -DSDL_EXAMPLES=OFF \
  -DCAPSTONE_BUILD_MACOS_THIN=ON -DUSE_AUDIOUNIT=OFF \
  -DPLAYTENDO_OPENSSL="$OSSL_OUT" \
  -DPLAYTENDO_MOLTENVK_INCLUDE="$ROOT/sources/MoltenVK/MoltenVK/MoltenVK/include" \
  -DPLAYTENDO_VITA_HOST="$ROOT/vita/PTVitaHost.cpp" -DPLAYTENDO_VITA_VIEW="$ROOT/vita/PTVitaView.mm" \
  -DPLAYTENDO_INCLUDE="$ROOT/app/PlayTendo/Emulation" > "$ROOT/build/vita3k-cmake.log" 2>&1 \
  || { echo "!!! ÉCHEC de la préparation — fin du journal :"; tail -30 "$ROOT/build/vita3k-cmake.log"; exit 1; }

LOG="$ROOT/build/vita3k-ios.log"
echo "=== Compilation (journal : $LOG) ==="
# Ninja affiche « [n/total] » : on garde cette progression sur une seule ligne.
if ! ninja -C "$BUILD" -k 0 vita3k 2>&1 | tee "$LOG" | while IFS= read -r line; do
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

DYLIB="$BUILD/lib/libVita3K.dylib"
[ -f "$DYLIB" ] || DYLIB=$(find "$BUILD" -name "libVita3K.dylib" -type f | head -1)
[ -n "$DYLIB" ] && [ -f "$DYLIB" ] || { echo "!!! libVita3K.dylib introuvable"; exit 1; }

# Framework : la bibliothèque + les fichiers fixes que Vita3K lit (shaders de l'affichage, icônes, données).
OUT="$ROOT/cores/ios/VitaCore.framework"
rm -rf "$OUT"
mkdir -p "$OUT"
cp "$DYLIB" "$OUT/VitaCore"
install_name_tool -id @rpath/VitaCore.framework/VitaCore "$OUT/VitaCore"
strip -x "$OUT/VitaCore"
rsync -a "$SRC/data/" "$OUT/data/"
rsync -a "$SRC/vita3k/shaders-builtin/" "$OUT/shaders-builtin/"
rsync -a "$SRC/vita3k/icons/" "$OUT/icons/"
cat > "$OUT/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>VitaCore</string>
  <key>CFBundleIdentifier</key><string>com.playtendo.vitacore</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>VitaCore</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>0.2.1-4135</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
  <key>MinimumOSVersion</key><string>$IOS_MIN</string>
</dict>
</plist>
PLIST
echo "=== VitaCore.framework prêt : $(du -sh "$OUT" | cut -f1) en $((SECONDS / 60)) min ==="
