import 'dart:typed_data';

import 'package:fnesemu_core/core/nes/mapper/namco163.dart';
import 'package:test/test.dart';

void main() {
  test('mapper 19 irq counter counts every cpu cycle', () {
    final m = MapperNamco163()
      ..setRom(Uint8List(0x2000), Uint8List(0x8000))
      ..init();
    var irq = false;
    m.holdIrq = (hold) => irq = hold;

    m.write(0x5000, 0xff - 100);
    m.write(0x5800, 0x80 | 0x7f); // enable, counter = 0x7fff - 100
    m.handleClock(99);
    expect(irq, false);
    m.handleClock(100);
    expect(irq, true);
  });
}
