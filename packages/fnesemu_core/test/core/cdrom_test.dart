import 'dart:typed_data';

import 'package:cdrom_image/memory.dart';
import 'package:fnesemu_core/src/cdrom.dart';
import 'package:test/test.dart';

import '../../tool/cdrom_drive.dart';

void main() {
  test('the disc is read by absolute sectors, null while pending', () async {
    final data = Uint8List(4 * cdSectorSize);
    for (int i = 0; i < 4; i++) {
      data.fillRange(i * cdSectorSize, (i + 1) * cdSectorSize, i);
    }
    final drive = SimpleCdromDrive();
    await drive
        .insert(memoryDisc("a.bin", {"a.bin": MemoryDiscFile("a.bin", data)}));
    final disc = drive;
    expect(disc.isEmpty, false);
    expect(disc.totalSectors, 4);
    expect(disc.readAbsolute(150 + 1), isNull);
    await drive.settle();
    expect(disc.readAbsolute(150 + 1)![16], 1);
    expect(disc.readAbsolute(149), isEmpty);
    expect(EmptyCdromDrive().isEmpty, true);
  });
}
