import 'dart:typed_data';

import 'package:fnesemu_core/core_factory.dart';
import 'package:fnesemu_core/src/core/nes/fds/fds_audio.dart';
import 'package:fnesemu_core/src/core/nes/fds/fds_image.dart';
import 'package:fnesemu_core/src/core/nes/fds/fds_mapper.dart';
import 'package:fnesemu_core/src/core/nes/nes.dart';
import 'package:fnesemu_core/src/pad_button.dart';
import 'package:fnesemu_core/src/sram.dart';
import 'package:test/test.dart';
import '../../pad_helper.dart';

Uint8List disk({int sides = 1, bool header = true}) {
  final result = Uint8List((header ? 16 : 0) + 65500 * sides);
  if (header) result.setAll(0, [0x46, 0x44, 0x53, 0x1a, sides]);
  for (var side = 0; side < sides; side++) {
    final at = (header ? 16 : 0) + 65500 * side;
    result[at] = 1;
    result.setAll(at + 1, List.filled(14, 0x2a));
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

  test('Flip Disk occupies R, is edge triggered and bypasses the joypad', () {
    final core = Nes(diskSystem: true)
      ..setBiosFiles([bios()])
      ..setRom(disk(sides: 2));
    final mapper = core.bus.mapper as FdsMapper;
    expect(core.buttons[17], Nes.flipDisk);
    expect(core.buttons.sublist(8, 17), everyElement(PadButton.none));
    // the key is sampled once a frame
    void frame(Nes nes) => nes.runFrame(nes.scanlinesInFrame);
    core.padDown(0, Nes.flipDisk);
    frame(core);
    expect(mapper.selectedSide, 1);
    frame(core);
    expect(mapper.selectedSide, 1);
    core.padUp(0, Nes.flipDisk);
    frame(core);
    core.padDown(0, Nes.flipDisk);
    frame(core);
    expect(mapper.selectedSide, 0);
    core.padUp(0, Nes.flipDisk);
    final single = Nes(diskSystem: true)
      ..setBiosFiles([bios()])
      ..setRom(disk());
    single.padDown(0, Nes.flipDisk);
    frame(single);
    expect((single.bus.mapper as FdsMapper).selectedSide, 0);
    expect(Nes().buttons, isNot(contains(Nes.flipDisk)));
  });

}

class _SavedSram extends Sram {
  final Uint8List saved;
  _SavedSram(this.saved);
  @override
  void init(String id, Uint8List initialData) => super.init(id, saved);
}
