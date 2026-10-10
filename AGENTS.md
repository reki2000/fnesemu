# Test
see docs/TEST.md

# Core boundary
- App/GUI depends only on public core interfaces and metadata, never concrete cores or core-specific IDs/formats.
- Each core owns ROM, disc and BIOS identification/interpretation: which system a ROM or a disc (given as a `CdromDrive`) is. Disc image formats (.cue/.iso/.bin) are not the cores' but `packages/cdrom_image`'s. CoreFactory may reference concrete classes for registration/enumeration, but only delegates identification to core modules.
- Keep concrete-core registration separate from App/GUI; App/GUI must compile with any core omitted, including an empty registry.
- After adding/removing a core module, run `dart run tool/generate_core_registry.dart` in `packages/fnesemu_core`; do not modify App/GUI for it.
- The cores (`packages/fnesemu_core`: lib/core, lib/util, their tests and harnesses) are pure Dart and must not depend on Flutter or on the app. Only the harnesses and the tests use `packages/cdrom_image` (dev dependency), with `tool/cdrom_drive.dart` (a simple drive without read-ahead or cache) and `tool/local_disc.dart` (dart:io files).
- `packages/cdrom_image` decodes disc images on its own virtual file system (`DiscFile`, `DiscDirectory`); it has no dependencies (not the cores, mp_bigfile_picker or dart:io). The app glues them: `lib/gui/picked_disc.dart` (picker files to cdrom_image) and `lib/gui/async_cdrom_drive.dart` (the cores' `CdromDrive` on a cdrom_image disc image, with read-ahead and cache).
