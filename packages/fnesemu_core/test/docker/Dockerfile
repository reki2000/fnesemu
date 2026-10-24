# The toolchains that the setup.py scripts under test/e2e use to build public test ROMs that have no prebuilt release.
# setuplib.toolchain() builds this image on demand and runs a build inside it when a tool is missing on the host.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates cmake git make nasm python3 \
        gcc-mipsel-linux-gnu g++-mipsel-linux-gnu \
    && rm -rf /var/lib/apt/lists/*

# WLA DX (wla-z80, wlalink): the Z80 assembler of the SMS test ROMs
RUN git clone --depth 1 --branch v10.6 https://github.com/vhelin/wla-dx.git /tmp/wla-dx \
    && cmake -S /tmp/wla-dx -B /tmp/wla-dx/build -DCMAKE_BUILD_TYPE=Release \
    && cmake --build /tmp/wla-dx/build -j"$(nproc)" --target wla-z80 wlalink \
    && install /tmp/wla-dx/build/binaries/wla-z80 /tmp/wla-dx/build/binaries/wlalink /usr/local/bin/ \
    && rm -rf /tmp/wla-dx
