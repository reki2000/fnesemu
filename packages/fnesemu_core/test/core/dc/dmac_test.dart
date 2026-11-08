import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
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
      'Core DMA handler acknowledges completion and returns to interrupted code',
      () {
    final core = Dc()..setRom(Uint8List.fromList([9, 0, 9, 0, 9, 0]));
    addTearDown(core.dispose);
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

}
