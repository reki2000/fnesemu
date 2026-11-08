import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/aica_dsp.dart';
import 'package:fnesemu_core/src/core/dc/aica_feg.dart';
import 'package:fnesemu_core/src/core/dc/aica_sound.dart';
import 'package:test/test.dart';

void main() {
  late List<int> regs;
  late DcAicaFeg feg;
  setUp(() {
    regs = List.filled(18, 0);
    regs[5] = 15 << 10;
    feg = DcAicaFeg();
  });
  test('rate 62 traverses the published full range in 14 milliseconds', () {
    regs[12] = 0x1ff8;
    regs[16] = 31 << 8;
    feg.start(8);
    for (var i = 0; i < 617; i++) {
      feg.advance(regs);
    }
    expect(feg.state, 0);
    expect(feg.level, closeTo(8 + 8176 * 617 / 617.4, 1e-8));
    feg.advance(regs);
    expect((feg.state, feg.level), (1, 0x1ff8));
  });
  test('zero rate holds, while equal targets complete one stage per edge', () {
    feg.start(8);
    regs[12] = 100;
    for (var i = 0; i < 100; i++) {
      feg.advance(regs);
    }
    expect((feg.state, feg.level), (0, 8));
    regs[12] = regs[13] = 8;
    feg.advance(regs);
    expect(feg.state, 1);
    feg.advance(regs);
    expect(feg.state, 2);
  });

  test('live rate and target changes retain cutoff and reset clears state', () {
    regs[12] = 0x1ff8;
    regs[16] = 31 << 8;
    feg.start(100);
    feg.advance(regs);
    final previous = feg.level;
    regs[16] = 0;
    feg.advance(regs);
    expect(feg.level, previous);
    regs[12] = 8;
    regs[16] = 31 << 8;
    feg.advance(regs);
    expect(feg.level, closeTo(100, 1e-10));
    feg.reset();
    expect((feg.state, feg.level), (3, 0));
  });
  group('sound integration', () {
    late DcAicaSound sound;
    void configure(int slot) {
      final base = slot * 0x80;
      sound.write(base, 0x4200);
      sound.write(base + 12, 511);
      sound.write(base + 0x10, 31);
      sound.write(base + 0x14, 15 << 10);
      sound.write(base + 0x28, 4);
      for (var offset = 0x2c; offset <= 0x3c; offset += 4) {
        sound.write(base + offset, 0x1ff8);
      }
    }

    setUp(() {
      sound = DcAicaSound(Uint8List(2 * 1024 * 1024), dsp: DcAicaDsp());
      configure(0);
      sound.write(0, 0xc200);
      sound.monitor = 0x4000;
    });
  });
}
