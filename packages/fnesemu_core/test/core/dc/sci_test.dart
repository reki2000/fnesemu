import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/sci.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:test/test.dart';

void main() {
  late DcBus bus;
  const base = 0xffe00000;
  setUp(() => bus = DcBus());

  void send(int byte) {
    final status = bus.read8(base + 16);
    bus.write8(base + 12, byte);
    bus.write8(base + 16, status & ~0x80);
  }

  test('byte register resets, aliases and read-only data', () {
    expect([
      for (final offset in [0, 4, 8, 12, 16, 20]) bus.read8(base + offset)
    ], [
      0,
      255,
      0,
      255,
      0x84,
      0
    ]);
    bus.write8(base + 4, 7);
    expect(bus.read8(0x1fe00004), 7);
    expect(() => bus.read16(base), throwsA(isA<DcUnsupported>()));
    expect(() => bus.read32(base), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write16(base, 0), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write32(base, 0), throwsA(isA<DcUnsupported>()));
    expect(() => bus.write8(base + 20, 0), throwsA(isA<DcUnsupported>()));
    expect(() => bus.read8(0xdfe00000), throwsA(isA<DcUnsupported>()));
    bus.write8(base, 4);
    bus.write8(base + 8, 0x20);
    expect(bus.read8(base + 8), 0x20);
  });

  test('multiprocessor address filtering, rearming and data reception', () {
    final chip = DcSci();
    chip.write(0, 1, 0x64); // Seven data bits; MP replaces parity.
    chip.write(8, 1, 0x58); // RIE, RE, MPIE.
    expect(chip.frameBits, 10);
    chip.receiveFrame(0x11, parityError: true, framingError: true);
    expect(chip.read(16, 1), 0x84);
    expect(chip.read(20, 1), 0);
    expect(chip.read(8, 1), 0x58);
    expect(chip.receiveRequest, isFalse);
    chip.receiveFrame(0xe1, multiprocessorBit: true, parityError: true);
    expect(chip.read(8, 1), 0x50);
    expect(chip.read(20, 1), 0x61);
    expect(chip.interruptEvent, 0x500);
    expect(chip.read(16, 1) & 0x0a, 0); // No parity; MPB is undefined.
    chip.dmaRead();
    chip.receiveFrame(0x22);
    expect(chip.dmaRead(), 0x22);
    chip.write(8, 1, 0x58);
    chip.receiveFrame(0x33);
    expect(chip.read(20, 1), 0x22);
    chip.receiveFrame(0x44, multiprocessorBit: true);
    expect(chip.read(20, 1), 0x44);
  });

  test('multiprocessor address releases MPIE before framing and overrun checks',
      () {
    final chip = DcSci();
    chip.write(0, 1, 4);
    chip.write(8, 1, 0x58);
    chip.receiveFrame(1, multiprocessorBit: true, framingError: true);
    expect(chip.read(8, 1) & 8, 0);
    expect(chip.read(16, 1) & 0x78, 0x10);
    expect(chip.interruptEvent, 0x4e0);
    chip.write(16, 1, 0x84);
    chip.receiveFrame(2);
    chip.write(8, 1, 0x58);
    chip.receiveFrame(3); // Ignored even with unread data.
    expect(chip.read(16, 1) & 0x78, 0x40);
    chip.receiveFrame(4, multiprocessorBit: true);
    expect(chip.read(8, 1) & 8, 0);
    expect(chip.read(16, 1) & 0x78, 0x60);
    expect(chip.read(20, 1), 2);
  });

  for (final mode in [0, 0x84]) {
    test('MPIE and injected MP bit are ignored outside MP mode $mode', () {
      final chip = DcSci();
      chip.write(0, 1, mode);
      chip.write(8, 1, 0x58);
      chip.receiveFrame(0x81, multiprocessorBit: true);
      expect(chip.read(8, 1) & 8, 8);
      expect(chip.read(20, 1), 0x81);
      expect(chip.interruptEvent, 0x500);
    });
  }

  for (var clock = 0; clock < 4; clock++) {
    test('baud selection $clock and stop-start TEND timing', () {
      final output = <int>[];
      bus.sci.onTransmit = output.add;
      bus.write8(base, 0x68 | clock); // Seven bits, parity, two stop bits.
      bus.write8(base + 4, 2);
      bus.write8(base + 8, 0x24);
      final bit = 32 * 3 * (1 << (clock * 2));
      expect(bus.sci.bitClocks, bit);
      expect(bus.sci.frameBits, 11);
      send(0xff);
      expect(bus.read8(base + 16) & 0x84, 0x80);
      bus.sci.tickPeripheralClocks(9 * bit - 1);
      expect(bus.sci.interruptEvent, 0);
      bus.sci.tickPeripheralClocks(1);
      expect(bus.sci.interruptEvent, 0x540);
      expect(output, isEmpty);
      bus.sci.tickPeripheralClocks(2 * bit);
      expect(output, [127]);
    });
  }

  test('CPU TDR writes need a prior status read and TDRE acknowledgement', () {
    final output = <int>[];
    bus.sci.onTransmit = output.add;
    bus.write8(base + 4, 0);
    bus.write8(base + 8, 0x20);
    bus.write8(base + 12, 0x41);
    bus.write8(base + 16, 0);
    bus.tickMasterClocks(1280);
    expect(output, isEmpty);
    expect(bus.peek8(base + 16) & 0x84, 0x84);
    send(0x42);
    bus.tickMasterClocks(1280);
    expect(output, [0x42]);
  });

  test(
      'double buffering reloads at the first stop bit and preserves byte order',
      () {
    final output = <int>[];
    bus.sci.onTransmit = output.add;
    bus.write8(base + 4, 0);
    bus.write8(base + 8, 0x20);
    send(0x41);
    send(0x42);
    expect(bus.read8(base + 16) & 0x80, 0);
    bus.sci.tickPeripheralClocks(288);
    expect(bus.read8(base + 16) & 0x84, 0x80);
    send(0x43);
    bus.sci.tickPeripheralClocks(32 + 640);
    expect(output, [0x41, 0x42, 0x43]);
    expect(bus.read8(base + 16) & 0x84, 0x84);
  });

  test(
      'receive acknowledgement, peeks, overrun and disabled receiver retain data',
      () {
    bus.write8(base + 8, 0x50);
    bus.sci.receiveFrame(0x41);
    expect(bus.sci.interruptEvent, 0x500);
    expect(bus.read8(base + 20), 0x41);
    expect(bus.sci.receiveRequest, isTrue);
    bus.peek8(base + 16);
    bus.write8(base + 16, 0x84);
    expect(bus.sci.receiveRequest, isTrue);
    bus.sci.receiveFrame(0x42);
    expect(bus.sci.interruptEvent, 0x4e0);
    bus.read8(base + 16);
    bus.write8(base + 16, 0x84);
    bus.write8(base + 8, 0);
    bus.sci.receiveFrame(0x43);
    expect(bus.read8(base + 20), 0x41);
    bus.write8(base + 8, 0x50);
    bus.sci.receiveFrame(0x44);
    expect(bus.read8(base + 20), 0x44);
  });

  test(
      'parity and framing errors transfer data without RDRF and block reception',
      () {
    bus.write8(base, 0x60);
    bus.write8(base + 8, 0x50);
    bus.sci.receiveFrame(0xff, parityError: true, framingError: true);
    expect(bus.read8(base + 20), 127);
    expect(bus.peek8(base + 16) & 0x78, 0x18);
    expect(bus.sci.receiveRequest, isFalse);
    bus.sci.receiveFrame(0x42);
    expect(bus.read8(base + 20), 127);
    bus.write8(base + 8, 0);
    expect(bus.peek8(base + 16) & 0x18, 0x18);
    bus.read8(base + 16);
    bus.write8(base + 16, 0x84);
    bus.write8(base, 0);
    bus.write8(base + 8, 0x50);
    bus.sci.receiveFrame(0x42, parityError: true);
    expect(bus.sci.interruptEvent, 0x500);
    expect(bus.read8(base + 20), 0x42);
  });

  test('EIO suppresses RXI but retains DMA and error requests', () {
    bus.write8(base + 8, 0x50);
    bus.write8(base + 28, 0x80);
    bus.sci.receiveFrame(1);
    expect(bus.sci.interruptEvent, 0);
    expect(bus.sci.receiveRequest, isTrue);
    bus.sci.receiveFrame(2);
    expect(bus.sci.interruptEvent, 0x4e0);
  });

  test('SCI interrupt enters the CPU handler with IPRB priority', () {
    final cpu = Sh4(bus)..sr = 0x40000000;
    cpu.pc = 0x8c010000;
    cpu.vbr = 0x8c030000;
    bus.write16(0xffd00008, 0x90);
    bus.write8(base + 8, 0x80);
    cpu.step();
    expect(bus.intevt, 0x520);
    expect(cpu.spc, 0x8c010000);
    expect(cpu.pc, 0x8c030600);
    expect(cpu.instructionExecuted, isFalse);
  });

  test(
      'module stop resets SCI except port and rejects activity until reconfigured',
      () {
    final output = <int>[];
    bus.sci.onTransmit = output.add;
    bus.write8(base + 28, 0x8a);
    bus.write8(base + 4, 0);
    bus.write8(base + 8, 0x30);
    send(0x41);
    bus.write8(0xffc00004, 1);
    bus.sci.receiveFrame(1);
    bus.write8(base + 4, 0);
    expect(bus.read8(base + 4), 255);
    expect(bus.read8(base + 8), 0);
    expect(bus.read8(base + 16), 0x84);
    expect(bus.read8(base + 28) & 0x8a, 0x8a);
    bus.write8(0xffc00004, 0);
    bus.tickMasterClocks(200000);
    expect(output, isEmpty);
    expect(bus.read8(base + 20), 0);
  });

  test('equal-priority requests follow TMU, SCI, SCIF, WDT order', () {
    bus.write16(0xffd00004, 0x9000);
    bus.write16(0xffd00008, 0x9090);
    bus.write16(0xffd0000c, 0x90);
    bus.write32(0xffd8000c, 0);
    bus.write16(0xffd80010, 0x20);
    bus.write8(0xffd80004, 1);
    bus.write8(base + 8, 0x80);
    bus.write16(0xffe80008, 0x80);
    bus.write16(0xffc00008, 0x5aff);
    bus.write16(0xffc0000c, 0xa580);
    bus.tickMasterClocks(32);
    (int, int) pending() => bus.intc
        .pending(15, bus.tmu, sci: bus.sci, scif: bus.scif, cpg: bus.cpg);
    expect(pending(), (9, 0x400));
    bus.write8(0xffd80004, 0);
    bus.write16(0xffd80010, 0x20);
    expect(pending(), (9, 0x520));
    bus.write8(base + 8, 0);
    expect(pending(), (9, 0x760));
    bus.write16(0xffe80008, 0);
    expect(pending(), (9, 0x560));
  });

  void dma(int channel, int source, int target, int count, int control) {
    final registers = 0xffa00000 + channel * 16;
    bus.write32(registers, source);
    bus.write32(registers + 4, target);
    bus.write32(registers + 8, count);
    bus.write32(registers + 12, control);
  }

  test('SCI DMA transmit streams across double buffer with interrupts disabled',
      () {
    final output = <int>[];
    bus.sci.onTransmit = output.add;
    bus.write8(base + 4, 0);
    bus.write8(base + 8, 0x20);
    for (var i = 0; i < 8; i++) {
      bus.write8(0x8c020000 + i, 0x40 + i);
    }
    dma(0, 0x8c020000, base + 12, 8, 0x1811);
    bus.write32(0xffa00040, 1);
    bus.tickMasterClocks(1280 * 8 + 4);
    expect(output, [for (var i = 0; i < 8; i++) 0x40 + i]);
    expect(bus.read32(0xffa00008), 0);
    expect(bus.read32(0xffa0000c) & 2, 2);
    expect(bus.sci.interruptEvent, 0);
  });

  test('SCI DMA receive clears RDRF and invalid width leaves data available',
      () {
    bus.write8(base + 8, 0x10);
    dma(1, base + 20, 0x8c020000, 2, 0x4911);
    bus.write32(0xffa00040, 1);
    for (var i = 0; i < 2; i++) {
      bus.sci.receiveFrame(0x40 + i);
      bus.tickMasterClocks(2);
      expect(bus.sci.receiveRequest, isFalse);
    }
    expect([bus.read8(0x8c020000), bus.read8(0x8c020001)], [0x40, 0x41]);
    bus.read32(0xffa0001c);
    bus.write32(0xffa0001c, 0);
    dma(1, base + 20, 0x8c020004, 1, 0x4921);
    bus.sci.receiveFrame(0x55);
    bus.tickMasterClocks(2);
    expect(bus.dma.addressError, isTrue);
    expect(bus.sci.receiveRequest, isTrue);
    expect(bus.read8(base + 20), 0x55);
  });

  test('a serial DMA request cannot target the other serial channel', () {
    bus.write8(base + 8, 0x20);
    bus.write8(0x8c020000, 0x41);
    dma(0, 0x8c020000, 0xffe8000c, 1, 0x1811);
    bus.write32(0xffa00040, 1);
    expect(() => bus.tickMasterClocks(2), throwsA(isA<DcUnsupported>()));
    expect(bus.read32(0xffa00008), 1);
    expect(bus.read16(0xffe8001c), 0);
  });

  test('disabled and stopped SCI retain their specified DMA register state',
      () {
    bus.sci.dmaWrite(0x41);
    expect(bus.read8(base + 12), 0x41);
    expect(bus.read8(base + 16), 0x84);
    bus.write8(0xffc00004, 1);
    bus.sci.dmaWrite(0x42);
    expect(bus.read8(base + 12), 255);
    expect(bus.read8(base + 16), 0x84);
  });

  test('Core executes a guest SCI output program', () {
    final core = Dc()
      ..setRom(Uint8List.fromList([0x00, 0x21, 0xfe, 0xaf, 9, 0]));
    final output = <int>[];
    core.bus.sci.onTransmit = output.add;
    core.bus.write8(base + 4, 0);
    core.bus.write8(base + 8, 0x20);
    core.bus.write8(base + 12, 0x41);
    core.cpu.r[1] = base + 16;
    core.cpu.r[0] = core.bus.read8(base + 16) & ~0x80;
    for (var i = 0; i < 1280; i++) {
      expect(core.exec(true).stopped, isFalse);
    }
    expect(output, [0x41]);
  });

  test('batched SCI advancement agrees with individual peripheral clocks', () {
    final batch = DcSci(), single = DcSci();
    final outputs = [<int>[], <int>[]];
    for (final (i, device) in [batch, single].indexed) {
      device.onTransmit = outputs[i].add;
      device.write(4, 1, 0);
      device.write(8, 1, 0x20);
      for (final byte in [0x41, 0x42]) {
        device.read(16, 1);
        device.write(12, 1, byte);
        device.write(16, 1, 0);
      }
    }
    batch.tickPeripheralClocks(1000);
    for (var i = 0; i < 1000; i++) {
      single.tickPeripheralClocks(1);
    }
    expect(outputs[0], [0x41, 0x42]);
    expect(outputs[0], outputs[1]);
    expect(batch.read(16, 1), single.read(16, 1));
  });
}
