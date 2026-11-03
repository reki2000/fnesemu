import 'package:fnesemu_core/src/core/nes/component/cpu.dart';
import 'package:test/test.dart';

import 'test_system.dart';

void main() {
  group('cpu', () {

    test('BRK pushes B=1, IRQ pushes B=0, and costs 7 cycles', () {
      final s = TestSystem();
      s.vector(0xfffe, 0x9000);
      s.load(0x8000, [0x58, 0x00, 0x00, 0xea]); // CLI, BRK, pad, NOP
      s.load(0x9000, [0x40]); // RTI
      s.reset(0x8000);

      s.cpu.exec(); // CLI
      s.cpu.exec(); // BRK
      expect(
        s.bus.read(0x100 | ((s.cpu.regs.s + 1) & 0xff)) & Flags.B,
        Flags.B,
      );
      s.cpu.exec(); // RTI

      s.bus.holdIrq();
      s.cpu.exec(); // NOP, irq is taken on the next exec
      final cycle = s.cpu.cycle;
      s.cpu.exec(); // IRQ
      expect(s.cpu.regs.pc, 0x9000);
      expect(s.cpu.cycle - cycle, 7);
      expect(s.bus.read(0x100 | ((s.cpu.regs.s + 1) & 0xff)) & Flags.B, 0);
    });

    test('read-modify-write instructions write 8bit values', () {
      final s = TestSystem();
      s.load(0x8000, [0xee, 0x00, 0x60, 0xce, 0x01, 0x60, 0x0e, 0x02, 0x60]);
      s.mapper.mem[0] = 0xff; // INC $6000
      s.mapper.mem[1] = 0x00; // DEC $6001
      s.mapper.mem[2] = 0x80; // ASL $6002
      s.reset(0x8000);
      s.cpu.exec();
      s.cpu.exec();
      s.cpu.exec();
      expect(s.mapper.mem.sublist(0, 3), [0x00, 0xff, 0x00]);
    });
  });
}
