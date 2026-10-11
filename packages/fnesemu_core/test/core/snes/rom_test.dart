import 'dart:typed_data';

import 'package:fnesemu_core/src/core/snes/rom/snes_file.dart';
import 'package:test/test.dart';

void main() {
  test('an interleaved HiROM image is put back in order', () {
    // 4 blocks of 32KB in HiROM order 0,1,2,3 are stored as 1,3,0,2
    final hiRom = Uint8List(0x20000);
    for (var b = 0; b < 4; b++) {
      hiRom.fillRange(b * 0x8000, b * 0x8000 + 0x10, b + 1);
    }
    final header = hiRom.buffer.asUint8List(0xffc0, 0x40);
    header.fillRange(0, 21, 0x41);
    header[0x15] = 0x21;
    header[0x1c] = 0xff;
    header[0x1d] = 0xff;
    header[0x3d] = 0x80;
    final image = Uint8List(0x20000);
    for (final (to, from) in [(0, 1), (1, 3), (2, 0), (3, 2)]) {
      image.setRange(to * 0x8000, (to + 1) * 0x8000, hiRom, from * 0x8000);
    }
    final file = SnesFile()..load(image);
    expect(file.mapping, SnesMapping.hiRom);
    expect([for (var b = 0; b < 4; b++) file.rom[b * 0x8000]], [1, 2, 3, 4]);
  });
}
