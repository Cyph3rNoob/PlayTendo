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

# Clone un dépôt à un commit précis (pour les moteurs sans version numérotée).
clone_commit() { # nom url commit
  if [ -d "$1" ]; then echo "OK  $1 deja present"; return; fi
  echo ""
  echo ">>> $1 (commit $3)"
  mkdir "$1" && cd "$1"
  git init -q && git remote add origin "$2"
  git fetch --depth 1 --progress origin "$3" && git checkout -q FETCH_HEAD
  git submodule update --init --recursive --depth 1 || echo "(sous-modules ignorés)"
  cd ..
}

clone mesen        https://github.com/SourMesen/Mesen       0.9.9
clone bsnes        https://github.com/bsnes-emu/bsnes      v115
clone mgba         https://github.com/mgba-emu/mgba        0.10.5
clone melonds-ds   https://github.com/JesseTG/melonds-ds   v1.4.0
clone pcsx_rearmed https://github.com/libretro/pcsx_rearmed r26l
# Phase 2
clone ppsspp       https://github.com/hrydgard/ppsspp      v1.20.4
# Mupen64Plus-Next n'a pas de version numérotée : version figée le 2026-10-05 (accord de l'utilisateur).
clone_commit mupen64plus-nx https://github.com/libretro/mupen64plus-libretro-nx 12edd2c74a517ff86dfa8cfc71ad75e4c10486d5

# Bibliothèque : base libretro (No-Intro / Redump) pour reconnaître les jeux.
DB_TAG=v1.22.1
fetch_database() {
  local dir="libretro-database"
  mkdir -p "$dir"
  for f in "metadat/no-intro/Nintendo - Nintendo Entertainment System.dat" \
           "metadat/no-intro/Nintendo - Super Nintendo Entertainment System.dat" \
           "metadat/no-intro/Nintendo - Nintendo 64.dat" \
           "metadat/no-intro/Nintendo - Game Boy.dat" \
           "metadat/no-intro/Nintendo - Game Boy Color.dat" \
           "metadat/no-intro/Nintendo - Game Boy Advance.dat" \
           "metadat/no-intro/Nintendo - Nintendo DS.dat" \
           "metadat/redump/Sony - PlayStation.dat" \
           "metadat/redump/Sony - PlayStation Portable.dat" \
           "metadat/no-intro/Sony - PlayStation Portable.dat"; do
    local out="$dir/${f#metadat/}"
    if [ -s "$out" ]; then continue; fi
    mkdir -p "$(dirname "$out")"
    curl -sfL "https://raw.githubusercontent.com/libretro/libretro-database/$DB_TAG/${f// /%20}" -o "$out" \
      && echo "OK  $out" || { echo "!!! ECHEC $f"; exit 1; }
  done
}
fetch_database

echo ""
du -sh "$ROOT/sources"/*
echo "=== SOURCES OK ==="
