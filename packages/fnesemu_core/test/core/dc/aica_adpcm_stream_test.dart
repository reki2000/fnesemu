import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/aica_adpcm_stream.dart';
import 'package:fnesemu_core/src/core/dc/aica_dsp.dart';
import 'package:fnesemu_core/src/core/dc/aica_sound.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/types.dart';
import 'package:test/test.dart';

void main() {
  test('published nibble order and quantization survive sequential lookahead',
      () {
    final memory = Uint8List.fromList([0x10, 0x32, 0x54, 0x76, 0]);
    final stream = DcAicaAdpcmStream(memory, start: 0, loopStart: 0, end: 8);
    const expected = [15, 62, 141, 252, 394, 603, 996, 1903];
    for (var i = 0; i < expected.length; i++) {
      expect(stream.sample(i), expected[i]);
      if (i > 0) expect(stream.sample(i - 1), expected[i - 1]);
    }
  });
  test('adaptive quantization is retained across the encoded loop boundary',
      () {
    final memory = Uint8List.fromList([0x10, 0x32, 0x54, 0x76, 0]);
    final stream = DcAicaAdpcmStream(memory, start: 0, loopStart: 0, end: 8);
    // Code 7 leaves step 1160; code 0 reduces it to 1042 at the boundary.
    expect(stream.sample(8), 2048);
    expect(stream.sample(9), 2438);
    expect(stream.sample(10), 3023);
  });
  test('loop history continues instead of replaying a decoded first pass', () {
    final memory = Uint8List(9)..fillRange(0, 9, 0x11);
    final stream = DcAicaAdpcmStream(memory, start: 0, loopStart: 12, end: 16);
    for (var i = 0; i < 500; i++) {
      expect(stream.sample(i), (i + 1) * 47);
    }
    expect(() => stream.sample(100), throwsArgumentError);
  });
  test(
      'loop refills read new encoded bytes while interpolation retains history',
      () {
    final memory = Uint8List(9)..fillRange(0, 9, 0x11);
    final stream = DcAicaAdpcmStream(memory, start: 0, loopStart: 12, end: 16);
    expect(stream.sample(16), 17 * 47);
    memory.fillRange(0, 9, 0x99);
    expect(stream.sample(17), 16 * 47);
    expect(stream.sample(16), 17 * 47);
    expect(stream.sample(20), 13 * 47);
  });
  test('large skips decode every intervening nibble and saturate both signs',
      () {
    final memory = Uint8List(9)..fillRange(0, 9, 0x11);
    final stream = DcAicaAdpcmStream(memory, start: 0, loopStart: 12, end: 16);
    expect(stream.sample(100000), 32767);
    memory.fillRange(0, 9, 0x99);
    expect(stream.sample(200000), -32768);
  });
  group('sound integration', () {
    late DcAicaSound sound;
    late Uint8List memory;
    late List<AudioBuffer> packets;
    void configure({int format = 3, int pitch = 0, bool loop = true}) {
      sound.write(0, 0x4000 | (loop ? 0x200 : 0) | (format << 7));
      sound.write(8, 12);
      sound.write(12, 16);
      sound.write(0x10, 31);
      sound.write(0x14, 15 << 10);
      sound.write(0x18, pitch);
      sound.write(0x24, 15 << 8);
      sound.write(0x28, 4);
      for (var offset = 0x2c; offset <= 0x3c; offset += 4) {
        sound.write(offset, 0x1ff8);
      }
    }

    void key({int format = 3, bool loop = true, bool on = true}) => sound.write(
        0, 0x8000 | (on ? 0x4000 : 0) | (loop ? 0x200 : 0) | (format << 7));
    setUp(() {
      memory = Uint8List(2 * 1024 * 1024)..fillRange(0, 9, 0x11);
      sound = DcAicaSound(memory, dsp: DcAicaDsp());
      packets = [];
      sound.setAudio(packets.add);
      sound.control = 15;
    });
    test('long-stream loops keep predictor history and current address wraps',
        () {
      configure();
      key();
      sound.advance(256);
      for (var i = 0; i < 256; i++) {
        expect(
            packets.single.buffer[i * 2], closeTo((i + 1) * 47 / 32768, 1e-7));
      }
      expect(sound.currentAddress, 16);
      expect(sound.readMonitor() & 0x8000, 0x8000);
      expect(sound.readMonitor() & 0x8000, 0);
    });
    test('normal ADPCM retains its repeating loop behavior', () {
      configure(format: 2);
      key(format: 2);
      sound.advance(256);
      expect(packets.single.buffer[17 * 2], 14 * 47 / 32768);
      expect(packets.single.buffer[21 * 2], 14 * 47 / 32768);
    });
    test('fractional pitch interpolates across the long-stream wrap', () {
      configure(pitch: 15 << 11);
      key();
      sound.advance(256);
      for (var i = 0; i < 256; i++) {
        expect(packets.single.buffer[i * 2],
            closeTo((1 + i / 2) * 47 / 32768, 1e-7));
      }
    });
    test('high pitch advances through all skipped loop histories', () {
      configure(pitch: 4 << 11);
      key();
      sound.advance(256);
      expect(packets.single.buffer[2], 17 * 47 / 32768);
      expect(packets.single.buffer[4], 33 * 47 / 32768);
      expect(packets.single.buffer[6], 49 * 47 / 32768);
      expect(packets.single.buffer[200], 32767 / 32768);
    });
    test('nonlooping streams stop after LEA without reading a wrapped sample',
        () {
      configure(loop: false);
      key(loop: false);
      sound.advance(256);
      expect(sound.active, isFalse);
      expect(packets.single.buffer[32], 17 * 47 / 32768);
      expect(packets.single.buffer[34], 0);
    });
    test('key-off and retrigger reset predictor and encoded stream position',
        () {
      configure();
      key();
      sound.advance(128);
      key(on: false);
      key();
      sound.advance(128);
      expect(packets.single.buffer[256], 47 / 32768);
    });
    test('alignment and live source mutations fail without partial changes',
        () {
      configure();
      sound.write(8, 13);
      expect(key, throwsA(isA<DcUnsupported>()));
      expect(sound.active, isFalse);
      sound.write(8, 12);
      key();
      for (final entry in [(0, 0xc300), (4, 4), (8, 8), (12, 20)]) {
        final previous = sound.read(entry.$1);
        expect(() => sound.write(entry.$1, entry.$2),
            throwsA(isA<DcUnsupported>()));
        expect(sound.read(entry.$1), previous);
      }
    });
    test('chunked and batched advancement return identical streaming audio',
        () {
      configure(pitch: 512);
      key();
      sound.advance(256);
      final expected = Float32List.fromList(packets.single.buffer);
      sound.reset();
      sound.control = 15;
      packets.clear();
      configure(pitch: 512);
      key();
      for (var i = 0; i < 256; i++) {
        sound.advance(1);
      }
      expect(packets.single.buffer, expected);
    });
  });
}
