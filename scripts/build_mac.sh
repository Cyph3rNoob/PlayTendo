#!/bin/zsh
# Compile l'app PlayTendo pour Mac (Apple Silicon, macOS 14 minimum) en version finale et la range dans
# le dossier du projet : PlayTendo-Mac/PlayTendo.app (double-cliquer pour l'ouvrir), et PlayTendo-Mac/PlayTendo.dmg
# (image disque à donner : l'app, un raccourci vers Applications et un Lisez-moi). Signature locale (« ad hoc »),
# sans « hardened runtime » : le mode turbo prépare lui-même sa mémoire. Compilée sur ce Mac, elle s'ouvre sans
# avertissement ; envoyée à quelqu'un d'autre, macOS la bloquera au premier lancement (pas de notarisation, qui
# demande un compte développeur payant).
# Les moteurs viennent de cores/mac (scripts/build_cores_macos.sh ; PS Vita : scripts/build_vita3k.sh mac), libarchive
# de libs/libarchive/mac (scripts/build_libarchive.sh mac).
set -e
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# « .noindex » : Spotlight ignore ce dossier, et le Mac n'y prend pas une copie de travail de l'app pour ouvrir les
# jeux (double-clic dans le Finder).
BUILD="$ROOT/build/xcode-mac.noindex"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
LOG="$ROOT/build/logs/app-mac-release.log"
OUT="$ROOT/PlayTendo-Mac"
mkdir -p "$ROOT/build/logs"

# PS Vita : incluse par défaut, comme sur iPhone (scripts/build_app.sh) ; PLAYTENDO_VITA=0 la retire.
VITA_SETTINGS=()
if [ "${PLAYTENDO_VITA:-1}" = "1" ]; then
  if [ ! -f "$ROOT/cores/mac/VitaCore.framework/VitaCore" ]; then
    echo "!!! Moteur PS Vita absent : lance d'abord zsh scripts/build_vita3k.sh mac (ou PLAYTENDO_VITA=0 pour s'en passer)"
    exit 1
  fi
  VITA_SETTINGS=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) PLAYTENDO_VITA'
                 'GCC_PREPROCESSOR_DEFINITIONS=$(inherited) PLAYTENDO_VITA=1')
  echo ">>> Avec la PS Vita"
else
  echo ">>> Sans la PS Vita"
fi

APP="$BUILD/Release/PlayTendo.app"
# Repart d'une app vide : Xcode ne retire pas les fichiers d'une ancienne compilation.
rm -rf "${APP:?}"

if [ -s "$ROOT/secrets/steamgriddb.key" ]; then
  echo ">>> Clé SteamGridDB embarquée, masquée (jaquettes de secours)"
else
  echo ">>> Pas de clé SteamGridDB (secrets/steamgriddb.key) : jaquettes de secours désactivées"
fi
echo ">>> Compilation de l'app Mac…"
if ! xcodebuild -project "$ROOT/app/PlayTendo.xcodeproj" -target "PlayTendo Mac" -configuration Release \
    SYMROOT="$BUILD" OBJROOT="$BUILD/obj" "${VITA_SETTINGS[@]}" build > "$LOG" 2>&1; then
  echo "!!! ECHEC — erreurs :"
  grep -E "error:" "$LOG" | sort -u | head -40
  exit 1
fi
grep -E "warning:" "$LOG" | grep "/app/PlayTendo/" | sort -u | head -20 || true
codesign --verify --deep --strict "$APP"

# Seulement l'app : le dossier reste (le Finder, s'il l'affiche, y recrée son .DS_Store pendant qu'on le vide).
rm -rf "${OUT:?}/PlayTendo.app"
mkdir -p "$OUT"
# ditto garde les liens des frameworks et la signature.
ditto "$APP" "$OUT/PlayTendo.app"
# Types de fichiers (jeux ouverts depuis le Finder) : pris en compte tout de suite, pour cette copie seulement.
"$LSREGISTER" -u "$APP" > /dev/null 2>&1 || true
"$LSREGISTER" -f "$OUT/PlayTendo.app" > /dev/null 2>&1 || true
echo "=== OK : $OUT/PlayTendo.app ($(du -sh "$OUT/PlayTendo.app" | cut -f1 | tr -d ' ')) ==="

# Image disque : l'app, un raccourci vers Applications (on y glisse l'app) et un Lisez-moi.
STAGE="$ROOT/build/dmg.noindex/PlayTendo"
rm -rf "${STAGE:?}"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/PlayTendo.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/scripts/mac/Lisez-moi.txt" "$STAGE/Lisez-moi.txt"
"$LSREGISTER" -u "$STAGE/PlayTendo.app" > /dev/null 2>&1 || true
rm -f "$OUT/PlayTendo.dmg"
hdiutil create -quiet -volname PlayTendo -srcfolder "$STAGE" -fs APFS -format ULFO "$OUT/PlayTendo.dmg"
rm -rf "${STAGE:?}"
hdiutil verify -quiet "$OUT/PlayTendo.dmg"
echo "=== OK : $OUT/PlayTendo.dmg ($(du -sh "$OUT/PlayTendo.dmg" | cut -f1 | tr -d ' ')) ==="
# Une app déjà ouverte garde l'ancienne version (moteurs listés à son lancement) jusqu'à ce qu'on la relance.
if pgrep -f "$OUT/PlayTendo.app/Contents/MacOS/PlayTendo" > /dev/null; then
  echo "!!! PlayTendo est encore ouverte avec l'ancienne version : quitte-la (⌘Q) puis rouvre-la."
fi
