import 'package:fnesemu/core/pce/component/bus.dart';
import 'package:fnesemu/core/pce/component/cpu.dart';
import 'package:fnesemu/core/pce/component/pic.dart';
import 'package:test/test.dart';

void main() {
  test('acknowledged IRQ1 is absent from interrupt status', () {
    final bus = Bus();
    Cpu2(bus);
    final pic = Pic(bus);
    pic.holdIrq1();
    expect(pic.hold & 0x02, 0x02);
    pic.acknoledgeIrq1();
    expect(pic.hold & 0x02, 0);
  });

  for (final interrupt in [Interrupt.irq1, Interrupt.irq2, Interrupt.tirq]) {
    test('pending $interrupt survives masking and is delivered on unmask', () {
      final bus = Bus();
      final cpu = Cpu2(bus);
      final pic = Pic(bus);
      final mask = switch (interrupt) {
        Interrupt.irq1 => 2,
        Interrupt.irq2 => 1,
        _ => 4,
      };
      bool requested() => switch (interrupt) {
            Interrupt.irq1 => cpu.holdIrq1,
            Interrupt.irq2 => cpu.holdIrq2,
            _ => cpu.holdTirq,
          };
      pic.mask = mask;
      switch (interrupt) {
        case Interrupt.irq1:
          pic.holdIrq1();
        case Interrupt.irq2:
          pic.holdIrq2();
        default:
          pic.holdTirq();
      }
      expect(requested(), isFalse);
      expect(pic.hold & mask, mask);
      pic.mask = 0;
      expect(requested(), isTrue);
      pic.mask = mask;
      expect(requested(), isFalse);
      expect(pic.hold & mask, mask);
    });
  }

  test(
      'an interrupt unmasked by the mask register is entered after the next instruction',
      () {
    final bus = Bus();
    final cpu = Cpu2(bus);
    final pic = Pic(bus);
    pic.mask = 0x04;
    pic.holdTirq();
    cpu.regs.p &= ~0x04; // clear I
    cpu.regs.pc = 0x1234;
    pic.mask = 0; // the store that unmasks the timer irq
    cpu.handleIrq(); // the instruction after the store runs first
    expect(cpu.regs.pc, 0x1234);
    pic.acknoledgeTirq(); // acknowledge (STZ $1403)
    cpu.handleIrq();
    expect(cpu.regs.pc, 0x1234);
  });

  test('masking a pending IRQ1 prevents CPU interrupt entry', () {
    final bus = Bus();
    final cpu = Cpu2(bus);
    final pic = Pic(bus);
    pic.holdIrq1();
    pic.mask = 0x02;
    cpu.regs.pc = 0x1234;
    cpu.handleIrq();
    expect(cpu.regs.pc, 0x1234);
  });
}
