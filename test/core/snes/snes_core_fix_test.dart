import 'dart:typed_data';

import 'package:fnesemu/core/snes/component/bus.dart';
import 'package:fnesemu/core/snes/component/cpu.dart';
import 'package:fnesemu/core/snes/component/dma.dart';
import 'package:fnesemu/core/snes/component/dsp.dart';
import 'package:fnesemu/core/snes/component/ppu.dart';
import 'package:fnesemu/core/snes/component/ppu_render.dart';
import 'package:fnesemu/core/snes/component/spc700.dart';
import 'package:fnesemu/core/snes/rom/snes_file.dart';
import 'package:fnesemu/util/int.dart';
import 'package:test/test.dart';

// LoROM image with the reset vector at $8000 and [sramSizeByte] as the
// header's ram-size byte (0 = none, 3 = 8KB)
Uint8List _loRom({int sramSizeByte = 0}) {
  final rom = Uint8List(0x8000);
  rom[0x7fd8] = sramSizeByte;
  rom[0x7ffc] = 0x00; // emulation-mode reset vector -> $8000
  rom[0x7ffd] = 0x80;
  rom[0x7ffe] = 0x00; // emulation-mode IRQ/BRK vector -> $9000
  rom[0x7fff] = 0x90;
  return rom;
}

// HiROM image with a plausible header at $FFC0 and an 8KB sram
Uint8List _hiRom() {
  final rom = Uint8List(0x10000);
  for (int i = 0; i < 21; i++) {
    rom[0xffc0 + i] = 0x41; // printable title
  }
  rom[0xffd8] = 3; // 8KB sram
  rom[0xffdc] = 0xff; // checksum complement
  rom[0xffdd] = 0xff;
  rom[0xfffd] = 0x80; // reset vector $8000
  return rom;
}

Bus _busWith(Uint8List rom) {
  final bus = Bus();
  bus.setRom(SnesFile()..load(rom));
  return bus;
}

Spc700 _soundCpuAt(List<int> program) {
  final snd = Spc700(Dsp());
  for (int i = 0; i < program.length; i++) {
    snd.ram[0x200 + i] = program[i];
  }
  snd.pc = 0x200;
  return snd;
}

void main() {
  group('main cpu', () {
    test('IRQ in emulation mode pushes P with the B flag clear', () {
      final rom = _loRom();
      rom[0] = 0x58; // CLI
      final bus = _busWith(rom);
      final cpu = Cpu(bus)..reset();

      cpu.exec(); // CLI
      cpu.holdIrq();
      cpu.exec(); // IRQ

      expect(cpu.regs.pc, 0x9000);
      expect(bus.wram[0x1fd] & 0x10, 0);
    });

    test('MVN with 8-bit index registers wraps X/Y within the low byte', () {
      final rom = _loRom();
      rom.setAll(0, [0x54, 0x7e, 0x7e]); // MVN $7e,$7e
      final bus = _busWith(rom);
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

  group('bus', () {
    test('LoROM sram is mapped at banks \$70-\$7D / \$F0-\$FF', () {
      final bus = _busWith(_loRom(sramSizeByte: 3));
      bus.write(0x700010, 0x5a);
      expect(bus.read(0x700010), 0x5a);
      expect(bus.read(0xf00010), 0x5a);
      expect(bus.read(0x708010), isNot(0x5a)); // upper half is rom
    });

    test('HiROM sram is mapped at \$6000-\$7FFF of banks \$20-\$3F', () {
      final bus = _busWith(_hiRom());
      expect(bus.mapping, SnesMapping.hiRom);
      bus.write(0x206000, 0xa5);
      bus.write(0x217fff, 0x3c);
      expect(bus.read(0xa06000), 0xa5);
      expect(bus.read(0x217fff), 0x3c);
      expect(bus.sram[0x1fff], 0x3c); // 8KB sram mirrors per bank
    });

    test('multiply / divide unit', () {
      final bus = _busWith(_loRom());
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

  group('hdma', () {
    (Bus, Dma, Ppu) setup(List<int> table) {
      final bus = _busWith(_loRom());
      final ppu = Ppu();
      final dma = Dma(bus);
      bus.ppu = ppu;
      bus.dma = dma;
      bus.wram.setAll(0x1000, table);
      dma.channels[0]
        ..dmap = 0 // 1 register, write once
        ..bbad = 0x18 // VMDATAL: every write advances the vram address
        ..a1tAddr = 0x1000
        ..a1bBank = 0x7e;
      dma.hdmaEnableMask = 1;
      return (bus, dma, ppu);
    }

    test('non-repeat entry transfers only on its first line', () {
      final (_, dma, ppu) = setup([0x03, 0xaa, 0x00]);
      dma.hdmaInit();
      for (int i = 0; i < 3; i++) {
        dma.hdmaScanline();
      }
      expect(ppu.vramAddr, 1);
      expect(ppu.vram[0], 0xaa);
    });

    test('repeat entry transfers on every line', () {
      final (_, dma, ppu) = setup([0x83, 0x01, 0x02, 0x03, 0x00]);
      dma.hdmaInit();
      for (int i = 0; i < 3; i++) {
        dma.hdmaScanline();
      }
      expect(ppu.vramAddr, 3);
      expect([ppu.vram[0], ppu.vram[2], ppu.vram[4]], [1, 2, 3]);
    });
  });

  group('ppu', () {
    Ppu backdropPpu() {
      final ppu = Ppu();
      ppu.write(0x2100, 0x0f); // display on, full brightness
      ppu.write(0x2105, 0x01); // mode 1
      ppu.write(0x2121, 0x00);
      ppu.write(0x2122, 0x1f); // backdrop = red
      ppu.write(0x2122, 0x00);
      return ppu;
    }

    test('color math runs when CGWSEL selects "always" (0)', () {
      final ppu = backdropPpu();
      ppu.write(0x2130, 0x00); // math always, fixed color as sub screen
      ppu.write(0x2131, 0x20); // add, backdrop participates
      ppu.write(0x2132, 0x9f); // fixed color: blue 31
      ppu.renderScanline(1);
      expect(ppu.buffer[0], 0xffff00ff);
    });

    test('halved subtraction', () {
      final ppu = backdropPpu();
      ppu.write(0x2131, 0xe0); // subtract, half, backdrop
      ppu.write(0x2132, 0x21); // fixed color: red 1
      ppu.renderScanline(1);
      // (31 - 1) / 2 = 15 -> 8-bit 0x7b
      expect(ppu.buffer[0], 0xff00007b);
    });

    test('master brightness is applied', () {
      final ppu = backdropPpu();
      ppu.write(0x2100, 0x00);
      ppu.renderScanline(1);
      expect(ppu.buffer[0], 0xff000000);
    });
  });

  group('sound cpu', () {
    test('BCS / BCC follow the carry flag', () {
      final bcs = _soundCpuAt([0x80, 0xb0, 0x02, 0xe8, 0x11, 0xe8, 0x22]);
      for (int i = 0; i < 3; i++) {
        bcs.exec();
      }
      expect(bcs.a, 0x22);

      final bcc = _soundCpuAt([0x60, 0x90, 0x02, 0xe8, 0x11, 0xe8, 0x22]);
      for (int i = 0; i < 3; i++) {
        bcc.exec();
      }
      expect(bcc.a, 0x22);

      final noBranch = _soundCpuAt([0x60, 0xb0, 0x02, 0xe8, 0x11]);
      for (int i = 0; i < 3; i++) {
        noBranch.exec();
      }
      expect(noBranch.a, 0x11);
    });

    test('ADC / SBC (X),(Y) store the result to (X)', () {
      final snd = _soundCpuAt([0x99, 0x80, 0xb9]); // ADC (X),(Y); SETC; SBC
      snd.x = 0x10;
      snd.y = 0x20;
      snd.ram[0x10] = 5;
      snd.ram[0x20] = 3;
      snd.exec();
      expect(snd.ram[0x10], 8);
      expect(snd.ram[0x20], 3);

      snd.exec();
      snd.exec();
      expect(snd.ram[0x10], 5);
      expect(snd.ram[0x20], 3);
    });
  });

  group('dsp', () {
    // voice 0 plays source 0: a single end+loop BRR block at $0300 that
    // loops back to $0400. directory at $0200.
    Dsp setup() {
      final dsp = Dsp();
      final snd = Spc700(dsp);
      snd.ram.setAll(0x200, [0x00, 0x03, 0x00, 0x04]);
      snd.ram[0x300] = 0xc3; // shift 12, filter 0, loop + end
      snd.ram.fillRange(0x301, 0x309, 0x11);
      snd.ram[0x400] = 0xc0;
      snd.ram.fillRange(0x401, 0x409, 0x11);
      dsp.write(0x5d, 0x02); // DIR
      dsp.write(0x6c, 0x00); // FLG: no reset / mute
      dsp.write(0x0c, 0x7f); // main volume
      dsp.write(0x1c, 0x7f);
      dsp.write(0x00, 0x7f); // voice 0 volume
      dsp.write(0x01, 0x7f);
      dsp.write(0x03, 0x10); // pitch 0x1000
      return dsp;
    }

    test('global registers at \$x8-\$xF are writable', () {
      final dsp = setup();
      expect(dsp.read(0x0c), 0x7f);
      expect(dsp.mainVolL, 0x7f);
      expect(dsp.dir, 0x200);
    });

    test('KON starts a voice and an end block continues at the loop point',
        () {
      final dsp = setup();
      dsp.write(0x05, 0x8f); // ADSR, fastest attack
      dsp.write(0x4c, 0x01); // KON
      expect(dsp.voices[0].envMode, isNot(EnvMode.off));

      dsp.mixSample();
      expect(dsp.voices[0].brrAddr, 0x400);
      expect(dsp.endx.mask1, 1);
      expect(dsp.voices[0].envMode, isNot(EnvMode.off));
    });

    test('KOFF releases a voice in GAIN mode', () {
      final dsp = setup();
      dsp.write(0x05, 0x00); // GAIN mode
      dsp.write(0x07, 0x7f); // fixed max gain
      dsp.write(0x4c, 0x01);
      dsp.mixSample();
      final before = dsp.voices[0].env;

      dsp.write(0x5c, 0x01); // KOFF
      dsp.mixSample();
      expect(dsp.voices[0].env, lessThan(before));

      for (int i = 0; i < 0x800 ~/ 8; i++) {
        dsp.mixSample();
      }
      expect(dsp.voices[0].envMode, EnvMode.off);
    });

    test('decay stops at the sustain level', () {
      final dsp = setup();
      dsp.write(0x05, 0xff); // ADSR, fastest attack and decay
      dsp.write(0x06, 0xe0); // SL = 7 (-> 0x800), no sustain decrease
      dsp.write(0x4c, 0x01);
      for (int i = 0; i < 200; i++) {
        dsp.mixSample();
      }
      expect(dsp.voices[0].envMode, EnvMode.sustain);
      expect(dsp.voices[0].env, greaterThan(0x700));
    });
  });
}
