import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:test/test.dart';

void main() {
  late DcBus bus;
  late Sh4 cpu;
  const base = 0xffa00000, source = 0x0c020000, destination = 0x0c030000;
  const code = 0xac010000;
  setUp(() {
    bus = DcBus();
    cpu = Sh4(bus)..sr = 0x40000000;
    cpu.pc = code;
    cpu.vbr = 0x8c040000;
    bus.write16(code, 0x0009);
    bus.write16(code + 2, 0x0009);
  });

  void configure(int channel,
      {int count = 1,
      int from = source,
      int to = destination,
      int control = 0x5435}) {
    final registers = base + channel * 16;
    bus.write32(registers, from);
    bus.write32(registers + 4, to);
    bus.write32(registers + 8, count);
    bus.write32(registers + 12, control);
  }

  test('DMAC aliases, field masks, access widths and reset', () {
    bus.write32(0x1fa00008, 0xffffffff);
    expect(bus.read32(base + 8), 0xffffff);
    for (var channel = 0; channel < 4; channel++) {
      bus.write32(base + channel * 16 + 12, 0xffffffff);
      expect(bus.read32(base + channel * 16 + 12),
          channel < 2 ? 0xff0ffff5 : 0xff0afff5);
    }
    bus.write32(base + 0x40, 0x7fff);
    expect(bus.read32(base + 0x40), 0x301);
    bus.write32(base + 0x40, 0x8001);
    expect(bus.read32(base + 0x40), 0x8001);
    expect(() => bus.write32(base, 0), throwsA(isA<DcUnsupported>()));
    expect(() => bus.read16(base), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write8(base, 0), throwsA(isA<DcUnsupported>()));
    expect(() => bus.read32(0xdfa00000), throwsA(isA<DcUnsupported>()));
    cpu.reset();
    expect(bus.read32(base + 0x40), 0);
    for (var channel = 0; channel < 4; channel++) {
      expect(bus.read32(base + channel * 16 + 12), 0);
    }
  });

  test(
      'all five transfer sizes and nine address-mode pairs follow unit addressing',
      () {
    const sizes = [8, 1, 2, 4, 32], delta = [0, 1, -1];
    for (var sizeCode = 0; sizeCode < 5; sizeCode++) {
      final size = sizes[sizeCode];
      for (var sm = 0; sm < 3; sm++) {
        for (var dm = 0; dm < 3; dm++) {
          bus.dma.reset();
          for (var i = 0; i < size * 3; i++) {
            bus.ram[0x20000 + i] = (i * 17 + 3) & 255;
            bus.ram[0x30000 + i] = 0;
          }
          final from = source + (sm == 2 ? size * 2 : 0);
          final to = destination + (dm == 2 ? size * 2 : 0);
          final expected = List.filled(size * 3, 0);
          for (var unit = 0; unit < 3; unit++) {
            final input = from - source + unit * size * delta[sm];
            final output = to - destination + unit * size * delta[dm];
            for (var i = 0; i < size; i++) {
              expected[output + i] = ((input + i) * 17 + 3) & 255;
            }
          }
          configure(0,
              from: from,
              to: to,
              count: 3,
              control: (dm << 14) | (sm << 12) | 0x405 | (sizeCode << 4));
          bus.write32(base + 0x40, 1);
          bus.dma.tickTransferUnits(3);
          expect(bus.ram.sublist(0x30000, 0x30000 + size * 3), expected);
          expect(bus.read32(base), from + 3 * size * delta[sm]);
          expect(bus.read32(base + 4), to + 3 * size * delta[dm]);
          expect(bus.read32(base + 8), 0);
          expect(bus.dma.interruptPending(0), isTrue);
        }
      }
    }
  });

  test('DMA ignores high address bits and transfers boot ROM bytes to RAM', () {
    for (var i = 0; i < 32; i++) {
      bus.bios[i] = i;
    }
    configure(0, from: 0xa0000000, to: 0xac030000, control: 0x5445);
    bus.write32(base + 0x40, 1);
    bus.dma.tickTransferUnits(1);
    expect(bus.ram.sublist(0x30000, 0x30020), List.generate(32, (i) => i));
    expect(bus.read32(base), 0xa0000020);
    expect(bus.read32(base + 4), 0xac030020);
  });

  test(
      'zero transfer count means 16M units rather than an immediate completion',
      () {
    configure(0, count: 0);
    bus.write32(base + 0x40, 1);
    bus.dma.tickTransferUnits(1);
    expect(bus.read32(base + 8), 0xffffff);
    expect(bus.dma.interruptPending(0), isFalse);
  });

  test('decrement feedback wraps to a 32-bit address after the current unit',
      () {
    bus.bios[0] = 42;
    configure(0, from: 0, control: 0x2415);
    bus.write32(base + 0x40, 1);
    bus.dma.tickTransferUnits(1);
    expect(bus.read8(destination), 42);
    expect(bus.read32(base), 0xffffffff);
  });

  test('overlapping transfers read a new snapshot for each quadword unit', () {
    for (var i = 0; i < 24; i++) {
      bus.ram[0x20000 + i] = i;
    }
    configure(0, to: source + 8, count: 2, control: 0x5405);
    bus.write32(base + 0x40, 1);
    bus.dma.tickTransferUnits(2);
    expect(bus.ram.sublist(0x20000, 0x20018), List.generate(24, (i) => i % 8));
  });

  test('DME and DE suspend and resume without setting TE or losing progress',
      () {
    bus.write32(source, 42);
    bus.write32(source + 4, 43);
    configure(0, count: 2);
    bus.dma.tickTransferUnits(1);
    expect(bus.read32(base + 8), 2);
    bus.write32(base + 0x40, 1);
    bus.dma.tickTransferUnits(1);
    bus.write32(base + 12, 0x5434);
    bus.dma.tickTransferUnits(10);
    expect(bus.read32(base + 8), 1);
    expect(bus.dma.interruptPending(0), isFalse);
    bus.write32(base + 12, 0x5435);
    bus.dma.tickTransferUnits(1);
    expect(bus.read32(destination), 42);
    expect(bus.read32(destination + 4), 43);
    expect(bus.dma.interruptPending(0), isTrue);
  });

  test(
      'TE cannot be set by software or cleared without a preceding status read',
      () {
    configure(0, control: 0x5437);
    expect(bus.dma.interruptPending(0), isFalse);
    bus.write32(base + 0x40, 1);
    bus.dma.tickTransferUnits(1);
    bus.read32(base + 12, peek: true);
    bus.write32(base + 12, 0x5435);
    expect(bus.dma.interruptPending(0), isTrue);
    bus.read32(base + 12);
    bus.write32(base + 12, 0x5434);
    expect(bus.dma.interruptPending(0), isFalse);
  });

  test('alignment and area-7 errors suspend all channels and assert DMAE', () {
    for (final from in [source + 1, 0x1f000000]) {
      bus.dma.reset();
      configure(0, from: from);
      configure(1, to: destination + 4);
      bus.write32(base + 0x40, 1);
      bus.dma.tickTransferUnits(2);
      expect(bus.dma.addressError, isTrue);
      expect(bus.read32(base + 8), 1);
      expect(bus.read32(base + 24), 1);
      expect(bus.read32(destination), 0);
      bus.write16(0xffd0000c, 0xf00);
      expect(bus.intc.pending(15, bus.tmu, dma: bus.dma), (15, 0x6c0));
    }
  });

  test('AE and NMIF require read-one then write-zero to clear', () {
    configure(0, from: source + 1);
    bus.write32(base + 0x40, 1);
    bus.dma.tickTransferUnits(1);
    bus.write32(base + 0x40, 1);
    expect(bus.dma.addressError, isTrue);
    bus.read32(base + 0x40);
    bus.write32(base + 0x40, 1);
    expect(bus.dma.addressError, isFalse);
    bus.intc.nmiHigh = false;
    bus.write32(base + 0x40, 1);
    expect(bus.read32(base + 0x40), 3);
    bus.write32(base + 0x40, 1);
    expect(bus.read32(base + 0x40), 1);
  });

  test('NMI stops DMA even when the CPU blocks the pending NMI', () {
    configure(0, count: 3);
    bus.write32(base + 0x40, 1);
    bus.dma.tickTransferUnits(1);
    cpu.sr = 0x50000000;
    bus.intc.nmiHigh = false;
    cpu.step();
    bus.dma.tickTransferUnits(10);
    expect(cpu.pc, code + 2);
    expect(bus.read32(base + 8), 2);
    expect(bus.read32(base + 0x40) & 2, 2);
  });

  for (var channel = 0; channel < 4; channel++) {
    test(
        'channel $channel completion enters its DMTE handler and remains pending',
        () {
      configure(channel);
      bus.write16(0xffd0000c, 0x900);
      bus.write32(base + 0x40, 1);
      bus.dma.tickTransferUnits(1);
      cpu.step();
      expect(bus.intevt, 0x640 + channel * 0x20);
      expect(cpu.pc, 0x8c040600);
      expect(cpu.spc, code);
      expect(cpu.instructionExecuted, isFalse);
      expect(bus.dma.interruptPending(channel), isTrue);
    });
  }

  test(
      'three fixed priorities and round robin select channels at unit boundaries',
      () {
    for (var mode = 0; mode < 4; mode++) {
      bus.dma.reset();
      bus.ram.fillRange(0x30000, 0x30040, 0);
      for (var channel = 0; channel < 4; channel++) {
        bus.write32(source + channel * 8, channel + 1);
        bus.write32(source + channel * 8 + 4, channel + 1);
        configure(channel,
            from: source + channel * 8,
            count: 2,
            to: destination + channel * 8);
      }
      bus.write32(base + 0x40, 1 | (mode << 8));
      bus.dma.tickTransferUnits(2);
      if (mode == 3) {
        expect(bus.read32(base + 8), 1);
        expect(bus.read32(base + 24), 1);
      } else {
        final first = mode == 2 ? 2 : 0;
        expect(bus.read32(base + first * 16 + 8), 0);
        expect(bus.read32(destination + first * 8 + 4), first + 1);
      }
    }
  });

  test(
      'DMA reads and writes external RAM without cache snooping or MMU translation',
      () {
    bus.write32(source, 11);
    bus.write32(destination + 32, 22);
    bus.write32(0xff00001c, 5);
    bus.write32(source | 0x80000000, 42);
    expect(bus.read32((destination + 32) | 0x80000000), 22);
    bus.mmucr = 1;
    configure(0, to: destination + 32);
    bus.write32(base + 0x40, 1);
    bus.dma.tickTransferUnits(1);
    expect(bus.read32((destination + 32) | 0xa0000000), 11);
    expect(bus.read32((destination + 32) | 0x80000000), 22);
  });

  test(
      'unknown device transfer stops before copying or committing channel state',
      () {
    configure(0, to: 0x08000000);
    bus.write32(base + 0x40, 1);
    expect(() => bus.dma.tickTransferUnits(1), throwsA(isA<DcUnsupported>()));
    expect(bus.read32(base), source);
    expect(bus.read32(base + 8), 1);
    expect(bus.dma.addressError, isFalse);
  });

  test('DMA completion wins a same-priority TMU request in default order', () {
    configure(0);
    bus.write32(base + 0x40, 1);
    bus.dma.tickTransferUnits(1);
    bus.write32(0xffd8000c, 0);
    bus.write16(0xffd80010, 0x20);
    bus.write8(0xffd80004, 1);
    bus.tmu.tickPeripheralClocks(4);
    bus.write16(0xffd00004, 0x9000);
    bus.write16(0xffd0000c, 0x900);
    expect(bus.intc.pending(15, bus.tmu, dma: bus.dma), (9, 0x640));
    bus.read32(base + 12);
    bus.write32(base + 12, 0);
    expect(bus.intc.pending(15, bus.tmu, dma: bus.dma), (9, 0x400));
  });

  test(
      'Core DMA handler acknowledges completion and returns to interrupted code',
      () {
    final core = Dc()..setRom(Uint8List.fromList([9, 0, 9, 0, 9, 0]));
    core.cpu.sr = 0x40000000;
    core.cpu.vbr = 0x8c040000;
    core.cpu.r[10] = base + 12;
    core.cpu.r[12] = 0xfffffffc;
    core.bus.write32(source, 42);
    core.bus.write32(base, source);
    core.bus.write32(base + 4, destination);
    core.bus.write32(base + 8, 1);
    core.bus.write32(base + 12, 0x5435);
    core.bus.write32(base + 0x40, 1);
    core.bus.write16(0xffd0000c, 0x900);
    const handler = [0x6ba2, 0x2bc9, 0x2ab2, 0x002b, 0x0009];
    for (var i = 0; i < handler.length; i++) {
      core.bus.write16(0x8c040600 + i * 2, handler[i]);
    }
    core.exec(true);
    core.exec(true);
    expect(core.bus.read32(destination), 42);
    expect(core.exec(true).executed(0), isFalse);
    expect(core.bus.intevt, 0x640);
    for (var i = 0; i < handler.length; i++) {
      expect(core.exec(true).stopped, isFalse);
    }
    expect(core.cpu.pc, Dc.programAddress + 4);
    expect(core.bus.dma.interruptPending(0), isFalse);
    expect(core.exec(true).executed(0), isTrue);
  });

  test('Core schedules DMA and preserves a completed CPU step on a device stop',
      () {
    final core = Dc()..setRom(Uint8List.fromList([9, 0, 9, 0, 9, 0]));
    core.bus.write32(base, source);
    core.bus.write32(base + 4, 0x08000000);
    core.bus.write32(base + 8, 1);
    core.bus.write32(base + 12, 0x5435);
    core.bus.write32(base + 0x40, 1);
    expect(core.exec(true).stopped, isFalse);
    final stopped = core.exec(true);
    expect(stopped.stopped, isTrue);
    expect(stopped.executed(0), isTrue);
    expect(stopped.elapsedClocks, 1);
    expect(core.cpuClocks, 2);
    expect(core.cpu.pc, Dc.programAddress + 4);
    expect(core.stopReason, isNotNull);
    expect(core.exec(true).elapsedClocks, 0);
  });
}
