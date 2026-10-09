import 'package:fnesemu_core/core/snes/component/cpu.dart';
import 'package:fnesemu_core/core/snes/component/ppu.dart';
import 'package:fnesemu_core/core/snes/rom/snes_file.dart';
import 'package:fnesemu_core/core/snes/snes.dart';
import 'package:fnesemu_core/util/int.dart';
import 'package:test/test.dart';

import 'test_rom.dart';

void main() {
  group('bus', () {
    test('LoROM sram is mapped at banks \$70-\$7D / \$F0-\$FF', () {
      final bus = busWith(loRom(sramSizeByte: 3));
      bus.write(0x700010, 0x5a);
      expect(bus.read(0x700010), 0x5a);
      expect(bus.read(0xf00010), 0x5a);
      expect(bus.read(0x708010), isNot(0x5a)); // upper half is rom
    });

    test('HiROM sram is mapped at \$6000-\$7FFF of banks \$20-\$3F', () {
      final bus = busWith(hiRom());
      expect(bus.mapping, SnesMapping.hiRom);
      bus.write(0x206000, 0xa5);
      bus.write(0x217fff, 0x3c);
      expect(bus.read(0xa06000), 0xa5);
      expect(bus.read(0x217fff), 0x3c);
      expect(bus.sram[0x1fff], 0x3c); // 8KB sram mirrors per bank
    });

    test('multiply / divide unit', () {
      final bus = busWith(loRom());
      bus.write(0x4202, 12);
      bus.write(0x4203, 10);
      expect(bus.read(0x4216) | bus.read(0x4217).shl8, 120);

      bus.write(0x4204, 0x34);
      bus.write(0x4205, 0x12);
      bus.write(0x4206, 0x10);
      expect(bus.read(0x4214) | bus.read(0x4215).shl8, 0x123);
      expect(bus.read(0x4216) | bus.read(0x4217).shl8, 0x4);

      bus.write(0x4206, 0); // divide by zero
      expect(bus.read(0x4214) | bus.read(0x4215).shl8, 0xffff);
      expect(bus.read(0x4216) | bus.read(0x4217).shl8, 0x1234);
    });
  });

  group('timer irq', () {
    test('H/V match sets TIMEUP and reading it acknowledges the IRQ', () {
      final bus = busWith(loRom());
      Cpu(bus).reset();
      bus.write(0x4207, 100); // H target dot
      bus.write(0x4208, 0);
      bus.write(0x4209, 4); // V target line
      bus.write(0x420a, 0);
      bus.write(0x4200, 0x30); // H + V IRQ

      expect(bus.timerReached(3, 300, 400, 227), isFalse);
      expect(bus.timerReached(4, 400, 465, 227), isFalse);
      expect(bus.timerReached(4, 400, 466, 227), isTrue);
      expect(bus.read(0x4211), 0x80);
      expect(bus.read(0x4211), 0);

      bus.write(0x4200, 0x10); // H-only: trigger on any scanline
      expect(bus.timerReached(5, 500, 565, 227), isFalse);
      expect(bus.timerReached(5, 500, 566, 227), isTrue);
      bus.write(0x4200, 0); // disabling clears the pending IRQ
      expect(bus.read(0x4211), 0);
    });

    test('vertical timer runs an IRQ handler during the frame', () {
      final rom = loRom();
      rom.setAll(0, [
        0x58, // CLI
        0xa9, 0x05, // LDA #5
        0x8d, 0x09, 0x42, // STA VTIME
        0x9c, 0x0a, 0x42, // STZ VTIMEH
        0xa9, 0x20, // LDA #V-IRQ enable
        0x8d, 0x00, 0x42, // STA NMITIMEN
        0xcb, // WAI
        0x80, 0xfd, // BRA back to WAI
      ]);
      rom.setAll(0x100, [
        0xa9, 0x07, // LDA #7
        0x8d, 0x05, 0x21, // STA BGMODE
        0xad, 0x11, 0x42, // LDA TIMEUP (acknowledge IRQ)
        0x40, // RTI
      ]);
      rom[0x7ffe] = 0x00;
      rom[0x7fff] = 0x81; // emulation-mode IRQ vector -> $8100
      final core = Snes()..setRom(rom);

      for (var i = 0; i < 10000 && core.ppu.bgMode != 7; i++) {
        expect(core.exec(false).stopped, isFalse);
      }
      expect(core.ppu.bgMode, 7);
      expect(core.cpu.cycle, lessThan(Snes.cpuCyclesInScanline * 6));
      expect(core.bus.read(0x4211), 0x80);
    });
  });

  test('WMDATA reads and writes wram at WMADD, which increments', () {
    final bus = (busWith(loRom())..ppu = Ppu());
    bus.write(0x2181, 0xff);
    bus.write(0x2182, 0xff);
    bus.write(0x2183, 0x00);
    bus.write(0x2180, 0x12);
    bus.write(0x2180, 0x34); // crosses into bank $7F
    expect(bus.read(0x7effff), 0x12);
    expect(bus.read(0x7f0000), 0x34);

    bus.write(0x2181, 0xff);
    bus.write(0x2182, 0xff);
    bus.write(0x2183, 0x00);
    expect(bus.read(0x2180), 0x12);
    expect(bus.read(0x2180), 0x34);
  });
}
