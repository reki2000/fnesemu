import 'package:fnesemu/core/gba/arm7tdmi/arm7.dart';
import 'package:fnesemu/core/gba/bus.dart';
import 'package:test/test.dart';

import 'cputest_rom.dart';

void main() {
  test('self-checking CPU test ROM reports all cases passing', () {
    final bus = Bus();
    bus.cart.load(buildCpuTestRom());
    final cpu = Arm7(bus)..resetHle();

    // run until the final `b .` (pc stops moving)
    var last = -1;
    var done = false;
    for (var i = 0; i < 100000; i++) {
      cpu.step();
      if (cpu.regs.pc == last) {
        done = true;
        break;
      }
      last = cpu.regs.pc;
    }

    expect(done, true, reason: 'ROM did not reach the end loop');
    expect(bus.read32(0x02000008).toRadixString(16), '600dc0de',
        reason: 'completion magic missing');
    expect(bus.read32(0x02000000), 0,
        reason:
            'fail count (last failing case id: ${bus.read32(0x02000004)})');
  });
}
