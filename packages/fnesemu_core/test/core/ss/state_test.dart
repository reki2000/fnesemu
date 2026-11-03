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
  test('clock selection survives state restoration and resets to 320 mode', () {
    final ss = _ss(false);
    expect(ss.systemClockHz, Ss.clock320Hz);
    // This fixture has no NMI handler; the clock transition is tested separately.
    ss.smpc.onNmi = () {};
    ss.smpc.write(0x0f, 0x0e);
    ss.smpc.exec(200);
    expect(ss.systemClockHz, Ss.clock352Hz);
    _frames(ss, 1);
    final state = _save(ss);
    final copy = _ss(false);
    _load(copy, state);
    expect(copy.systemClockHz, Ss.clock352Hz);
    _frames(ss, 1);
    _frames(copy, 1);
    expect(_save(copy), _save(ss));
    copy.smpc.write(0x0f, 0x0f);
    copy.smpc.exec(200);
    expect(copy.systemClockHz, Ss.clock320Hz);
    ss.reset();
    expect(ss.systemClockHz, Ss.clock320Hz);
    expect(ss.smpc.is352, isFalse);
  });

  for (final jit in [false, true]) {
  }

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

}
