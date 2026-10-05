#!/bin/zsh
# Compile l'app PlayTendo pour iPhone et fabrique le fichier PlayTendo.ipa
# (non signé : AltStore s'occupe de la signature à l'installation).
set -e
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/xcode"
LOG="$ROOT/build/logs/app.log"
mkdir -p "$ROOT/build/logs"

echo ">>> Compilation de l'app…"
if ! xcodebuild -project "$ROOT/app/PlayTendo.xcodeproj" -target PlayTendo -configuration Release -sdk iphoneos \
    SYMROOT="$BUILD" OBJROOT="$BUILD/obj" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    build > "$LOG" 2>&1; then
  echo "!!! ECHEC — erreurs :"
  grep -E "error:" "$LOG" | sort -u | head -40
  exit 1
fi
grep -E "warning:" "$LOG" | grep "/app/PlayTendo/" | sort -u | head -20 || true

APP="$BUILD/Release-iphoneos/PlayTendo.app"
echo ">>> Fabrication du fichier d'installation…"
rm -rf "$ROOT/build/ipa"
mkdir -p "$ROOT/build/ipa/Payload"
cp -R "$APP" "$ROOT/build/ipa/Payload/"
rm -f "$ROOT/PlayTendo.ipa"
(cd "$ROOT/build/ipa" && zip -qry "$ROOT/PlayTendo.ipa" Payload)
echo "=== OK : $ROOT/PlayTendo.ipa ($(du -h "$ROOT/PlayTendo.ipa" | cut -f1 | tr -d ' ')) ==="
