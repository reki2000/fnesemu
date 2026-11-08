import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/aica.dart';
import 'package:fnesemu_core/src/core/dc/aica_dsp.dart';
import 'package:fnesemu_core/src/core/dc/aica_sound.dart';
import 'package:fnesemu_core/src/types.dart';
import 'package:test/test.dart';

void main() {
  late DcAicaDsp dsp;
  late Uint8List wave;
  setUp(() {
    dsp = DcAicaDsp();
    wave = Uint8List(0x200000);
  });
  test(
      'all four ring sizes decrement once per sample and wrap in constant time',
      () {
    for (var size = 0; size < 4; size++) {
      dsp.reset();
      dsp.write(0x2804, size << 13);
      final length = 8192 << size;
      expect(dsp.ringCounter, 0);
      dsp.advanceSamples(1);
      expect(dsp.ringCounter, length - 1);
      dsp.advanceSamples(length - 1);
      expect(dsp.ringCounter, 0);
      dsp.advanceSamples(1000000000000 + 17);
      expect(
          dsp.ringCounter, (length - (1000000000000 + 17) % length) % length);
    }
  });
  test('TABLE gates both decrement offset and ring-length mask', () {
    dsp.write(0x3200, 0x9000);
    dsp.advanceSamples(3);
    expect(dsp.relativeWordAddress(0), 0xffd);
    expect(dsp.relativeWordAddress(0, table: true), 0x9000);
    expect(dsp.relativeWordAddress(0, table: true, next: true), 0x9001);
  });
  test('ring resize masks the retained counter without resetting its phase',
      () {
    dsp.write(0x2804, 3 << 13);
    dsp.advanceSamples(1);
    expect(dsp.ringCounter, 65535);
    dsp.write(0x2804, 0);
    expect(dsp.ringCounter, 8191);
    expect(() => dsp.advanceSamples(-1), throwsArgumentError);
    expect(dsp.ringCounter, 8191);
  });
}
