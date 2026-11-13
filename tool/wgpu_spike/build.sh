#!/bin/sh
# Builds build/libgsgpu.so against wgpu-native. WGPU_NATIVE is the directory
# of an unpacked wgpu-native release (include/ and lib/).
set -e
cd "$(dirname "$0")"
: "${WGPU_NATIVE:?set WGPU_NATIVE to an unpacked wgpu-native release}"
mkdir -p build
cp "$WGPU_NATIVE/lib/libwgpu_native.so" build/
cc -O2 -fPIC -shared -Wall -Wextra -Wno-unused-parameter \
  -I"$WGPU_NATIVE/include" native/gsgpu.c \
  -Lbuild -lwgpu_native -Wl,-rpath,'$ORIGIN' -o build/libgsgpu.so
