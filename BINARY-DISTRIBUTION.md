# Binary distribution

Application: `.`. Versions follow the root `pubspec.yaml`.

See [mp-build-tools](https://github.com/reki2000/mp-build-tools) for CI, internal verification, releases, signing and installation.

Pages: [stable](https://reki2000.github.io/fnesemu/) · [develop](https://reki2000.github.io/fnesemu/develop/).

Web emulation requires Wasm for N64 and exact 64-bit GBA/SH2 instructions. CI runs those cases on VM/Wasm across all hosts; the JavaScript fallback has these existing limitations. Filesystem/tool suites run on VM hosts.
