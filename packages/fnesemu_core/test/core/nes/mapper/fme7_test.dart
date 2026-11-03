import 'dart:typed_data';

import 'package:fnesemu_core/src/core/nes/mapper/fme7.dart';
import 'package:fnesemu_core/src/core/nes/mapper/sunsoft5b_apu.dart';
import 'package:test/test.dart';

MapperFme7 _mapper() {
  // 8 prg banks of 8KB and 8 chr banks of 1KB, each filled with its number
  final prg = Uint8List(0x10000);
  for (var b = 0; b < 8; b++) {
    prg.fillRange(b * 0x2000, (b + 1) * 0x2000, b);
  }
  final chr = Uint8List(0x2000);
  for (var b = 0; b < 8; b++) {
    chr.fillRange(b * 0x400, (b + 1) * 0x400, b);
  }
  return MapperFme7()
    ..setRom(chr, prg)
    ..init();
}

void main() {
  test('switches prg and chr banks by command and parameter', () {
    final m = _mapper();
    expect(m.read(0xe000), 7); // the last bank is fixed
    m.write(0x8000, 9);
    m.write(0xa000, 3);
    expect(m.read(0x8000), 3);
    m.write(0x8000, 2);
    m.write(0xa000, 5);
    expect(m.readVram(0x0800), 5);
  });

}
