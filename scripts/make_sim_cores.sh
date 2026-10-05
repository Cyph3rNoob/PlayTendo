#!/bin/zsh
# Prépare les moteurs pour le simulateur d'iPhone à partir des moteurs iPhone :
# même code machine (arm64), seule l'étiquette de plateforme change.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-version)"
rm -rf "$ROOT/cores/sim"
mkdir -p "$ROOT/cores/sim"
for fw in "$ROOT"/cores/ios/*.framework; do
  name="$(basename "$fw" .framework)"
  out="$ROOT/cores/sim/$name.framework"
  mkdir -p "$out"
  sed 's/<string>iPhoneOS<\/string>/<string>iPhoneSimulator<\/string>/' "$fw/Info.plist" > "$out/Info.plist"
  xcrun vtool -arch arm64 -set-build-version iossim 15.0 "$SDK_VERSION" -replace -output "$out/$name" "$fw/$name"
  codesign --force --sign - "$out" >/dev/null 2>&1
  echo "$name : OK"
done
