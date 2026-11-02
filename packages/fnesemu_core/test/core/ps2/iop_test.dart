import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps2/iop/iop.dart';
import 'package:test/test.dart';

class _Ram implements IopBus {
  final data = ByteData(0x10000);

  int _a(int a) => a & 0xffff;
  @override
  int read8(int a) => data.getUint8(_a(a));
  @override
  int read16(int a) => data.getUint16(_a(a), Endian.little);
  @override
  int read32(int a) => data.getUint32(_a(a), Endian.little);
  @override
  void write8(int a, int v) => data.setUint8(_a(a), v);
  @override
  void write16(int a, int v) => data.setUint16(_a(a), v, Endian.little);
  @override
  void write32(int a, int v) => data.setUint32(_a(a), v, Endian.little);
}

int _i(int op, int rs, int rt, int imm) =>
    (op << 26) | (rs << 21) | (rt << 16) | (imm & 0xffff);
int _r(int funct, int rs, int rt, int rd, [int sa = 0]) =>
    (rs << 21) | (rt << 16) | (rd << 11) | (sa << 6) | funct;

Iop _run(List<int> code, {int steps = -1}) {
  final ram = _Ram();
  for (var i = 0; i < code.length; i++) {
    ram.write32(0x1000 + i * 4, code[i]);
  }
  final cpu = Iop(ram)..jump(0x1000);
  cpu.cop0[Iop.cop0Status] = 0;
  for (var i = 0; i < (steps < 0 ? code.length : steps); i++) {
    cpu.step();
  }
  return cpu;
}

void main() {
  test('arithmetic and logic', () {
    final cpu = _run([
      _i(9, 0, 1, 5), // ADDIU r1, r0, 5
      _i(9, 0, 2, -3), // ADDIU r2, r0, -3
      _r(33, 1, 2, 3), // ADDU r3 = 2
      _r(35, 1, 2, 4), // SUBU r4 = 8
      _r(42, 2, 1, 5), // SLT r5 = (-3 < 5)
      _r(43, 2, 1, 6), // SLTU r6 = 0
    ]);
    expect(cpu.r[3], 2);
    expect(cpu.r[4], 8);
    expect(cpu.r[5], 1);
    expect(cpu.r[6], 0);
  });

  test('multiply and divide', () {
    final cpu = _run([
      _i(15, 0, 1, 0x8000), // LUI r1, 0x8000
      _i(9, 0, 2, 4),
      _r(25, 1, 2, 0), // MULTU
      _r(16, 0, 0, 3), // MFHI r3
      _r(18, 0, 0, 4), // MFLO r4
      _i(9, 0, 5, 7),
      _i(9, 0, 6, 2),
      _r(26, 5, 6, 0), // DIV
      _r(16, 0, 0, 7),
      _r(18, 0, 0, 8),
    ]);
    expect(cpu.r[3], 2);
    expect(cpu.r[4], 0);
    expect(cpu.r[7], 1);
    expect(cpu.r[8], 3);
  });

  test('a branch executes its delay slot', () {
    final cpu = _run([
      _i(4, 0, 0, 2), // BEQ r0, r0, +2 (target = after the next two)
      _i(9, 0, 1, 1), // delay slot
      _i(9, 0, 2, 2), // skipped
      _i(9, 0, 3, 3),
    ], steps: 3);
    expect(cpu.r[1], 1);
    expect(cpu.r[2], 0);
    expect(cpu.r[3], 3);
  });

  test('the instruction after a load sees the old value', () {
    final ram = _Ram()..write32(0x2000, 0x1234);
    final code = [
      _i(9, 0, 1, 0x77),
      _i(15, 0, 4, 0), // LUI r4, 0 (r4 = 0)
      _i(35, 4, 1, 0x2000), // LW r1, 0x2000(r4)
      _r(33, 1, 0, 2), // ADDU r2 = r1 (old value 0x77)
      _r(33, 1, 0, 3), // ADDU r3 = r1 (new value)
    ];
    for (var i = 0; i < code.length; i++) {
      ram.write32(0x1000 + i * 4, code[i]);
    }
    final cpu = Iop(ram)..jump(0x1000);
    cpu.cop0[Iop.cop0Status] = 0;
    for (var i = 0; i < code.length; i++) {
      cpu.step();
    }
    expect(cpu.r[2], 0x77);
    expect(cpu.r[3], 0x1234);
  });

  test('unaligned loads and stores merge with LWL/LWR/SWL/SWR', () {
    final ram = _Ram()..write32(0x2000, 0x44332211);
    final code = [
      _i(15, 0, 4, 0),
      _i(9, 0, 1, 0), // r1 = 0
      _i(34, 4, 1, 0x2003), // LWL r1, 0x2003
      _i(38, 4, 1, 0x2000), // LWR r1, 0x2000
      _r(0, 0, 0, 0), // NOP (let the load land)
      _r(0, 0, 0, 0),
      _i(42, 4, 1, 0x2007), // SWL r1, 0x2007
      _i(46, 4, 1, 0x2004), // SWR r1, 0x2004
    ];
    for (var i = 0; i < code.length; i++) {
      ram.write32(0x1000 + i * 4, code[i]);
    }
    final cpu = Iop(ram)..jump(0x1000);
    cpu.cop0[Iop.cop0Status] = 0;
    for (var i = 0; i < code.length; i++) {
      cpu.step();
    }
    expect(cpu.r[1], 0x44332211);
    expect(ram.read32(0x2004), 0x44332211);
  });

  test('SYSCALL in a delay slot sets BD and EPC at the branch', () {
    final cpu = _run([
      _r(8, 31, 0, 0), // JR r31 (r31 = 0 -> jumps to 0)
      _r(12, 0, 0, 0), // SYSCALL in the delay slot
    ]);
    expect(cpu.cop0[Iop.cop0Epc], 0x1000);
    expect(cpu.cop0[Iop.cop0Cause] >>> 31, 1);
    expect((cpu.cop0[Iop.cop0Cause] >> 2) & 31, Iop.excSyscall);
    expect(cpu.pc, 0x80000080);
  });

  test('hardware interrupt is taken when enabled and RFE restores the mode',
      () {
    final ram = _Ram();
    for (var i = 0; i < 4; i++) {
      ram.write32(0x1000 + i * 4, 0);
    }
    final cpu = Iop(ram)..jump(0x1000);
    cpu.cop0[Iop.cop0Status] = 0x401; // IM2, IEc
    cpu.setInterrupt(true);
    cpu.step();
    expect(cpu.cop0[Iop.cop0Epc], 0x1000);
    expect((cpu.cop0[Iop.cop0Cause] >> 2) & 31, Iop.excInterrupt);
    expect(cpu.cop0[Iop.cop0Status] & 1, 0);
    expect((cpu.cop0[Iop.cop0Status] >> 2) & 1, 1);
  });

  test('ADD overflows', () {
    final cpu = _run([
      _i(15, 0, 1, 0x7fff),
      _i(13, 1, 1, 0xffff), // r1 = 0x7fffffff
      _r(32, 1, 1, 2), // ADD overflow
    ]);
    expect(cpu.r[2], 0);
    expect((cpu.cop0[Iop.cop0Cause] >> 2) & 31, Iop.excOverflow);
  });

  test('an interrupt does not drop the load of the previous instruction', () {
    final ram = _Ram()..write32(0x2000, 0x1234);
    final code = [
      _i(35, 0, 1, 0x2000), // LW r1, 0x2000(r0)
      _r(0, 0, 0, 0),
    ];
    for (var i = 0; i < code.length; i++) {
      ram.write32(0x1000 + i * 4, code[i]);
    }
    final cpu = Iop(ram)..jump(0x1000);
    cpu.cop0[Iop.cop0Status] = 0x401;
    cpu.step();
    cpu.setInterrupt(true);
    cpu.step(); // the interrupt is taken before the NOP
    expect(cpu.cop0[Iop.cop0Epc], 0x1004);
    expect(cpu.r[1], 0x1234);
  });
}
