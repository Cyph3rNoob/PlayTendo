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
# Phase 3 : PS2. ARMSX2, dernière version iOS stable (les « 2.8.x » sont pour Android, les « nightly » des
# préversions) ; PlayTendo en compile le cœur avec son pilote ps2/PTPS2Host.mm (scripts/build_ps2.sh).
clone armsx2       https://github.com/ARMSX2/ARMSX2.git    iOSv2.6.0
# Mupen64Plus-Next n'a pas de version numérotée : version figée le 2026-10-05 (accord de l'utilisateur).
clone_commit mupen64plus-nx https://github.com/libretro/mupen64plus-libretro-nx 12edd2c74a517ff86dfa8cfc71ad75e4c10486d5
# Phase 3 : GameCube/Wii. DolphiniOS n'existe qu'en bêta (exception acceptée par l'utilisateur). Sans les
# compléments Windows (Qt, FFmpeg précompilés : plusieurs centaines de Mo inutiles ici).
if [ ! -d dolphin-ios ]; then
  echo ""
  echo ">>> dolphin-ios (version v5.0.0b6)"
  git clone --depth 1 --branch v5.0.0b6 --progress https://github.com/OatmealDome/dolphin-ios dolphin-ios
  git -C dolphin-ios -c submodule."Externals/Qt".update=none -c submodule."Externals/FFmpeg-bin".update=none \
    submodule update --init --recursive --depth 1 --progress
else
  echo "OK  dolphin-ios deja present"
fi

# Phase 3 : 3DS. Archive officielle complète d'Azahar (avec ses sous-modules : dynarmic, oaknut…), vérifiée par
# l'empreinte SHA-256 publiée avec elle.
AZAHAR_TAG=2126.1.2
if [ ! -d azahar ]; then
  echo ""
  echo ">>> azahar (version $AZAHAR_TAG, 43 Mo)"
  base="https://github.com/azahar-emu/azahar/releases/download/$AZAHAR_TAG"
  curl -fL --progress-bar "$base/azahar-unified-source-$AZAHAR_TAG.tar.xz" -o azahar.tar.xz
  expected=$(curl -fsL "$base/azahar-unified-source-$AZAHAR_TAG.tar.xz.sha256sum" | awk '{print $1}')
  actual=$(shasum -a 256 azahar.tar.xz | awk '{print $1}')
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    echo "!!! azahar : empreinte SHA-256 différente de celle publiée ($actual / $expected)"
    rm -f azahar.tar.xz
    exit 1
  fi
  echo "OK  empreinte SHA-256 vérifiée"
  rm -rf azahar.tmp && mkdir azahar.tmp && tar -xJf azahar.tar.xz -C azahar.tmp && rm azahar.tar.xz
  # L'archive contient un seul dossier : il devient sources/azahar.
  mv azahar.tmp/*(/) azahar && rmdir azahar.tmp
else
  echo "OK  azahar deja present"
fi

# MoltenVK (Vulkan traduit en Metal, Apache-2.0) : l'image de la 3DS sur iPhone.
MOLTENVK_TAG=v1.4.2
if [ ! -d MoltenVK ]; then
  echo ""
  echo ">>> MoltenVK (version $MOLTENVK_TAG, 35 Mo)"
  curl -fL --progress-bar "https://github.com/KhronosGroup/MoltenVK/releases/download/$MOLTENVK_TAG/MoltenVK-ios.tar" \
    -o MoltenVK-ios.tar
  rm -rf MoltenVK.tmp && mkdir MoltenVK.tmp && tar -xf MoltenVK-ios.tar -C MoltenVK.tmp && rm MoltenVK-ios.tar
  mv MoltenVK.tmp MoltenVK
else
  echo "OK  MoltenVK deja present"
fi

# MoltenVK pour Mac (même version) : l'image de la 3DS dans l'app Mac. Vérifié par l'empreinte SHA-256 que GitHub
# publie pour ce fichier de la version.
MOLTENVK_MACOS_SHA256=f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e
if [ ! -d MoltenVK-macos ]; then
  echo ""
  echo ">>> MoltenVK pour Mac (version $MOLTENVK_TAG, 60 Mo)"
  curl -fL --progress-bar "https://github.com/KhronosGroup/MoltenVK/releases/download/$MOLTENVK_TAG/MoltenVK-macos.tar" \
    -o MoltenVK-macos.tar
  actual=$(shasum -a 256 MoltenVK-macos.tar | awk '{print $1}')
  if [ "$actual" != "$MOLTENVK_MACOS_SHA256" ]; then
    echo "!!! MoltenVK pour Mac : empreinte SHA-256 différente de celle publiée ($actual)"
    rm -f MoltenVK-macos.tar
    exit 1
  fi
  echo "OK  empreinte SHA-256 vérifiée"
  rm -rf MoltenVK-macos.tmp && mkdir MoltenVK-macos.tmp && tar -xf MoltenVK-macos.tar -C MoltenVK-macos.tmp
  rm MoltenVK-macos.tar
  mv MoltenVK-macos.tmp MoltenVK-macos
else
  echo "OK  MoltenVK pour Mac deja present"
fi

# Archives importées (.zip, .7z, .rar) : libarchive (BSD-2-Clause) et le décompresseur LZMA des .7z, liblzma
# (xz, 0BSD). Compilées par scripts/build_libarchive.sh.
clone libarchive   https://github.com/libarchive/libarchive.git v3.8.9
clone xz           https://github.com/tukaani-project/xz.git    v5.8.4

# PS Vita (mise de côté le 2026-10-10) : seulement avec PLAYTENDO_VITA=1, comme scripts/build_app.sh.
if [ "${PLAYTENDO_VITA:-0}" = "1" ]; then
  # PS Vita : Vita3K n'a pas de version numérotée (seulement des versions automatiques en continu) : version figée le
  # 2026-10-07 (build 4135, accord de l'utilisateur). Sans les sous-modules propres à Android (libadrenotools), à
  # Windows (dirent) et à l'interface PC (nativefiledialog-extended).
  VITA3K_COMMIT=681f695bbc752df38fbb4053473f352de6c8643f
  if [ ! -d vita3k ]; then
    echo ""
    echo ">>> vita3k (commit $VITA3K_COMMIT, build 4135)"
    mkdir vita3k.tmp && cd vita3k.tmp
    git init -q && git remote add origin https://github.com/Vita3K/Vita3K
    git fetch --depth 1 --progress origin "$VITA3K_COMMIT" && git checkout -q FETCH_HEAD
    git -c submodule."external/libadrenotools".update=none -c submodule."external/dirent".update=none \
      -c submodule."external/nativefiledialog-extended".update=none \
      submodule update --init --recursive --depth 1 --progress
    cd .. && mv vita3k.tmp vita3k
  else
    echo "OK  vita3k deja present"
  fi

  # OpenSSL (Apache-2.0) : Vita3K déchiffre les paquets et les jeux Vita avec. Code source officiel, vérifié par
  # l'empreinte SHA-256 publiée avec lui.
  OPENSSL_VERSION=4.0.3
  if [ ! -d openssl ]; then
    echo ""
    echo ">>> openssl (version $OPENSSL_VERSION, 55 Mo)"
    base="https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION"
    curl -fL --progress-bar "$base/openssl-$OPENSSL_VERSION.tar.gz" -o openssl.tar.gz
    expected=$(curl -fsL "$base/openssl-$OPENSSL_VERSION.tar.gz.sha256" | awk '{print $1}')
    actual=$(shasum -a 256 openssl.tar.gz | awk '{print $1}')
    if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
      echo "!!! openssl : empreinte SHA-256 différente de celle publiée ($actual / $expected)"
      rm -f openssl.tar.gz
      exit 1
    fi
    echo "OK  empreinte SHA-256 vérifiée"
    rm -rf openssl.tmp && mkdir openssl.tmp && tar -xzf openssl.tar.gz -C openssl.tmp && rm openssl.tar.gz
    mv openssl.tmp/*(/) openssl && rmdir openssl.tmp
  else
    echo "OK  openssl deja present"
  fi

  # Programme libre pour un premier essai de la PS Vita : « Hello World » de xerpi (53 Ko).
  mkdir -p homebrew
  if [ ! -s homebrew/vitahelloworld.vpk ]; then
    echo ""
    echo ">>> vitahelloworld 1.0 (53 Ko)"
    curl -fL --progress-bar https://github.com/xerpi/vitahelloworld/releases/download/1.0/vitahelloworld.vpk \
      -o homebrew/vitahelloworld.vpk
  else
    echo "OK  vitahelloworld deja present"
  fi
else
  echo "--  PS Vita mise de côté : Vita3K, OpenSSL et Hello World non téléchargés (PLAYTENDO_VITA=1 pour les avoir)"
fi

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
           "metadat/redump/Sony - PlayStation 2.dat" \
           "metadat/redump/Nintendo - GameCube.dat" \
           "metadat/redump/Nintendo - Wii.dat" \
           "metadat/no-intro/Sony - PlayStation Portable.dat" \
           "metadat/no-intro/Nintendo - Nintendo 3DS.dat" \
           "metadat/no-intro/Nintendo - Nintendo 3DS (Digital).dat"; do
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
