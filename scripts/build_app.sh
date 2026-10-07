#!/bin/zsh
# Compile l'app PlayTendo pour iPhone et fabrique le fichier PlayTendo.ipa. AltStore la signe à
# l'installation ; elle porte seulement une signature locale (« ad hoc ») qui contient ses droits
# (app/PlayTendo.entitlements), qu'AltStore reprend.
set -e
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/xcode"
LOG="$ROOT/build/logs/app.log"
mkdir -p "$ROOT/build/logs"

APP="$BUILD/Release-iphoneos/PlayTendo.app"
# Repart d'une app vide : Xcode ne retire pas les fichiers d'une ancienne compilation (une extension
# supprimée du projet restait dans PlugIns et se retrouvait dans l'IPA).
rm -rf "$APP"

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

echo ">>> Fabrication du fichier d'installation…"
rm -rf "$ROOT/build/ipa"
mkdir -p "$ROOT/build/ipa/Payload"
cp -R "$APP" "$ROOT/build/ipa/Payload/"
# Signature locale : les moteurs d'abord (codesign refuse une app dont le contenu n'est pas signé), puis l'app
# avec ses droits.
PAYLOAD_APP="$ROOT/build/ipa/Payload/PlayTendo.app"
for fw in "$PAYLOAD_APP"/Frameworks/*.framework; do
  codesign --force --sign - --timestamp=none "$fw" >> "$LOG" 2>&1
done
codesign --force --sign - --timestamp=none --entitlements "$ROOT/app/PlayTendo.entitlements" "$PAYLOAD_APP" >> "$LOG" 2>&1
rm -f "$ROOT/PlayTendo.ipa"
(cd "$ROOT/build/ipa" && zip -qry "$ROOT/PlayTendo.ipa" Payload)
echo "=== OK : $ROOT/PlayTendo.ipa ($(du -h "$ROOT/PlayTendo.ipa" | cut -f1 | tr -d ' ')) ==="
