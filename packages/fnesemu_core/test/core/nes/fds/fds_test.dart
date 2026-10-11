import 'dart:typed_data';

import 'package:fnesemu_core/src/core/core_factory.dart';
import 'package:fnesemu_core/src/core/nes/fds/fds_audio.dart';
import 'package:fnesemu_core/src/core/nes/fds/fds_image.dart';
import 'package:fnesemu_core/src/core/nes/fds/fds_mapper.dart';
import 'package:fnesemu_core/src/core/nes/nes.dart';
import 'package:fnesemu_core/src/core/pad_button.dart';
import 'package:fnesemu_core/src/core/sram.dart';
import 'package:test/test.dart';

Uint8List disk({int sides = 1, bool header = true}) {
  final result = Uint8List((header ? 16 : 0) + 65500 * sides);
  if (header) result.setAll(0, [0x46, 0x44, 0x53, 0x1a, sides]);
  for (var side = 0; side < sides; side++) {
    final at = (header ? 16 : 0) + 65500 * side;
    result[at] = 1;
    result.setAll(at + 1, '*NINTENDO-HVC*'.codeUnits);
    result[at + 21] = side;
    result.setAll(at + 56, [2, 1, 3]);
    result[at + 58 + 11] = 0;
    result[at + 58 + 12] = 0x60;
    result[at + 58 + 13] = 4;
    result.setAll(at + 74, [4, 0xea, 0x4c, 0x00, 0x60]);
  }
  return result;
}

Uint8List bios() {
  final result = Uint8List(8192);
  // Synthetic firmware reads the first disk block through the hardware ports.
  result.setAll(0, [
    0x78,
    0xa9,
    3,
    0x8d,
    0x23,
    0x40,
    0xa9,
    0xc5,
    0x8d,
    0x25,
    0x40,
    0xa2,
    0,
    0xad,
    0x30,
    0x40,
    0x29,
    2,
    0xf0,
    0xf9,
    0xad,
    0x31,
    0x40,
    0x9d,
    0,
    0x60,
    0xe8,
    0xe0,
    56,
    0xd0,
    0xee,
    0x4c,
    0x1f,
    0xe0,
  ]);
  result.setAll(0x1ffa, [0x1f, 0xe0, 0, 0xe0, 0x1f, 0xe0]);
  return result;
}

Uint8List loaderBios() {
  final result = Uint8List(8192);
  final code = <int>[
    0x78,
    0xa9,
    3,
    0x8d,
    0x23,
    0x40,
    0xa9,
    0xc5,
    0x8d,
    0x25,
    0x40
  ];
  for (final length in [56, 2, 16, 5]) {
    code.addAll([0xa2, 0]);
    final loop = code.length;
    code.addAll([
      0xad,
      0x30,
      0x40,
      0x29,
      2,
      0xf0,
      0xf9,
      0xad,
      0x31,
      0x40,
      0x9d,
      length == 5 ? 0xff : 0,
      length == 5 ? 0x5f : 0x62,
      0xe8,
      0xe0,
      length,
      0xd0
    ]);
    code.add((loop - code.length - 1) & 255);
    if (length != 5) {
      code.addAll([
        0xa9,
        0xd5,
        0x8d,
        0x25,
        0x40,
        0xa2,
        0,
        0xca,
        0xd0,
        0xfd,
        0xa9,
        0x85,
        0x8d,
        0x25,
        0x40,
        0xa2,
        40,
        0xca,
        0xd0,
        0xfd,
        0xa9,
        0xc5,
        0x8d,
        0x25,
        0x40
      ]);
    }
  }
  code.addAll([0x4c, 0, 0x60]);
  result.setAll(0, code);
  result.setAll(0x1ffa, [0, 0xe0, 0, 0xe0, 0, 0xe0]);
  return result;
}

void main() {
  test('headered and headerless images, CRC and hidden file blocks', () {
    expect(FdsImage.parse(disk(sides: 2)).sides.length, 2);
    expect(FdsImage.parse(disk(header: false)).sides.single.length, 65500);
    expect(() => FdsImage.parse(Uint8List(15)), throwsFormatException);
    final bad = disk()..[4] = 2;
    expect(() => FdsImage.parse(bad), throwsFormatException);
    final side = FdsImage.parse(disk()).surfaces().single;
    expect(side[3537], 0x80);
    expect(side[3538], 1);
    var crc = 0;
    for (var i = 3537; i < 3537 + 1 + 56 + 2; i++) {
      crc = FdsImage.crcByte(crc, side[i]);
    }
    expect(crc, 0);
    expect(side.sublist(3538, 3538 + 56),
        FdsImage.parse(disk()).sides.single.sublist(0, 56));
  });

  test('RAM, BIOS protection, timer IRQ sources and master enable', () {
    final mapper = FdsMapper(bios(), [0], [100000])..init();
    var irq = false;
    mapper.holdIrq = (value) => irq = value;
    mapper.write(0x6000, 0x12);
    mapper.write(0xdfff, 0x34);
    expect(mapper.read(0x6000), 0x12);
    expect(mapper.read(0xdfff), 0x34);
    mapper.write(0xe000, 0);
    expect(mapper.read(0xe000), 0x78);
    mapper.writeVram(8191, 0x56);
    expect(mapper.readVram(8191), 0x56);
    mapper.write(0x4020, 3);
    mapper.write(0x4022, 2);
    mapper.handleClock(10);
    expect(irq, isFalse);
    mapper.write(0x4023, 1);
    mapper.write(0x4022, 2);
    mapper.handleClock(13);
    expect(irq, isFalse);
    mapper.handleClock(14);
    expect(irq, isTrue);
    mapper.read(0x4031);
    expect(irq, isTrue);
    expect(mapper.read(0x4030) & 1, 1);
    expect(irq, isFalse);
    mapper.handleClock(100);
    expect(irq, isFalse);
    mapper.write(0x4022, 3);
    mapper.handleClock(108);
    expect(irq, isTrue);
    mapper.read(0x4030);
    mapper.handleClock(112);
    expect(irq, isTrue);
    mapper.write(0x4023, 0);
    expect(irq, isFalse);
  });

  test('byte transfers reconstruct gaps and CRC, side changes expose ejection',
      () {
    final surface = FdsImage.parse(disk(sides: 2)).surfaces();
    final data = Uint8List.fromList(surface.expand((side) => side).toList());
    final mapper = FdsMapper(bios(), [0, surface.first.length],
        surface.map((s) => s.length).toList())
      ..setSramRw((at) => data[at], (at, value) => data[at] = value)
      ..init();
    mapper.write(0x4023, 3);
    mapper.write(0x4025, 0xc5);
    var cycles = 0;
    int nextByte() {
      final limit = cycles + 700000;
      while (cycles < limit) {
        cycles += 3;
        mapper.handleClock(cycles);
        if (mapper.read(0x4030) & 2 != 0) return mapper.read(0x4031);
      }
      throw StateError('Disk transfer timed out');
    }

    final read = [for (var i = 0; i < 56; i++) nextByte()];
    expect(read, FdsImage.parse(disk()).sides.first.sublist(0, 56));
    // The real BIOS enters CRC phase after the first CRC byte arrived.
    nextByte();
    mapper.write(0x4025, 0xd5);
    nextByte();
    expect(mapper.read(0x4030) & 0x10, 0);
    mapper.write(0x4025, 0x85);
    cycles += 200;
    mapper.handleClock(cycles);
    mapper.write(0x4025, 0xc5);
    expect(nextByte(), 2);
    expect(nextByte(), 1);
    mapper.selectSide(1);
    expect(mapper.read(0x4032) & 1, 1);
    cycles += 1789773;
    mapper.handleClock(cycles);
    expect(mapper.read(0x4032) & 1, 0);
    final secondHeader = [for (var i = 0; i < 56; i++) nextByte()];
    expect(
        secondHeader, FdsImage.parse(disk(sides: 2)).sides[1].sublist(0, 56));
    mapper.selectSide(null);
    expect(mapper.read(0x4032) & 5, 5);
    expect(() => mapper.selectSide(2), throwsRangeError);
  });

  test('disk writes persist separately from program RAM', () {
    final sram = Sram();
    final core = Nes(diskSystem: true)
      ..setSram(sram)
      ..setBiosFiles([bios()])
      ..setRom(disk());
    final mapper = core.bus.mapper as FdsMapper;
    final surface = FdsImage.parse(disk()).surfaces().single;
    final payload = surface.indexOf(0xea);
    int clockAt(int index) => 50000 + (index * 448 + 2) ~/ 3;
    mapper.write(0x4023, 1);
    mapper.write(0x4025, 0xc5);
    mapper.handleClock(clockAt(payload - 1));
    mapper.write(0x4025, 0xc1);
    final replacement = [0xea, 0x4c, 1, 0x60];
    for (var i = 0; i < replacement.length; i++) {
      mapper.write(0x4024, replacement[i]);
      mapper.handleClock(clockAt(payload + i));
    }
    mapper.write(0x4025, 0xd1);
    mapper.handleClock(clockAt(payload + replacement.length + 1));
    expect(sram.read8(payload + 2), 1);
    var crc = 0;
    for (var at = payload - 2; at < payload + replacement.length + 2; at++) {
      crc = FdsImage.crcByte(crc, sram.read8(at));
    }
    expect(crc, 0);
    mapper.write(0x6000, 0x77);
    expect(sram.read8(payload + 2), 1);
    final snapshot = Uint8List.fromList(sram.data);
    final restored = _SavedSram(snapshot);
    final reopened = Nes(diskSystem: true)
      ..setSram(restored)
      ..setBiosFiles([bios()])
      ..setRom(disk());
    expect(restored.read8(payload + 2), 1);
    expect(reopened.read(0, 0x6000), 0);
  });

  test(
      'synthetic BIOS boots and reads the first block through CPU instructions',
      () {
    final core = Nes(diskSystem: true)
      ..setBiosFiles([bios()])
      ..setRom(disk());
    expect(core.programCounter(0), 0xe000);
    for (var i = 0; i < 100 && core.programCounter(0) != 0xe01f; i++) {
      expect(core.runFrame(262).stopped, isFalse);
    }
    expect(core.programCounter(0), 0xe01f);
    expect([for (var i = 0; i < 56; i++) core.read(0, 0x6000 + i)],
        FdsImage.parse(disk()).sides.first.sublist(0, 56));
    expect((core.bus.mapper as FdsMapper).sideCount, 1);
  });

  test(
      'synthetic BIOS loads all blocks into PRG RAM and runs the loaded program',
      () {
    final core = Nes(diskSystem: true)
      ..setBiosFiles([loaderBios()])
      ..setRom(disk());
    for (var frame = 0;
        frame < 40 && core.programCounter(0) >= 0xe000;
        frame++) {
      expect(core.runFrame(262).stopped, isFalse);
    }
    expect(core.programCounter(0), inInclusiveRange(0x6000, 0x6003));
    expect([for (var at = 0x6000; at < 0x6004; at++) core.read(0, at)],
        [0xea, 0x4c, 0, 0x60]);
  });

  test('FDS frame execution matches instruction stepping through disk loading',
      () {
    final reference = Nes(diskSystem: true)
      ..setBiosFiles([loaderBios()])
      ..setRom(disk());
    final batched = Nes(diskSystem: true)
      ..setBiosFiles([loaderBios()])
      ..setRom(disk());
    for (var frame = 0; frame < 25; frame++) {
      var lines = 0;
      while (lines < 262) {
        final status = reference.exec(false);
        expect(status.stopped, isFalse);
        if (status.scanlineRendered) lines++;
      }
      expect(batched.runFrame(262).stopped, isFalse);
      expect(batched.programCounter(0), reference.programCounter(0));
      expect(batched.cpu.cycle, reference.cpu.cycle);
      expect(batched.dump(), reference.dump());
      expect(batched.imageBuffer().buffer, reference.imageBuffer().buffer);
    }
  });

  test('Flip Disk occupies R, is edge triggered and bypasses the joypad', () {
    final core = Nes(diskSystem: true)
      ..setBiosFiles([bios()])
      ..setRom(disk(sides: 2));
    final mapper = core.bus.mapper as FdsMapper;
    expect(core.buttons[12], Nes.flipDisk);
    expect(core.buttons.sublist(8, 12), everyElement(PadButton.none));
    core.padDown(0, Nes.flipDisk);
    expect(mapper.selectedSide, 1);
    expect(core.bus.joypad.isPressed.containsKey(Nes.flipDisk), isFalse);
    core.padDown(0, Nes.flipDisk);
    expect(mapper.selectedSide, 1);
    core.padUp(0, Nes.flipDisk);
    core.padDown(0, Nes.flipDisk);
    expect(mapper.selectedSide, 0);
    core.padUp(0, Nes.flipDisk);
    final single = Nes(diskSystem: true)
      ..setBiosFiles([bios()])
      ..setRom(disk());
    single.padDown(0, Nes.flipDisk);
    expect((single.bus.mapper as FdsMapper).selectedSide, 0);
    expect(Nes().buttons, isNot(contains(Nes.flipDisk)));
  });

  test('FDS factory needs BIOS and recognizes extension inside archives', () {
    expect(CoreFactory.systemOfFile('fixture.fds', disk()).id, 'fds');
    expect(CoreFactory.extensions, contains('fds'));
    expect(CoreFactory.system('fds').biosRequired, isTrue);
    expect(
        () => (CoreFactory.of('fds') as Nes).setRom(disk()), throwsStateError);
    expect(() => (CoreFactory.of('fds') as Nes).setBiosFiles([Uint8List(1)]),
        throwsFormatException);
  });

  test('wave write gate, gain registers, envelopes and audible synthesis', () {
    final audio = FdsAudio()..reset();
    audio.write(0x4040, 63);
    expect(audio.read(0x4040), 0);
    audio.write(0x4089, 0x80);
    for (var i = 0; i < 64; i++) {
      audio.write(0x4040 + i, i);
    }
    expect(audio.read(0x407f), 63);
    audio.write(0x4080, 0xa0);
    audio.write(0x4089, 0);
    audio.write(0x4082, 0x80);
    audio.write(0x4083, 0);
    final output = audio.synth(80000);
    expect(output.length, 40000);
    expect(output.any((sample) => sample > 0.01), isTrue);
    expect(output.any((sample) => sample < -0.01), isTrue);
    audio.write(0x408a, 0);
    audio.write(0x4080, 0x80);
    audio.write(0x4080, 0x40);
    audio.synth(16);
    expect(audio.read(0x4090) & 63, 2);
    audio.write(0x4084, 0x9f);
    expect(audio.read(0x4092), 0x5f);
  });
}

class _SavedSram extends Sram {
  final Uint8List saved;
  _SavedSram(this.saved);
  @override
  void init(String id, Uint8List initialData) => super.init(id, saved);
}
