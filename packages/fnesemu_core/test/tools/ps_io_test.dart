// Exercises file-backed memory cards and snapshots.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps/memory_card.dart';
import 'package:fnesemu_core/src/core/ps/ps.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import '../../tool/ps_io.dart';

int readCardByte(MemoryCard card, int sector) {
  card.reset();
  for (final byte in [
    0x81,
    0x52,
    0,
    0,
    sector >> 8,
    sector & 255,
    0,
    0,
    0,
    0
  ]) {
    card.notify(byte);
  }
  return card.notify(0).rxData;
}

void main() {
  test('PS accepts memory card contents without doing file I/O', () {
    final bytes = Uint8List.fromList(MemoryCard.blankImage)..[128] = 0x76;
    final core = Ps(memoryCard2Image: bytes);
    addTearDown(core.dispose);
    expect(readCardByte(core.memoryCard2, 1), 0x76);
    bytes[128] = 0x89;
    expect(readCardByte(core.memoryCard2, 1), 0x89);
  });

}
