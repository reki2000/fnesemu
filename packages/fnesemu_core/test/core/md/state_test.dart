@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:fnesemu_core/src/core/md/md.dart';
import 'package:fnesemu_core/src/util/state.dart';
import 'package:test/test.dart';

Uint8List _rom(bool expansion) {
  final bytes = Uint8List(0x800);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, 0xff1000);
  data.setUint32(4, expansion ? 0x880300 : 0x300);
  data.setUint16(0x300, 0x5280); // ADDQ.L #1,D0
  data.setUint16(0x302, 0x60fc); // BRA to the increment
  bytes.setAll(0x1f0, 'JUE'.codeUnits);
  return bytes;
}

Md _system({bool expansion = false, bool jit = false, int slice = 32}) {
  final md = Md(expansionBoot: expansion, sh2Jit: jit, sh2SliceClocks: slice)
    ..setRom(_rom(expansion));
  addTearDown(md.dispose);
  md.cpuZ80.busReq = true;
  if (expansion) {
    md.setExpansionBootRoms(
        main: Uint8List(256), master: Uint8List(2048), slave: Uint8List(1024));
    // Boot-ROM installation resets the expansion only. Execute separate
    // increment/store loops in shared RAM, with no cross-CPU race.
    final adapter = md.expansion!;
    final data = ByteData.sublistView(adapter.ram);
    for (var i = 0; i < 2; i++) {
      final offset = i * 32;
      for (final (j, opcode) in [0x7101, 0x2c12, 0xaffc, 9].indexed) {
        data.setUint16(offset + j * 2, opcode);
      }
      adapter.cpus[i].pc = 0x06000000 + offset;
      adapter.cpus[i].r[12] = 0x06001000 + i * 4;
    }
    adapter.control = 3;
  }
  return md;
}

void main() {
  test('MD restores into a fresh instance and continues frames and PCM', () {
    final original = _system();
    original.busM68.pad.writeData(0, 0x40, 100);
    original.busZ80.bank = 0x8000;
    original.busM68.ram[0x123] = 0x81;
    original.psg.write8(0x85);
    original.psg.write8(0x12);
    original.psg.write8(0x91);
    for (var i = 0; i < 2; i++) {
      expect(original.runFrame(original.scanlinesInFrame).stopped, isFalse);
    }
    final state = original.saveState();
    final restored = _system();
    final ram = restored.busM68.ram, zram = restored.busZ80.ram;
    final vram = restored.vdp.vram;
    restored.loadState(state);
    expect(restored.saveState(), state);
    expect(restored.busM68.ram, same(ram));
    expect(restored.busZ80.ram, same(zram));
    expect(restored.vdp.vram, same(vram));
    expect(restored.cpuM68.bus, same(restored.busM68));
    final pcmA = <double>[], pcmB = <double>[];
    original.onAudio((audio) => pcmA.addAll(audio.buffer));
    restored.onAudio((audio) => pcmB.addAll(audio.buffer));
    for (var i = 0; i < 3; i++) {
      expect(original.runFrame(original.scanlinesInFrame).stopped, isFalse);
      expect(restored.runFrame(restored.scanlinesInFrame).stopped, isFalse);
      expect(restored.saveState(), original.saveState());
      expect(restored.imageBuffer().buffer, original.imageBuffer().buffer);
    }
    expect(pcmA, isNotEmpty);
    expect(pcmB, pcmA);
  });

  for (final jit in [false, true]) {
  }

  test('media and execution configuration mismatches fail before mutation', () {
    final original = _system(expansion: true);
    final state = original.saveState();
    for (final other in [
      _system(),
      _system(expansion: true, slice: 64),
      _system(expansion: true)..busM68.rom.rom[0x700] = 1,
      _system(expansion: true)..expansion!.masterBoot[9] = 1,
    ]) {
      final before = other.saveState();
      expect(() => other.loadState(state), throwsA(isA<StateMismatch>()));
      expect(other.saveState(), before);
    }
  });
}
