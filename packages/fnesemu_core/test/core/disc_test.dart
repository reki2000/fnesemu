import 'dart:typed_data';

import 'package:cdrom_image/memory.dart';
import 'package:fnesemu_core/core/disc.dart';
import 'package:test/test.dart';

import '../../tool/cdrom_drive.dart';

void main() {
  test('Disc reads with absolute sectors and null while pending', () async {
    final data = Uint8List(4 * Disc.sectorSize);
    for (int i = 0; i < 4; i++) {
      data.fillRange(i * Disc.sectorSize, (i + 1) * Disc.sectorSize, i);
    }
    final drive = SimpleCdromDrive();
    await drive.insert(
        memoryDisc("a.bin", {"a.bin": MemoryDiscFile("a.bin", data)}));
    final disc = Disc(drive);
    expect(disc.isEmpty, false);
    expect(disc.totalSectors, 4);
    expect(disc.read(150 + 1), isNull);
    await drive.settle();
    expect(disc.read(150 + 1)![16], 1);
    expect(disc.read(149), isEmpty);
    expect(Disc.empty().isEmpty, true);
  });
}
