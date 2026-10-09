# Test
see docs/TEST.md

# Core boundary
- App/GUI depends only on public core interfaces and metadata, never concrete cores or core-specific IDs/formats.
- Each core owns ROM, disc and BIOS identification/interpretation. CoreFactory may reference concrete classes for registration/enumeration, but only delegates identification to core modules.
- Keep concrete-core registration separate from App/GUI; App/GUI must compile with any core omitted, including an empty registry.
- After adding/removing a core module, run `dart run tool/generate_core_registry.dart` in `packages/fnesemu_core`; do not modify App/GUI for it.
- The cores (`packages/fnesemu_core`: lib/core, lib/cdrom, lib/util, their tests and harnesses) are pure Dart and must not depend on Flutter; the GUI gives them the picked files.
