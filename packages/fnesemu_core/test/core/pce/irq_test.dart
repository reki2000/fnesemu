import 'package:fnesemu_core/src/core/pce/component/bus.dart';
import 'package:fnesemu_core/src/core/pce/component/cpu.dart';
import 'package:fnesemu_core/src/core/pce/component/pic.dart';
import 'package:test/test.dart';

void main() {

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

}
