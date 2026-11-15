#!/bin/zsh
# Version App Store seulement : télécharge les kits de Google pour les pubs (Google Mobile Ads) et le consentement
# RGPD (User Messaging Platform), aux versions figées ci-dessous, vérifiés par leur SHA-256 (celui des Package.swift
# officiels de Google), dans libs/googleads/ (hors de git). L'app normale ne s'en sert jamais.
set -e
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/libs/googleads"
TMP="$ROOT/build/googleads-download"

# Nom, version, adresse, SHA-256 (github.com/googleads/swift-package-manager-google-mobile-ads et
# …-google-user-messaging-platform, fichier Package.swift).
KITS=(
  "GoogleMobileAds 13.12.0 https://dl.google.com/googleadmobadssdk/6b8bfa69d6b4b848/googlemobileadsios-spm-13.12.0.zip 6b8bfa69d6b4b8484328803fc5f71d5735caf7ce01acff8abb76e8b73c83e005"
  "UserMessagingPlatform 3.1.0 https://dl.google.com/googleadmobadssdk/90fe6bf3b0f4ce0d/googleusermessagingplatformios-spm-3.1.0.zip 90fe6bf3b0f4ce0d0199628c0871de58b6f673375148b98d52348aecc86db231"
)

mkdir -p "$DEST"
rm -rf "${TMP:?}"
mkdir -p "$TMP"
for kit in "${KITS[@]}"; do
  parts=(${=kit})
  NAME=${parts[1]} VERSION=${parts[2]} URL=${parts[3]} SUM=${parts[4]}
  if [ "$(cat "$DEST/$NAME.version" 2>/dev/null)" = "$VERSION" ] && [ -d "$DEST/$NAME.xcframework" ]; then
    echo ">>> $NAME $VERSION déjà là"
    continue
  fi
  echo ">>> Téléchargement de $NAME $VERSION…"
  curl -fL --proto '=https' --retry 2 -o "$TMP/$NAME.zip" "$URL"
  if [ "$(shasum -a 256 "$TMP/$NAME.zip" | cut -d' ' -f1)" != "$SUM" ]; then
    echo "!!! $NAME : empreinte SHA-256 différente de celle publiée par Google — fichier refusé"
    exit 1
  fi
  mkdir -p "$TMP/$NAME"
  ditto -x -k "$TMP/$NAME.zip" "$TMP/$NAME"
  FOUND=$(find "$TMP/$NAME" -maxdepth 3 -type d -name "$NAME.xcframework" | head -1)
  if [ -z "$FOUND" ]; then
    echo "!!! $NAME.xcframework introuvable dans l'archive"
    exit 1
  fi
  rm -rf "${DEST:?}/$NAME.xcframework"
  mv "$FOUND" "$DEST/"
  echo "$VERSION" > "$DEST/$NAME.version"
done
rm -rf "${TMP:?}"
echo "=== OK : $DEST ==="
