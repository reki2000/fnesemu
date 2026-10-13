import 'dart:typed_data';
import '../../../util/int.dart';

/// Extracts the BIOS mapped at CPU $E000-$FFFF from a raw or iNES image.
Uint8List decodeFdsBios(Uint8List image) {
  const biosSize = 0x2000;
  if (image.length == biosSize) return Uint8List.fromList(image);
  if (image.length < 16 ||
      image[0] != 0x4e ||
      image[1] != 0x45 ||
      image[2] != 0x53 ||
      image[3] != 0x1a) {
    throw const FormatException('FDS BIOS must be 8 KiB or an iNES image');
  }
  final offset = 16 + (image[6].bit2 ? 512 : 0);
  final nes20 = image[7] & 0x0c == 8;
  int romSize(int low, int high, int unit) => high == 15
      ? (1 << low.shr2) * (low.mask2 * 2 + 1)
      : (low | high.shl8) * unit;
  var prgSize = romSize(image[4], nes20 ? image[9].mask4 : 0, 0x4000);
  final chrSize = romSize(image[5], nes20 ? image[9].shr4 : 0, 0x2000);
  // Some BIOS dumps retain a 16-byte header but only store the 8 KiB BIOS.
  if (image.length - offset == biosSize && chrSize == 0) prgSize = biosSize;
  if (prgSize < biosSize || offset + prgSize + chrSize > image.length) {
    throw const FormatException('Truncated or invalid iNES FDS BIOS image');
  }
  // PRG precedes CHR. The last PRG bank supplies the vectors and FDS BIOS.
  return Uint8List.fromList(
      image.sublist(offset + prgSize - biosSize, offset + prgSize));
}
