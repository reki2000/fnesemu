import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps2/ps2.dart';
import 'package:fnesemu_core/src/state.dart';
import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

/// an ELF whose program counts in v0 and stores the count at 0x2000
Uint8List _countElf() {
  const entry = 0x100000;
  const code = [
    0x24420001, // addiu v0, v0, 1
    0xac022000, // sw v0, 0x2000(zero)
    0x1000fffd, // b entry
    0x00000000, // nop
  ];
  final body = ByteData(84 + code.length * 4);
  body.setUint32(0, 0x464c457f, Endian.little);
  body.setUint8(4, 1);
  body.setUint8(5, 1);
  body.setUint16(16, 2, Endian.little);
  body.setUint16(18, 8, Endian.little);
  body.setUint32(24, entry, Endian.little);
  body.setUint32(28, 52, Endian.little);
  body.setUint16(42, 32, Endian.little);
  body.setUint16(44, 1, Endian.little);
  body.setUint32(52, 1, Endian.little);
  body.setUint32(56, 84, Endian.little);
  body.setUint32(60, entry, Endian.little);
  body.setUint32(68, code.length * 4, Endian.little);
  body.setUint32(72, code.length * 4, Endian.little);
  for (var i = 0; i < code.length; i++) {
    body.setUint32(84 + i * 4, code[i], Endian.little);
  }
  return body.buffer.asUint8List();
}

Ps2 _ps2(bool jit) {
  final ps2 = Ps2(jit: jit)..setRom(_countElf());
  addTearDown(ps2.dispose);
  return ps2;
}

void _frames(Ps2 ps2, int n) {
  for (var i = 0; i < n; i++) {
    expect(ps2.runFrame(ps2.scanlinesInFrame).stopped, isFalse);
  }
}

void main() {
  for (final jit in [false, true]) {
    test('a restored ${jit ? 'JIT' : 'CPU'} PS2 continues like the original',
        () {
      if (jit && !JitRuntime.nativeSupported) {
        markTestSkipped('no native recompiler on this host');
        return;
      }
      final original = _ps2(jit);
      _frames(original, 2);
      original.io.gs.mem.bytes[1000] = 5;
      original.io.vu1.data[7] = 9;
      original.iopIo.spu2.ram[300] = 0x1234;
      final state = original.saveState();
      _frames(original, 2);

      final restored = _ps2(jit)..loadState(state);
      _frames(restored, 2);
      expect(restored.cpu.gpr, original.cpu.gpr);
      expect([restored.cpu.pc, restored.cpu.clocks],
          [original.cpu.pc, original.cpu.clocks]);
      expect(restored.bus.ram.sublist(0x2000, 0x2004),
          original.bus.ram.sublist(0x2000, 0x2004));
      expect(restored.io.gs.mem.bytes[1000], 5);
      expect(restored.io.vu1.data[7], 9);
      expect(restored.iopIo.spu2.ram[300], 0x1234);
      if (!jit) expect(restored.saveState(), original.saveState());
    });
  }

  test('a state of another BIOS is rejected', () {
    final state = _ps2(false).saveState();
    final other = _ps2(false)..setBiosFiles([Uint8List(16)..[0] = 1]);
    expect(() => other.loadState(state), throwsA(isA<StateMismatch>()));
  });
}
