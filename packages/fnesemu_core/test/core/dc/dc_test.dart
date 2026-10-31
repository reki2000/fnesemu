import 'dart:typed_data';

import 'package:fnesemu_core/core_factory.dart';
import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/module.dart';
import 'package:test/test.dart';

void main() {
  test(
      'debug inspection observes cached instructions without allocating or evicting',
      () {
    final core = Dc(jit: false)..setRom(Uint8List.fromList([0x09, 0x00]));
    core.bus.write32(0xff00001c, 0x105);
    core.exec(true);
    core.bus.write16(0xac010000, 0xe12a);
    expect(core.disasm(0, Dc.programAddress).$1, contains('0009 nop'));
    core.bus.write32(0x8c004100, 42);
    final dirtyTag = core.bus.read32(0xf4000100);
    expect(core.read(0, 0x8c000100), 0);
    expect(core.bus.read32(0xf4000100), dirtyTag);
    expect(core.bus.read32(0xac004100), 0);
    final instructionTag = core.bus.read32(0xf0000000);
    core.disasm(0, Dc.programAddress + 0x2000);
    expect(core.bus.read32(0xf0000000), instructionTag);
  });

  test(
      'Core scheduling clocks TMU and accepts its interrupt at the next boundary',
      () {
    final core = Dc()
      ..setRom(Uint8List.fromList(
          List.generate(40, (index) => index.isEven ? 0x09 : 0x00)));
    core.cpu.sr = 0x40000000;
    core.cpu.vbr = 0x8c020000;
    core.bus.write16(0xffd00004, 0xf000);
    core.bus.write32(0xffd8000c, 0);
    core.bus.write16(0xffd80010, 0x20);
    core.bus.write8(0xffd80004, 1);
    for (var i = 0; i < 16; i++) {
      final result = core.exec(true);
      expect(result.executed(0), isTrue);
      expect(result.elapsedClocks, 1);
    }
    expect(core.bus.tmu.interruptPending(0), isTrue);
    final entry = core.exec(true);
    expect(entry.executed(0), isFalse);
    expect(entry.elapsedClocks, 1);
    expect(core.cpu.spc, Dc.programAddress + 32);
    expect(core.cpu.pc, 0x8c020600);
    expect(core.bus.intevt, 0x400);
    core.reset();
    expect(core.bus.tmu.interruptPending(0), isFalse);
    expect(core.bus.read16(0xffd00004), 0);
  });

  test('generated registry exposes dc and its BIOS metadata', () {
    expect(CoreFactory.of('dc'), isA<Dc>());
    expect(CoreFactory.system('dc').biosFiles, 2);
    expect(CoreFactory.systemOfFile('diagnostic.DC', Uint8List(2)).id, 'dc');
    expect(DcModule().identifyRom('1ST_READ.BIN', Uint8List(2)), isNull);
    expect(CoreFactory.system('dc').disc, 'dc');
  });

  test('empty core stops without executing', () {
    final core = Dc();
    final result = core.exec(false);
    expect(result.stopped, isTrue);
    expect(result.executed(0), isFalse);
    expect(result.elapsedClocks, 0);
    expect(core.stopReason, contains('No DC BIOS'));
  });

  test('boot ROM starts at reset vector; invalid replacement is atomic', () {
    final core = Dc();
    final bios = Uint8List(DcBus.biosSize)
      ..[0] = 0x2a
      ..[1] = 0xe1;
    core.setBiosFiles([bios]);
    bios[0] = 0;
    expect(core.exec(true).stopped, isFalse);
    expect(core.cpu.r[1], 42);
    expect(core.cpu.pc, 0xa0000002);
    expect(() => core.setBiosFiles([]), throwsArgumentError);
    expect(() => core.setBiosFiles([Uint8List(16)]), throwsArgumentError);
    expect(core.cpu.pc, 0xa0000002);
    expect(core.bus.bios[0], 42);
  });

  test('raw diagnostic is copied, reset reloads it, unsupported op stops', () {
    final core = Dc();
    final program = Uint8List.fromList([0x2a, 0xe1, 0xff, 0xff]);
    core.setRom(program);
    program[0] = 0;
    expect(core.cpu.r[15], 0x8d000000);
    expect(core.exec(true).stopped, isFalse);
    expect(core.cpu.r[1], 42);
    final stopped = core.exec(false);
    expect(stopped.stopped, isTrue);
    expect(stopped.elapsedClocks, 0);
    expect(stopped.executed(0), isFalse);
    expect(core.cpuClocks, 1);
    expect(core.cpu.pc, Dc.programAddress + 2);
    expect(core.stopReason, contains('ffff'));
    expect(core.dump(), contains('ffff'));
    expect(core.exec(false).executed(0), isFalse);
    core.bus.write16(Dc.programAddress, 0);
    core.reset();
    expect(core.stopReason, isNull);
    expect(core.cpuClocks, 0);
    expect(core.exec(true).stopped, isFalse);
    expect(core.cpu.r[1], 42);
  });

  test('BIOS replacement retains loaded diagnostic priority', () {
    final core = Dc()..setRom(Uint8List.fromList([0x09, 0x00]));
    core.setBiosFiles([Uint8List(DcBus.biosSize)]);
    expect(core.cpu.pc, Dc.programAddress);
    expect(core.exec(true).stopped, isFalse);
  });

  test(
      'guest trap handler returns through Core.exec without a development stop',
      () {
    final core = Dc()..setRom(Uint8List.fromList([0x01, 0xc3, 0x2a, 0xe9]));
    core.cpu.sr = 0x40000000;
    core.cpu.vbr = 0x8c020000;
    core.bus.write16(0x8c020100, 0x002b); // RTE.
    core.bus.write16(0x8c020102, 0x0009); // NOP slot.
    for (var i = 0; i < 4; i++) {
      expect(core.exec(true).stopped, isFalse);
    }
    expect(core.cpu.r[9], 42);
    expect(core.cpuClocks, 4);
    expect(core.stopReason, isNull);
    expect(core.dump(), contains('EXPEVT:00000160'));
  });

  test('diagnostic size is validated before replacing media', () {
    final core = Dc()..setRom(Uint8List.fromList([0x09, 0x00]));
    expect(() => core.setRom(Uint8List(0)), throwsArgumentError);
    expect(() => core.setRom(Uint8List(DcBus.ramSize)), throwsArgumentError);
    expect(core.exec(true).stopped, isFalse);
  });

  test('interrupt entry consumes a CPU step without reporting an instruction',
      () {
    final core = Dc()..setRom(Uint8List.fromList([0x2a, 0xe9]));
    core.cpu.sr = 0x40000000;
    core.cpu.vbr = 0x8c020000;
    core.cpu.irlPins = 0;
    core.bus.write16(0x8c020600, 0x002b); // RTE.
    core.bus.write16(0x8c020602, 0x0009); // NOP slot.
    final interrupt = core.exec(true);
    expect(interrupt.stopped, isFalse);
    expect(interrupt.executed(0), isFalse);
    expect(interrupt.elapsedClocks, 1);
    expect(core.cpu.spc, Dc.programAddress);
    core.cpu.irlPins = 15;
    for (var i = 0; i < 3; i++) {
      expect(core.exec(true).executed(0), isTrue);
    }
    expect(core.cpu.r[9], 42);
    expect(core.cpuClocks, 4);
    core.cpu.irlPins = 7;
    core.reset();
    expect(core.cpu.irlPins, 15);
    expect(core.cpu.mach, 0);
    expect(core.cpu.macl, 0);
  });

  test('runFrame is bounded and debugger can inspect mapped/unmapped code', () {
    // BRA to self; NOP. No devices or real video timing are required.
    final core = Dc(jit: false)
      ..setRom(Uint8List.fromList([0xfe, 0xaf, 0x09, 0x00]));
    expect(core.runFrame(0).elapsedClocks, 0);
    final result = core.runFrame(1);
    expect(result.stopped, isFalse);
    expect(result.scanlineRendered, isTrue);
    expect(core.cpuClocks, core.clocksInScanline);
    expect(core.disasm(0, Dc.programAddress).$2, 2);
    expect(core.disasm(0, 0xff000000).$1, contains('<unmapped>'));
    expect(core.trace(0).state, hasLength(74));
    expect(core.imageBuffer().buffer, isEmpty);
  });

  test('compiled SH-4 code matches the interpreter', () {
    // A loop mixing ALU, memory, GBR, store-queue, FPU and call forms.
    final words = <int>[
      0xd81d,
      0xd91e,
      0xdb1e,
      0xdc1f,
      0xed0c,
      0x2cd2,
      0xea14,
      0x30ac,
      0x6107,
      0x0018,
      0x310e,
      0x321f,
      0x332a,
      0x643a,
      0x314d,
      0x050a,
      0x3215,
      0x061a,
      0xe7fd,
      0x457c,
      0x467d,
      0x265c,
      0x0729,
      0x221d,
      0x6328,
      0xf3fd,
      0xf82b,
      0xf3fd,
      0x2806,
      0x6395,
      0x481b,
      0x0429,
      0x2217,
      0x3214,
      0xf31e,
      0x405a,
      0xf12d,
      0xf210,
      0xf5ed,
      0xf312,
      0xf33d,
      0x0c5a,
      0xfbfd,
      0xf82b,
      0xfbfd,
      0x2b02,
      0x0b83,
      0x18c1,
      0x5d81,
      0x481e,
      0xc202,
      0xb004,
      0xf3fd, // FSCHG in the BSR slot.
      0x4a10,
      0x8bcf,
      0xaffe,
      0x0009,
      0x000b,
      0x7e01,
      0x0009,
      0x0000,
      0x8c20,
      0x0000,
      0x8c18,
      0x0000,
      0xe010,
      0x0038,
      0xff00,
    ];
    Dc run(bool jit) {
      final core = Dc(jit: jit)
        ..setRom(Uint8List.fromList([
          for (final w in words) ...[w & 255, w >> 8]
        ]));
      // Round to nearest, so the compiled FPU arithmetic runs natively.
      core.cpu.fpscr = 0x40000;
      core.runFrame(8);
      return core;
    }

    final compiled = run(true), interpreted = run(false);
    expect(compiled.jitClocks, greaterThan(0));
    expect(compiled.stopReason, isNull);
    expect(interpreted.stopReason, isNull);
    for (final (a, b) in [
      (compiled.cpu.r, interpreted.cpu.r),
      (compiled.cpu.fr, interpreted.cpu.fr),
      (compiled.cpu.xf, interpreted.cpu.xf),
      (compiled.bus.ram, interpreted.bus.ram),
    ]) {
      expect(a, b);
    }
    expect([compiled.cpu.sr, compiled.cpu.fpscr, compiled.cpu.gbr],
        [interpreted.cpu.sr, interpreted.cpu.fpscr, interpreted.cpu.gbr]);
    expect([compiled.cpu.mach, compiled.cpu.macl, compiled.cpu.fpul],
        [interpreted.cpu.mach, interpreted.cpu.macl, interpreted.cpu.fpul]);
  });
}
