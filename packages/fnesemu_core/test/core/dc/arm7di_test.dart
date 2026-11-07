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

  test('compiled PSR transfers match the interpreter in results and cycles',
      () {
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
      0xe3a0c014, // mov r12,#20
      0xe10fa000, // loop: mrs r10,cpsr
      0xe38a90c0, // orr r9,r10,#0xc0
      0xe129f009, // msr cpsr_fc,r9: masks both interrupts
      0xe2800001, // add r0,r0,#1
      0xe129f00a, // msr cpsr_fc,r10
      0xe328f4f0, // msr cpsr_f,#0xf0000000
      0xe10f1000, // mrs r1,cpsr
      0xe3ca20c0, // bic r2,r10,#0xc0
      0xe129f002, // msr cpsr_fc,r2: enables both interrupts
      0xe129f00a, // msr cpsr_fc,r10
      0xe25cc001, // subs r12,r12,#1
      0x1afffff3, // bne loop
      0xeafffffe, // b .
    ];
    final memories = [Uint8List(0x10000), jit.memory];
    final cpus = [make(memories[0]), make(memories[1], jit: jit)];
    for (final memory in memories) {
      for (var i = 0; i < program.length; i++) {
        memory.setUint32LE(i * 4, program[i]);
      }
    }
    final interpreter = cpus[0], compiled = cpus[1];
    for (var n = 0; n < 100000 && interpreter.pc != 0x34; n++) {
      interpreter.run(interpreter.cycles + 1);
    }
    expect(interpreter.pc, 0x34);
    compiled.run(interpreter.cycles);
    expect(compiled.pc, 0x34);
    expect(jit.compiledClocks, greaterThan(0));
    // As above, the last block may end a few cycles late; a wrong cost
    // shows in each of the 20 passes.
    expect(compiled.cycles - interpreter.cycles, inInclusiveRange(0, 2));
    expect(compiled.r, interpreter.r);
    expect(compiled.cpsr, interpreter.cpsr);
    expect(interpreter.r[0], 20);
  });

  test('compiled block transfers match the interpreter in results and cycles',
      () {
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
    const end = 0x100;
    const program = [
      0xe3a0c014, // mov r12,#20
      // loop:
      0xe3a0dc04, // mov sp,#0x400
      0xe3a00001, 0xe3a01002, 0xe3a02003, 0xe3a0e0ee, // r0-r2, lr
      0xe3a05c01, // mov r5,#END (0x100)
      0xe92d4007, // stmdb sp!,{r0-r2,lr}
      0xe8bd00f0, // ldmia sp!,{r4-r7}
      0xe88d000f, // stmia sp,{r0-r3}
      0xe9bd0300, // ldmib sp!,{r8,r9}
      0xe82d0003, // stmda sp!,{r0,r1}
      0xe91d0c00, // ldmdb sp,{r10,r11}
      0xe3a01c03, // mov r1,#0x300
      0xe8a10007, // stmia r1!,{r0,r1,r2}: base not first, stores write-back
      0xe3a00d0d, // mov r0,#0x340
      0xe3a01002, // mov r1,#2
      0xe8a00003, // stmia r0!,{r0,r1}: base first, stores the old base
      0xe3a00001, // mov r0,#1
      0xe3a02c02, // mov r2,#0x200
      0xe8b2000c, // ldmia r2!,{r2,r3}: the loaded base wins
      0xe3a0dc04, // mov sp,#0x400
      0xe88d8001, // stmia sp,{r0,pc}
      0xe92d0030, // stmdb sp!,{r4,r5}
      0xe9ad0003, // stmib sp!,{r0,r1}
      0xe3a0dc04, // mov sp,#0x400
      0xe3a0de3f, // mov sp,#0x3f0 (a different base)
      0xe83d0030, // ldmda sp!,{r4,r5}
      0xe3a0dc04, // mov sp,#0x400
      0xe3a04000 | (32 * 4), // mov r4,#address of the subs below
      0xe92d0010, // stmdb sp!,{r4}
      0xe8bd8000, // ldmia sp!,{pc}: a load that includes PC, every pass
      0xe25cc001, // subs r12,r12,#1
      0x1affffe0, // bne loop (patched below)
      0xe3a0dc04, // mov sp,#0x400
      0xe3a05c01, // mov r5,#END (0x100)
      0xe92d0020, // stmdb sp!,{r5}
      0xe8bd8000, // ldmia sp!,{pc}: returns to END
      0xeafffffe, // b .
    ];
    final code = [...program];
    // Patch the loop branch: find it and aim it at "loop".
    final loopIndex = 1;
    final branchIndex = code.indexOf(0x1affffe0);
    code[branchIndex] =
        0x1a000000 | ((loopIndex - branchIndex - 2) & 0xffffff);
    // The last "b ." sits at END.
    final tail = code.removeLast();
    final memories = [Uint8List(0x10000), jit.memory];
    final cpus = [make(memories[0]), make(memories[1], jit: jit)];
    for (final memory in memories) {
      for (var i = 0; i < code.length; i++) {
        memory.setUint32LE(i * 4, code[i]);
      }
      memory.setUint32LE(end, tail);
      for (var i = 0; i < 0x400; i++) {
        memory[0x100 + 0x80 + i] = i * 37;
      }
    }
    final interpreter = cpus[0];
    for (var n = 0; n < 100000 && interpreter.pc != end; n++) {
      interpreter.run(interpreter.cycles + 1);
    }
    expect(interpreter.pc, end);
    final compiled = cpus[1];
    compiled.run(interpreter.cycles);
    expect(compiled.pc, end);
    // Compiled code finishes the block that crosses the budget, so it can end
    // a few cycles late. Every transfer runs in each of the 20 passes, so a
    // wrong cost shows as at least 20 cycles.
    expect(compiled.cycles - interpreter.cycles, inInclusiveRange(0, 2));
    expect(compiled.r, interpreter.r);
    expect(compiled.cpsr, interpreter.cpsr);
    expect(memories[1].sublist(0, 0x600), memories[0].sublist(0, 0x600));
  });
}
