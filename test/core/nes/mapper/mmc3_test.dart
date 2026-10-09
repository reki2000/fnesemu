import 'dart:typed_data';

import 'package:fnesemu/core/nes/mapper/mmc3.dart';
import 'package:test/test.dart';

void main() {
  test('mmc3 irq fires at the latch+1-th a12 rising edge after reload', () {
    final m = MapperMMC3()
      ..setRom(Uint8List(0x2000), Uint8List(0x8000))
      ..init();
    var irq = false;
    m.holdIrq = (hold) => irq = hold;

    m.write(0xc000, 3); // latch
    m.write(0xc001, 0); // reload
    m.write(0xe001, 0); // enable

    void edge() {
      m.readVram(0x0000);
      m.readVram(0x1000);
    }

    for (int i = 0; i < 3; i++) {
      edge();
    }
    expect(irq, false);
    edge();
    expect(irq, true);

    m.write(0xe000, 0); // acknowledge
    expect(irq, false);
  });
}
