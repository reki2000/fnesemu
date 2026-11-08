import 'dart:typed_data';

import 'package:fnesemu_core/src/core/gba/gba.dart';
import 'package:fnesemu_core/src/state.dart';
import 'package:test/test.dart';

import 'support/arm7_asm.dart';

Uint8List _rom({int extra = 0}) {
  final loop = [
    aAddI(0, 0, 1),
    aStr(0, 1, 0),
  ];
  final words = [
    ...aMovI32(1, 0x02000000),
    aMovI(0, 0),
    ...loop,
    aB(-loop.length - 2),
  ];
  final rom = Uint8List(0x200);
  final data = ByteData.sublistView(rom);
  for (var i = 0; i < words.length; i++) {
    data.setUint32(i * 4, words[i], Endian.little);
  }
  rom.setRange(0x100, 0x100 + 6, 'SRAM_V'.codeUnits);
  rom[0x1ff] = extra;
  return rom;
}

Gba _gba({int extra = 0}) => Gba()..setRom(_rom(extra: extra));

void _frames(Gba gba, int n) {
  for (var i = 0; i < n; i++) {
    expect(gba.runFrame(gba.scanlinesInFrame).stopped, isFalse);
  }
}

void main() {
  test('a restored GBA continues like the original', () {
    final original = _gba();
    _frames(original, 2);
    original.bus.write8(0x0e000005, 0xab);
    original.bus.write16(0x04000100, 0xfff0);
    original.bus.write16(0x04000102, 0x0080);
    final state = original.saveState();
    _frames(original, 2);

    final restored = _gba();
    _frames(restored, 1);
    restored.bus.write8(0x0e000005, 0x11);
    restored.bus.ewram[9] = 0x77;
    restored.loadState(state);
    expect(restored.saveState(), state);
    expect(restored.bus.read8(0x0e000005), 0xab);
    _frames(restored, 2);
    expect(restored.dump(), original.dump());
    expect(restored.bus.read32(0x02000000), original.bus.read32(0x02000000));
    expect(restored.imageBuffer().buffer, original.imageBuffer().buffer);
    expect(restored.saveState(), original.saveState());
  });

  test('a state of another cartridge or a truncated state is rejected without changing the core', () {
    final state = _gba().saveState();
    final other = _gba(extra: 1);
    _frames(other, 1);
    final before = other.saveState();
    expect(() => other.loadState(state), throwsA(isA<StateMismatch>()));
    expect(other.saveState(), before);
    final same = _gba();
    _frames(same, 1);
    final sameBefore = same.saveState();
    expect(
        () => same.loadState(Uint8List.sublistView(state, 0, state.length - 1)),
        throwsA(isA<StateMismatch>()));
    expect(same.saveState(), sameBefore);
    expect(() => same.loadState(Uint8List.fromList([...state, 0])),
        throwsA(isA<StateMismatch>()));
    expect(same.saveState(), sameBefore);
  });
}
