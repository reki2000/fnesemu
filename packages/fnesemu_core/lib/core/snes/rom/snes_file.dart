import 'dart:developer';
import 'dart:typed_data';

import '../../../util/crc32.dart';
import '../../../util/int.dart';

enum SnesMapping { loRom, hiRom }

/// parses a .sfc/.smc image: strips the optional 512-byte copier header and
/// detects LoROM / HiROM by scoring the internal header at $7FC0 / $FFC0.
class SnesFile {
  late Uint8List rom;
  late SnesMapping mapping;
  late final String title;
  late final String crc;

  int sramSize = 0; // bytes

  /// the cartridge's expansion ram (bytes) from the extended header, which
  /// a header with the maker code $33 has just before it
  int expansionRamSize = 0;
  bool hasBattery = false;
  bool fastRom = false;
  int romType = 0; // $FFD6: chips on the cartridge
  int _base = 0x7fc0; // the header

  /// S-DD1 (graphics decompression and 1MB rom banks)
  bool get hasSdd1 => romType == 0x43 || romType == 0x45;

  /// SA-1 (a second cpu, shared I-RAM and BW-RAM)
  bool get hasSa1 => romType >= 0x33 && romType <= 0x36;

  /// DSP-1 (a math coprocessor for 3D and Mode 7 projection)
  bool get hasDsp1 => romType >= 0x03 && romType <= 0x05;

  /// Cx4 (a risc cpu for sprites and wireframes)
  bool get hasCx4 => romType == 0xf3 && _at(_base - 1) == 0x10;

  /// SPC7110 (graphics decompression, with a real time clock in one game)
  bool get hasSpc7110 =>
      (romType == 0xf5 || romType == 0xf9) && _at(_base - 1) == 0x00;

  /// Super FX (a risc cpu drawing into its own ram)
  bool get hasSuperFx => romType >= 0x13 && romType <= 0x1a;

  void load(Uint8List body) {
    // strip 512-byte copier header if present
    final hasCopier = body.length.mask10 == 0x200;
    rom = hasCopier ? Uint8List.sublistView(body, 0x200) : body;

    crc = crc32Hex(rom);

    final scoreLo = _score(0x7fc0);
    final scoreHi = _score(0xffc0);
    mapping = scoreHi > scoreLo ? SnesMapping.hiRom : SnesMapping.loRom;

    // a copier's interleaved HiROM image: the header at $7FC0 says HiROM
    if (mapping == SnesMapping.loRom &&
        _at(0x7fc0 + 0x15) & 0xef == 0x21 &&
        rom.length % 0x10000 == 0) {
      rom = _deinterleave(rom);
      mapping = SnesMapping.hiRom;
    }

    final base = _base = mapping == SnesMapping.hiRom ? 0xffc0 : 0x7fc0;
    title = _ascii(base, 21);

    final mapByte = _at(base + 0x15);
    fastRom = mapByte.bit4;

    romType = _at(base + 0x16);
    // the low nibble: 2 = rom+ram+battery, 5/6 = rom+chip+ram+battery,
    // 9 = rom+chip+ram+battery+clock
    hasBattery = const [2, 5, 6, 9].contains(romType.mask4);

    final expansion = _at(base - 3);
    if (_at(base + 0x1a) == 0x33 && expansion > 0 && expansion <= 8) {
      expansionRamSize = 0x400 << expansion;
    }

    final ramByte = _at(base + 0x18);
    sramSize = ramByte == 0 ? 0 : (0x400 << ramByte);

    log("snes rom len:${rom.length} "
        "map:${mapping.name} title:'$title' "
        "type:${romType.x2} sram:${sramSize}B fastRom:$fastRom crc:$crc");
  }

  // the image holds the odd 32KB blocks first, then the even ones
  static Uint8List _deinterleave(Uint8List image) {
    final blocks = image.length ~/ 0x8000;
    final half = blocks ~/ 2;
    final out = Uint8List(image.length);
    for (var i = 0; i < half; i++) {
      out.setRange((2 * i + 1) * 0x8000, (2 * i + 2) * 0x8000, image,
          i * 0x8000);
      out.setRange(2 * i * 0x8000, (2 * i + 1) * 0x8000, image,
          (half + i) * 0x8000);
    }
    return out;
  }

  int _at(int i) => i < rom.length ? rom[i] : 0;

  String _ascii(int offset, int len) {
    final b = StringBuffer();
    for (int i = 0; i < len; i++) {
      final c = _at(offset + i);
      b.writeCharCode(c >= 0x20 && c < 0x7f ? c : 0x20);
    }
    return b.toString().trim();
  }

  /// heuristic: title printable + reset vector points to bank ROM + checksum
  /// complement consistency. higher is more likely.
  int _score(int base) {
    if (base + 0x20 > rom.length) return -1;
    var score = 0;

    // printable title
    for (int i = 0; i < 21; i++) {
      final c = _at(base + i);
      if (c >= 0x20 && c < 0x7f) score++;
    }

    // checksum + complement should be 0xffff
    final checksum = _at(base + 0x1e) | _at(base + 0x1f).shl8;
    final complement = _at(base + 0x1c) | _at(base + 0x1d).shl8;
    if ((checksum ^ complement) == 0xffff) score += 8;

    // reset vector ($base+0x3c) in $8000..$ffff
    final reset = _at(base + 0x3c) | _at(base + 0x3d).shl8;
    if (reset >= 0x8000) score += 4;

    return score;
  }
}
