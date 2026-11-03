import 'dart:typed_data';

import 'package:fnesemu_core/src/core/n64/n64.dart';
import 'package:fnesemu_core/src/types.dart';
import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

N64 createCore({bool stop = false, bool jit = true}) {
  final rom = ByteData(0x1008);
  rom.setUint32(0, 0x80371240);
  rom.setUint32(8, 0x80000400);
  rom.setUint32(0x1000, stop ? 0x70000000 : 0x1000ffff);
  final core = N64(jit: jit)..setRom(rom.buffer.asUint8List());
  addTearDown(core.dispose);
  core.reset();
  return core;
}

void main() {

  test('a suspended JIT runs frames with the interpreter and can resume', () {
    if (!JitRuntime.nativeSupported) {
      markTestSkipped('no native recompiler on this host');
      return;
    }
    N64 spin(bool enabled) {
      final bytes = ByteData(0x100c);
      bytes.setUint32(0, 0x80371240);
      bytes.setUint32(8, 0x80000400);
      bytes.setUint32(0x1000, 0x24210001);
      bytes.setUint32(0x1004, 0x1000fffe);
      final core = N64(jit: enabled)..setRom(bytes.buffer.asUint8List());
      core.reset();
      addTearDown(core.dispose);
      return core;
    }

    final reference = spin(false), actual = spin(true);
    actual.jitSuspended = true;
    reference.runFrame(reference.scanlinesInFrame);
    actual.runFrame(actual.scanlinesInFrame);
    expect(actual.jitClocks, 0);
    expect(actual.dump(), reference.dump());
    actual.jitSuspended = false;
    actual.runFrame(actual.scanlinesInFrame);
    expect(actual.jitClocks, greaterThan(0));
  });


  test('frame execution matches instruction stepping across partial frames',
      () {
    final reference = createCore(jit: false), batched = createCore();
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
