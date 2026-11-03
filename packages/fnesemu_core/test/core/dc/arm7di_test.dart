import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/arm7di.dart';
import 'package:fnesemu_core/src/core/dc/arm_jit.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

void main() {
  late Uint8List memory;
  late DcArm7di cpu;
  late List<(int, int, int)> writes;
  setUp(() {
    memory = Uint8List(4096);
    writes = [];
    cpu = DcArm7di(
        read: (address, size) =>
            size == 1 ? memory[address] : memory.getUint32LE(address),
        write: (address, size, value) {
          writes.add((address, size, value));
          if (size == 1) {
            memory[address] = value;
          } else {
            memory.setUint32LE(address, value);
          }
        });
  });
  int execute(int op) {
    memory.setUint32LE(cpu.pc, op);
    return cpu.step();
  }

  test('reset state and banked registers across all six ARM7DI modes', () {
    expect(cpu.pc, 0);
    expect(cpu.cpsr, 0xd3);
    cpu.cpsr = 0x10;
    for (var i = 8; i < 15; i++) {
      cpu.r[i] = i + 100;
    }
    for (final mode in [0x11, 0x12, 0x13, 0x17, 0x1b]) {
      cpu.cpsr = mode;
      expect(cpu.r[13], 0);
      expect(cpu.r[14], 0);
      cpu.r[13] = mode * 16;
      cpu.r[14] = mode * 32;
      cpu.spsr = mode + 0x60000000;
      if (mode == 0x11) {
        expect(cpu.r[8], 0);
        cpu.r[8] = 999;
      } else {
        expect(cpu.r[8], 108);
      }
    }
    for (final mode in [0x11, 0x12, 0x13, 0x17, 0x1b]) {
      cpu.cpsr = mode;
      expect(cpu.r[13], mode * 16);
      expect(cpu.r[14], mode * 32);
      expect(cpu.spsr, mode + 0x60000000);
    }
    cpu.cpsr = 0x10;
    expect(cpu.r.sublist(8, 15), List.generate(7, (i) => 108 + i));
    expect(() => cpu.spsr, throwsA(isA<DcUnsupported>()));
    expect(() => cpu.cpsr = 0x1f, throwsA(isA<DcUnsupported>()));
    expect(cpu.cpsr, 0x10);
  });

  test('all condition codes follow the ARM7DI truth table including NV', () {
    const truth = [
      0xf0f0,
      0x0f0f,
      0xcccc,
      0x3333,
      0xff00,
      0x00ff,
      0xaaaa,
      0x5555,
      0x0c0c,
      0xf3f3,
      0xaa55,
      0x55aa,
      0x0a05,
      0xf5fa,
      0xffff,
      0
    ];
    for (var condition = 0; condition < 16; condition++) {
      for (var flags = 0; flags < 16; flags++) {
        cpu.pc = 0;
        cpu.cpsr = (flags << 28) | 0xd3;
        cpu.r[0] = 0;
        execute((condition << 28) | 0x03a00001);
        expect(cpu.r[0], (truth[condition] >> flags) & 1,
            reason: 'condition $condition, NZCV $flags');
        expect(cpu.pc, 4);
        expect(cpu.cpsr, (flags << 28) | 0xd3);
      }
    }
    cpu.cpsr = 0xd3;
    cpu.r[1] = 0xffffffff;
    execute(0x05810000); // STREQ must not access memory when Z is clear.
    expect(writes, isEmpty);
  });

  test('all sixteen data operations produce results and arithmetic flags', () {
    const results = [
      3,
      4,
      4,
      0xfffffffc,
      10,
      11,
      4,
      0xfffffffc,
      99,
      99,
      99,
      99,
      7,
      3,
      4,
      0xfffffffc
    ];
    const flags = [3, 3, 2, 8, 0, 0, 2, 8, 3, 3, 2, 0, 3, 3, 3, 11];
    for (var operation = 0; operation < 16; operation++) {
      cpu.pc = 0;
      cpu.cpsr = 0x300000d3;
      cpu.r[1] = 7;
      cpu.r[2] = 99;
      execute(0xe2112003 | (operation << 21));
      expect(cpu.r[2], results[operation], reason: 'operation $operation');
      expect(cpu.cpsr >>> 28, flags[operation], reason: 'operation $operation');
    }
  });












  test('STM base overlap and LDM loaded-base priority match original ARM7DI',
      () {
    cpu.r[1] = 0x200;
    cpu.r[0] = 99;
    execute(0xe8a10003); // STMIA R1!,{R0,R1}: modified base is stored second.
    expect(memory.getUint32LE(0x204), 0x208);
    cpu.r[1] = 0x200;
    execute(0xe8a10006); // STMIA R1!,{R1,R2}: original base is stored first.
    expect(memory.getUint32LE(0x200), 0x200);
    cpu.r[1] = 0x200;
    memory.setUint32LE(0x204, 0x700);
    execute(0xe8b10003);
    expect(cpu.r[1], 0x700);
  });

  test('compiled ARM code matches the interpreter', () {
    final jit = DcArmJit.create(0x10000);
    if (jit == null) return;
    addTearDown(jit.dispose);
    DcArm7di make(Uint8List memory, {DcArmJit? jit}) => DcArm7di(
        read: (address, size) =>
            size == 1 ? memory[address] : memory.getUint32LE(address),
        write: (address, size, value) => size == 1
            ? memory[address] = value
            : memory.setUint32LE(address, value),
        registers: jit?.registers)
      ..compiled = jit?.run;
    const program = [
      0xe3a00c02, 0xe3a01014, 0xe3e02000, 0xe3a03000, // r0-r3 setup
      0xe0933002, 0xe0b44183, 0xe1b05061, 0xe1b06022, // ADDS ADCS RRX LSR#32
      0xe1b07042, 0xe0478001, 0xe2d99007, 0xe0f59004, // ASR#32 SUB SBCS RSCS
      0xc28aa001, 0xd1a0b0e1, 0xe5a03004, 0xe4c04001, // ADDGT MOVLE STR! STRB
      0xe590c002, 0xe7d0e101, 0xeb000003, 0xe2511001, // LDR LDRB BL SUBS
      0x1affffee, 0xeafffffe, 0xe1a00000, 0xe1340003, // BNE B. NOP TEQ
      0x01a0f00e, 0xe1a0f00e, // MOVEQ PC,LR; MOV PC,LR
    ];
    final memories = [Uint8List(0x10000), jit.memory];
    final cpus = [make(memories[0]), make(memories[1], jit: jit)];
    for (final memory in memories) {
      for (var i = 0; i < program.length; i++) {
        memory.setUint32LE(i * 4, program[i]);
      }
      for (var i = 0; i < 256; i++) {
        memory[0x200 + i] = i * 37;
      }
    }
    for (final cpu in cpus) {
      for (var n = 0; n < 1000 && cpu.pc != 0x54; n++) {
        cpu.run(cpu.cycles + 16);
      }
      expect(cpu.pc, 0x54);
    }
    expect(cpus[1].r, cpus[0].r);
    expect(cpus[1].cpsr, cpus[0].cpsr);
    expect(
        memories[1].sublist(0x200, 0x300), memories[0].sublist(0x200, 0x300));
  });
}
