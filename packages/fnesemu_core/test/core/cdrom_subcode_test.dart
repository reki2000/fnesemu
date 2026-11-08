import 'dart:math';
import 'dart:typed_data';

import 'package:fnesemu_core/src/cdrom_drive.dart';
import 'package:test/test.dart';

import '../support/subcode_fixture.dart';

void main() {
  const position = [0xe1, 0x23, 0x12, 0x12, 0x34, 0x56, 0, 0x67, 0x45, 0x23];

  test('packed Q symbols decode BCD times and preserve control and index', () {
    final result = CdromSubcode.fromRaw(packedSubcode(position));
    final q = result.position!;
    expect(q.control, 14);
    expect(q.track, 23);
    expect(q.index, 12);
    expect(q.trackFrames, (12 * 60 + 34) * 75 + 56);
    expect(q.discFrames, (67 * 60 + 45) * 75 + 23);
    expect(result.catalog, isNull);
    expect(result.recording, isNull);
  });

  test('every single-bit Q error is rejected, including all sixteen CRC bits',
      () {
    final raw = packedSubcode(position);
    for (var bit = 0; bit < 96; bit++) {
      final damaged = Uint8List.fromList(raw)..[bit] ^= 0x40;
      final result = CdromSubcode.fromRaw(damaged);
      expect(result.position, isNull, reason: 'Q bit $bit');
      expect(result.catalog, isNull);
      expect(result.raw, damaged);
    }
  });

  group('ADR=3 recording identifiers', () {

  });

}
