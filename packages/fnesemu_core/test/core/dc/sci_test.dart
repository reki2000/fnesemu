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


  void dma(int channel, int source, int target, int count, int control) {
    final registers = 0xffa00000 + channel * 16;
    bus.write32(registers, source);
    bus.write32(registers + 4, target);
    bus.write32(registers + 8, count);
    bus.write32(registers + 12, control);
  }





  test('Core executes a guest SCI output program', () {
    final core = Dc()
      ..setRom(Uint8List.fromList([0x00, 0x21, 0xfe, 0xaf, 9, 0]));
    addTearDown(core.dispose);
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
