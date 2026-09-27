import 'dart:typed_data';

import 'package:fnesemu/core/nes/component/apu.dart';
import 'package:fnesemu/core/nes/component/bus.dart';
import 'package:fnesemu/core/nes/component/cpu.dart';
import 'package:fnesemu/core/nes/component/ppu.dart';
import 'package:fnesemu/core/nes/mapper/mapper.dart';
import 'package:fnesemu/core/nes/mapper/mmc1.dart';
import 'package:fnesemu/core/nes/mapper/mmc3.dart';
import 'package:fnesemu/core/nes/mapper/namco163.dart';
import 'package:fnesemu/core/nes/mapper/vrc6_apu.dart';
import 'package:fnesemu/core/nes/rom/nes_file.dart';
import 'package:test/test.dart';

// 0x6000-0xffff is RAM, so that a test can place a program and vectors
class _RamMapper extends Mapper {
  final mem = Uint8List(0xa000);

  @override
  void init() {}

  @override
  int read(int addr) => mem[addr - 0x6000];

  @override
  void write(int addr, int data) => mem[addr - 0x6000] = data;
}

class _System {
  final bus = Bus();
  late final Cpu cpu;
  late final Ppu ppu;
  late final Apu apu;
  final mapper = _RamMapper();

  _System() {
    cpu = Cpu(bus);
    ppu = Ppu(bus);
    apu = Apu(bus);
    bus.mapper = mapper;
  }

  void load(int addr, List<int> code) {
    for (int i = 0; i < code.length; i++) {
      mapper.mem[addr + i - 0x6000] = code[i];
    }
  }

  void vector(int addr, int target) {
    load(addr, [target & 0xff, target >> 8]);
  }

  void reset(int pc) {
    vector(0xfffc, pc);
    bus.onReset();
  }
}

// iNES image with 1 x 16k prg and the given chr banks
Uint8List _ines({
  int flags6 = 0,
  List<int> header7to15 = const [0, 0, 0, 0, 0, 0, 0, 0, 0],
}) {
  return Uint8List.fromList([
    0x4e, 0x45, 0x53, 0x1a, 1, 0, flags6, ...header7to15, //
    ...List.filled(0x4000, 0),
  ]);
}

void main() {
  group('bus', () {
    test('internal ram is mirrored at 0x0800-0x1fff', () {
      final s = _System();
      s.bus.write(0x1801, 0x5a);
      expect(s.bus.read(0x0001), 0x5a);
      expect(s.bus.read(0x0801), 0x5a);
    });

    test('ppu registers are mirrored up to 0x3fff', () {
      final s = _System();
      s.bus.write(0x3ffe, 0x3f); // $2006
      s.bus.write(0x3ffe, 0x01);
      s.bus.write(0x2007, 0x2a);
      expect(s.ppu.palette[1], 0x2a);
    });

    test('oam dma can read from any page', () {
      final s = _System();
      s.mapper.mem[0] = 0x12; // 0x6000
      s.bus.write(0x4014, 0x60);
      expect(s.ppu.objRam[0], 0x12);

      s.bus.write(0x0900, 0x34); // mirrored ram
      s.bus.write(0x4014, 0x09);
      expect(s.ppu.objRam[0], 0x34);
    });

    test('expansion area is routed only to mappers which use it', () {
      final s = _System();
      s.bus.mapper = MapperNamco163()
        ..setRom(Uint8List(0x2000), Uint8List(0x8000))
        ..init();
      s.bus.write(0x5000, 0x34);
      s.bus.write(0x5800, 0x12);
      expect(s.bus.read(0x5000), 0x34);
      expect(s.bus.read(0x5800), 0x12);
    });
  });

  group('cpu', () {
    test('reset sets I flag and clears B', () {
      final s = _System();
      s.reset(0x8000);
      expect(s.cpu.regs.p & Flags.I, Flags.I);
      expect(s.cpu.regs.p & Flags.B, 0);
    });

    test('BRK pushes B=1, IRQ pushes B=0, and costs 7 cycles', () {
      final s = _System();
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

    test('irq sources are independent', () {
      final s = _System();
      s.vector(0xfffe, 0x9000);
      s.load(0x8000, [0x58, 0xea, 0xea, 0xea]); // CLI, NOP...
      s.reset(0x8000);

      s.bus.holdIrq(); // mapper
      s.apu.read(0x4015); // acknowledges frame irq only
      s.cpu.exec(); // CLI
      s.cpu.exec(); // NOP
      s.cpu.exec(); // IRQ
      expect(s.cpu.regs.pc, 0x9000);
    });

    test('irq acknowledged before being taken is not executed', () {
      final s = _System();
      s.vector(0xfffe, 0x9000);
      s.load(0x8000, [0x58, 0xea, 0xea, 0xea]);
      s.reset(0x8000);

      s.bus.holdIrq();
      s.cpu.exec(); // CLI
      s.cpu.exec(); // NOP: irq is pending
      s.bus.releaseIrq();
      s.cpu.exec();
      expect(s.cpu.regs.pc, isNot(0x9000));
    });

    test('read-modify-write instructions write 8bit values', () {
      final s = _System();
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

  group('ppu', () {
    test('palette 0x3f10 mirrors are also mirrored at 0x3f30', () {
      final s = _System();
      s.ppu.writeVram(0x3f30, 0x21);
      expect(s.ppu.readVram(0x3f00), 0x21);
      expect(s.ppu.readVram(0x3f10), 0x21);
    });

    test('0x2004 returns oam data', () {
      final s = _System();
      s.bus.write(0x2003, 0x05);
      s.bus.write(0x2004, 0x77);
      s.bus.write(0x2003, 0x05);
      expect(s.bus.read(0x2004), 0x77);
    });
  });

  group('apu', () {
    test('writing 0x80- to 0x4011 does not overflow the mixer', () {
      final s = _System();
      s.apu.write(0x4011, 0xff);
      s.apu.write(0x4015, 0x10);
      expect(() => s.apu.exec(2000), returnsNormally);
    });

    test('direct 0x4011 writes are output', () {
      final s = _System();
      s.apu.write(0x4011, 0x40);
      final out = s.apu.exec(100);
      expect(out.last, greaterThan(0));
    });

    test('disabling a channel clears its length counter', () {
      final s = _System();
      s.apu.write(0x4015, 0x01);
      s.apu.write(0x4003, 0x08);
      expect(s.apu.read(0x4015) & 0x01, 0x01);
      s.apu.write(0x4015, 0x00);
      expect(s.apu.read(0x4015) & 0x01, 0x00);
    });

    test('dmc irq is raised at the end of a non-looped sample', () {
      final s = _System();
      s.vector(0xfffe, 0x9000);
      s.apu.write(0x4010, 0x8f); // irq, fastest
      s.apu.write(0x4012, 0x00);
      s.apu.write(0x4013, 0x00); // 1 byte
      s.apu.write(0x4015, 0x10);
      s.apu.exec(2000);
      expect(s.apu.read(0x4015) & 0x80, 0x80);

      s.apu.write(0x4015, 0x00); // acknowledge
      expect(s.apu.read(0x4015) & 0x80, 0);
    });

    test('looped dmc sample does not raise irq', () {
      final s = _System();
      s.apu.write(0x4010, 0xcf); // irq, loop, fastest
      s.apu.write(0x4013, 0x00);
      s.apu.write(0x4015, 0x10);
      s.apu.exec(2000);
      expect(s.apu.read(0x4015) & 0x80, 0);
    });
  });

  group('rom', () {
    test('garbage in the header does not change the mapper number', () {
      final file = NesFile()
        ..load(
          _ines(
            flags6: 0x10,
            header7to15: [0x44, 0x69, 0x73, 0x6b, 0x44, 0x75, 0x64, 0x65, 0x21],
          ),
        );
      expect(file.mapper, 1);
    });

    test('nes 2.0 mapper bits 8-11 are read from byte 8', () {
      final file = NesFile()
        ..load(
          _ines(flags6: 0x50, header7to15: [0x48, 0x01, 0, 0, 0, 0, 0, 0, 0]),
        );
      expect(file.mapper, 0x145);
    });
  });

  group('mappers', () {
    test('mmc1 switches chr rom banks', () {
      final chr = Uint8List(0x8000); // 8 x 4k
      for (int i = 0; i < 8; i++) {
        chr[i * 0x1000] = i;
      }
      final m = MapperMMC1()
        ..setRom(chr, Uint8List(0x8000))
        ..init();

      void serial(int addr, int value) {
        for (int i = 0; i < 5; i++) {
          m.write(addr, (value >> i) & 1);
        }
      }

      serial(0x8000, 0x10 | 0x0c); // 4k chr mode
      serial(0xa000, 5);
      serial(0xc000, 3);
      expect(m.readVram(0x0000), 5);
      expect(m.readVram(0x1000), 3);

      serial(0x8000, 0x0c); // 8k chr mode
      serial(0xa000, 6);
      expect(m.readVram(0x0000), 6);
      expect(m.readVram(0x1000), 7);
    });

    test('mmc1 reset selects prg mode 3', () {
      final prg = Uint8List(0x10000); // 4 x 16k
      for (int i = 0; i < 4; i++) {
        prg[i * 0x4000] = i;
      }
      final m = MapperMMC1()
        ..setRom(Uint8List(0), prg)
        ..init();

      void serial(int addr, int value) {
        for (int i = 0; i < 5; i++) {
          m.write(addr, (value >> i) & 1);
        }
      }

      serial(0x8000, 0x08); // prg mode 2: fixed first bank at 8000
      serial(0xe000, 1);
      expect(m.read(0x8000), 0);
      m.write(0x8000, 0x80); // reset
      expect(m.read(0x8000), 1);
      expect(m.read(0xc000), 3);
    });

    test('mmc3 irq fires at the latch+1-th a12 rising edge after reload', () {
      final m = MapperMMC3()
        ..setRom(Uint8List(0x2000), Uint8List(0x8000))
        ..init();
      var irq = false;
      m.holdIrq = (hold) => irq = hold;

      m.write(0xc000, 3); // latch
      m.write(0xc001, 0); // reload
      m.write(0xe001, 0); // enable

      void edge() {
        m.readVram(0x0000);
        m.readVram(0x1000);
      }

      for (int i = 0; i < 3; i++) {
        edge();
      }
      expect(irq, false);
      edge();
      expect(irq, true);

      m.write(0xe000, 0); // acknowledge
      expect(irq, false);
    });

    test('namco163 irq counter counts every cpu cycle', () {
      final m = MapperNamco163()
        ..setRom(Uint8List(0x2000), Uint8List(0x8000))
        ..init();
      var irq = false;
      m.holdIrq = (hold) => irq = hold;

      m.write(0x5000, 0xff - 100);
      m.write(0x5800, 0x80 | 0x7f); // enable, counter = 0x7fff - 100
      m.handleClock(99);
      expect(irq, false);
      m.handleClock(100);
      expect(irq, true);
    });

    test('vrc6 sawtooth produces output', () {
      final apu = Vrc6Apu();
      apu.write(0xb000, 0x20); // rate
      apu.write(0xb001, 0x10);
      apu.write(0xb002, 0x80); // enable
      final out = apu.exec(2000);
      expect(out.any((v) => v > 0), true);
    });
  });
}
