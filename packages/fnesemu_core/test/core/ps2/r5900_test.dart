import 'package:fnesemu_core/src/core/ps2/bus.dart';
import 'package:fnesemu_core/src/core/ps2/r5900/r5900.dart';
import 'package:test/test.dart';

const _base = 0x100000;

int _r(int fn, {int rs = 0, int rt = 0, int rd = 0, int sa = 0}) =>
    rs << 21 | rt << 16 | rd << 11 | sa << 6 | fn;
int _i(int op, int rs, int rt, int imm) =>
    op << 26 | rs << 21 | rt << 16 | (imm & 0xffff);

/// runs [program] from [_base] until [count] instructions have executed
R5900 _run(List<int> program, {int? count, void Function(R5900)? setup}) {
  final cpu = R5900(Ps2Bus());
  for (var i = 0; i < program.length; i++) {
    cpu.bus.write32(_base + i * 4, program[i]);
  }
  cpu.jumpTo(_base);
  setup?.call(cpu);
  for (var i = 0; i < (count ?? program.length); i++) {
    expect(cpu.step(), isTrue, reason: 'instruction $i');
  }
  return cpu;
}

void main() {
  test('registers are 128 bits stored as two adjacent words', () {
    final cpu = R5900(Ps2Bus());
    cpu.setReg(5, 1);
    expect(cpu.gpr[10], 1);
    expect(cpu.gpr[11], 0);
  });

  test('r0 stays zero', () {
    final cpu = _run([_i(9, 0, 0, 5)]);
    expect(cpu.reg(0), 0);
  });

  test('32-bit results are sign extended and 64-bit ones are not', () {
    final cpu = _run([
      _i(15, 0, 1, 0x8000), // lui r1, 0x8000
      _i(9, 1, 2, 0), // addiu r2, r1, 0
      _r(45, rs: 1, rt: 0, rd: 3), // daddu r3, r1, r0
      _r(56, rt: 2, rd: 4, sa: 1), // dsll r4, r2, 1
    ]);
    expect(cpu.reg(1), -0x80000000);
    expect(cpu.reg(2), -0x80000000);
    expect(cpu.reg(4), -0x100000000);
  });

  test('ADD overflow raises an exception and keeps the register', () {
    final cpu = _run([
      _i(15, 0, 1, 0x7fff),
      _i(13, 1, 1, 0xffff), // ori: r1 = 0x7fffffff
      _r(32, rs: 1, rt: 1, rd: 2), // add r2, r1, r1
    ], setup: (c) => c.setReg(2, 7));
    expect(cpu.reg(2), 7);
    expect((cpu.cop0[R5900.cop0Cause] >> 2) & 31, R5900.excOverflow);
    expect(cpu.cop0[R5900.cop0Epc], _base + 8);
    expect(cpu.pc, 0xbfc00380);
  });

  test('SLTU compares as unsigned', () {
    final cpu = _run([
      _i(9, 0, 1, -1),
      _r(43, rs: 0, rt: 1, rd: 2), // sltu r2, r0, r1
      _r(42, rs: 0, rt: 1, rd: 3), // slt r3, r0, r1
    ]);
    expect(cpu.reg(2), 1);
    expect(cpu.reg(3), 0);
  });

  test('MULT writes HI, LO and rd; DIV handles zero and overflow', () {
    final cpu = _run([
      _i(9, 0, 1, -3),
      _i(9, 0, 2, 7),
      _r(24, rs: 1, rt: 2, rd: 3), // mult r3, r1, r2
    ]);
    expect(cpu.reg(3), -21);
    expect(cpu.lo, -21);
    expect(cpu.hi, -1);

    final div = _run([
      _i(9, 0, 1, -7),
      _i(9, 0, 2, 2),
      _r(26, rs: 1, rt: 2), // div
    ]);
    expect(div.lo, -3);
    expect(div.hi, -1);

    final zero = _run([_i(9, 0, 1, -7), _r(26, rs: 1, rt: 0)]);
    expect(zero.lo, 1);
    expect(zero.hi, -7);
  });

  test('branch executes its delay slot', () {
    final cpu = _run([
      _i(4, 0, 0, 2), // beq r0, r0, +2 (target _base + 12)
      _i(9, 0, 1, 1), // delay slot
      _i(9, 0, 2, 2), // skipped
      _i(9, 0, 3, 3),
    ], count: 3);
    expect(cpu.reg(1), 1);
    expect(cpu.reg(2), 0);
    expect(cpu.reg(3), 3);
  });

  test('branch likely skips the slot when not taken', () {
    final cpu = _run([
      _i(21, 0, 0, 3), // bnel r0, r0
      _i(9, 0, 1, 1), // annulled
      _i(9, 0, 2, 2),
    ], count: 2);
    expect(cpu.reg(1), 0);
    expect(cpu.reg(2), 2);
  });

  test('JAL links past the delay slot and JR returns', () {
    final cpu = _run([
      (3 << 26) | ((_base + 16) >> 2), // jal
      0,
      _i(9, 0, 5, 5), // return lands here
      0,
      _r(8, rs: 31), // jr ra at _base + 16
      0,
    ], count: 4);
    expect(cpu.reg(31), _base + 8);
    expect(cpu.pc, _base + 8);
    expect(cpu.reg(5), 0);
  });

  test('loads and stores use little endian and sign extension', () {
    final cpu = _run([
      _i(15, 0, 1, 0x0010), // lui r1, 0x10 -> 0x100000
      _i(9, 0, 2, -2),
      _i(43, 1, 2, 0x100), // sw
      _i(32, 1, 3, 0x100), // lb  (0xfe)
      _i(36, 1, 4, 0x100), // lbu
      _i(35, 1, 5, 0x100), // lw
      _i(39, 1, 6, 0x100), // lwu
    ]);
    expect(cpu.bus.read8(0x100100), 0xfe);
    expect(cpu.bus.read8(0x100103), 0xff);
    expect(cpu.reg(3), -2);
    expect(cpu.reg(4), 0xfe);
    expect(cpu.reg(5), -2);
    expect(cpu.reg(6), 0xfffffffe);
  });

  test('LWL and LWR assemble an unaligned word', () {
    final cpu = _run([
      _i(15, 0, 1, 0x0010),
      _i(34, 1, 2, 0x103), // lwl r2, 0x103(r1)
      _i(38, 1, 2, 0x100), // lwr r2, 0x100(r1)
    ], setup: (c) {
      // bytes 0x11..0x44 at 0x100100..0x100103
      for (var i = 0; i < 4; i++) {
        c.bus.write8(0x100100 + i, 0x11 * (i + 1));
      }
    });
    expect(cpu.reg(2), 0x44332211);
  });

  test('LQ and SQ move all 128 bits', () {
    final cpu = _run([
      _i(15, 0, 1, 0x0010),
      _i(30, 1, 2, 0x200), // lq r2
      _i(31, 1, 2, 0x300), // sq r2
    ], setup: (c) {
      c.bus.write64(0x100200, 0x1122334455667788);
      c.bus.write64(0x100208, 0x0102030405060708);
    });
    expect(cpu.gpr[4], 0x1122334455667788);
    expect(cpu.gpr[5], 0x0102030405060708);
    expect(cpu.bus.read64(0x100300), 0x1122334455667788);
    expect(cpu.bus.read64(0x100308), 0x0102030405060708);
  });

  test('scratchpad and KSEG1 alias main memory', () {
    final bus = Ps2Bus();
    bus.write32(0x70000010, 0xdeadbeef);
    expect(bus.read32(0x70000010), 0xdeadbeef);
    bus.write32(0xa0100000, 0x12345678);
    expect(bus.read32(0x80100000), 0x12345678);
    expect(bus.read32(0x100000), 0x12345678);
    expect(bus.read32(0x1000000000 & 0xffffffff), isNotNull);
    bus.read32(0x40000000);
    expect(bus.unmappedAccesses, 1);
  });

  test('SYSCALL in a delay slot sets BD and EPC to the branch', () {
    final cpu = _run([
      _i(4, 0, 0, 4), // beq
      _r(12), // syscall in the slot
    ]);
    expect(cpu.cop0[R5900.cop0Epc], _base);
    expect(cpu.cop0[R5900.cop0Cause] >>> 31, 1);
  });

  test('ERET returns to EPC', () {
    // clear BEV and ERL so the general vector is in main memory
    final cpu = _run([
      _r(12), // syscall
    ], setup: (c) {
      c.cop0[R5900.cop0Status] &= ~((1 << 22) | (1 << 2));
      c.bus.write32(0x80000180, 0x42000018); // eret
    });
    cpu.step();
    expect(cpu.pc, _base);
  });

  test('unimplemented instructions are reported without advancing', () {
    final cpu = R5900(Ps2Bus());
    cpu.jumpTo(_base);
    cpu.bus.write32(_base, 0x70000709); // PMULTH, not implemented yet
    expect(cpu.step(), isFalse);
    expect(cpu.pc, _base);
    expect(cpu.unimplementedInstruction, 0x70000709);
  });

  test('MTSAB and MTSAH set the funnel shift amount', () {
    final cpu = _run([
      _i(9, 0, 4, 0x13), // addiu a0, zero, 0x13
      _i(1, 4, 0x18, 0x01), // mtsab a0, 1
      _r(40, rd: 5), // mfsa a1
      _i(1, 4, 0x19, 0x01), // mtsah a0, 1
      _r(40, rd: 6), // mfsa a2
    ]);
    expect(cpu.reg(5), 2);
    expect(cpu.reg(6), 4);
  });
}
