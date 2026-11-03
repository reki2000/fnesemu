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





}
