#!/bin/zsh
# Prépare les moteurs pour le simulateur d'iPhone à partir des moteurs iPhone :
# même code machine (arm64), seule l'étiquette de plateforme change.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-version)"
# PS2Core et DolphinCore ne sont pas concernés : build_ps2.sh et build_dolphin.sh les compilent directement pour
# le simulateur (avec des réglages propres au simulateur). VitaCore (PS Vita) n'existe pas pour le simulateur : son
# affichage passe par MoltenVK, qui y plante.
mkdir -p "$ROOT/cores/sim"
for fw in "$ROOT"/cores/ios/*.framework; do
  name="$(basename "$fw" .framework)"
  [ "$name" = PS2Core ] || [ "$name" = DolphinCore ] || [ "$name" = VitaCore ] && continue
  out="$ROOT/cores/sim/$name.framework"
  rm -rf "${out:?}"
  mkdir -p "$out"
  sed 's/<string>iPhoneOS<\/string>/<string>iPhoneSimulator<\/string>/' "$fw/Info.plist" > "$out/Info.plist"
  xcrun vtool -arch arm64 -set-build-version iossim 15.0 "$SDK_VERSION" -replace -output "$out/$name" "$fw/$name"
  codesign --force --sign - "$out" >/dev/null 2>&1
  echo "$name : OK"
done
