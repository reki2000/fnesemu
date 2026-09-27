import 'dart:typed_data';

/// Cartridge dumps are normalized to the N64's big endian bus order.
class N64Rom {
  final Uint8List bytes;
  final int entryPoint;
  final String title;

  N64Rom._(this.bytes)
      : entryPoint = ByteData.sublistView(bytes).getUint32(8),
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
    final rom = N64Rom._(bytes);
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
