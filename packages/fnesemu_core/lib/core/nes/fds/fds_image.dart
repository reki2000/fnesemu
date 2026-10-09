import 'dart:typed_data';

/// fwNES .fds images omit physical gaps, sync marks and CRCs.
class FdsImage {
  static const sideBytes = 65500;
  final List<Uint8List> sides;
  FdsImage._(this.sides);

  factory FdsImage.parse(Uint8List bytes) {
    final header = bytes.length >= 16 &&
        bytes[0] == 0x46 &&
        bytes[1] == 0x44 &&
        bytes[2] == 0x53 &&
        bytes[3] == 0x1a;
    final offset = header ? 16 : 0;
    final length = bytes.length - offset;
    if (length <= 0 ||
        length % sideBytes != 0 ||
        (header && bytes[4] != length ~/ sideBytes)) {
      throw const FormatException('Invalid FDS side count or disk size');
    }
    return FdsImage._([
      for (var at = offset; at < bytes.length; at += sideBytes)
        Uint8List.fromList(bytes.sublist(at, at + sideBytes))
    ]);
  }

  static int crcByte(int crc, int value) {
    crc ^= value;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0x8408 : 0);
    }
    return crc;
  }

  /// Writable physical surfaces are persisted, including newly written blocks.
  List<Uint8List> surfaces() => sides.map((side) {
        final out = <int>[...List.filled(3537, 0)];
        var position = 0, fileLength = 0;
        while (position < side.length && side[position] != 0) {
          final type = side[position];
          final length = switch (type) {
            1 => 56,
            2 => 2,
            3 => 16,
            4 => fileLength + 1,
            5 => side.length - position,
            _ => throw FormatException('Unsupported FDS block type: $type'),
          };
          if (position + length > side.length) {
            throw const FormatException('Truncated FDS block');
          }
          if (type == 3) {
            fileLength = side[position + 13] | side[position + 14] << 8;
          }
          if (position != 0) out.addAll(List.filled(122, 0));
          out.add(0x80);
          var crc = crcByte(0, 0x80);
          for (var i = 0; i < length; i++) {
            final value = side[position + i];
            out.add(value);
            crc = crcByte(crc, value);
          }
          out.addAll([crc & 0xff, crc >> 8]);
          position += length;
        }
        // About eight seconds per revolution at 149 1/3 CPU clocks per byte.
        if (out.length < 100000) {
          out.addAll(List.filled(100000 - out.length, 0));
        }
        return Uint8List.fromList(out);
      }).toList();
}
