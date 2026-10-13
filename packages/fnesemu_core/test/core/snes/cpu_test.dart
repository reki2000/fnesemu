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

    test('MVN with 8-bit index registers wraps X/Y within the low byte', () {
      final rom = loRom();
      rom.setAll(0, [0x54, 0x7e, 0x7e]); // MVN $7e,$7e
      final bus = busWith(rom);
      final cpu = Cpu(bus)..reset();
      cpu.regs.a = 1; // 2 bytes
      cpu.regs.x = 0xff;
      cpu.regs.y = 0x10;
      bus.wram[0xff] = 0x11;
      bus.wram[0x00] = 0x22;

      cpu.exec();

      expect(bus.wram[0x10], 0x11);
      expect(bus.wram[0x11], 0x22);
      expect(cpu.regs.x, 0x01);
    });
  });
}
