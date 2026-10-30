@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/maple_controller.dart';
import 'package:fnesemu_core/src/core/dc/memory_card.dart';
import 'package:fnesemu_core/src/state.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

Dc diagnostic({int add = 1}) =>
    Dc()..setRom(Uint8List.fromList([add, 0x70, 0xfd, 0xaf, 9, 0]));
void equalBytes(Uint8List actual, Uint8List expected) {
  expect(actual.length, expected.length);
  for (var i = 0; i < actual.length; i++) {
    if (actual[i] != expected[i]) fail('byte $i differs');
  }
}

void advance(Dc source, Dc target, int count, {bool step = false}) {
  for (var i = 0; i < count; i++) {
    final a = source.exec(step), b = target.exec(step);
    expect(a.stopped, isFalse, reason: source.stopReason);
    expect(b.stopped, isFalse, reason: target.stopReason);
    expect(b.elapsedClocks, a.elapsedClocks);
    expect(b.executed(0), a.executed(0));
    expect(b.executed(1), a.executed(1));
    expect(b.scanlineRendered, a.scanlineRendered);
  }
  expect(target.cpu.pc, source.cpu.pc);
  expect(target.cpu.r, source.cpu.r);
  expect(target.cpuClocks, source.cpuClocks);
}

void main() {
  test('public DC state resumes CPU execution alongside G2 and Maple transfers',
      () {
    final source = diagnostic(), target = diagnostic();
    final bus = source.bus;
    bus.ram.fillRange(0x70000, 0x70040, 0x6d);
    bus.ram.setUint32LE(0x50000, 0x80000000);
    bus.ram.setUint32LE(0x50004, 0x0c060000);
    bus.ram.setRange(0x50008, 0x5000c, [0, 0, 32, 3]);
    bus.dma.write(0x40, 0x8201);
    bus.g2.write(0xbc, 4, 0x4659007f);
    for (final (offset, value) in [
      (0, 0x00802000),
      (4, 0x0c070000),
      (8, 0x80000040),
      (12, 0),
      (16, 0),
      (20, 1),
      (24, 1)
    ]) {
      bus.g2.write(offset, 4, value);
    }
    bus.g2.prepare();
    bus.maple.write(0x8c, 4, 0x6155407f);
    bus.maple.write(0xe8, 4, 0);
    bus.maple.write(4, 4, 0x0c050000);
    bus.maple.write(0x14, 4, 1);
    bus.maple.write(0x18, 4, 1);
    bus.maple.prepare();
    target.loadState(source.saveState());
    source.bus.tickMasterClocks(1000000);
    target.bus.tickMasterClocks(1000000);
    advance(source, target, 10000);
    expect(target.bus.aica.memory.sublist(0x2000, 0x2040), everyElement(0x6d));
    expect(target.bus.ram.getUint32LE(0x60000), 0x07002000);
    expect(target.bus.systemBus.normalStatus & ((1 << 12) | (1 << 15)),
        (1 << 12) | (1 << 15));
    equalBytes(target.saveState(), source.saveState());
  });

  test(
      'public DC state retains presented video, controller input and memory card identity',
      () {
    final source = diagnostic(), target = diagnostic();
    source.attachMemoryCard(0, 0, DcMemoryCard());
    final destinationMemoryCard = DcMemoryCard();
    target.attachMemoryCard(0, 0, destinationMemoryCard);
    source.padDown(0, DcMapleController.a);
    source.bus.maple.controllers[0]!
        .exchange(Uint8List.fromList([1, 32, 0, 0]), 0);
    final gpu = source.bus.gpu;
    for (final (offset, value) in [
      (0x44, 0x80000d),
      (0xd8, 0x00020008),
      (0xc8, 0x00042000),
      (0xcc, 0x00020001),
      (0xd4, 0x00020006),
      (0xdc, 2),
      (0xe0, 0x101),
      (0xec, 2),
      (0xf0, 0),
      (0xe8, 0),
      (0x5c, 1 << 20),
      (0xd0, 0x100)
    ]) {
      gpu.write(offset, 4, value);
    }
    gpu.vram.setUint32LE(0, 0x00112233);
    for (var i = 0; i < 215; i++) {
      expect(source.exec(false).stopped, isFalse);
    }
    expect(source.imageBuffer().buffer, [0xff332211]);
    target.loadState(source.saveState());
    expect(target.imageBuffer().buffer, [0xff332211]);
    expect(
        identical(target.bus.maple.controllers[0]!.expansions[0],
            destinationMemoryCard),
        isTrue);
    final request = Uint8List.fromList([9, 32, 0, 1, 0, 0, 0, 1]);
    expect(target.bus.maple.controllers[0]!.exchange(request, 0)![8], 0xfb);
    advance(source, target, 503);
    expect(target.imageBuffer().buffer, source.imageBuffer().buffer);
    equalBytes(target.saveState(), source.saveState());
    target.padUp(0, DcMapleController.a);
    expect(target.bus.maple.controllers[0]!.exchange(request, 0)![8], 0xff);
    expect(source.bus.maple.controllers[0]!.exchange(request, 0)![8], 0xfb);
  });

  test('public DC state retains partial DSP audio and destination callback',
      () {
    final source = diagnostic(), target = diagnostic();
    final packets = <Float32List>[], resumed = <Float32List>[];
    source
        .onAudio((packet) => packets.add(Float32List.fromList(packet.buffer)));
    target
        .onAudio((packet) => resumed.add(Float32List.fromList(packet.buffer)));
    final sound = source.bus.aica.sound;
    source.bus.write32(0xa0702880, 2);
    sound.control = 15;
    sound.writeOutput(0x2000, 0xf00);
    final dsp = source.bus.aica.dsp;
    for (final (offset, value) in [
      (0x3000, 0x4000),
      (0x3404, 0xb000),
      (0x3408, 2),
      (0x3200, 0x1000),
      (0x3410, 0x100),
      (0x3414, 0x40),
      (0x3418, 0xd002),
      (0x341c, 0x8000),
      (0x3bf8, 0xa002),
      (0x3bfc, 0x8000)
    ]) {
      dsp.write(offset, value);
    }
    for (final (offset, value) in [
      (0, 0x4600),
      (4, 0x1000),
      (8, 0),
      (12, 1),
      (0x10, 31),
      (0x14, 31),
      (0x18, 0x7800),
      (0x20, 15 << 4),
      (0x24, 0),
      (0x28, 4),
      for (var offset = 0x2c; offset <= 0x3c; offset += 4) (offset, 0x1ff8),
      (0, 0xc600)
    ]) {
      sound.write(offset, value);
    }
    source.bus.tickMasterClocks(185000);
    expect(packets, isEmpty);
    target.loadState(source.saveState());
    expect(resumed, isEmpty);
    source.bus.tickMasterClocks(2000000);
    target.bus.tickMasterClocks(2000000);
    expect(packets, isNotEmpty);
    expect(resumed.length, packets.length);
    expect(packets.first.any((sample) => sample != 0), isTrue);
    for (var i = 0; i < packets.length; i++) {
      expect(resumed[i], packets[i]);
    }
    equalBytes(target.saveState(), source.saveState());
  });

  test('public DC state rejects late corruption before committing CPU or RAM',
      () {
    final source = diagnostic(), target = diagnostic();
    for (var i = 0; i < 17; i++) {
      target.exec(false);
    }
    target.bus.ram[0x12345] = 0x56;
    final before = target.saveState(), bytes = source.saveState();
    expect(
        () =>
            target.loadState(Uint8List.sublistView(bytes, 0, bytes.length - 1)),
        throwsA(isA<StateMismatch>()));
    equalBytes(target.saveState(), before);
    expect(() => target.loadState(Uint8List.fromList([...bytes, 0])),
        throwsA(isA<StateMismatch>()));
    equalBytes(target.saveState(), before);
  });
}
