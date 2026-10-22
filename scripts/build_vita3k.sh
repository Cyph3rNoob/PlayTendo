#!/bin/zsh
# Compile le moteur PS Vita de PlayTendo (Vita3K build 4135, sources/vita3k) : le cœur de Vita3K et son pilote
# (vita/PTVitaHost.cpp, PTVitaView.mm), sans l'interface de Vita3K.
#   zsh scripts/build_vita3k.sh       → iPhone : cores/ios/VitaCore.framework
#   zsh scripts/build_vita3k.sh mac   → Mac (Apple Silicon) : cores/mac/VitaCore.framework
# Le rendu passe par Vulkan, donc par le MoltenVK.framework de l'app (celui de la 3DS) : pas de version simulateur
# (MoltenVK y plante).
# Étapes : retouches (scripts/patch_vita3k.py), OpenSSL 4.0.3 (sources/openssl → build/openssl-ios ou openssl-mac, une
# seule fois), puis Vita3K. La première préparation du projet télécharge le FFmpeg précompilé par l'équipe Vita3K
# (ffmpeg-core, 9,8 Mo pour iPhone, 9,9 Mo pour Mac), gardé ensuite dans le dossier de compilation. Longue la première
# fois, ensuite seuls les fichiers modifiés sont recompilés.
# Journaux complets : build/openssl-<plateforme>.log, build/vita3k-cmake[-mac].log, build/vita3k-<plateforme>.log
set -e
setopt pipefail
PLATFORM="${1:-ios}"
case "$PLATFORM" in
  ios|mac) ;;
  *) echo "Usage : zsh scripts/build_vita3k.sh [ios|mac]"; exit 1 ;;
esac
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/sources/vita3k"
BUILD="$SRC/build-playtendo-$PLATFORM"
OSSL_SRC="$ROOT/sources/openssl"
OSSL_BUILD="$ROOT/build/openssl-$PLATFORM-build"
OSSL_OUT="$ROOT/build/openssl-$PLATFORM"
IOS_MIN=18.0
MAC_MIN=14.0
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
mkdir -p "$ROOT/build"
SECONDS=0

if [ "$PLATFORM" = mac ] && [ ! -d "$ROOT/sources/MoltenVK-macos/MoltenVK" ]; then
  echo "!!! MoltenVK pour Mac absent : lancer d'abord scripts/fetch_sources.sh"
  exit 1
fi

python3 "$ROOT/scripts/patch_vita3k.py" "$SRC"

# OpenSSL : bibliothèques statiques (arm64), sans programmes, tests ni documentation.
if [ ! -f "$OSSL_OUT/lib/libcrypto.a" ] || [ ! -f "$OSSL_OUT/lib/libssl.a" ]; then
  if [ "$PLATFORM" = mac ]; then
    echo "=== OpenSSL pour Mac (journal : build/openssl-mac.log) ==="
    OSSL_TARGET=(darwin64-arm64-cc -mmacosx-version-min=$MAC_MIN)
  else
    echo "=== OpenSSL pour iPhone (journal : build/openssl-ios.log) ==="
    OSSL_TARGET=(ios64-xcrun -mios-version-min=$IOS_MIN)
  fi
  rm -rf "${OSSL_BUILD:?}" "${OSSL_OUT:?}"
  mkdir -p "$OSSL_BUILD"
  (
    cd "$OSSL_BUILD"
    perl "$OSSL_SRC/Configure" "${OSSL_TARGET[1]}" no-shared no-tests no-apps no-docs no-ui-console no-dso no-module \
      --prefix="$OSSL_OUT" --openssldir="$OSSL_OUT/ssl" "${OSSL_TARGET[2]}"
    make -j"$(sysctl -n hw.ncpu)" build_libs
    make install_dev
  ) > "$ROOT/build/openssl-$PLATFORM.log" 2>&1 \
    || { echo "!!! ÉCHEC d'OpenSSL — fin du journal :"; tail -30 "$ROOT/build/openssl-$PLATFORM.log"; exit 1; }
  # Seules les bibliothèques installées servent : le dossier de compilation est effacé.
  rm -rf "${OSSL_BUILD:?}"
  echo "OK  OpenSSL prêt en $((SECONDS / 60)) min $((SECONDS % 60)) s"
fi

echo "=== Préparation du projet ($PLATFORM) ==="
# Sans Discord (module non libre) ; SDL intégré au moteur (pas de bibliothèque à part) ; capstone pour arm64
# seulement (il viserait aussi les Mac Intel) ; cubeb sans sortie AudioUnit : le son passe par SDL. PLAYTENDO : les
# retouches de patch_vita3k.py (bibliothèque sans Qt, OpenSSL et MoltenVK fournis ici).
# Seules les fonctions PTVita* (cherchées par l'app avec dlsym) restent visibles : le lieur retire alors tout le code
# jamais appelé (-dead_strip) et la table des 66 000 symboles publics. Moteur bien plus léger, même comportement.
COMMON=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  "-DCMAKE_SHARED_LINKER_FLAGS=-Wl,-exported_symbols_list,$ROOT/vita/VitaCore.exports -Wl,-dead_strip"
  -DPLAYTENDO=ON -DUSE_DISCORD_RICH_PRESENCE=OFF -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST_LIBRARY=OFF -DSDL_EXAMPLES=OFF
  -DCAPSTONE_BUILD_MACOS_THIN=ON -DUSE_AUDIOUNIT=OFF
  -DPLAYTENDO_OPENSSL="$OSSL_OUT"
  -DPLAYTENDO_VITA_HOST="$ROOT/vita/PTVitaHost.cpp" -DPLAYTENDO_VITA_VIEW="$ROOT/vita/PTVitaView.mm"
  -DPLAYTENDO_INCLUDE="$ROOT/app/PlayTendo/Emulation")
if [ "$PLATFORM" = mac ]; then
  # Mac : seulement les bibliothèques incluses dans les sources (Homebrew ignoré : ses bibliothèques ne seraient pas
  # dans l'app), comme pour la 3DS.
  CMAKE_LOG="$ROOT/build/vita3k-cmake-mac.log"
  cmake -S "$SRC" -B "$BUILD" "${COMMON[@]}" -DCMAKE_OSX_DEPLOYMENT_TARGET=$MAC_MIN \
    -DPLAYTENDO_MOLTENVK_INCLUDE="$ROOT/sources/MoltenVK-macos/MoltenVK/MoltenVK/include" \
    "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local" > "$CMAKE_LOG" 2>&1 \
    || { echo "!!! ÉCHEC de la préparation — fin du journal :"; tail -30 "$CMAKE_LOG"; exit 1; }
else
  CMAKE_LOG="$ROOT/build/vita3k-cmake.log"
  cmake -S "$SRC" -B "$BUILD" "${COMMON[@]}" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_MIN \
    -DPLAYTENDO_MOLTENVK_INCLUDE="$ROOT/sources/MoltenVK/MoltenVK/MoltenVK/include" > "$CMAKE_LOG" 2>&1 \
    || { echo "!!! ÉCHEC de la préparation — fin du journal :"; tail -30 "$CMAKE_LOG"; exit 1; }
fi

LOG="$ROOT/build/vita3k-$PLATFORM.log"
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

# Framework : la bibliothèque + les fichiers fixes que Vita3K lit (shaders de l'affichage, icônes, données). Sur Mac,
# au format Versions/A exigé par la signature : les fichiers fixes vont dans Resources (PTVitaEngine.m les y cherche).
if [ "$PLATFORM" = mac ]; then
  OUT="$ROOT/cores/mac/VitaCore.framework"
  BIN="$OUT/Versions/A/VitaCore"
  RES="$OUT/Versions/A/Resources"
  INSTALL_NAME=@rpath/VitaCore.framework/Versions/A/VitaCore
  PLIST_PLATFORM='<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>'
  PLIST_MIN="<key>LSMinimumSystemVersion</key><string>$MAC_MIN</string>"
else
  OUT="$ROOT/cores/ios/VitaCore.framework"
  BIN="$OUT/VitaCore"
  RES="$OUT"
  INSTALL_NAME=@rpath/VitaCore.framework/VitaCore
  PLIST_PLATFORM='<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>'
  PLIST_MIN="<key>MinimumOSVersion</key><string>$IOS_MIN</string>"
fi
rm -rf "${OUT:?}"
mkdir -p "$RES"
cp "$DYLIB" "$BIN"
install_name_tool -id "$INSTALL_NAME" "$BIN"
strip -x "$BIN"
rsync -a "$SRC/data/" "$RES/data/"
rsync -a "$SRC/vita3k/shaders-builtin/" "$RES/shaders-builtin/"
rsync -a "$SRC/vita3k/icons/" "$RES/icons/"
cat > "$RES/Info.plist" <<PLIST
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
  $PLIST_PLATFORM
  $PLIST_MIN
</dict>
</plist>
PLIST
if [ "$PLATFORM" = mac ]; then
  ln -s A "$OUT/Versions/Current"
  ln -s Versions/Current/VitaCore "$OUT/VitaCore"
  ln -s Versions/Current/Resources "$OUT/Resources"
  # Signature locale : macOS refuse de charger une bibliothèque non signée.
  codesign --force --sign - "$OUT" > /dev/null 2>&1
fi
echo "=== VitaCore.framework ($PLATFORM) prêt : $(du -sh "$OUT" | cut -f1) en $((SECONDS / 60)) min ==="
