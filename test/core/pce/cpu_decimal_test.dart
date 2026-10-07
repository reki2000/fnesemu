import 'package:fnesemu/core/pce/component/bus.dart';
import 'package:fnesemu/core/pce/component/cpu.dart';
import 'package:fnesemu/core/pce/component/pic.dart';
import 'package:test/test.dart';

void main() {
  // runs `op #b` in decimal mode with a and carry, on work ram mapped at $2000
  (int, bool) run(int op, int a, int b, bool carry) {
    final bus = Bus();
    final cpu = Cpu2(bus);
    Pic(bus);
    cpu.regs.mpr[1] = 0xf8;
    cpu.regs.mprAddress[1] = 0xf8 << 13;
    bus.write(0xf8 << 13, op);
    bus.write((0xf8 << 13) | 1, b);
    cpu.regs.pc = 0x2000;
    cpu.regs.a = a;
    cpu.regs.p = Flags.D | Flags.I | (carry ? Flags.C : 0);
    cpu.exec();
    return (cpu.regs.a, cpu.regs.p & Flags.C != 0);
  }

  int bcd(int v) => (v ~/ 10) << 4 | v % 10;

  test('decimal ADC adds bcd digits', () {
    for (var a = 0; a < 100; a++) {
      for (var b = 0; b < 100; b++) {
        for (final c in [false, true]) {
          final sum = a + b + (c ? 1 : 0);
          final (r, carry) = run(0x69, bcd(a), bcd(b), c);
          expect(r, bcd(sum % 100), reason: '$a + $b + $c');
          expect(carry, sum >= 100, reason: '$a + $b + $c');
        }
      }
    }
  });

  test('decimal SBC subtracts bcd digits', () {
    for (var a = 0; a < 100; a++) {
      for (var b = 0; b < 100; b++) {
        for (final c in [false, true]) {
          final diff = a - b - (c ? 0 : 1);
          final (r, carry) = run(0xe9, bcd(a), bcd(b), c);
          expect(r, bcd((diff + 100) % 100), reason: '$a - $b, carry $c');
          expect(carry, diff >= 0, reason: '$a - $b, carry $c');
        }
      }
    }
  });

  test('an interrupt clears the decimal flag for the handler', () {
    final bus = Bus();
    final cpu = Cpu2(bus);
    final pic = Pic(bus);
    pic.mask = 0;
    cpu.regs.mprAddress[1] = 0xf8 << 13; // work ram for the stack
    cpu.regs.p = Flags.D | Flags.C;
    cpu.regs.s = 0xff;
    pic.holdTirq();
    cpu.handleIrq(); // the instruction after the mask write runs first
    cpu.handleIrq();
    expect(cpu.regs.p & Flags.D, 0);
    expect(cpu.regs.p & Flags.I, Flags.I);
    // the pushed status keeps the decimal flag for RTI
    final pushed = bus.read(cpu.regs.mprAddress[1] | 0x100 | (cpu.regs.s + 1));
    expect(pushed & Flags.D, Flags.D);
  });
}
