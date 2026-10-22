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

# PS Vita : incluse par défaut depuis le 2026-10-12 (mémoire mappée : Gravity Rush jouable), dans le projet lui-même
# depuis le 2026-10-20 (une compilation lancée depuis Xcode l'a aussi). Son moteur se compile d'abord avec
# scripts/build_vita3k.sh. PLAYTENDO_VITA=0 la retire : ni son code ni VitaCore.framework n'entrent alors dans l'app,
# et l'app efface au lancement ce que la Vita avait installé, sauf les sauvegardes des jeux.
VITA_SETTINGS=()
if [ "${PLAYTENDO_VITA:-1}" = "1" ]; then
  if [ ! -f "$ROOT/cores/ios/VitaCore.framework/VitaCore" ]; then
    echo "!!! Moteur PS Vita absent : lance d'abord zsh scripts/build_vita3k.sh (ou PLAYTENDO_VITA=0 pour s'en passer)"
    exit 1
  fi
  echo ">>> Avec la PS Vita"
else
  VITA_SETTINGS=('PLAYTENDO_VITA_CONDITION=' 'PLAYTENDO_VITA_DEFINE=PLAYTENDO_VITA=0')
  echo ">>> Sans la PS Vita"
fi

APP="$BUILD/Release-iphoneos/PlayTendo.app"
# Repart d'une app vide : Xcode ne retire pas les fichiers d'une ancienne compilation (une extension
# supprimée du projet restait dans PlugIns et se retrouvait dans l'IPA).
rm -rf "${APP:?}"

if [ -s "$ROOT/secrets/steamgriddb.key" ]; then
  echo ">>> Clé SteamGridDB embarquée, masquée (jaquettes de secours)"
else
  echo ">>> Pas de clé SteamGridDB (secrets/steamgriddb.key) : jaquettes de secours désactivées"
fi
if [ -s "$ROOT/secrets/screenscraper_devid" ] && [ -s "$ROOT/secrets/screenscraper_devpassword" ]; then
  echo ">>> Identifiants ScreenScraper embarqués, masqués (boîtes 3D des jaquettes)"
else
  echo ">>> Pas d'identifiants ScreenScraper (secrets/screenscraper_devid, …devpassword) : jaquettes libretro et SteamGridDB seulement"
fi
echo ">>> Compilation de l'app…"
if ! xcodebuild -project "$ROOT/app/PlayTendo.xcodeproj" -target PlayTendo -configuration Release -sdk iphoneos \
    SYMROOT="$BUILD" OBJROOT="$BUILD/obj" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" "${VITA_SETTINGS[@]}" \
    build > "$LOG" 2>&1; then
  echo "!!! ECHEC — erreurs :"
  grep -E "error:" "$LOG" | sort -u | head -40
  exit 1
fi
grep -E "warning:" "$LOG" | grep "/app/PlayTendo/" | sort -u | head -20 || true

echo ">>> Fabrication du fichier d'installation…"
rm -rf "${ROOT:?}/build/ipa"
mkdir -p "$ROOT/build/ipa/Payload"
cp -R "$APP" "$ROOT/build/ipa/Payload/"
# Signature locale : les moteurs d'abord (codesign refuse une app dont le contenu n'est pas signé), puis l'app
# avec ses droits.
PAYLOAD_APP="$ROOT/build/ipa/Payload/PlayTendo.app"
# Plus léger, sans rien changer au jeu : symboles internes retirés de l'app et des moteurs (strip -x garde ceux que
# l'app cherche par dlsym), et fichiers de Dolphin dont PlayTendo ne se sert pas (noms des jeux en 15 langues : titre
# de fenêtre seulement ; base de symboles de son débogueur).
strip -x "$PAYLOAD_APP/PlayTendo" >> "$LOG" 2>&1
for fw in "$PAYLOAD_APP"/Frameworks/*.framework; do
  strip -x "$fw/$(basename "$fw" .framework)" >> "$LOG" 2>&1
done
rm -f "$PAYLOAD_APP"/Frameworks/DolphinCore.framework/Sys/wiitdb-*.txt \
      "$PAYLOAD_APP"/Frameworks/DolphinCore.framework/Sys/totaldb.dsy
for fw in "$PAYLOAD_APP"/Frameworks/*.framework; do
  codesign --force --sign - --timestamp=none "$fw" >> "$LOG" 2>&1
done
codesign --force --sign - --timestamp=none --entitlements "$ROOT/app/PlayTendo.entitlements" "$PAYLOAD_APP" >> "$LOG" 2>&1
rm -f "$ROOT/PlayTendo.ipa"
(cd "$ROOT/build/ipa" && zip -qry -9 "$ROOT/PlayTendo.ipa" Payload)
# Taille du fichier (du compterait la place occupée sur le disque, souvent plus grande).
echo "=== OK : $ROOT/PlayTendo.ipa ($(( $(stat -f %z "$ROOT/PlayTendo.ipa") / 1000000 )) Mo) ==="
