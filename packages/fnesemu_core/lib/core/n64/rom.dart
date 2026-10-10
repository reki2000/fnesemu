import 'dart:typed_data';
import '../../util/int.dart';

/// Cartridge dumps are normalized to the N64's big endian bus order.
class N64Rom {
  final Uint8List bytes;
  final int entryPoint;
  final String title;

  /// CRC32 of the IPL3 boot code (0x40-0xfff) identifies the CIC chip
  final int ipl3Crc;

  /// seed that the IPL3 leaves in the registers / osCicId area
  int get cicSeed => switch (ipl3Crc) {
        0x0b050ee0 => 0x78, // CIC-6103
        0x98bc2c86 => 0x91, // CIC-6105
        0xacc8580a => 0x85, // CIC-6106
        _ => 0x3f, // CIC-6101 / 6102
      };

  static int _crc32(Uint8List data, int start, int end) {
    var crc = 0xffffffff;
    for (var i = start; i < end; i++) {
      crc ^= data[i];
      for (var k = 0; k < 8; k++) {
        crc = crc.bit0 ? (crc >>> 1) ^ 0xedb88320 : crc >>> 1;
      }
    }
    return (~crc).mask32;
  }

  N64Rom._(this.bytes, int crc)
      : ipl3Crc = crc,
        // the entry point in the header is scrambled for CIC-6103 / 6106
        entryPoint = (ByteData.sublistView(bytes).getUint32(8) -
                switch (crc) {
                  0x0b050ee0 => 0x100000,
                  0xacc8580a => 0x200000,
                  _ => 0,
                }).mask32,
        title = String.fromCharCodes(bytes.sublist(0x20, 0x34))
            .replaceAll('\x00', '')
            .trim();

  factory N64Rom(Uint8List input) {
    if (input.length < 0x1004 || input.length % 4 != 0) {
      throw const FormatException(
        'N64 ROM must include a header and program, aligned to 4 bytes',
      );
    }
    final magic = ByteData.sublistView(input).getUint32(0);
    final bytes = Uint8List.fromList(input);
    switch (magic) {
      case 0x80371240: // .z64
        break;
      case 0x37804012: // .v64
        for (var i = 0; i < bytes.length; i += 2) {
          bytes[i] = input[i + 1];
          bytes[i + 1] = input[i];
        }
      case 0x40123780: // .n64
        for (var i = 0; i < bytes.length; i += 4) {
          for (var j = 0; j < 4; j++) {
            bytes[i + j] = input[i + 3 - j];
          }
        }
      default:
        throw const FormatException(
          'Invalid N64 cartridge byte order signature',
        );
    }
    final rom = N64Rom._(bytes, _crc32(bytes, 0x40, 0x1000));
    final physical = rom.entryPoint & 0x1fffffff;
    if (rom.entryPoint < 0x80000000 ||
        rom.entryPoint >= 0xc0000000 ||
        physical >= 0x800000 ||
        physical % 4 != 0) {
      throw const FormatException(
        'N64 direct boot requires an aligned RDRAM entry point in KSEG0/KSEG1',
      );
    }
    return rom;
  }
}
