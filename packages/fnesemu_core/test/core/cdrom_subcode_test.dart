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

  test('P and R-W symbols do not affect Q decoding and raw input is copied',
      () {
    final raw = packedSubcode(position, otherChannels: 0xbf);
    final result = CdromSubcode.fromRaw(raw);
    expect(result.position!.track, 23);
    expect(result.raw, raw);
    final saved = result.raw![0];
    raw[0] ^= 255;
    expect(result.raw![0], saved);
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

  test('CRC inversion rejects a zero-filled blank and uninverted parity', () {
    expect(CdromSubcode.fromRaw(Uint8List(96)).position, isNull);
    final raw = packedSubcode(position);
    for (var bit = 80; bit < 96; bit++) {
      raw[bit] ^= 0x40;
    }
    expect(CdromSubcode.fromRaw(raw).position, isNull);
  });

  test('CRC-valid malformed BCD, time bounds and reserved zero are rejected',
      () {
    for (final (offset, value) in [
      (1, 0x9a),
      (2, 0xa0),
      (3, 0x1a),
      (4, 0x60),
      (5, 0x75),
      (6, 1),
      (7, 0xa1),
      (8, 0x60),
      (9, 0x75),
    ]) {
      final payload = [...position]..[offset] = value;
      expect(CdromSubcode.fromRaw(packedSubcode(payload)).position, isNull);
    }
  });

  test('lead-out AA and index-zero pause preserve their encoded relative time',
      () {
    final leadOut = [...position]..[1] = 0xaa;
    expect(CdromSubcode.fromRaw(packedSubcode(leadOut)).position!.track, 0xaa);
    final pause = [...position]..[2] = 0;
    final decoded = CdromSubcode.fromRaw(packedSubcode(pause)).position!;
    expect(decoded.index, 0);
    expect(decoded.trackFrames, (12 * 60 + 34) * 75 + 56);
  });

  test('lead-in TOC and unsupported ADR are retained only as raw symbols', () {
    for (final payload in [
      [...position]..[1] = 0,
      [...position]..[0] = 0xe4,
      [...position]..[0] = 0xef,
    ]) {
      final raw = packedSubcode(payload);
      final decoded = CdromSubcode.fromRaw(raw);
      expect(decoded.raw, raw);
      expect(decoded.position, isNull);
      expect(decoded.catalog, isNull);
      expect(decoded.recording, isNull);
    }
  });

  group('ADR=3 recording identifiers', () {
    test('six-bit alphanumeric cells and BCD digits become an ISRC', () {
      final raw = packedSubcode(isrcPayload('US1AZ9912345', frame: 74));
      final decoded = CdromSubcode.fromRaw(raw);
      expect(decoded.recording!.value, 'US1AZ9912345');
      expect(decoded.recording!.frame, 74);
      expect(decoded.raw, raw);
      expect(decoded.position, isNull);
      expect(decoded.catalog, isNull);
    });

    test('all registrant letters and digits use their published six-bit codes',
        () {
      for (final character
          in '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('')) {
        final value = 'JP${character}Z09999999';
        expect(
            CdromSubcode.fromRaw(packedSubcode(isrcPayload(value)))
                .recording!
                .value,
            value);
      }
    });

    test('all-zero CD-R ISRC explicitly reports not detected', () {
      final decoded =
          CdromSubcode.fromRaw(packedSubcode(isrcPayload('', frame: 13)));
      expect(decoded.recording!.value, '');
      expect(decoded.recording!.frame, 13);
    });

    test('recorder, TBD and unused selector records do not become ISRC', () {
      for (final selector in [1, 2, 3]) {
        final raw =
            packedSubcode(isrcPayload('US1AZ9912345', selector: selector));
        final decoded = CdromSubcode.fromRaw(raw);
        expect(decoded.recording, isNull);
        expect(decoded.raw, raw);
      }
    });

    test('invalid six-bit characters and numeric country prefixes reject', () {
      for (var value = 0; value < 64; value++) {
        if (value >= 0x11 && value <= 0x2a) continue;
        final payload = isrcPayload('US1AZ9912345');
        payload[1] = (payload[1] & 3) | (value << 2);
        expect(CdromSubcode.fromRaw(packedSubcode(payload)).recording, isNull);
      }
      for (var value = 10; value < 64; value++) {
        if (value >= 0x11 && value <= 0x2a) continue;
        final payload = isrcPayload('US1AZ9912345');
        // I4 occupies the low six bits of the third data byte.
        payload[3] = (payload[3] & 0xc0) | value;
        expect(CdromSubcode.fromRaw(packedSubcode(payload)).recording, isNull);
      }
    });

    test('invalid BCD digits, reserved nibble and absolute frame reject', () {
      for (var digit = 0; digit < 7; digit++) {
        final payload = isrcPayload('US1AZ9912345');
        final byte = 5 + digit ~/ 2, shift = digit.isEven ? 4 : 0;
        payload[byte] = (payload[byte] & ~(15 << shift)) | (10 << shift);
        expect(CdromSubcode.fromRaw(packedSubcode(payload)).recording, isNull);
      }
      for (final (offset, value) in [(8, 1), (9, 0x75), (9, 0xfa)]) {
        final payload = isrcPayload('US1AZ9912345')..[offset] |= value;
        expect(CdromSubcode.fromRaw(packedSubcode(payload)).recording, isNull);
      }
    });

    test('each Q bit is covered by CRC before an ISRC can be returned', () {
      final raw = packedSubcode(isrcPayload('US1AZ9912345'));
      for (var bit = 0; bit < 96; bit++) {
        final damaged = Uint8List.fromList(raw)..[bit] ^= 0x40;
        expect(CdromSubcode.fromRaw(damaged).recording, isNull);
      }
    });

    test('random complete identifiers survive independent bit-string packing',
        () {
      const letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
          alphanumeric = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
      final random = Random(0x60908);
      for (var trial = 0; trial < 1024; trial++) {
        final value = List.generate(
            12,
            (index) => index < 2
                ? letters[random.nextInt(26)]
                : index < 5
                    ? alphanumeric[random.nextInt(36)]
                    : '${random.nextInt(10)}').join();
        final frame = random.nextInt(75);
        final decoded = CdromSubcode.fromRaw(
            packedSubcode(isrcPayload(value, frame: frame)));
        expect(decoded.recording!.value, value);
        expect(decoded.recording!.frame, frame);
      }
    });
  });

  test('ADR=2 decodes thirteen catalog digits and its own BCD frame', () {
    final payload = [0x42, 0x12, 0x34, 0x56, 0x78, 0x90, 0x12, 0x30, 0, 0x74];
    final decoded = CdromSubcode.fromRaw(packedSubcode(payload));
    expect(decoded.catalog!.value, '1234567890123');
    expect(decoded.catalog!.frame, 74);
    expect(decoded.position, isNull);
    final absent = [0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    expect(CdromSubcode.fromRaw(packedSubcode(absent)).catalog!.value,
        '0000000000000');
  });

  test('catalog invalid digits, twelve reserved bits and frame bounds reject',
      () {
    const payload = [0x02, 0x12, 0x34, 0x56, 0x78, 0x90, 0x12, 0x30, 0, 0x74];
    for (final (offset, value) in [
      (1, 0xa2),
      (7, 0xf0),
      (7, 0x31),
      (8, 1),
      (9, 0x75),
      (9, 0xfa),
    ]) {
      final damaged = [...payload]..[offset] = value;
      expect(CdromSubcode.fromRaw(packedSubcode(damaged)).catalog, isNull);
    }
  });

  test('random positions agree with independent polynomial CRC encoding', () {
    final random = Random(0x130);
    int bcd(int value) => (value ~/ 10) * 16 + value % 10;
    for (var trial = 0; trial < 1024; trial++) {
      final track = random.nextInt(99) + 1, index = random.nextInt(100);
      final fields = [
        random.nextInt(100),
        random.nextInt(60),
        random.nextInt(75),
        random.nextInt(100),
        random.nextInt(60),
        random.nextInt(75)
      ];
      final payload = [
        (random.nextInt(16) << 4) | 1,
        bcd(track),
        bcd(index),
        ...fields.take(3).map(bcd),
        0,
        ...fields.skip(3).map(bcd)
      ];
      final q = CdromSubcode.fromRaw(packedSubcode(payload)).position!;
      expect(q.track, track);
      expect(q.index, index);
      expect(q.trackFrames, (fields[0] * 60 + fields[1]) * 75 + fields[2]);
      expect(q.discFrames, (fields[3] * 60 + fields[4]) * 75 + fields[5]);
    }
  });

  test('symbol counts exclude the two synchronization symbols', () {
    for (final length in [0, 12, 95, 97, 98]) {
      expect(
          () => CdromSubcode.fromRaw(Uint8List(length)), throwsArgumentError);
    }
  });
}
