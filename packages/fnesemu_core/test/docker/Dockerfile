# The toolchains that the setup.py scripts under test/roms use to build public test ROMs that have no prebuilt release.
# setuplib.toolchain() builds this image on demand and runs a build inside it when a tool is missing on the host.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates git make python3 \
        gcc-mipsel-linux-gnu g++-mipsel-linux-gnu \
    && rm -rf /var/lib/apt/lists/*
