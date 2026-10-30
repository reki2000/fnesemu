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

  test('long inactive spans preserve exact cycle phase in browser arithmetic',
      () {
    final small = DcAicaLfo(), large = DcAicaLfo();
    expect(
        large.sample(4410000 * 1000000 + 1234, fast), small.sample(1234, fast));
  });

  test(
      'saw, square and triangle amplitude waveforms cover unsigned eight-bit levels',
      () {
    const expected = [
      [0, 64, 128, 192, 255],
      [0, 0, 255, 255, 255],
      [0, 128, 255, 128, 2]
    ];
    for (var wave = 0; wave < 3; wave++) {
      final lfo = DcAicaLfo();
      expect([
        for (final tick in [0, 64, 128, 192, 255])
          lfo.sample(tick, fast | (wave << 3)).$1
      ], expected[wave]);
    }
  });

  test(
      'pitch waveforms use signed levels and the documented square-wave polarity',
      () {
    const expected = [
      [-128, -64, 0, 64, 127],
      [127, 127, -128, -128, -128],
      [0, 127, 0, -128, -2]
    ];
    for (var wave = 0; wave < 3; wave++) {
      final lfo = DcAicaLfo();
      expect([
        for (final tick in [0, 64, 128, 192, 255])
          lfo.sample(tick, fast | (wave << 8)).$2
      ], expected[wave]);
    }
  });

  test('all seven pitch depths reproduce the printed rounded cent endpoints',
      () {
    const endpoints = [
      (-3, 2),
      (-7, 5),
      (-14, 12),
      (-27, 25),
      (-55, 52),
      (-112, 103),
      (-231, 202)
    ];
    for (var depth = 1; depth <= 7; depth++) {
      int cents(int code) => (1200 *
              math.log(DcAicaLfo.pitchStep(0, depth, code) / (1 << 18)) /
              math.ln2)
          .round();
      expect((cents(-128), cents(127)), endpoints[depth - 1]);
    }
  });

  test(
      'pitch modulation truncates in the F-number domain before octave scaling',
      () {
    expect(DcAicaLfo.pitchStep(512, 7, -128), 1344 << 8);
    expect(DcAicaLfo.pitchStep(512, 7, 127), 1726 << 8);
    expect(DcAicaLfo.pitchStep((15 << 11) | 512, 7, -128), 1344 << 7);
    expect(DcAicaLfo.pitchStep(8 << 11, 0, 127), 1024);
    expect(DcAicaLfo.pitchStep(7 << 11, 0, -128), 1024 << 15);
  });

  test('amplitude depths are attenuation-only with a unity zero-depth path',
      () {
    expect(DcAicaLfo.amplitudeGain(0, 255), 1);
    for (var depth = 1; depth < 8; depth++) {
      expect(DcAicaLfo.amplitudeGain(depth, 0), 1);
    }
    expect(DcAicaLfo.amplitudeGain(1, 255), closeTo(0.9549925860, 1e-10));
    expect(DcAicaLfo.amplitudeGain(7, 255), closeTo(0.06309573445, 1e-10));
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

  test(
      'noise is reproducible per slot and independent of reset and frequency controls',
      () {
    final first = DcAicaLfo(seed: 123),
        second = DcAicaLfo(seed: 123),
        different = DcAicaLfo(seed: 456);
    const waves = (3 << 8) | (3 << 3);
    final values = <int>[];
    var differences = 0;
    for (var tick = 0; tick < 256; tick++) {
      final a = first.sample(tick, waves | 0x8000),
          b = second.sample(tick, waves | fast);
      final c = different.sample(tick, waves);
      expect(a, b);
      expect(a.$2, a.$1.toSigned(8));
      values.add(a.$1);
      if (a != c) differences++;
    }
    expect(values.toSet().length, greaterThan(64));
    expect(differences, greaterThan(128));
  });

  test(
      'full LFO reset restores its initial phase and deterministic noise epoch',
      () {
    final lfo = DcAicaLfo();
    final first = lfo.sample(0, 0x318);
    lfo.sample(1000, fast);
    lfo.reset();
    expect(lfo.sample(0, 0x318), first);
    expect(lfo.phaseCode, 0);
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
      packets = [];
      core.onAudio(packets.add);
      write(0x2800, 15);
    });

    test(
        'zero modulation depths preserve PCM samples despite nonzero waveform settings',
        () {
      configure(0);
      write(0x1c, fast | 0x318);
      key();
      frames(256);
      expect(packets.single.buffer, everyElement(0.5));
      expect(read(0x2814), 256);
    });

    test(
        'saw amplitude modulation reaches Core audio at the expected sample phases',
        () {
      configure(0);
      write(0x1c, fast | 7);
      key();
      frames(256);
      expect(packets.single.buffer[0], 0.5);
      expect(packets.single.buffer[128 * 2], closeTo(0.1249157107, 1e-8));
      expect(packets.single.buffer[255 * 2], closeTo(0.0315478672, 1e-8));
    });

    test(
        'square amplitude modulation changes between full and -24 dB half-cycles',
        () {
      configure(0);
      write(0x1c, fast | (1 << 3) | 7);
      key();
      frames(256);
      expect(packets.single.buffer[127 * 2], 0.5);
      expect(packets.single.buffer[128 * 2], closeTo(0.0315478672, 1e-8));
    });

    test(
        'pitch modulation changes actual source advancement at the half-cycle boundary',
        () {
      configure(0);
      write(0x1c, fast | (1 << 8) | (7 << 5));
      key();
      frames(128);
      expect(read(0x2814), 143);
      frames(128);
      expect(read(0x2814), 255);
      expect(packets.single.buffer, everyElement(0.5));
    });

    test(
        'pitch-modulated PCM interpolation uses the changed fractional position',
        () {
      configure(0);
      for (var i = 0; i <= 1023; i++) {
        core.bus.aica.memory.setUint16LE(0x1000 + i * 2, i * 24);
      }
      write(0x1c, fast | (1 << 8) | (7 << 5));
      key();
      frames(256);
      expect(
          packets.single.buffer[2], closeTo((1151 / 1024) * 24 / 32768, 1e-9));
    });

    test(
        'LFO amplitude affects DSP input before the independent direct-send control',
        () {
      configure(0, direct: 0, dspSend: 15);
      write(0x1c, fast | (1 << 3) | 7);
      key();
      frames(129);
      expect(read(0x4500) | (read(0x4504) << 4), 16540);
    });

    test('PCM8 and ADPCM sources both pass through amplitude modulation', () {
      for (final format in [1, 2]) {
        core = Dc();
        packets.clear();
        core.onAudio(packets.add);
        write(0x2800, 15);
        configure(0, format: format, sample: 64, end: 511);
        write(0x1c, fast | (1 << 3) | 7);
        key();
        frames(256);
        expect(packets.single.buffer[0], format == 1 ? 0.5 : 47 / 32768);
        expect(packets.single.buffer[128 * 2],
            closeTo((format == 1 ? 0.5 : 6063 / 32768) * 0.06309573445, 1e-8));
      }
    });

    test('LFORE holds the oscillator until an ARM byte write releases it', () {
      configure(0);
      write(0x1c, 0x8000 | fast | 7);
      key();
      frames(128);
      expect(read(0x1c) & 0x8000, 0x8000);
      core.bus.aica.write(0x1d, 1, 0x7c, fromArm: true);
      frames(128);
      expect(packets.single.buffer.take(128 * 2), everyElement(0.5));
      expect(packets.single.buffer[128 * 2], 0.5);
      expect(packets.single.buffer[255 * 2], lessThan(0.2));
    });

    test('live frequency writes retain the already advanced oscillator phase',
        () {
      configure(0);
      write(0x1c, fast | 7);
      key();
      frames(128);
      write(0x1c, 7);
      frames(128);
      expect(packets.single.buffer[128 * 2], closeTo(0.1249157107, 1e-8));
    });

    test(
        'disabled modulation retains the free-running phase for later enabling',
        () {
      configure(0);
      write(0x1c, fast);
      key();
      frames(128);
      write(0x1c, fast | 7);
      frames(128);
      expect(packets.single.buffer[127 * 2], 0.5);
      expect(packets.single.buffer[128 * 2], closeTo(0.1249157107, 1e-8));
    });

    test(
        'inactive oscillators advance lazily without requiring an audio callback',
        () {
      core = Dc();
      write(0x2800, 15);
      configure(0, loop: true, end: 1);
      write(0x1c, fast | 7);
      frames(128);
      core.onAudio(packets.add);
      key();
      frames(256);
      expect(packets.single.buffer[0], closeTo(0.1249157107, 1e-8));
      expect(packets.single.buffer[128 * 2], 0.5);
    });

    test(
        'key-off and key-on restart the source without implicitly resetting the LFO',
        () {
      configure(0, loop: true, end: 1);
      write(0x1c, fast | 7);
      key();
      frames(128);
      key(on: false);
      key();
      frames(128);
      expect(packets.single.buffer[128 * 2], closeTo(0.1249157107, 1e-8));
    });

    test('each voice has independent LFO reset state and modulation settings',
        () {
      configure(0, pan: 31);
      configure(1, pan: 15);
      write(0x1c, 0x8000 | fast | 7);
      write(0x9c, fast | (1 << 3) | 7);
      key(slot: 1);
      frames(256);
      expect(packets.single.buffer[128 * 2], 0.5);
      expect(packets.single.buffer[128 * 2 + 1], closeTo(0.0315478672, 1e-8));
    });

    test('deterministic noise modulation is reproducible after full reset', () {
      configure(0);
      write(0x1c, 0x318 | 7 | (7 << 5));
      key();
      frames(256);
      final first = packets.single.buffer.toList();
      core.reset();
      packets.clear();
      write(0x2800, 15);
      configure(0);
      write(0x1c, 0x318 | 7 | (7 << 5));
      key();
      frames(256);
      expect(packets.single.buffer, first);
      expect(first.toSet().length, greaterThan(64));
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
