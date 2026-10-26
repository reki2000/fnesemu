import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ss/sh2/sh2.dart';
import 'package:fnesemu_core/src/core/ss/ss.dart';
import 'package:fnesemu_core/src/sram.dart';
import 'package:fnesemu_core/src/state.dart';
import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

/// A BIOS whose master CPU counts in r2 and stores the count to work RAM.
Uint8List _bios() {
  final bios = ByteData(0x80000);
  bios.setUint32(0, 0x1000); // reset PC
  bios.setUint32(4, 0x06004000); // reset SP
  const code = [
    0xd103, // mov.l @(12, pc), r1
    0x7201, // add #1, r2
    0x2122, // mov.l r2, @r1
    0xaffc, // bra to add
    0x0009, // nop
  ];
  for (var i = 0; i < code.length; i++) {
    bios.setUint16(0x1000 + i * 2, code[i]);
  }
  bios.setUint32(0x1010, 0x06001000);
  return bios.buffer.asUint8List();
}

Ss _ss(bool jit) {
  final ss = Ss(jit: jit)
    ..setSram(Sram())
    ..setRom(_bios());
  ss.reset();
  addTearDown(ss.dispose);
  return ss;
}

void _frames(Ss ss, int n) {
  for (var i = 0; i < n; i++) {
    expect(ss.runFrame(ss.scanlinesInFrame).stopped, isFalse);
  }
}

Uint8List _save(Ss ss) {
  final w = StateWriter('ss-devices', 1, 0);
  ss.saveDeviceState(w);
  return w.take();
}

void _load(Ss ss, Uint8List state) {
  final r = StateReader(state, 'ss-devices', 1, 0);
  ss.loadDeviceState(r);
  r.end();
}

void main() {
  for (final jit in [false, true]) {
    test('a restored ${jit ? 'JIT' : 'CPU'} SS continues like the original',
        () {
      if (jit && !JitRuntime.nativeSupported) {
        markTestSkipped('no native recompiler on this host');
        return;
      }
      final original = _ss(jit);
      _frames(original, 3);
      final state = _save(original);
      _frames(original, 3);

      final restored = _ss(jit);
      _load(restored, state);
      _frames(restored, 3);
      final a = original.master as Sh2, b = restored.master as Sh2;
      expect(b.r, a.r);
      expect([b.pc, b.clocks, b.sr], [a.pc, a.clocks, a.sr]);
      expect(restored.bus.wramH, original.bus.wramH);
      expect(restored.bus.wramL, original.bus.wramL);
      expect(restored.vdp2.frame, original.vdp2.frame);
      if (!jit) {
        expect(_save(restored), _save(original));
      }
      // A restored JIT run starts with cold compiled code, so the split of
      // write counters, the last interpreted opcode and when the idle
      // detector snapshots registers differ; emulated state above matches.
    });
  }

  test('saving a restored state reproduces it across devices', () {
    final ss = _ss(false);
    _frames(ss, 2);
    ss.vdp2.writeReg(0x00e, 0x1000);
    ss.vdp2.writeCram16(0x20, 0x7c1f);
    ss.vdp1.vram[100] = 9;
    ss.scsp.ram[200] = 7;
    ss.scu.dsp.prog[3] = 0x12345678;
    ss.smpc.oreg[5] = 0x44;
    ss.cdblock.cdda[11] = -3;
    final state = _save(ss);
    final copy = _ss(false);
    _load(copy, state);
    expect(_save(copy), state);
    expect(copy.vdp2.readCram16(0x20), 0x7c1f);
  });

  test('core states round trip and reject a different BIOS', () {
    final original = _ss(false);
    _frames(original, 2);
    final state = original.saveState();
    _frames(original, 2);
    final restored = _ss(false)..loadState(state);
    _frames(restored, 2);
    expect(restored.saveState(), original.saveState());

    final other = Ss(jit: false)
      ..setSram(Sram())
      ..setRom(_bios()..[0x2000] = 1);
    addTearDown(other.dispose);
    expect(() => other.loadState(state), throwsA(isA<StateMismatch>()));
  });

  test('device states of other formats are rejected', () {
    final state = _save(_ss(false));
    expect(() => StateReader(state, 'ss-devices', 2, 0),
        throwsA(isA<StateMismatch>()));
    final truncated = Uint8List.sublistView(state, 0, state.length - 100);
    expect(() => _load(_ss(false), truncated), throwsA(isA<StateMismatch>()));
  });
}
