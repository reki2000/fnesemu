import 'dart:io';

import 'cputest_rom.dart';

/// Writes the self-checking CPU test ROM to test/core/gba/roms/arm7_cputest.gba.
///
///   dart run test/core/gba/gen_cputest_rom.dart
///
/// Load the ROM in a reference emulator (e.g. mGBA) and inspect EWRAM to
/// cross-check this emulator's expectations:
///   [0x02000000] = fail count, [0x02000004] = last failing case id,
///   [0x02000008] = 0x600dc0de once the run finished.
void main() {
  final rom = buildCpuTestRom();
  final file = File('test/core/gba/roms/arm7_cputest.gba')
    ..createSync(recursive: true)
    ..writeAsBytesSync(rom);
  // ignore: avoid_print
  print('wrote ${file.path} (${rom.length} bytes)');
}
