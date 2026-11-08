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
