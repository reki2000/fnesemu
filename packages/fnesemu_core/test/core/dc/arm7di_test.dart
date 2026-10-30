import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/arm7di.dart';
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

  test('carry, borrow and signed overflow use full-width arithmetic', () {
    for (final (op, a, b, carry, result, flags) in [
      (4, 0x7fffffff, 1, 0, 0x80000000, 9),
      (4, 0xffffffff, 1, 0, 0, 6),
      (5, 0x7fffffff, 0, 1, 0x80000000, 9),
      (5, 0xffffffff, 0xffffffff, 1, 0xffffffff, 10),
      (2, 0x80000000, 1, 0, 0x7fffffff, 3),
      (2, 0, 1, 0, 0xffffffff, 8),
      (6, 0, 0, 0, 0xffffffff, 8),
      (6, 0, 0, 1, 0, 6),
    ]) {
      cpu.pc = 0;
      cpu.cpsr = (carry << 29) | 0xd3;
      cpu.r[1] = a;
      cpu.r[3] = b;
      execute(0xe0112003 | (op << 21));
      expect(cpu.r[2], result);
      expect(cpu.cpsr >>> 28, flags);
    }
  });

  test('immediate and register shifts cover zero, 32 and oversized amounts',
      () {
    for (final (type, amount, register, result, carry) in [
      (0, 0, false, 0x80000001, false),
      (0, 1, false, 2, true),
      (0, 31, false, 0x80000000, false),
      (1, 0, false, 0, true),
      (2, 0, false, 0xffffffff, true),
      (3, 0, false, 0x40000000, true),
      (3, 1, false, 0xc0000000, true),
      (0, 32, true, 0, true),
      (0, 33, true, 0, false),
      (1, 32, true, 0, true),
      (1, 33, true, 0, false),
      (2, 255, true, 0xffffffff, true),
      (3, 32, true, 0x80000001, true),
      (3, 33, true, 0xc0000000, true),
      (3, 0, true, 0x80000001, false),
    ]) {
      cpu.pc = 0;
      cpu.cpsr = 0x100000d3;
      cpu.r[1] = 0x80000001;
      cpu.r[2] = amount;
      final cost =
          execute(0xe1b00001 | (type << 5) | (register ? 0x210 : amount << 7));
      expect(cpu.r[0], result, reason: '$type/$amount/$register');
      expect(cpu.cpsr & 0x20000000 != 0, carry);
      expect(cpu.cpsr & 0x10000000, 0x10000000);
      expect(cost, register ? 2 : 1);
    }
    cpu.pc = 0;
    cpu.cpsr = 0x200000d3;
    execute(0xe3b00102); // MOVS R0,#80000000h.
    expect(cpu.r[0], 0x80000000);
    expect(cpu.cpsr & 0x20000000, 0x20000000);
  });

  test('PC operands, branch link and register returns use documented offsets',
      () {
    execute(0xe1a0000f); // MOV R0,PC.
    expect(cpu.r[0], 8);
    cpu.r[1] = 0;
    execute(0xe1a0011f); // MOV R0,PC,LSL R1.
    expect(cpu.r[0], 16);
    expect(execute(0xeb000003), 3); // BL from 8 to 28.
    expect(cpu.pc, 28);
    expect(cpu.r[14], 12);
    execute(0xe1a0f00e);
    expect(cpu.pc, 12);
    execute(0xeafffffe);
    expect(cpu.pc, 12);
  });

  test('MRS, whole and flag-only MSR respect privilege and saved status', () {
    execute(0xe10f0000);
    expect(cpu.r[0], 0xd3);
    cpu.r[2] = 0x60000092;
    execute(0xe129f002);
    expect(cpu.cpsr, 0x60000092);
    cpu.spsr = 0x90000010;
    execute(0xe14f1000);
    expect(cpu.r[1], 0x90000010);
    execute(0xe328f4f0);
    expect(cpu.cpsr, 0xf0000092);
    cpu.cpsr = 0x10;
    cpu.r[2] = 0xa00000d3;
    execute(0xe129f002);
    expect(cpu.cpsr, 0xa0000010);
  });

  test('SWI and undefined coprocessor enter banked handlers and return', () {
    cpu.cpsr = 0x60000010;
    cpu.r[13] = 0x500;
    expect(execute(0xef123456), 3);
    expect(cpu.pc, 8);
    expect(cpu.mode, 0x13);
    expect(cpu.r[14], 4);
    expect(cpu.spsr, 0x60000010);
    execute(0xe1b0f00e);
    expect(cpu.pc, 4);
    expect(cpu.cpsr, 0x60000010);
    expect(cpu.r[13], 0x500);
    execute(0xee000010);
    expect(cpu.pc, 4);
    expect(cpu.mode, 0x1b);
    expect(cpu.r[14], 8);
    expect(cpu.spsr, 0x60000010);
  });

  test('legacy TEQP follows the documented 32-bit mode behavior', () {
    cpu.spsr = 0x60000010;
    execute(0xe131f000);
    expect(cpu.cpsr, 0x60000010);
    expect(cpu.pc, 4);
    execute(0xe131f000);
    expect(cpu.cpsr, 0x60000010);
    expect(cpu.pc, 8);
  });

  test('FIQ precedes IRQ and SUBS PC,LR restores the interrupted mode', () {
    cpu.pc = 0x100;
    cpu.cpsr = 0x10;
    cpu.r[8] = 123;
    cpu.irq = cpu.fiq = true;
    cpu.step();
    expect(cpu.pc, 0x1c);
    expect(cpu.mode, 0x11);
    expect(cpu.r[8], 0);
    expect(cpu.r[14], 0x104);
    expect(cpu.cpsr & 0xc0, 0xc0);
    cpu.fiq = false;
    execute(0xe25ef004);
    expect(cpu.pc, 0x100);
    expect(cpu.r[8], 123);
    cpu.step();
    expect(cpu.pc, 0x18);
    expect(cpu.mode, 0x12);
    expect(cpu.r[14], 0x104);
    cpu.irq = false;
    execute(0xe25ef004);
    expect(cpu.pc, 0x100);
    expect(cpu.cpsr, 0x10);
  });

  test('MUL and MLA retain exact low products on native and JavaScript', () {
    for (final (a, b) in [
      (0xffffffff, 0xffffffff),
      (0x12345678, 0x87654321),
      (0x80000000, 2),
      (0x10001, 0x10001)
    ]) {
      cpu.pc = 0;
      cpu.r[1] = a;
      cpu.r[2] = b;
      execute(0xe0000291);
      final product =
          (BigInt.from(a) * BigInt.from(b)) & BigInt.from(0xffffffff);
      expect(cpu.r[0], product.toInt());
      cpu.r[3] = 0xdeadbeef;
      execute(0xe0203291);
      expect(
          cpu.r[0],
          ((product + BigInt.from(0xdeadbeef)) & BigInt.from(0xffffffff))
              .toInt());
    }
    cpu.r[0] = 7;
    cpu.r[2] = 8;
    execute(0xe0000290); // Original ARM7DI MUL Rd=Rm returns zero.
    expect(cpu.r[0], 0);
  });

  test('single transfers implement indexing, bytes, rotation and PC stores',
      () {
    cpu.r[1] = 0x200;
    cpu.r[0] = 0x11223344;
    execute(0xe5a10004); // STR R0,[R1,#4]!.
    expect(cpu.r[1], 0x204);
    expect(memory.getUint32LE(0x204), 0x11223344);
    execute(0xe4912004); // LDR R2,[R1],#4.
    expect(cpu.r[2], 0x11223344);
    expect(cpu.r[1], 0x208);
    execute(0xe5513001); // LDRB R3,[R1,#-1].
    expect(cpu.r[3], 0x11);
    cpu.r[1] = 0x205;
    execute(0xe5914000);
    expect(cpu.r[4], 0x44112233);
    execute(0xe5810000); // Word store aligns without rotating.
    expect(memory.getUint32LE(0x204), 0x11223344);
    execute(0xe5c10001); // STRB R0,[R1,#1].
    expect(memory[0x206], 0x44);
    final address = cpu.pc;
    cpu.r[1] = 0x300;
    execute(0xe581f000);
    expect(memory.getUint32LE(0x300), address + 12);
    cpu.r[3] = 1;
    memory.setUint32LE(0x304, 0x99887766);
    execute(0xe7912103); // LDR R2,[R1,R3,LSL#2].
    expect(cpu.r[2], 0x99887766);
  });

  test('SWP and SWPB snapshot the source before replacing the destination', () {
    cpu.r[1] = 0x200;
    cpu.r[0] = 0xaabbccdd;
    memory.setUint32LE(0x200, 0x11223344);
    execute(0xe1010090); // SWP R0,R0,[R1].
    expect(cpu.r[0], 0x11223344);
    expect(memory.getUint32LE(0x200), 0xaabbccdd);
    execute(0xe1412090); // SWPB R2,R0,[R1].
    expect(cpu.r[2], 0xdd);
    expect(memory[0x200], 0x44);
  });

  test(
      'block transfers implement all addressing modes and increasing register order',
      () {
    for (final (bits, first, finalBase) in [
      (0x800000, 0x200, 0x20c),
      (0x1800000, 0x204, 0x20c),
      (0, 0x1f8, 0x1f4),
      (0x1000000, 0x1f4, 0x1f4),
    ]) {
      cpu.pc = 0;
      cpu.r[0] = 10;
      cpu.r[2] = 20;
      cpu.r[3] = 30;
      cpu.r[4] = 0x200;
      execute(0xe824000d | bits); // STM R4!,{R0,R2,R3}.
      expect(cpu.r[4], finalBase);
      expect([for (var i = 0; i < 3; i++) memory.getUint32LE(first + 4 * i)],
          [10, 20, 30]);
      cpu.r[4] = 0x200;
      execute(0xe83400e0 | bits); // LDM R4!,{R5,R6,R7}.
      expect(cpu.r.sublist(5, 8), [10, 20, 30]);
      expect(cpu.r[4], finalBase);
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

  test('user-bank blocks and LDM exception returns restore banked state', () {
    cpu.cpsr = 0x10;
    cpu.r[13] = 0x777;
    cpu.cpsr = 0xd3;
    cpu.r[13] = 0x888;
    cpu.r[0] = 0x200;
    execute(0xe8c02000); // STMIA R0,{SP}^.
    expect(memory.getUint32LE(0x200), 0x777);
    memory.setUint32LE(0x200, 0x555);
    execute(0xe8d02000); // LDMIA R0,{SP}^.
    expect(cpu.r[13], 0x888);
    cpu.spsr = 0x60000010;
    memory.setUint32LE(0x200, 0x300);
    execute(0xe8f08000); // LDMIA R0!,{PC}^.
    expect(cpu.pc, 0x300);
    expect(cpu.cpsr, 0x60000010);
    expect(cpu.r[13], 0x555);
    expect(cpu.r[0], 0x204);
  });

  test(
      'unsupported ARMv4 encodings and prohibited operands stop without advancing PC',
      () {
    for (final op in [
      0xe12fff1e,
      0xe0800291,
      0xe8a00000,
      0xe1a0f000 | 0x100000
    ]) {
      cpu.reset();
      if (op == 0xe1b0f000) cpu.cpsr = 0x10;
      expect(() => execute(op), throwsA(isA<DcUnsupported>()));
      expect(cpu.pc, 0);
      expect(writes, isEmpty);
    }
  });
}
