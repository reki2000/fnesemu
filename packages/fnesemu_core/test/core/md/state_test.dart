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
    test('32X restores CPU views across JIT modes, source JIT=$jit', () {
      final original = _system(expansion: true, jit: jit);
      final a = original.expansion!;
      for (var i = 0; i < 300; i++) {
        expect(original.exec(false).stopped, isFalse);
      }
      a.video.writeRegister(4, 31);
      a.video.writeRegister(8, 0x1234);
      a.video.beginLine(0);
      a.video.writeRegister(10, 1); // swap pending until VBlank
      a.pwm.write(0, 0x205);
      a.pwm.write(2, 101);
      a.pwm.write(4, 11);
      a.pwm.write(6, 71);
      a.pwm.tick(33);
      a.writeMain16(0xa15106, 4);
      a.writeMain16(0xa15110, 2);
      a.writeMain16(0xa15112, 0x7654);
      a.writeMain16(0xa15112, 0x3210);
      a.cpus[0].onchip.tick(7); // timer divider remainder
      a.cpus[1].onchip.write8(0xfffffe12, 0xab); // pending high byte
      final state = original.saveState();
      final restored = _system(expansion: true, jit: !jit);
      final b = restored.expansion!;
      final ram = b.ram, registers = b.cpus[0].r;
      restored.loadState(state);
      expect(b.ram, same(ram));
      expect(b.cpus[0].r, same(registers));
      expect(restored.saveState(), state);
      // Run through the CPU adapter without native blocks, whose cold
      // compilation state is intentionally not persisted.
      original.jitSuspended = restored.jitSuspended = true;
      for (var i = 0; i < 200; i++) {
        expect(original.exec(false).stopped, isFalse);
        expect(restored.exec(false).stopped, isFalse);
      }
      expect(restored.saveState(), original.saveState());
      expect(b.video.busy, a.video.busy);
      expect(b.pwm.sample(), a.pwm.sample());
      expect(b.readSh16(0x4012, 0), 0x7654);
      expect(a.readSh16(0x4012, 0), 0x7654);
      for (final adapter in [a, b]) {
        adapter.cpus[1].onchip.write8(0xfffffe13, 0xcd);
      }
      expect(b.cpus[1].onchip.frc, 0xabcd);
      expect(restored.saveState(), original.saveState());
    });
  }

  test('MD CD snapshots reject unsupported device state', () {
    final md = Md(cdBoot: true)..setRom(Uint8List(0x20000));
    addTearDown(md.dispose);
    expect(md.saveState, throwsUnsupportedError);
    expect(() => md.loadState(Uint8List(0)), throwsUnsupportedError);
  });

  test('32X restores an in-flight SH-2 delay slot', () {
    final original = _system(expansion: true);
    final a = original.expansion!;
    final cpu = a.cpus[0];
    ByteData.sublistView(a.ram).setUint16(0, 0xa002);
    ByteData.sublistView(a.ram).setUint16(2, 0xe22a);
    expect(cpu.exec(compiled: false), isTrue);
    expect(cpu.pc, 0x06000002);
    final restored = _system(expansion: true);
    restored.loadState(original.saveState());
    final other = restored.expansion!.cpus[0];
    expect(cpu.exec(compiled: false), isTrue);
    expect(other.exec(compiled: false), isTrue);
    expect(other.pc, 0x06000008);
    expect(other.r[2], 42);
    expect(restored.saveState(), original.saveState());
  });

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
