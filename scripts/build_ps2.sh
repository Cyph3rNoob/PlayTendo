#!/bin/zsh
# Compile le moteur PS2 de PlayTendo (PS2Core.framework) à partir d'ARMSX2 iOS 2.6.0 (sources/armsx2).
#   scripts/build_ps2.sh sim [Debug|Release]   → cores/sim/PS2Core.framework (simulateur, Debug par défaut)
#   scripts/build_ps2.sh ios                    → cores/ios/PS2Core.framework (iPhone, Release)
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
  *) echo "usage : $0 sim|ios [Debug|Release]"; exit 1 ;;
esac

python3 "$ROOT/scripts/patch_armsx2.py" "$SRC"

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
