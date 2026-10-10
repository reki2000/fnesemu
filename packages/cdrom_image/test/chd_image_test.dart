import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cdrom_image/cdrom_image.dart';
import 'package:cdrom_image/format/chd/cd_ecc.dart';
import 'package:cdrom_image/memory.dart';
import 'package:test/test.dart';

import 'chd_fixture.dart';

const frameBytes = 2448;

/// an uncompressed CHD (version 5) of [tracks]: (metadata text, frames of
/// 2448 bytes). the frames of each track are padded to a multiple of 4.
Uint8List uncompressedChd(List<(String, List<Uint8List>)> tracks,
    {int framesPerHunk = 4}) {
  final hunkBytes = framesPerHunk * frameBytes;
  final frames = <Uint8List>[];
  for (final (_, data) in tracks) {
    frames.addAll(data);
    while (frames.length % 4 != 0) {
      frames.add(Uint8List(frameBytes));
    }
  }
  final hunks = (frames.length + framesPerHunk - 1) ~/ framesPerHunk;

  final out = BytesBuilder();
  void u32(int v) =>
      out.add([v >> 24, v >> 16, v >> 8, v].map((b) => b & 0xff).toList());
  void u64(int v) {
    u32(v >> 32);
    u32(v & 0xffffffff);
  }

  // the header, the map, the metadata, then the hunks
  const headerBytes = 124;
  final mapOffset = headerBytes;
  final metaOffset = mapOffset + hunks * 4;
  final meta = BytesBuilder();
  for (int i = 0; i < tracks.length; i++) {
    final text = Uint8List.fromList([...tracks[i].$1.codeUnits, 0]);
    final next =
        i + 1 < tracks.length ? metaOffset + meta.length + 16 + text.length : 0;
    meta.add('CHT2'.codeUnits);
    meta.add(
        [0, text.length >> 16, text.length >> 8 & 0xff, text.length & 0xff]);
    meta.add([
      for (int b = 7; b >= 0; b--) (next >> (b * 8)) & 0xff,
    ]);
    meta.add(text);
  }
  var dataOffset = metaOffset + meta.length;
  dataOffset = (dataOffset + hunkBytes - 1) ~/ hunkBytes * hunkBytes;

  out.add('MComprHD'.codeUnits);
  u32(headerBytes);
  u32(5);
  for (int i = 0; i < 4; i++) {
    u32(0); // uncompressed
  }
  u64(frames.length * frameBytes);
  u64(mapOffset);
  u64(metaOffset);
  u32(hunkBytes);
  u32(frameBytes);
  out.add(Uint8List(60)); // sha1s, no parent
  for (int h = 0; h < hunks; h++) {
    u32(dataOffset ~/ hunkBytes + h);
  }
  out.add(meta.toBytes());
  out.add(Uint8List(dataOffset - out.length));
  for (final f in frames) {
    out.add(f);
  }
  while (out.length < dataOffset + hunks * hunkBytes) {
    out.addByte(0);
  }
  return out.toBytes();
}

Uint8List frame(int fill, {int size = 2352}) =>
    Uint8List(frameBytes)..fillRange(0, size, fill);

Future<DiscImage> open(Uint8List chd) async {
  final file = MemoryDiscFile('disc.chd', chd);
  final (image, refs) = await DiscImage.parse([file], file);
  expect(refs, isEmpty);
  return image;
}

void main() {
  chdmanFixture();

  test('.chd files are disc images', () {
    expect(DiscFileKind.of('Game.CHD'), DiscFileKind.image);
  });

  test('tracks, pregaps and the 4 frame padding', () async {
    final image = await open(uncompressedChd([
      (
        'TRACK:1 TYPE:MODE1_RAW SUBTYPE:NONE FRAMES:5 PREGAP:0 PGTYPE:MODE1 '
            'PGSUB:NONE POSTGAP:0',
        [for (int i = 0; i < 5; i++) frame(i + 1)]
      ),
      (
        // a pregap of 2 frames stored before the track
        'TRACK:2 TYPE:AUDIO SUBTYPE:NONE FRAMES:6 PREGAP:2 PGTYPE:VAUDIO '
            'PGSUB:NONE POSTGAP:0',
        [for (int i = 0; i < 6; i++) frame(0x10 + i)]
      ),
      (
        // a pregap of 3 frames not stored: silence
        'TRACK:3 TYPE:MODE1_RAW SUBTYPE:NONE FRAMES:2 PREGAP:3 PGTYPE:MODE1 '
            'PGSUB:NONE POSTGAP:0',
        [frame(0x20), frame(0x21)]
      ),
    ]));
    expect(
        [for (final t in image.toc.tracks) (t.number, t.isAudio, t.startLba)],
        [(1, false, 0), (2, true, 7), (3, false, 14)]);
    expect([for (final t in image.toc.tracks) t.sectors], [7, 7, 2]);
    expect(image.totalSectors, 16);

    final sectors = await image.readSectors(0, 16);
    expect([
      for (final s in sectors) s[100]
    ], [
      1,
      2,
      3,
      4,
      5,
      0x10,
      0x11,
      0x12,
      0x13,
      0x14,
      0x15,
      0,
      0,
      0,
      0x20,
      0x21
    ]);
  });

  test('audio is byte swapped from big-endian', () async {
    final data = frame(0);
    for (int i = 0; i < 2352; i += 2) {
      data[i] = 0x12;
      data[i + 1] = 0x34;
    }
    final image = await open(uncompressedChd([
      (
        'TRACK:1 TYPE:AUDIO SUBTYPE:NONE FRAMES:1 PREGAP:0 PGTYPE:AUDIO '
            'PGSUB:NONE POSTGAP:0',
        [data]
      ),
    ]));
    final s = (await image.readSectors(0, 1)).single;
    expect(s.sublist(0, 4), [0x34, 0x12, 0x34, 0x12]);
  });

  test('a MODE1 (2048 bytes) track is given as raw sectors', () async {
    final image = await open(uncompressedChd([
      (
        'TRACK:1 TYPE:MODE1 SUBTYPE:NONE FRAMES:3 PREGAP:0 PGTYPE:MODE1 '
            'PGSUB:NONE POSTGAP:0',
        [for (int i = 0; i < 3; i++) frame(i + 1, size: 2048)]
      ),
    ]));
    final s = (await image.readSectors(2, 1)).single;
    expect(s.length, 2352);
    expect(s.sublist(0, 16),
        [0, ...List.filled(10, 0xff), 0, 0, 0x02, 0x02, 1]); // 00:02:02 mode 1
    expect(s[16], 3);
  });

  test('hunks across tracks and reading many sectors', () async {
    final image = await open(uncompressedChd([
      (
        'TRACK:1 TYPE:MODE1_RAW SUBTYPE:NONE FRAMES:30 PREGAP:0 PGTYPE:MODE1 '
            'PGSUB:NONE POSTGAP:0',
        [for (int i = 0; i < 30; i++) frame(i)]
      ),
    ], framesPerHunk: 8));
    final sectors = await image.readSectors(3, 25);
    expect(
        [for (final s in sectors) s[2000]], [for (int i = 3; i < 28; i++) i]);
  });

  test('not a CHD, or not version 5', () async {
    final file = MemoryDiscFile('bad.chd', Uint8List(200));
    expect(DiscImage.parse([file], file), throwsA(isA<DiscParseException>()));
    final v4 = uncompressedChd([
      ('TRACK:1 TYPE:MODE1_RAW SUBTYPE:NONE FRAMES:1', [frame(1)])
    ]);
    v4[15] = 4;
    final f4 = MemoryDiscFile('v4.chd', v4);
    expect(DiscImage.parse([f4], f4), throwsA(isA<DiscParseException>()));
  });

  for (final mode in [1, 2]) {
    test(
        'the regenerated ECC of mode $mode satisfies the parity check equations',
        () {
      final random = Random(7);
      final sector = Uint8List(2352);
      for (int i = 12; i < 0x81c; i++) {
        sector[i] = random.nextInt(256);
      }
      sector[15] = mode;
      final header = sector.sublist(12, 16);
      generateEcc(sector);
      expect(sector.sublist(12, 16), header);
      // mode 2 form 1: the parity is of the sector with a zero header
      if (mode == 2) sector.fillRange(12, 16, 0);

      // GF(2^8) with x^8 + x^4 + x^3 + x^2 + 1
      int mul(int a, int b) {
        var r = 0;
        while (b != 0) {
          if (b & 1 != 0) r ^= a;
          a = (a << 1) ^ (a & 0x80 != 0 ? 0x11d : 0);
          a &= 0xff;
          b >>= 1;
        }
        return r;
      }

      int pow(int e) {
        var r = 1;
        for (int i = 0; i < e; i++) {
          r = mul(r, 2);
        }
        return r;
      }

      // P: 86 vectors of 24 bytes + 2 parity, column stride 86 bytes
      for (int col = 0; col < 86; col++) {
        final v = [
          for (int r = 0; r < 24; r++) sector[12 + col + 86 * r],
          sector[0x81c + col],
          sector[0x81c + 86 + col],
        ];
        var s0 = 0, s1 = 0;
        for (int i = 0; i < v.length; i++) {
          s0 ^= v[i];
          s1 ^= mul(pow(v.length - 1 - i), v[i]);
        }
        expect((s0, s1), (0, 0), reason: 'P $col');
      }
      // Q: 52 vectors of 43 bytes on the diagonals + 2 parity
      for (int d = 0; d < 52; d++) {
        final v = [
          for (int r = 0; r < 43; r++)
            sector[12 + ((d >> 1) * 86 + (d & 1) + 88 * r) % 2236],
          sector[0x8c8 + d],
          sector[0x8c8 + 52 + d],
        ];
        var s0 = 0, s1 = 0;
        for (int i = 0; i < v.length; i++) {
          s0 ^= v[i];
          s1 ^= mul(pow(v.length - 1 - i), v[i]);
        }
        expect((s0, s1), (0, 0), reason: 'Q $d');
      }
    });
  }
}

void chdmanFixture() {
  test('a CHD made by chdman (cdlz, cdzl, cdfl) gives the sectors of the disc',
      () async {
    final file = MemoryDiscFile(
        'small.chd', File('test/fixtures/small.chd').readAsBytesSync());
    final (image, _) = await DiscImage.parse([file], file);
    expect([
      for (final t in image.toc.tracks)
        (t.number, t.isAudio, t.startLba, t.sectors)
    ], [
      (1, false, 0, dataSectors),
      (2, true, dataSectors, audioSectors)
    ]);
    final expected = fixtureSectors();
    final sectors = await image.readSectors(0, image.totalSectors);
    for (int lba = 0; lba < expected.length; lba++) {
      expect(sectors[lba], expected[lba], reason: 'lba $lba');
    }
  });
}
