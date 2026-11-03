import 'package:fnesemu_core/src/core/snes/component/cpu.dart';
import 'package:test/test.dart';

import 'test_rom.dart';

void main() {
  group('main cpu', () {
    test('IRQ in emulation mode pushes P with the B flag clear', () {
      final rom = loRom();
      rom[0] = 0x58; // CLI
      final bus = busWith(rom);
      final cpu = Cpu(bus)..reset();

      cpu.exec(); // CLI
      cpu.holdIrq();
      cpu.exec(); // IRQ

      expect(cpu.regs.pc, 0x9000);
      expect(bus.wram[0x1fd] & 0x10, 0);
    });

  });
}
