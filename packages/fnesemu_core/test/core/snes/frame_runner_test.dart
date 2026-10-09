import 'dart:typed_data';

import 'package:fnesemu_core/core/snes/snes.dart';
import 'package:fnesemu_core/core/types.dart';
import 'package:test/test.dart';

Snes createCore({bool stop = false}) {
  final rom = Uint8List(0x8000)..setAll(0, [stop ? 0xdb : 0xea, 0x80, 0xfd]);
  rom[0x7ffd] = 0x80;
  return Snes()..setRom(rom);
}

void main() {
  test('a stopped CPU keeps advancing peripherals through a frame', () {
    final reference = createCore(stop: true), batched = createCore(stop: true);
    var expected = ExecResult(0, false, false);
    var lines = 0;
    while (lines < reference.scanlinesInFrame) {
      expected = reference.exec(false);
      expect(expected.stopped, isFalse);
      if (expected.scanlineRendered) lines++;
    }
    final actual = batched.runFrame(batched.scanlinesInFrame);
    expect(reference.cpu.stopped, isTrue);
    expect(batched.cpu.stopped, isTrue);
    expect(actual.stopped, isFalse);
    expect(actual.scanlineRendered, isTrue);
    expect(actual.elapsedClocks, expected.elapsedClocks);
    expect(batched.dump(), reference.dump());
  });

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
