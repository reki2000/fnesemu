import 'dart:typed_data';

import 'package:fnesemu_core/debugger.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:test/test.dart';

void main() {
  late Dc core;
  const wave = 0xa0800000, reset = 0xa0702c00;
  setUp(() {
    core = Dc()..setRom(Uint8List.fromList([0xfe, 0xaf, 9, 0]));
    addTearDown(core.dispose);
    for (final (i, op) in [0xe3a00001, 0xe2800001, 0xeafffffd].indexed) {
      core.bus.write32(wave + 4 * i, op);
    }
  });

  test(
      'ARM CPU identity, address space, PC, stack and disassembly are core-owned',
      () {
    expect(core.cpuInfos.map((cpu) => (cpu.no, cpu.name)),
        [(0, 'SH-4'), (1, 'ARM7DI')]);
    core.bus.aica.arm.r[13] = 0x1000;
    expect(core.stackPointer(1), 0x1000);
    expect(core.stackPointer(0), 0x8d000000);
    expect(core.programCounter(1), 0);
    expect(core.programCounter(0), Dc.programAddress);
    expect(List.generate(4, (i) => core.read(1, i)), [1, 0, 0xa0, 0xe3]);
    expect(core.disasm(1, 0).$1, contains('mov r0,#0x1'));
    expect(core.disasm(1, 0).$2, 4);
    expect(core.disasm(0, Dc.programAddress).$2, 2);
    expect(core.disasm(1, 0x400000).$1, contains('<unmapped>'));
    expect(core.dump(showApu: true), contains('AICA ARM7DI'));
  });

  test(
      'ARM trace inspection snapshots banks without changing clocks or requests',
      () {
    core.bus.write32(0xa07028b8, 0x20);
    core.bus.write32(0xa07028b4, 0x20);
    final before = core.trace(1);
    final state = List.of(before.state);
    expect(before.pc, 0);
    expect(before.regs, contains('CPSR'));
    expect(core.read(1, 0x8028b8), 0x20);
    core.disasm(1, 0x8028b8);
    expect(core.bus.systemBus.externalStatus, 2);
    expect(core.bus.aica.arm.cycles, 0);
    core.bus.aica.arm.cpsr = 0x11;
    core.bus.aica.arm.r[8] = 99;
    core.bus.aica.arm.cpsr = 0xd3;
    expect(core.trace(1).state, isNot(state));
    expect(before.state, state);
  });


  test('ARM reset does not masquerade as an executed instruction', () {
    core.bus.write32(reset, 0);
    for (var i = 0; i < 100; i++) {
      core.exec(false);
    }
    final serial = core.bus.aica.executedInstructions;
    expect(serial, greaterThan(0));
    core.bus.write16(core.cpu.pc, 0x2102);
    core.cpu.r[0] = 1;
    core.cpu.r[1] = reset;
    final result = core.exec(true);
    expect(result.executed(1), isFalse);
    expect(core.bus.aica.executedInstructions, serial);
    expect(core.bus.aica.arm.cycles, 0);
    expect(core.programCounter(1), 0);
  });





}
