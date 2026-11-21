#!/bin/sh
# Builds the libavcodec that the app ships for ATRAC3 and ATRAC3plus: a
# shared LGPL build of a pinned FFmpeg release with only the ATRAC decoders.
# It has no GPL, version 3 or nonfree parts and no other codecs, and it
# detects no system libraries, so it depends on nothing but the C library.
#
# Usage: build_libav_atrac.sh OUT_DIR [WORK_DIR]
#
# OUT_DIR receives the libavcodec and libavutil shared libraries, the
# license text and the source tarball, which the app ships beside the
# libraries to meet the LGPL. Set CROSS_FLAGS to pass extra configure flags,
# such as the target of a cross build.
set -eu

version=7.1.1
sha256=733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1

out=$(mkdir -p "$1" && cd "$1" && pwd)
work=$(mkdir -p "${2:-$out/build}" && cd "${2:-$out/build}" && pwd)
tarball=ffmpeg-$version.tar.xz

cd "$work"
if [ ! -f "$tarball" ]; then
  curl -sSfLO "https://ffmpeg.org/releases/$tarball"
fi
if command -v sha256sum >/dev/null; then
  echo "$sha256  $tarball" | sha256sum -c -
else
  echo "$sha256  $tarball" | shasum -a 256 -c -
fi
rm -rf "ffmpeg-$version"
tar xf "$tarball"
cd "ffmpeg-$version"

asm=
command -v nasm >/dev/null || asm=--disable-x86asm

# shellcheck disable=SC2086
./configure \
  --prefix="$work/install" \
  --enable-shared --disable-static --enable-pic \
  --disable-autodetect --disable-everything \
  --disable-programs --disable-doc \
  --disable-avdevice --disable-avformat --disable-avfilter \
  --disable-swscale --disable-swresample --disable-network \
  --enable-decoder=atrac3,atrac3al,atrac3p,atrac3pal \
  $asm ${CROSS_FLAGS:-}
make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
make install

# The build must stay LGPL: configure prints the license it chose.
grep -q '^#define FFMPEG_LICENSE "LGPL version 2.1 or later"' config.h

cp COPYING.LGPLv2.1 "$out/LICENSE.ffmpeg.txt"
cp "$work/$tarball" "$out/"
for lib in "$work"/install/lib/*avcodec* "$work"/install/lib/*avutil* \
  "$work"/install/bin/*.dll; do
  [ -e "$lib" ] && cp -P "$lib" "$out/"
done
ls -l "$out"
