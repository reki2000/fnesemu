# Test
see docs/TEST.md

# Architecture
Follow the design rules in ARCHITECTURE.md: the parts, the direction of the
dependencies, and the interfaces between them.
- After adding/removing a core module, run `dart run tool/generate_core_registry.dart` in `packages/fnesemu_core`; do not modify App/GUI for it.
