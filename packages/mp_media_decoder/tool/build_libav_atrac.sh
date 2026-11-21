#!/bin/sh
# Builds the libavcodec that the app ships for ATRAC3 and ATRAC3plus: an
# LGPL build of a pinned FFmpeg release with only the ATRAC decoders. It has
# no GPL, version 3 or nonfree parts and no other codecs, and it detects no
# system libraries, so it depends on nothing but the C library of the
# system.
#
# libavcodec and libavutil are built as static archives and then linked as
# one shared library, mmd_libav, which exports only the functions that
# lib/src/libavcodec.dart calls. The app loads it at run time, so it stays a
# separate library that a user can rebuild with this script and replace.
#
# Usage: build_libav_atrac.sh TARGET OUT_DIR [WORK_DIR]
#
# TARGET is one of linux-x64, linux-arm64 (native builds on such a host),
# android-arm64, android-arm, android-x64 (with the NDK in
# ANDROID_NDK_HOME), windows-x64, windows-arm64 (with llvm-mingw on PATH),
# macos-x64, macos-arm64, ios-arm64, iossim-arm64 and iossim-x64 (with
# Xcode).
#
# OUT_DIR receives the library under the name of the release asset
# (mmd_libav-TARGET.so, .dll or .dylib) and its SHA-256.
set -eu

version=7.1.1
sha256=733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1

target=$1
out=$(mkdir -p "$2" && cd "$2" && pwd)
work=$(mkdir -p "${3:-$out/build}" && cd "${3:-$out/build}" && pwd)
tarball=ffmpeg-$version.tar.xz

# the functions of the library, as lib/src/libavcodec.dart calls them
symbols='avcodec_license avutil_license avcodec_find_decoder_by_name
avcodec_alloc_context3 avcodec_open2 avcodec_send_packet
avcodec_receive_frame avcodec_flush_buffers avcodec_free_context
av_packet_alloc av_packet_free av_new_packet av_packet_unref
av_frame_alloc av_frame_free av_opt_set_int av_opt_set'

ndk_bin() {
  echo "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME is not set}/toolchains/llvm/prebuilt/$(uname -s | tr A-Z a-z)-x86_64/bin"
}

# the configure flags, the C compiler and the kind of the library
cflags=
threads=--enable-pthreads
case $target in
  linux-x64 | linux-arm64)
    cc=${CC:-cc}
    cross=
    kind=elf
    ext=so
    ;;
  android-arm64 | android-arm | android-x64)
    bin=$(ndk_bin)
    case $target in
      android-arm64) triple=aarch64-linux-android arch=aarch64 ;;
      android-arm) triple=armv7a-linux-androideabi arch=arm ;;
      android-x64) triple=x86_64-linux-android arch=x86_64 ;;
    esac
    cc=$bin/${triple}21-clang
    cross="--enable-cross-compile --target-os=android --arch=$arch
      --cc=$cc --ar=$bin/llvm-ar --nm=$bin/llvm-nm --ranlib=$bin/llvm-ranlib
      --strip=$bin/llvm-strip --disable-mediacodec --disable-jni"
    kind=elf
    ext=so
    ;;
  windows-x64 | windows-arm64)
    case $target in
      windows-x64) triple=x86_64-w64-mingw32 arch=x86_64 ;;
      windows-arm64) triple=aarch64-w64-mingw32 arch=aarch64 ;;
    esac
    cc=$triple-clang
    cross="--enable-cross-compile --target-os=mingw32 --arch=$arch
      --cross-prefix=$triple- --cc=$cc"
    threads="--disable-pthreads --enable-w32threads"
    kind=pe
    ext=dll
    ;;
  macos-x64 | macos-arm64 | ios-arm64 | iossim-arm64 | iossim-x64)
    case $target in
      macos-x64) sdk=macosx arch=x86_64 min=-mmacosx-version-min=10.14 ;;
      macos-arm64) sdk=macosx arch=arm64 min=-mmacosx-version-min=11.0 ;;
      ios-arm64) sdk=iphoneos arch=arm64 min=-miphoneos-version-min=12.0 ;;
      iossim-arm64)
        sdk=iphonesimulator arch=arm64 min=-mios-simulator-version-min=12.0 ;;
      iossim-x64)
        sdk=iphonesimulator arch=x86_64 min=-mios-simulator-version-min=12.0 ;;
    esac
    cc="xcrun -sdk $sdk clang"
    cflags="-arch $arch $min"
    cross="--enable-cross-compile --target-os=darwin --arch=$arch"
    kind=macho
    ext=dylib
    ;;
  *)
    echo "unknown target: $target" >&2
    exit 1
    ;;
esac

cd "$work"
if [ ! -f "$tarball" ]; then
  curl -sSfLO "https://ffmpeg.org/releases/$tarball"
fi
if command -v sha256sum >/dev/null; then
  echo "$sha256  $tarball" | sha256sum -c -
else
  echo "$sha256  $tarball" | shasum -a 256 -c -
fi
rm -rf "ffmpeg-$version" install
tar xf "$tarball"
cd "ffmpeg-$version"

# No assembly: the ATRAC decoders gain little from it, and it would need an
# assembler for each target. The threads are those of the system, which
# libavutil needs to initialize its tables safely: the native ones on
# Windows, so that no thread library of MinGW comes along, and POSIX
# threads elsewhere.
# shellcheck disable=SC2086
./configure \
  --prefix="$work/install" \
  --disable-shared --enable-static --enable-pic \
  --disable-autodetect --disable-everything \
  --disable-programs --disable-doc --disable-debug \
  --disable-avdevice --disable-avformat --disable-avfilter \
  --disable-swscale --disable-swresample --disable-network \
  --disable-asm $threads \
  --enable-decoder=atrac3,atrac3al,atrac3p,atrac3pal \
  --cc="$cc" --extra-cflags="$cflags" --extra-ldflags="$cflags" \
  $cross
make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
make install

# The build must stay LGPL: configure prints the license it chose.
grep -q '^#define FFMPEG_LICENSE "LGPL version 2.1 or later"' config.h

# the system libraries that the archives need
lib=$work/install/lib
libs=$(sed -n 's/^Libs\(\.private\)*: *//p' "$lib/pkgconfig/libavcodec.pc" \
  "$lib/pkgconfig/libavutil.pc" | tr '\n' ' ' |
  sed 's/-L[^ ]*//g; s/-lavutil//g; s/-lavcodec//g')

name=mmd_libav-$target.$ext
rm -f "$out/$name"
case $kind in
  elf)
    for s in $symbols; do echo "$s;"; done |
      { echo '{ global:'; cat; echo 'local: *; };'; } >"$work/exports.map"
    # shellcheck disable=SC2086
    $cc -shared -o "$out/$name" -Wl,-soname,libmmd_libav.so \
      -Wl,--whole-archive "$lib/libavcodec.a" "$lib/libavutil.a" \
      -Wl,--no-whole-archive -Wl,--version-script="$work/exports.map" \
      -Wl,-z,max-page-size=16384 -Wl,-z,noexecstack -Wl,--no-undefined \
      -Wl,-s -Wl,--as-needed $libs
    ;;
  pe)
    { echo 'EXPORTS'; for s in $symbols; do echo "  $s"; done; } \
      >"$work/exports.def"
    # shellcheck disable=SC2086
    $cc -shared -o "$out/$name" \
      -Wl,--whole-archive "$lib/libavcodec.a" "$lib/libavutil.a" \
      -Wl,--no-whole-archive "$work/exports.def" -Wl,-s $libs
    ;;
  macho)
    for s in $symbols; do echo "_$s"; done >"$work/exports.txt"
    # shellcheck disable=SC2086
    $cc $cflags -dynamiclib -o "$out/$name" \
      -install_name @rpath/libmmd_libav.dylib \
      -Wl,-headerpad_max_install_names \
      -Wl,-force_load,"$lib/libavcodec.a" -Wl,-force_load,"$lib/libavutil.a" \
      -Wl,-exported_symbols_list,"$work/exports.txt" -Wl,-x $libs
    ;;
esac

cd "$out"
if command -v sha256sum >/dev/null; then
  sha256sum "$name" >"$name.sha256"
else
  shasum -a 256 "$name" >"$name.sha256"
fi
cat "$name.sha256"
ls -l "$name"
