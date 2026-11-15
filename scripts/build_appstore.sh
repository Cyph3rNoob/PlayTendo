#!/bin/zsh
# Compile la version App Store de PlayTendo et fabrique PlayTendo-AppStore.ipa (signature locale, pour l'essayer par
# AltServer avant la publication). « zsh scripts/build_appstore.sh sim » : version Debug installée sur le simulateur. Réglage PLAYTENDO_APPSTORE : sans PS2, GameCube, Wii ni PS Vita (moteurs qui
# exigent le JIT, interdit sur l'App Store) et sans aucun code du mode turbo (StikDebug, débogueur) ; PSP et 3DS sur
# leurs interpréteurs. L'app normale (scripts/build_app.sh, PlayTendo.ipa) n'est pas touchée : compilation à part
# dans build/xcode-appstore.
set -e
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/xcode-appstore"
LOG="$ROOT/build/logs/appstore.log"
mkdir -p "$ROOT/build/logs"

APPSTORE_SETTINGS=('PLAYTENDO_APPSTORE_CONDITION=PLAYTENDO_APPSTORE' 'PLAYTENDO_APPSTORE_DEFINE=PLAYTENDO_APPSTORE=1'
                   'PLAYTENDO_VITA_CONDITION=' 'PLAYTENDO_VITA_DEFINE=PLAYTENDO_VITA=0')

echo ">>> Version App Store : sans PS2, GameCube, Wii, PS Vita ni mode turbo ; pubs AdMob"

# Kits de Google (pubs, consentement RGPD) : bibliothèques statiques, liées seulement dans cette version.
GADS="$ROOT/libs/googleads"
for kit in GoogleMobileAds UserMessagingPlatform; do
  if [ ! -d "$GADS/$kit.xcframework" ]; then
    echo "!!! $kit absent : lance d'abord zsh scripts/fetch_googleads.sh"
    exit 1
  fi
done
# Réglages de compilation des kits pour une partie de l'xcframework (ios-arm64 ou ios-arm64_x86_64-simulator).
ads_settings() {
  echo "FRAMEWORK_SEARCH_PATHS=\$(inherited) $GADS/GoogleMobileAds.xcframework/$1 $GADS/UserMessagingPlatform.xcframework/$1"
  echo "OTHER_LDFLAGS=\$(inherited) -ObjC -framework GoogleMobileAds -framework UserMessagingPlatform"
}
# Clés de l'Info.plist pour les pubs (app/AppStore-Info.plist), ajoutées à l'app compilée.
add_ads_keys() {
  for key in GADApplicationIdentifier NSUserTrackingUsageDescription SKAdNetworkItems; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$1/Info.plist" 2>/dev/null || true
  done
  /usr/libexec/PlistBuddy -c "Merge $ROOT/app/AppStore-Info.plist" "$1/Info.plist" > /dev/null
}
# Fichiers propres à la version App Store, posés dans l'app compilée ($1 = app, $2 = partie des xcframeworks) :
# manifeste de confidentialité de l'app, textes des questions du système (en.lproj, fr.lproj), et les manifestes des
# kits de Google (bibliothèques statiques : leur PrivacyInfo.xcprivacy n'entre pas seul dans l'app, il lui faut un
# paquet de ressources, comme le fait le Swift Package Manager).
add_appstore_resources() {
  cp "$ROOT/app/AppStore/PrivacyInfo.xcprivacy" "$1/"
  for lang in en fr; do
    mkdir -p "$1/$lang.lproj"
    cp "$ROOT/app/AppStore/$lang.lproj/InfoPlist.strings" "$1/$lang.lproj/"
  done
  for kit in GoogleMobileAds UserMessagingPlatform; do
    local bundle="$1/${kit}Resources.bundle"
    rm -rf "${bundle:?}"
    mkdir -p "$bundle"
    cp "$GADS/$kit.xcframework/$2/$kit.framework/PrivacyInfo.xcprivacy" "$bundle/"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.playtendo.app.$kit-resources" \
      -c "Add :CFBundleName string ${kit}Resources" -c "Add :CFBundlePackageType string BNDL" \
      -c "Add :CFBundleInfoDictionaryVersion string 6.0" "$bundle/Info.plist" > /dev/null
  done
}

# « sim » : version Debug pour le simulateur, installée sur le simulateur ouvert (par-dessus PlayTendo, données
# gardées). L'achat « Retirer les pubs » y passe par une boutique d'essai (rien n'est payé).
if [ "${1:-}" = "sim" ]; then
  SIMAPP="$ROOT/build/xcode-appstore-sim/Debug-iphonesimulator/PlayTendo.app"
  rm -rf "${SIMAPP:?}"
  echo ">>> Compilation pour le simulateur…"
  if ! xcodebuild -project "$ROOT/app/PlayTendo.xcodeproj" -target PlayTendo -configuration Debug -sdk iphonesimulator \
      -arch arm64 SYMROOT="$ROOT/build/xcode-appstore-sim" OBJROOT="$ROOT/build/xcode-appstore-sim/obj" \
      CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= "${APPSTORE_SETTINGS[@]}" \
      "${(f)$(ads_settings ios-arm64_x86_64-simulator)}" \
      build > "$LOG" 2>&1; then
    echo "!!! ECHEC — erreurs :"
    grep -E "error:" "$LOG" | sort -u | head -40
    exit 1
  fi
  grep -E "warning:" "$LOG" | grep "/app/PlayTendo/" | sort -u | head -20 || true
  add_ads_keys "$SIMAPP"
  add_appstore_resources "$SIMAPP" ios-arm64_x86_64-simulator
  codesign --force --sign - --timestamp=none "$SIMAPP" >> "$LOG" 2>&1
  if ! xcrun simctl install booted "$SIMAPP"; then
    echo "!!! Aucun simulateur ouvert : ouvre l'app Simulator, puis relance cette commande"
    exit 1
  fi
  echo "=== OK : version App Store installée sur le simulateur ==="
  exit 0
fi

APP="$BUILD/Release-iphoneos/PlayTendo.app"
# Repart d'une app vide (Xcode ne retire pas les fichiers d'une ancienne compilation).
rm -rf "${APP:?}"

echo ">>> Compilation de l'app…"
if ! xcodebuild -project "$ROOT/app/PlayTendo.xcodeproj" -target PlayTendo -configuration Release -sdk iphoneos \
    SYMROOT="$BUILD" OBJROOT="$BUILD/obj" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" "${APPSTORE_SETTINGS[@]}" \
    "${(f)$(ads_settings ios-arm64)}" \
    build > "$LOG" 2>&1; then
  echo "!!! ECHEC — erreurs :"
  grep -E "error:" "$LOG" | sort -u | head -40
  exit 1
fi
grep -E "warning:" "$LOG" | grep "/app/PlayTendo/" | sort -u | head -20 || true

# Vérifications : aucun moteur interdit ni lien vers StikDebug dans l'app.
for fw in PS2Core DolphinCore VitaCore; do
  if [ -d "$APP/Frameworks/$fw.framework" ]; then
    echo "!!! $fw.framework se trouve dans l'app : version App Store refusée"
    exit 1
  fi
done

echo ">>> Fabrication du fichier d'installation…"
rm -rf "${ROOT:?}/build/ipa-appstore"
mkdir -p "$ROOT/build/ipa-appstore/Payload"
cp -R "$APP" "$ROOT/build/ipa-appstore/Payload/"
PAYLOAD_APP="$ROOT/build/ipa-appstore/Payload/PlayTendo.app"
# L'app n'ouvre plus StikDebug : on retire l'adresse « stikdebug » de la liste des apps qu'elle peut interroger.
/usr/libexec/PlistBuddy -c "Delete :LSApplicationQueriesSchemes" "$PAYLOAD_APP/Info.plist" 2>/dev/null || true
add_ads_keys "$PAYLOAD_APP"
add_appstore_resources "$PAYLOAD_APP" ios-arm64
# (« stikdebug:// » seulement : la traduction anglaise d'un texte d'aide contient le nom du site.)
if grep -aq "stikdebug" "$PAYLOAD_APP/Info.plist" || grep -aq "stikdebug://" "$PAYLOAD_APP/PlayTendo"; then
  echo "!!! L'adresse « stikdebug » est encore dans l'app : version App Store refusée"
  exit 1
fi
strip -x "$PAYLOAD_APP/PlayTendo" >> "$LOG" 2>&1
for fw in "$PAYLOAD_APP"/Frameworks/*.framework; do
  strip -x "$fw/$(basename "$fw" .framework)" >> "$LOG" 2>&1
done
for fw in "$PAYLOAD_APP"/Frameworks/*.framework; do
  codesign --force --sign - --timestamp=none "$fw" >> "$LOG" 2>&1
done
codesign --force --sign - --timestamp=none --entitlements "$ROOT/app/PlayTendo-AppStore.entitlements" "$PAYLOAD_APP" >> "$LOG" 2>&1
rm -f "$ROOT/PlayTendo-AppStore.ipa"
(cd "$ROOT/build/ipa-appstore" && zip -qry -9 "$ROOT/PlayTendo-AppStore.ipa" Payload)
echo "=== OK : $ROOT/PlayTendo-AppStore.ipa ($(( $(stat -f %z "$ROOT/PlayTendo-AppStore.ipa") / 1000000 )) Mo) ==="
