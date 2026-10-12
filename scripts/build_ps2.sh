#!/bin/zsh
# Compile le moteur PS2 de PlayTendo (PS2Core.framework) à partir d'ARMSX2 iOS 2.6.0 (sources/armsx2).
#   scripts/build_ps2.sh sim [Debug|Release]   → cores/sim/PS2Core.framework (simulateur, Debug par défaut)
#   scripts/build_ps2.sh ios                    → cores/ios/PS2Core.framework (iPhone, Release)
#   scripts/build_ps2.sh mac                    → cores/mac/PS2Core.framework (app Mac : cœur PCSX2 + ps2/PTPS2HostMac.mm)
# Le cœur PS2 (PCSX2, ~1650 fichiers) est long à compiler la première fois (20 à 30 min) ; ensuite
# seuls les fichiers modifiés sont recompilés. Journal complet : build/ps2-<plateforme>-<config>.log
set -e
setopt pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLATFORM="${1:-sim}"
SRC="$ROOT/sources/armsx2"
CPP="$SRC/platforms/ios/app/src/main/cpp"

case "$PLATFORM" in
  sim)
    CONFIG="${2:-Debug}"
    SDK=iphonesimulator
    BUILD="$SRC/platforms/ios/build-ios-sim-xcode"
    EXTRA=(-DCMAKE_OSX_SYSROOT=iphonesimulator -DARMSX2_REAL_DEVICE=OFF)
    ;;
  ios)
    CONFIG="${2:-Release}"
    SDK=iphoneos
    BUILD="$SRC/platforms/ios/build-ios-xcode"
    EXTRA=(-DARMSX2_REAL_DEVICE=ON -DLTO_PCSX2_CORE=ON -DARMSX2_ENABLE_JIT_ENTITLEMENTS=OFF)
    ;;
  mac) CONFIG=Release ;;
  *) echo "usage : $0 sim|ios|mac [Debug|Release]"; exit 1 ;;
esac

python3 "$ROOT/scripts/patch_armsx2.py" "$SRC"

if [ "$PLATFORM" = mac ]; then
  # Mac : le cœur PCSX2 d'ARMSX2 (déjà prévu pour macOS : Metal, Cocoa, recompilateurs ARM64) sans sa couche iOS, avec
  # le pilote ps2/PTPS2HostMac.mm ; dépendances compilées depuis les copies d'ARMSX2 (Homebrew ignoré), curl et
  # libpcap du SDK de macOS ; sans Vulkan, OpenGL, Qt ni librashader (Rust absent). Ninja, Release.
  BUILD="$SRC/platforms/ios/build-mac"
  export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
  echo "=== Préparation du projet (mac) ==="
  cmake -S "$CPP" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_OSX_SYSROOT="$(xcrun --sdk macosx --show-sdk-path)" \
    -DUSE_VULKAN=OFF -DUSE_OPENGL=OFF -DENABLE_QT_UI=OFF -DENABLE_TESTS=OFF -DENABLE_GSRUNNER=OFF \
    "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local" \
    -DPLAYTENDO_PS2_MAC=ON -DPLAYTENDO_PS2_HOST="$ROOT/ps2/PTPS2HostMac.mm" \
    -DPLAYTENDO_INCLUDE="$ROOT/app/PlayTendo/Emulation" > "$ROOT/build/logs/ps2-mac-cmake.log" 2>&1 \
    || { echo "!!! ÉCHEC de la préparation — fin du journal :"; tail -20 "$ROOT/build/logs/ps2-mac-cmake.log"; exit 1; }
  LOG="$ROOT/build/ps2-mac-Release.log"
  echo "=== Compilation (journal : $LOG) ==="
  SECONDS=0
  if ! ninja -C "$BUILD" PS2Core 2>&1 | tee "$LOG" | while IFS= read -r line; do
    case "$line" in
      \[*/*\]*) printf "\r  %s fichiers — %d min %02d s   " "${${line%%\]*}#\[}" $((SECONDS / 60)) $((SECONDS % 60)) ;;
      *"error:"*|FAILED*) printf "\n%s\n" "$line" ;;
    esac
  done; then
    echo ""
    echo "!!! ÉCHEC de la compilation — erreurs :"
    grep -E "error:|Undefined symbols|referenced from" "$LOG" | sort -u | head -30
    exit 1
  fi
  echo ""

  # Shaders Metal (comme PCSX2 pour Mac : Metal 2.3, macOS 11) → Metal23.metallib, cherché dans les ressources du moteur.
  echo "=== Shaders Metal ==="
  AIR="$BUILD/metal-air"
  rm -rf "${AIR:?}" && mkdir -p "$AIR"
  for shader in "$SRC"/pcsx2/GS/Renderers/Metal/*.metal; do
    xcrun -sdk macosx metal -ffast-math -std=macos-metal2.3 -target air64-apple-macos11.0 \
      -o "$AIR/$(basename "$shader" .metal).air" -c "$shader"
  done
  xcrun -sdk macosx metallib -o "$BUILD/Metal23.metallib" "$AIR"/*.air

  # Framework Mac (Versions/A) : la bibliothèque, ses shaders et les fichiers du moteur (bin/resources d'ARMSX2, comme
  # sur iPhone : base des jeux, polices, sons, shaders de post-traitement sans ceux de DirectX, correctifs 16:9).
  OUT="$ROOT/cores/mac/PS2Core.framework"
  RES="$OUT/Versions/A/Resources"
  rm -rf "${OUT:?}"
  mkdir -p "$RES"
  cp "$BUILD/libPS2Core.dylib" "$OUT/Versions/A/PS2Core"
  install_name_tool -id @rpath/PS2Core.framework/Versions/A/PS2Core "$OUT/Versions/A/PS2Core"
  cp "$BUILD/Metal23.metallib" "$RES/"
  SHARED="$SRC/bin/resources"
  rsync -a --exclude dx11 "$SHARED/shaders" "$SHARED/fonts" "$SHARED/sounds" "$RES/"
  cp "$SHARED/GameIndex.yaml" "$SHARED/RedumpDatabase.yaml" "$SHARED/game_controller_db.txt" \
    "$SRC/bin/resources-overlay/armsx2_overrides.yaml" "$CPP/../assets/resources/patches.zip" "$RES/"
  cat > "$RES/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>PS2Core</string>
  <key>CFBundleIdentifier</key><string>com.playtendo.ps2core</string>
  <key>CFBundleName</key><string>PS2Core</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>2.6.0</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>CFBundleVersion</key><string>260</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
  ln -s A "$OUT/Versions/Current"
  ln -s Versions/Current/PS2Core "$OUT/PS2Core"
  ln -s Versions/Current/Resources "$OUT/Resources"
  codesign --force --sign - "$OUT" > /dev/null 2>&1
  echo "=== PS2Core.framework prêt : $(du -sh "$OUT" | cut -f1) en $((SECONDS / 60)) min ==="
  exit 0
fi

echo "=== Préparation du projet ($PLATFORM, $CONFIG) ==="
CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
cmake -S "$CPP" -B "$BUILD" -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO \
  "${EXTRA[@]}" \
  -DPLAYTENDO_PS2CORE=ON \
  -DPLAYTENDO_PS2_HOST="$ROOT/ps2/PTPS2Host.mm" \
  -DPLAYTENDO_INCLUDE="$ROOT/app/PlayTendo/Emulation" > /dev/null

mkdir -p "$ROOT/build"
LOG="$ROOT/build/ps2-$PLATFORM-$CONFIG.log"
echo "=== Compilation (journal : $LOG) ==="
SECONDS=0
n=0
xcodebuild -project "$BUILD/ARMSX2iOS.xcodeproj" -scheme ARMSX2iOS -configuration "$CONFIG" -sdk "$SDK" \
  -derivedDataPath "$BUILD/DerivedData" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build 2>&1 \
  | tee "$LOG" \
  | while IFS= read -r line; do
      case "$line" in
        CompileC*|CompileMetalFile*|"Ld "*|Libtool*|MetalLink*)
          n=$((n + 1))
          printf "\r  %4d fichiers compilés (sur ~1650 la première fois) — %d min %02d s   " \
            $n $((SECONDS / 60)) $((SECONDS % 60)) ;;
        *" error: "*) printf "\n%s\n" "$line" ;;
      esac
    done
echo ""

FW="$BUILD/$CONFIG-$SDK/PS2Core.framework"
OUT="$ROOT/cores/$PLATFORM/PS2Core.framework"
rm -rf "${OUT:?}"
mkdir -p "$(dirname "$OUT")"
cp -R "$FW" "$OUT"
# Le moteur cherche « Metal23.metallib » dans son dossier avant tout « default.metallib » : sous ce nom,
# il ne risque pas de prendre les shaders de PlayTendo (default.metallib de l'app).
mv "$OUT/default.metallib" "$OUT/Metal23.metallib"
if [ "$PLATFORM" = sim ]; then
  codesign --force --sign - "$OUT" > /dev/null 2>&1
fi
echo "=== PS2Core.framework prêt : $(du -sh "$OUT" | cut -f1) en $((SECONDS / 60)) min ==="
