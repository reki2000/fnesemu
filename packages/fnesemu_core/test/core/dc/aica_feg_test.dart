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
  test('four stages reach targets in both directions and release holds', () {
    regs[12] = 10;
    regs[13] = 8;
    regs[14] = 11;
    regs[15] = 8;
    regs[16] = regs[17] = 0x1f1f;
    feg.start(8);
    feg.advance(regs);
    expect((feg.state, feg.level), (1, 10));
    feg.advance(regs);
    expect((feg.state, feg.level), (2, 8));
    feg.advance(regs);
    expect((feg.state, feg.level), (2, 11));
    feg.release(regs[14]);
    feg.advance(regs);
    expect((feg.state, feg.level), (3, 8));
    feg.advance(regs);
    expect((feg.state, feg.level), (3, 8));
  });
  test('key scaling uses signed octave and FNS unless KRS is disabled', () {
    regs[12] = 0x1ff8;
    regs[16] = 30 << 8;
    regs[5] = 1 << 10;
    feg.start(8);
    feg.advance(regs);
    final rate62 = feg.level;
    regs[6] = 1 << 9;
    feg.start(8);
    feg.advance(regs);
    expect(feg.level - 8, closeTo(8176 / (12 * 44.1), 1e-10));
    regs[6] = 15 << 11;
    feg.start(8);
    feg.advance(regs);
    expect(feg.level, lessThan(rate62));
    regs[5] = 15 << 10;
    feg.start(8);
    feg.advance(regs);
    expect(feg.level - 8, closeTo(8176 / (22 * 44.1), 1e-10));
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
    test('FEG monitor exposes independent 13-bit cutoff and stage', () {
      expect(sound.readMonitor(), 0x1ff8);
      sound.advance(1);
      expect(sound.readMonitor(), 0x3ff8);
      sound.advance(1);
      expect(sound.readMonitor(), 0x5ff8);
      sound.monitor = 0;
      expect(sound.readMonitor() & 0x1fff, 0);
    });
    test('key-off releases and retrigger restarts attack', () {
      sound.advance(2);
      sound.write(0, 0x8200);
      expect(sound.readMonitor(), 0x7ff8);
      sound.write(0, 0xc200);
      expect(sound.readMonitor(), 0x1ff8);
      sound.reset();
      sound.monitor = 0x4000;
      expect(sound.readMonitor(), 0x6000);
    });
    test('slot selection and peeks preserve independent states', () {
      configure(1);
      sound.advance(2);
      sound.monitor = 0x4100;
      expect(sound.readMonitor(sideEffects: false), 0x6000);
      sound.monitor = 0x4000;
      expect(sound.readMonitor(sideEffects: false), 0x5ff8);
    });
  });
}
