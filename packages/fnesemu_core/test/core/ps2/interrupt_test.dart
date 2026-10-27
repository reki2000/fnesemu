import 'package:fnesemu_core/src/core/ps2/intc.dart';
import 'package:fnesemu_core/src/core/ps2/ps2.dart';
import 'package:fnesemu_core/src/core/ps2/r5900/r5900.dart';
import 'package:test/test.dart';

// lui-free program: every instruction is a NOP (sll r0, r0, 0)
Ps2 _ps2() {
  final ps2 = Ps2();
  ps2.reset();
  ps2.cpu.jumpTo(0x100000);
  return ps2;
}

void main() {
  test('INTC interrupt is taken when IE, EIE and the mask allow it', () {
    final ps2 = _ps2();
    final cpu = ps2.cpu;
    // BEV and ERL cleared, IE and EIE set, IM2 set
    cpu.cop0[R5900.cop0Status] = (1 << 16) | 1 | (1 << 10);
    ps2.io.intc.mask = 1 << Intc.vblankStart;
    ps2.io.intc.raise(Intc.vblankStart);
    ps2.exec(true); // the lines are sampled after this instruction
    ps2.exec(true);
    expect(cpu.pc, 0x80000200 + 4,
        reason: 'vector 0x200, then one instruction');
    expect(cpu.cop0[R5900.cop0Epc], 0x100004);
    expect((cpu.cop0[R5900.cop0Cause] >> 2) & 31, 0);
  });

  test('a masked interrupt is not taken', () {
    final ps2 = _ps2();
    final cpu = ps2.cpu;
    cpu.cop0[R5900.cop0Status] = (1 << 16) | 1 | (1 << 10);
    ps2.io.intc.raise(Intc.vblankStart);
    ps2.exec(true);
    expect(cpu.pc, 0x100004);
  });

  test('EXL blocks interrupts', () {
    final ps2 = _ps2();
    final cpu = ps2.cpu;
    cpu.cop0[R5900.cop0Status] = (1 << 16) | 1 | 2 | (1 << 10);
    ps2.io.intc.mask = 1 << Intc.vblankStart;
    ps2.io.intc.raise(Intc.vblankStart);
    ps2.exec(true);
    expect(cpu.pc, 0x100004);
  });

  test('Count reaching Compare raises IP7 and writing Compare clears it', () {
    final ps2 = _ps2();
    final cpu = ps2.cpu;
    cpu.cop0[R5900.cop0Compare] = 3;
    for (var i = 0; i < 3; i++) {
      ps2.exec(true);
    }
    expect(cpu.cop0[R5900.cop0Cause] & R5900.ipTimer, isNonZero);
    // mtc0 r0, Compare
    cpu.bus.write32(cpu.pc, 16 << 26 | 4 << 21 | 11 << 11);
    ps2.exec(true);
    expect(cpu.cop0[R5900.cop0Cause] & R5900.ipTimer, 0);
  });

  test('vblank raises the INTC lines over a frame', () {
    final ps2 = _ps2();
    var starts = 0, ends = 0;
    ps2.io.intc.mask = 0;
    for (var line = 0; line < ps2.scanlinesInFrame * 2;) {
      final r = ps2.exec(false);
      if (r.scanlineRendered) line++;
      if (ps2.io.intc.stat & (1 << Intc.vblankStart) != 0) {
        starts++;
        ps2.io.intc.stat = 0;
      }
      if (ps2.io.intc.stat & (1 << Intc.vblankEnd) != 0) {
        ends++;
        ps2.io.intc.stat = 0;
      }
    }
    expect(starts, 2);
    expect(ends, 2);
  });

  test('timer interrupt reaches the CPU through the INTC', () {
    final ps2 = _ps2();
    final cpu = ps2.cpu;
    cpu.cop0[R5900.cop0Status] = (1 << 16) | 1 | (1 << 10);
    ps2.io.intc.mask = 1 << Intc.timer0;
    ps2.bus.write32(0x10000020, 5); // compare
    ps2.bus.write32(0x10000010, 0x80 | 0x100);
    var taken = false;
    for (var i = 0; i < 200 && !taken; i++) {
      ps2.exec(true);
      taken = cpu.pc >= 0x80000200 && cpu.pc < 0x80000300;
    }
    expect(taken, isTrue);
  });
}
