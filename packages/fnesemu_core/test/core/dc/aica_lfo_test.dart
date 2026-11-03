import 'dart:math' as math;

import 'package:fnesemu_core/src/core/dc/aica.dart';
import 'package:fnesemu_core/src/core/dc/aica_lfo.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/types.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

void main() {
  const fast = 31 << 10;
  test('published low and high frequency values advance the rational phase',
      () {
    final low = DcAicaLfo(), high = DcAicaLfo();
    low.sample(44100, 0);
    high.sample(44100, fast);
    expect(low.phaseCode, 43); // 0.17 cycles * 256.
    expect(high.phaseCode, 76); // Fractional part of 172.3 cycles * 256.
  });







  test(
      'frequency changes retain phase while the reset level holds periodic waves at zero',
      () {
    final lfo = DcAicaLfo();
    lfo.sample(128, fast);
    lfo.write(128, fast, 0);
    lfo.sample(129, 0);
    expect(lfo.phaseCode, 128);
    lfo.write(129, 0, 0x8000 | fast);
    lfo.sample(500, 0x8000 | fast);
    expect(lfo.phaseCode, 0);
    lfo.write(500, 0x8000 | fast, fast);
    lfo.sample(501, fast);
    expect(lfo.phaseCode, 1);
  });



  group('slot and Core integration', () {
    const base = 0xa0700000;
    late Dc core;
    late List<AudioBuffer> packets;
    int clocks(int samples) => (samples * DcAica.masterHz + 44099) ~/ 44100;
    void write(int offset, int value) => core.bus.write32(base + offset, value);
    int read(int offset) => core.bus.read32(base + offset);
    void frames(int count) => core.bus.tickMasterClocks(clocks(count));
    void configure(int slot,
        {int format = 0,
        int sample = 16384,
        int end = 1023,
        bool loop = false,
        int pan = 0,
        int direct = 15,
        int dspSend = 0}) {
      final reg = slot * 0x80, start = 0x1000 + slot * 0x1000;
      write(reg, 0x4000 | (format << 7) | (loop ? 0x200 : 0));
      write(reg + 4, start);
      write(reg + 12, end);
      write(reg + 0x10, 31);
      write(reg + 0x14, 15 << 10);
      write(reg + 0x20, dspSend << 4);
      write(reg + 0x24, (direct << 8) | pan);
      write(reg + 0x28, 4);
      for (var offset = 0x2c; offset <= 0x3c; offset += 4) {
        write(reg + offset, 0x1ff8);
      }
      if (format == 2) {
        core.bus.aica.memory.fillRange(start, start + end ~/ 2 + 1, 0x11);
      } else {
        for (var i = 0; i <= end; i++) {
          if (format == 0) {
            core.bus.aica.memory.setUint16LE(start + i * 2, sample);
          } else {
            core.bus.aica.memory[start + i] = sample & 255;
          }
        }
      }
    }

    void key({int slot = 0, bool on = true}) => write(slot * 0x80,
        (read(slot * 0x80) & ~0x4000) | 0x8000 | (on ? 0x4000 : 0));
    setUp(() {
      core = Dc();
      addTearDown(core.dispose);
      packets = [];
      core.onAudio(packets.add);
      write(0x2800, 15);
    });















    test(
        'batched clock advancement matches short chunks for combined amplitude and pitch LFO',
        () {
      void setup() {
        configure(0);
        for (var i = 0; i <= 1023; i++) {
          core.bus.aica.memory.setUint16LE(0x1000 + i * 2, i * 24);
        }
        write(0x1c, fast | (2 << 8) | (7 << 5) | 7);
        key();
      }

      setup();
      frames(256);
      final expected = packets.single.buffer.toList();
      final address = read(0x2814);
      core = Dc();
      addTearDown(core.dispose);
      packets.clear();
      core.onAudio(packets.add);
      write(0x2800, 15);
      setup();
      var remaining = clocks(256);
      while (remaining > 0) {
        final count = math.min(17, remaining);
        core.bus.tickMasterClocks(count);
        remaining -= count;
      }
      expect(packets.single.buffer, expected);
      expect(read(0x2814), address);
    });
  });
}
