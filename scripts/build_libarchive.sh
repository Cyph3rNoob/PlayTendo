#!/bin/zsh
# Compile la bibliothèque d'archives de l'app : libarchive 3.8.9 (lecture des .zip, ZIP64 compris, .7z, .rar et .rar5)
# avec liblzma de xz 5.8.4 (méthodes LZMA/LZMA2 des .7z), en bibliothèques statiques pour l'iPhone et le simulateur
# → libs/libarchive/<ios|sim>/libarchive.a (les deux réunies) et libs/libarchive/include (archive.h, archive_entry.h).
# zlib, bzip2 et iconv sont ceux d'iOS. Rien d'autre n'est compilé (ni outils, ni tests, ni chiffrement).
# Sources : scripts/fetch_sources.sh. Rapide (~1 min) ; journaux : build/libarchive-<plateforme>.log
set -e
setopt pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/libs/libarchive"
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
# Même version minimale que l'app (IPHONEOS_DEPLOYMENT_TARGET du projet).
MIN_IOS=18.0

mkdir -p "$ROOT/build"
for platform in ios sim; do
  if [ "$platform" = ios ]; then sdk=iphoneos; else sdk=iphonesimulator; fi
  BUILD="$ROOT/build/libarchive-$platform"
  PREFIX="$BUILD/prefix"
  LOG="$ROOT/build/libarchive-$platform.log"
  rm -rf "${BUILD:?}" && mkdir -p "$BUILD"
  : > "$LOG"
  COMMON=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=$sdk
          -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_IOS -DBUILD_SHARED_LIBS=OFF
          -DCMAKE_INSTALL_PREFIX="$PREFIX")

  echo "=== $platform : liblzma (xz 5.8.4) ==="
  cmake -S "$ROOT/sources/xz" -B "$BUILD/xz" "${COMMON[@]}" -DXZ_NLS=OFF -DXZ_DOC=OFF -DXZ_TOOL_XZ=OFF \
    -DXZ_TOOL_XZDEC=OFF -DXZ_TOOL_LZMADEC=OFF -DXZ_TOOL_LZMAINFO=OFF -DXZ_TOOL_SCRIPTS=OFF -DXZ_TOOL_SYMLINKS=OFF \
    -DXZ_TOOL_SYMLINKS_LZMA=OFF -DBUILD_TESTING=OFF >> "$LOG" 2>&1 \
    && cmake --build "$BUILD/xz" >> "$LOG" 2>&1 && cmake --install "$BUILD/xz" >> "$LOG" 2>&1 \
    || { echo "!!! ÉCHEC — fin du journal ($LOG) :"; tail -30 "$LOG"; exit 1; }

  echo "=== $platform : libarchive 3.8.9 ==="
  cmake -S "$ROOT/sources/libarchive" -B "$BUILD/libarchive" "${COMMON[@]}" \
    -DLIBLZMA_INCLUDE_DIR="$PREFIX/include" -DLIBLZMA_LIBRARY="$PREFIX/lib/liblzma.a" \
    -DENABLE_LZMA=ON -DENABLE_ZLIB=ON -DENABLE_BZip2=ON -DENABLE_ICONV=ON \
    -DENABLE_OPENSSL=OFF -DENABLE_MBEDTLS=OFF -DENABLE_NETTLE=OFF -DENABLE_CNG=OFF -DENABLE_LIBB2=OFF \
    -DENABLE_LZ4=OFF -DENABLE_LZO=OFF -DENABLE_ZSTD=OFF -DENABLE_LIBXML2=OFF -DENABLE_EXPAT=OFF \
    -DENABLE_WIN32_XMLLITE=OFF -DENABLE_PCREPOSIX=OFF -DENABLE_PCRE2POSIX=OFF -DENABLE_LIBGCC=OFF \
    -DENABLE_TAR=OFF -DENABLE_CPIO=OFF -DENABLE_CAT=OFF -DENABLE_UNZIP=OFF -DENABLE_XATTR=OFF -DENABLE_ACL=OFF \
    -DENABLE_TEST=OFF >> "$LOG" 2>&1 \
    && cmake --build "$BUILD/libarchive" >> "$LOG" 2>&1 && cmake --install "$BUILD/libarchive" >> "$LOG" 2>&1 \
    || { echo "!!! ÉCHEC — fin du journal ($LOG) :"; tail -30 "$LOG"; exit 1; }
  grep -E "^-- (Found|Could NOT find) (ZLIB|BZip2|LibLZMA|Iconv)" "$LOG" | sed 's/^/  /' || true

  mkdir -p "$OUT/$platform"
  rm -f "$OUT/$platform/libarchive.a"
  libtool -static -o "$OUT/$platform/libarchive.a" "$PREFIX/lib/libarchive.a" "$PREFIX/lib/liblzma.a" 2>> "$LOG"
  echo "  → libs/libarchive/$platform/libarchive.a ($(( $(stat -f %z "$OUT/$platform/libarchive.a") / 1024 )) Ko)"
done

mkdir -p "$OUT/include"
cp "$ROOT/build/libarchive-ios/prefix/include/archive.h" "$ROOT/build/libarchive-ios/prefix/include/archive_entry.h" \
  "$OUT/include/"
echo "=== libarchive prête ==="
