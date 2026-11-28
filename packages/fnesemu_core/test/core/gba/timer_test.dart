import 'package:fnesemu_core/src/core/gba/irq.dart';
import 'package:fnesemu_core/src/core/gba/timer.dart';
import 'package:test/test.dart';

void main() {
  test('cyclesToOverflow counts to the next interrupt overflow', () {
    final timers = Timers(Irq());
    expect(timers.cyclesToOverflow(), 0x7fffffff);

    // timer 0: reload 0xff00, prescaler 64, interrupt
    timers.write16(0x100, 0xff00);
    timers.write16(0x102, 0xc1);
    expect(timers.cyclesToOverflow(), 0x100 * 64);
    timers.tick(100);
    expect(timers.cyclesToOverflow(), 0x100 * 64 - 100);

    // without the interrupt and with no count-up channel, no limit
    timers.write16(0x102, 0x81);
    expect(timers.cyclesToOverflow(), 0x7fffffff);

    // a count-up timer 1 that the overflow drives
    timers.write16(0x106, 0x84);
    expect(timers.cyclesToOverflow(), 0x100 * 64 - 100);
  });
}
