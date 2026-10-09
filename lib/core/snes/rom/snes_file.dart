import 'package:fnesemu/util/int.dart';
// Dart imports:
import 'dart:developer';
import 'dart:typed_data';

// Project imports:
import 'package:archive/archive_io.dart';

enum SnesMapping { loRom, hiRom }

/// parses a .sfc/.smc image: strips the optional 512-byte copier header and
/// detects LoROM / HiROM by scoring the internal header at $7FC0 / $FFC0.
class SnesFile {
  late final Uint8List rom;
  late final SnesMapping mapping;
  late final String title;
  late final String crc;

  int sramSize = 0; // bytes
  bool hasBattery = false;
  bool fastRom = false;
  int romType = 0; // $FFD6: chips on the cartridge

  /// S-DD1 (graphics decompression and 1MB rom banks)
  bool get hasSdd1 => romType == 0x43 || romType == 0x45;

  /// SA-1 (a second cpu, shared I-RAM and BW-RAM)
  bool get hasSa1 => romType >= 0x33 && romType <= 0x36;

  void load(Uint8List body) {
    // strip 512-byte copier header if present
    final hasCopier = body.length.mask10 == 0x200;
    rom = hasCopier ? Uint8List.sublistView(body, 0x200) : body;

    crc = (Crc32()..add(rom.toList())).close().map((v) => v.x2).join();

    final scoreLo = _score(0x7fc0);
    final scoreHi = _score(0xffc0);
    mapping = scoreHi > scoreLo ? SnesMapping.hiRom : SnesMapping.loRom;

    final base = mapping == SnesMapping.hiRom ? 0xffc0 : 0x7fc0;
    title = _ascii(base, 21);

    final mapByte = _at(base + 0x15);
    fastRom = mapByte.bit4;

    romType = _at(base + 0x16);
    // the low nibble: 2 = rom+ram+battery, 5/6 = rom+chip+ram+battery
    hasBattery = const [2, 5, 6].contains(romType & 0xf);

    final ramByte = _at(base + 0x18);
    sramSize = ramByte == 0 ? 0 : (0x400 << ramByte);

    log("snes rom len:${rom.length} "
        "map:${mapping.name} title:'$title' "
        "type:${romType.x2} sram:${sramSize}B fastRom:$fastRom crc:$crc");
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
