#!/bin/zsh
# Télécharge le code source des moteurs d'émulation, à leur dernière version stable.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/sources"
cd "$ROOT/sources"

clone() { # nom url tag
  if [ -d "$1" ]; then echo "OK  $1 deja present"; return; fi
  echo ""
  echo ">>> $1 (version $3)"
  git clone --depth 1 --branch "$3" --recurse-submodules --shallow-submodules --progress "$2" "$1"
}

clone mesen        https://github.com/SourMesen/Mesen       0.9.9
clone bsnes        https://github.com/bsnes-emu/bsnes      v115
clone mgba         https://github.com/mgba-emu/mgba        0.10.5
clone melonds-ds   https://github.com/JesseTG/melonds-ds   v1.4.0
clone pcsx_rearmed https://github.com/libretro/pcsx_rearmed r26l

echo ""
du -sh "$ROOT/sources"/*
echo "=== SOURCES OK ==="
