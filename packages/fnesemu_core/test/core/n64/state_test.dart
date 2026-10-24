import 'dart:typed_data';

import 'package:fnesemu_core/src/core/n64/n64.dart';
import 'package:fnesemu_core/src/sram.dart';
import 'package:fnesemu_core/src/state.dart';
import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

/// A ROM whose program counts in r1, stores the count to RAM, reads Count
/// and loops while timer interrupts arrive.
Uint8List _rom({int salt = 0}) {
  final bytes = ByteData(0x1040);
  bytes.setUint32(0, 0x80371240);
  bytes.setUint32(8, 0x80000400);
  final code = [
    0x24210001, // addiu r1, r1, 1
    0x3c028000, // lui r2, 0x8000
    0xac412000, // sw r1, 0x2000(r2)
    0x40034800, // mfc0 r3, Count
    0x1000fffb, // b back to the start
    0x00000000,
  ];
  for (var i = 0; i < code.length; i++) {
    bytes.setUint32(0x1000 + i * 4, code[i]);
  }
  bytes.setUint32(0x1030, salt);
  return bytes.buffer.asUint8List();
}

N64 _core(bool jit, {int salt = 0}) {
  final core = N64(jit: jit)
    ..setSram(Sram())
    ..setRom(_rom(salt: salt));
  core.reset();
  // The timer handler rearms Compare 5000 counts ahead and returns.
  const handler = [0x40044800, 0x24841388, 0x40845800, 0x42000018];
  for (var i = 0; i < handler.length; i++) {
    core.bus.ramWrite(0x180 + i * 4, handler[i], 4);
  }
  core.cpu.cop0[11] = 5000;
  core.cpu.cop0[12] = 0x8001;
  addTearDown(core.dispose);
  return core;
}

void _frames(N64 core, int n) {
  for (var i = 0; i < n; i++) {
    expect(core.runFrame(core.scanlinesInFrame).stopped, isFalse);
  }
}

void main() {
  for (final jit in [false, true]) {
    test('a restored ${jit ? 'JIT' : 'CPU'} core continues like the original',
        () {
      if (jit && !JitRuntime.nativeSupported) {
        markTestSkipped('no native recompiler on this host');
        return;
      }
      final original = _core(jit);
      _frames(original, 3);
      // The handler has rearmed Compare, so timer interrupts were taken.
      expect(original.cpu.cop0[11], isNot(5000));
      original.padDown(0, original.buttons.first);
      final state = original.saveState();
      _frames(original, 4);

      final restored = _core(jit);
      restored.loadState(state);
      _frames(restored, 4);
      expect(restored.dump(), original.dump());
      expect(restored.bus.ram, original.bus.ram);
      expect(restored.bus.mi, original.bus.mi);
      expect(restored.bus.held, original.bus.held);
      expect(restored.saveState(), original.saveState());
    });
  }

  test('saving a restored state reproduces it, including HLE state', () {
    final core = _core(false);
    _frames(core, 2);
    core.graphics.segments[3] = 0x123456;
    core.graphics.depths[0x100000] = Float64List.fromList([1.5, -2]);
    core.graphics.stack.add(List<double>.filled(16, 0.25));
    core.graphics.tiles[2].sMask = 5;
    core.audio.memory[100] = 7;
    core.audio.reverb = -9;
    core.cpu.fpu.wide = true;
    core.cpu.fpu.control = 0x800001;
    core.padDown(0, core.buttons.last);
    final state = core.saveState();
    final copy = _core(false)..loadState(state);
    expect(copy.saveState(), state);
    expect(copy.graphics.depths[0x100000], [1.5, -2]);
    expect(copy.audio.reverb, -9);
  });

  test('states of other media, cores or versions are rejected', () {
    final state = (_core(false)..runFrame(10)).saveState();
    expect(() => _core(false, salt: 1).loadState(state),
        throwsA(isA<StateMismatch>()));
    final other = StateWriter('ss', 1, 0).take();
    expect(() => _core(false).loadState(other),
        throwsA(isA<StateMismatch>()));
    expect(() => _core(false).loadState(Uint8List(3)),
        throwsA(isA<StateMismatch>()));
  });
}
