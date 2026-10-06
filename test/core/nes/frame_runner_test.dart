import 'dart:typed_data';

import 'package:fnesemu/core/nes/nes.dart';
import 'package:fnesemu/core/types.dart';
import 'package:test/test.dart';

Nes createCore() {
  final rom = Uint8List(16 + 0x4000 + 0x2000);
  rom.setAll(0, [0x4e, 0x45, 0x53, 0x1a, 1, 1]);
  rom.setAll(16, [0xea, 0x4c, 0, 0x80]);
  rom[16 + 0x3ffd] = 0x80;
  return Nes()..setRom(rom);
}

void main() {
  test('frame execution matches instruction stepping across partial frames',
      () {
    final reference = createCore(), batched = createCore();
    final expectedAudio = <double>[], actualAudio = <double>[];
    reference.onAudio((b) => expectedAudio.addAll(b.buffer));
    batched.onAudio((b) => actualAudio.addAll(b.buffer));
    for (final count in [
      0,
      1,
      17,
      reference.scanlinesInFrame - 18,
      reference.scanlinesInFrame,
      3,
      reference.scanlinesInFrame + 5
    ]) {
      var expected = ExecResult(0, false, false);
      var lines = 0;
      while (lines < count) {
        expected = reference.exec(false);
        expect(expected.stopped, isFalse);
        if (expected.scanlineRendered) lines++;
      }
      final actual = batched.runFrame(count);
      expect(actual.stopped, isFalse);
      expect(actual.scanlineRendered, count > 0);
      if (count > 0) expect(actual.elapsedClocks, expected.elapsedClocks);
      expect(batched.dump(), reference.dump());
      expect(batched.imageBuffer().buffer, reference.imageBuffer().buffer);
      expect(actualAudio, expectedAudio);
      for (var i = 0; i < 11; i++) {
        final a = batched.exec(true), b = reference.exec(true);
        expect(a.elapsedClocks, b.elapsedClocks);
        expect(a.scanlineRendered, b.scanlineRendered);
      }
    }
    reference.reset();
    batched.reset();
    var lines = 0;
    while (lines < reference.scanlinesInFrame) {
      if (reference.exec(false).scanlineRendered) lines++;
    }
    batched.runFrame(batched.scanlinesInFrame);
    expect(batched.dump(), reference.dump());
    expect(actualAudio, expectedAudio);
  });
}
