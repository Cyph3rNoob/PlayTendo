#!/bin/zsh
# Compile l'app PlayTendo pour Mac (Apple Silicon, macOS 14 minimum) en version finale et la range dans
# le dossier du projet : PlayTendo-Mac/PlayTendo.app (double-cliquer pour l'ouvrir). Signature locale (« ad hoc »),
# sans « hardened runtime » : le mode turbo prépare lui-même sa mémoire. Compilée sur ce Mac, elle s'ouvre sans
# avertissement ; envoyée à quelqu'un d'autre, macOS la bloquera au premier lancement (pas de notarisation, qui
# demande un compte développeur payant).
# Les moteurs viennent de cores/mac (scripts/build_cores_macos.sh), libarchive de libs/libarchive/mac
# (scripts/build_libarchive.sh mac).
set -e
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/xcode-mac"
LOG="$ROOT/build/logs/app-mac-release.log"
OUT="$ROOT/PlayTendo-Mac"
mkdir -p "$ROOT/build/logs"

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
    SYMROOT="$BUILD" OBJROOT="$BUILD/obj" build > "$LOG" 2>&1; then
  echo "!!! ECHEC — erreurs :"
  grep -E "error:" "$LOG" | sort -u | head -40
  exit 1
fi
grep -E "warning:" "$LOG" | grep "/app/PlayTendo/" | sort -u | head -20 || true
codesign --verify --deep --strict "$APP"

rm -rf "${OUT:?}"
mkdir -p "$OUT"
# ditto garde les liens des frameworks et la signature.
ditto "$APP" "$OUT/PlayTendo.app"
echo "=== OK : $OUT/PlayTendo.app ($(du -sh "$OUT/PlayTendo.app" | cut -f1 | tr -d ' ')) ==="
