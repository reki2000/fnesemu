import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/scif.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:test/test.dart';

void main() {
  late DcBus bus;
  late Sh4 cpu;
  late List<int> sent;
  const base = 0xffe80000;
  setUp(() {
    bus = DcBus();
    cpu = Sh4(bus)..sr = 0x40000000;
    cpu.pc = 0xac010000;
    cpu.vbr = 0x8c040000;
    bus.write16(cpu.pc, 0x0009);
    sent = [];
    bus.scif.onTransmit = sent.add;
    bus.write8(base + 4, 0);
  });

  test('queued transmission waits for TE and emits complete frames in order',
      () {
    for (final byte in [65, 66, 67]) {
      bus.write8(base + 0xc, byte);
    }
    bus.scif.tickPeripheralClocks(10000);
    expect(sent, isEmpty);
    expect(bus.read16(base + 0x1c), 0x300);
    bus.write16(base + 8, 0x20);
    expect(bus.read16(base + 0x1c), 0x200);
    bus.read16(base + 0x10);
    bus.write16(base + 0x10, 0);
    expect(bus.read16(base + 0x10) & 0x40, 0);
    bus.scif.tickPeripheralClocks(320 * 3);
    expect(sent, [65, 66, 67]);
    expect(bus.read16(base + 0x10), 0x60);
  });

  test('TEND is set at stop-bit start before a complete frame is emitted', () {
    bus.write16(base + 8, 0x20);
    bus.write8(base + 0xc, 65);
    bus.read16(base + 0x10);
    bus.write16(base + 0x10, 0);
    bus.scif.tickPeripheralClocks(32 * 9 - 1);
    expect(bus.read16(base + 0x10) & 0x40, 0);
    bus.scif.tickPeripheralClocks(1);
    expect(bus.read16(base + 0x10) & 0x40, 0x40);
    expect(sent, isEmpty);
    bus.scif.tickPeripheralClocks(32);
    expect(sent, [65]);
  });

  test('transmit FIFO is 16 bytes and discards writes beyond capacity', () {
    for (var i = 0; i < 18; i++) {
      bus.write8(base + 0xc, i);
    }
    expect(bus.read16(base + 0x1c), 0x1000);
    bus.write16(base + 8, 0x20);
    bus.scif.tickPeripheralClocks(320 * 16);
    expect(sent, List.generate(16, (i) => i));
  });

  test('TDFE clears only after read-one and enough FIFO data, then reasserts',
      () {
    bus.write16(base + 0x18, 0x30);
    bus.write16(base + 8, 0x20);
    for (var i = 0; i < 4; i++) {
      bus.write8(base + 0xc, i);
    }
    bus.write16(base + 0x10, 0);
    expect(bus.read16(base + 0x10) & 0x20, 0x20);
    bus.write16(base + 0x10, 0);
    expect(bus.read16(base + 0x10) & 0x20, 0);
    bus.scif.tickPeripheralClocks(320);
    expect(bus.read16(base + 0x10) & 0x20, 0);
    bus.scif.tickPeripheralClocks(320);
    expect(bus.read16(base + 0x10) & 0x20, 0x20);
  });

  test('receive data is gated by RE; peeks do not pop or acknowledge flags',
      () {
    bus.scif.receiveFrame(65);
    expect(bus.read16(base + 0x1c), 0);
    bus.write16(base + 8, 0x10);
    bus.scif.receiveFrame(66);
    expect(bus.read8(base + 0x14, peek: true), 66);
    expect(bus.read16(base + 0x1c), 1);
    expect(bus.read8(base + 0x14), 66);
    bus.read16(base + 0x10, peek: true);
    bus.write16(base + 0x10, 0);
    expect(bus.read16(base + 0x10) & 2, 2);
    bus.write16(base + 0x10, 0);
    expect(bus.read16(base + 0x10) & 2, 0);
  });

  test('receive timeout occurs after 15 bit periods below the FIFO trigger',
      () {
    bus.write16(base + 0x18, 0x40);
    bus.write16(base + 8, 0x10);
    bus.scif.receiveFrame(65);
    bus.scif.tickPeripheralClocks(32 * 15 - 1);
    expect(bus.read16(base + 0x10) & 3, 0);
    bus.scif.tickPeripheralClocks(1);
    expect(bus.read16(base + 0x10) & 3, 1);
    expect(bus.read8(base + 0x14), 65);
    bus.write16(base + 0x10, 0);
    expect(bus.read16(base + 0x10) & 3, 0);
  });

  test('per-frame receive errors update head flags and FIFO error counts', () {
    bus.write16(base, 0x20);
    bus.write16(base + 8, 0x18);
    bus.scif.receiveFrame(65, parityError: true);
    bus.scif.receiveFrame(66, framingError: true);
    expect(bus.read16(base + 0x10) & 0xff8c, 0x1184);
    expect(bus.scif.interruptEvent, 0x700);
    expect(bus.read8(base + 0x14), 65);
    expect(bus.read16(base + 0x10) & 0xff8c, 0x0188);
    bus.write16(base + 0x10, 0);
    expect(bus.read16(base + 0x10) & 0x80, 0);
  });

  test('receive overrun drops the new byte and requires read-before-clear', () {
    bus.write16(base + 8, 0x18);
    for (var i = 0; i < 17; i++) {
      bus.scif.receiveFrame(i);
    }
    expect(bus.read16(base + 0x1c), 16);
    expect(bus.scif.interruptEvent, 0x740);
    bus.read16(base + 0x24, peek: true);
    bus.write16(base + 0x24, 0);
    expect(bus.read16(base + 0x24), 1);
    bus.write16(base + 0x24, 0);
    expect(bus.read16(base + 0x24), 0);
    expect(List.generate(16, (_) => bus.read8(base + 0x14)),
        List.generate(16, (i) => i));
  });

  test('CTS stalls new frames and FIFO reset retains an already shifting byte',
      () {
    bus.write16(base + 0x18, 8);
    bus.scif.ctsHigh = true;
    bus.write16(base + 8, 0x20);
    bus.write8(base + 0xc, 65);
    bus.write8(base + 0xc, 66);
    bus.scif.tickPeripheralClocks(1000);
    expect(sent, isEmpty);
    bus.scif.ctsHigh = false;
    bus.write16(base + 0x18, 12);
    bus.scif.tickPeripheralClocks(320);
    expect(sent, [65]);
    expect(bus.read16(base + 0x1c), 0);
  });

  test('loopback and 7-bit format deliver masked completed characters', () {
    bus.write16(base, 0x40);
    bus.write16(base + 0x18, 1);
    bus.write16(base + 8, 0x30);
    bus.write8(base + 0xc, 255);
    bus.scif.tickPeripheralClocks(32 * 9);
    expect(sent, [127]);
    expect(bus.read8(base + 0x14), 127);
  });

  test(
      'all internal clock divisors and programmed frame formats set completion time',
      () {
    for (var divider = 0; divider < 4; divider++) {
      bus.scif.reset();
      sent.clear();
      bus.write16(base, 0x68 | divider);
      bus.write8(base + 4, 3);
      bus.write16(base + 8, 0x20);
      bus.write8(base + 0xc, 65);
      final clocks = 32 * 4 * (1 << (2 * divider)) * 11;
      bus.scif.tickPeripheralClocks(clocks - 1);
      expect(sent, isEmpty);
      bus.scif.tickPeripheralClocks(1);
      expect(sent, [65]);
    }
  });

  for (final event in [0x700, 0x720, 0x740, 0x760]) {
    test(
        'SCIF event ${event.toRadixString(16)} enters the CPU interrupt vector',
        () {
      bus.write16(0xffd0000c, 0x90);
      if (event == 0x760) {
        bus.write16(base + 8, 0x80);
      } else {
        bus.write16(base + 8, event == 0x720 ? 0x50 : 0x18);
        if (event == 0x740) {
          for (var i = 0; i < 17; i++) {
            bus.scif.receiveFrame(i);
          }
        } else {
          bus.write16(base, 0x20);
          bus.scif.receiveFrame(65, parityError: event == 0x700);
        }
      }
      cpu.step();
      expect(bus.intevt, event);
      expect(cpu.pc, 0x8c040600);
      expect(cpu.instructionExecuted, isFalse);
    });
  }

  test(
      'peripheral DMA transmits beyond FIFO capacity with CPU interrupts disabled',
      () {
    const dma = 0xffa00000, source = 0x0c020000;
    for (var i = 0; i < 21; i++) {
      bus.write8(source + i, i);
    }
    bus.write16(base + 0x18, 0x30);
    bus.write16(base + 8, 0x20);
    bus.write32(dma, source);
    bus.write32(dma + 4, base + 0xc);
    bus.write32(dma + 8, 21);
    bus.write32(dma + 12, 0x1a15);
    bus.write32(dma + 0x40, 1);
    bus.tickCpuClocks(21 * 1280 + 4);
    expect(sent, List.generate(21, (i) => i));
    expect(bus.read32(dma + 8), 0);
    expect(bus.dma.interruptPending(0), isTrue);
  });

  test('receive DMA clears RDF automatically and copies bytes without CPU RIE',
      () {
    const dma = 0xffa00000, destination = 0x0c020000;
    bus.write16(base + 8, 0x10);
    for (var i = 0; i < 4; i++) {
      bus.scif.receiveFrame(65 + i);
    }
    bus.write32(dma, base + 0x14);
    bus.write32(dma + 4, destination);
    bus.write32(dma + 8, 4);
    bus.write32(dma + 12, 0x4b11);
    bus.write32(dma + 0x40, 1);
    bus.tickCpuClocks(8);
    expect(
        List.generate(4, (i) => bus.read8(destination + i)), [65, 66, 67, 68]);
    expect(bus.read16(base + 0x10) & 3, 0);
    expect(bus.scif.interruptEvent, 0);
    expect(bus.read32(dma + 8), 0);
  });

  test(
      'batched loopback clocks match individual clocks including receive timeout',
      () {
    final batch = DcScif(), single = DcScif();
    final output = <int>[], reference = <int>[];
    batch.onTransmit = output.add;
    single.onTransmit = reference.add;
    for (final serial in [batch, single]) {
      serial.write(4, 1, 0);
      serial.write(0x18, 2, 0x41);
      serial.write(8, 2, 0x30);
      for (var i = 0; i < 3; i++) {
        serial.write(0xc, 1, i);
      }
    }
    batch.tickPeripheralClocks(1440);
    for (var i = 0; i < 1440; i++) {
      single.tickPeripheralClocks(1);
    }
    expect(output, reference);
    expect(batch.read(0x10, 2), single.read(0x10, 2));
    expect(batch.read(0x10, 2) & 1, 1);
    expect(batch.read(0x1c, 2), single.read(0x1c, 2));
  });

  test('Core executes a serial diagnostic and exposes its completed output',
      () {
    final core = Dc()
      ..setRom(Uint8List.fromList([0x10, 0x22, 0xfe, 0xaf, 9, 0]));
    core.cpu.r[1] = 65;
    core.cpu.r[2] = base + 0xc;
    core.bus.scif.onTransmit = sent.add;
    core.bus.write8(base + 4, 0);
    core.bus.write16(base + 8, 0x20);
    for (var i = 0; i < 1284; i++) {
      expect(core.exec(true).stopped, isFalse);
    }
    expect(sent, [65]);
  });

  test('all FIFO trigger levels require the documented counts to clear flags',
      () {
    for (var mode = 0; mode < 4; mode++) {
      bus.scif.reset();
      bus.write16(base + 0x18, mode << 6);
      bus.write16(base + 8, 0x10);
      final trigger = [1, 4, 8, 14][mode];
      for (var i = 1; i < trigger; i++) {
        bus.scif.receiveFrame(i);
      }
      expect(bus.read16(base + 0x10) & 2, 0);
      bus.scif.receiveFrame(trigger);
      expect(bus.read16(base + 0x10) & 2, 2);
      bus.write16(base + 0x10, 0);
      expect(bus.read16(base + 0x10) & 2, 2);
      bus.read8(base + 0x14);
      bus.write16(base + 0x10, 0);
      expect(bus.read16(base + 0x10) & 2, 0);

      bus.scif.reset();
      bus.write16(base + 0x18, mode << 4);
      final transmitTrigger = [8, 4, 2, 1][mode];
      for (var i = 0; i <= transmitTrigger; i++) {
        bus.write8(base + 0xc, i);
      }
      bus.read16(base + 0x10);
      bus.write16(base + 0x10, 0);
      expect(bus.read16(base + 0x10) & 0x20, 0);
      bus.write16(base + 8, 0x20);
      expect(bus.read16(base + 0x10) & 0x20, 0x20);
    }
  });

  test('overrun and break block further receive transfers until acknowledged',
      () {
    bus.write16(base + 8, 0x18);
    for (var i = 0; i < 17; i++) {
      bus.scif.receiveFrame(i);
    }
    bus.read8(base + 0x14);
    bus.scif.receiveFrame(99);
    expect(bus.read16(base + 0x1c), 15);
    bus.read16(base + 0x24);
    bus.write16(base + 0x24, 0);
    bus.scif.receiveFrame(99);
    expect(bus.read16(base + 0x1c), 16);

    bus.scif.reset();
    bus.write16(base + 8, 0x18);
    bus.scif.receiveBreak();
    expect(bus.scif.interruptEvent, 0x700);
    bus.scif.receiveFrame(65);
    expect(bus.read16(base + 0x1c), 1);
    bus.read16(base + 0x10);
    bus.write16(base + 0x10, 0xff7f);
    expect(bus.scif.interruptEvent, 0x740);
    bus.write16(base + 0x10, 0xff6f);
    expect(bus.scif.interruptEvent, 0);
    bus.scif.receiveFrame(65);
    expect(bus.read16(base + 0x1c), 2);
  });

  test(
      'coupled serial DMA batches match individual clocks through loopback and timeout',
      () {
    final batch = DcBus(), single = DcBus();
    final output = <int>[], reference = <int>[];
    batch.scif.onTransmit = output.add;
    single.scif.onTransmit = reference.add;
    for (final target in [batch, single]) {
      target.write8(base + 4, 0);
      target.write16(base + 0x18, 0x71);
      target.write16(base + 8, 0x30);
      for (var i = 0; i < 21; i++) {
        target.write8(0x0c020000 + i, i);
      }
      target.write32(0xffa00000, 0x0c020000);
      target.write32(0xffa00004, base + 0xc);
      target.write32(0xffa00008, 21);
      target.write32(0xffa0000c, 0x1a15);
      target.write32(0xffa00010, base + 0x14);
      target.write32(0xffa00014, 0x0c030000);
      target.write32(0xffa00018, 21);
      target.write32(0xffa0001c, 0x4b15);
      target.write32(0xffa00040, 0x301);
    }
    const clocks = 21 * 1280 + 1920 + 20;
    batch.tickCpuClocks(clocks);
    for (var i = 0; i < clocks; i++) {
      single.tickCpuClocks(1);
    }
    expect(output, List.generate(21, (i) => i));
    expect(output, reference);
    expect(batch.ram.sublist(0x30000, 0x30015), output);
    expect(single.ram.sublist(0x30000, 0x30015), output);
    for (final offset in [8, 12, 24, 28]) {
      expect(batch.read32(0xffa00000 + offset),
          single.read32(0xffa00000 + offset));
    }
    expect(batch.read32(0xffa00018), 0);
    expect(batch.read16(base + 0x10), single.read16(base + 0x10));
  });

  test('invalid SCIF DMA width sets AE without consuming receive data', () {
    bus.write16(base + 8, 0x10);
    bus.scif.receiveFrame(65);
    bus.write32(0xffa00000, base + 0x14);
    bus.write32(0xffa00004, 0x0c020000);
    bus.write32(0xffa00008, 1);
    bus.write32(0xffa0000c, 0x4b25);
    bus.write32(0xffa00040, 1);
    bus.dma.tickTransferUnits(1);
    expect(bus.dma.addressError, isTrue);
    expect(bus.read16(base + 0x1c), 1);
    expect(bus.read32(0xffa00008), 1);
  });
}
