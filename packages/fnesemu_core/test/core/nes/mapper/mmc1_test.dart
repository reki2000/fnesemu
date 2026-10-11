import 'dart:typed_data';

import 'package:fnesemu_core/src/core/nes/mapper/mmc1.dart';
import 'package:test/test.dart';

void main() {
  test('mmc1 switches chr rom banks', () {
    final chr = Uint8List(0x8000); // 8 x 4k
    for (int i = 0; i < 8; i++) {
      chr[i * 0x1000] = i;
    }
    final m = MapperMMC1()
      ..setRom(chr, Uint8List(0x8000))
      ..init();

    void serial(int addr, int value) {
      for (int i = 0; i < 5; i++) {
        m.write(addr, (value >> i) & 1);
      }
    }

    serial(0x8000, 0x10 | 0x0c); // 4k chr mode
    serial(0xa000, 5);
    serial(0xc000, 3);
    expect(m.readVram(0x0000), 5);
    expect(m.readVram(0x1000), 3);

    serial(0x8000, 0x0c); // 8k chr mode
    serial(0xa000, 6);
    expect(m.readVram(0x0000), 6);
    expect(m.readVram(0x1000), 7);
  });

  test('mmc1 reset selects prg mode 3', () {
    final prg = Uint8List(0x10000); // 4 x 16k
    for (int i = 0; i < 4; i++) {
      prg[i * 0x4000] = i;
    }
    final m = MapperMMC1()
      ..setRom(Uint8List(0), prg)
      ..init();

    void serial(int addr, int value) {
      for (int i = 0; i < 5; i++) {
        m.write(addr, (value >> i) & 1);
      }
    }

    serial(0x8000, 0x08); // prg mode 2: fixed first bank at 8000
    serial(0xe000, 1);
    expect(m.read(0x8000), 0);
    m.write(0x8000, 0x80); // reset
    expect(m.read(0x8000), 1);
    expect(m.read(0xc000), 3);
  });
}
