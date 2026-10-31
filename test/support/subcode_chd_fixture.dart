import 'dart:typed_data';

/// Original uncompressed four-frame CHD with configurable raw Q symbols.
/// CRC 9033 is the inverted CRC-16 of the first ten bytes, initial value zero.
Uint8List subcodeChd(
    {String subtype = 'RW_RAW', bool pHigh = false, List<int>? qRecord}) {
  const hunkBytes = 4 * 2448, metadata = 128;
  final bytes = Uint8List(hunkBytes * 2);
  final view = ByteData.sublistView(bytes);
  bytes.setAll(0, 'MComprHD'.codeUnits);
  view.setUint32(8, 124);
  view.setUint32(12, 5);
  view.setUint32(36, hunkBytes);
  view.setUint32(44, 124);
  view.setUint32(52, metadata);
  view.setUint32(56, hunkBytes);
  view.setUint32(60, 2448);
  view.setUint32(124, 1);
  final text =
      'TRACK:1 TYPE:MODE1_RAW SUBTYPE:$subtype FRAMES:4 PREGAP:0 PGTYPE:MODE1 PGSUB:NONE POSTGAP:0\u0000';
  bytes.setAll(metadata, 'CHT2'.codeUnits);
  view.setUint32(metadata + 4, text.length);
  bytes.setAll(metadata + 16, text.codeUnits);
  final q = qRecord ??
      const [0x61, 1, 3, 0, 0x12, 0x34, 0, 1, 0x23, 0x45, 0x90, 0x33];
  for (var frame = 0; frame < 4; frame++) {
    final offset = hunkBytes + frame * 2448;
    bytes.fillRange(offset, offset + 2352, frame + 5);
    for (var bit = 0; bit < 96; bit++) {
      bytes[offset + 2352 + bit] =
          (pHigh ? 0x80 : 0) | (((q[bit ~/ 8] >> (7 - bit % 8)) & 1) << 6);
    }
  }
  return bytes;
}

/// Guest-only SH-4 diagnostic: clear attention and copy a subchannel response.
Uint8List subcodeGuestProgram({int format = 1, int responseBytes = 14}) {
  final ops = <int>[];
  const literalOffset = 0x300, packetOffset = 0x400;
  const addresses = [
    0xa05f709c,
    0xa05f7080,
    0xa05f7018,
    0x8c010400,
    0x8c020000,
    0xa05f7090,
    0xa05f7094,
    0x8c020100
  ];
  for (var register = 1; register <= addresses.length; register++) {
    final pcBase = (ops.length * 2 + 4) & ~3;
    final literal = literalOffset + (register - 1) * 4;
    ops.add(0xd000 | (register << 8) | ((literal - pcBase) ~/ 4));
  }
  void waitBusy() => ops.addAll([0x6030, 0xc880, 0x8bfc]);
  for (var command = 0; command < 2; command++) {
    ops.addAll([0xe064, 0x2600, 0xe000, 0x2700]);
    ops.addAll([0xe0a0, 0x2100]);
    waitBusy();
    for (var word = 0; word < 6; word++) {
      ops.addAll([0x6045, 0x2201]);
    }
    waitBusy();
    for (var word = 0; word < (command == 0 ? 5 : responseBytes ~/ 2); word++) {
      ops.add(0x6021);
      if (command == 1) ops.addAll([0x2501, 0x7502]);
    }
  }
  ops.addAll([0xe001, 0x2800, 0xaffe, 0x0009]);
  final bytes = Uint8List(packetOffset + 24),
      view = ByteData(packetOffset + 24);
  for (var i = 0; i < ops.length; i++) {
    view.setUint16(i * 2, ops[i], Endian.little);
  }
  for (var i = 0; i < addresses.length; i++) {
    view.setUint32(literalOffset + i * 4, addresses[i], Endian.little);
  }
  bytes.setAll(0, view.buffer.asUint8List());
  bytes.setAll(packetOffset, [
    0x13,
    0,
    0,
    0,
    10,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0x40,
    format,
    0,
    responseBytes >> 8,
    responseBytes & 255,
    0,
    0,
    0,
    0,
    0,
    0,
    0
  ]);
  return bytes;
}
