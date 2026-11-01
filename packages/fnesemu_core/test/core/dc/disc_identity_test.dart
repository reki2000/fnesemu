import 'dart:typed_data';

import 'package:fnesemu_core/core_factory.dart';
import 'package:fnesemu_core/src/cdrom_drive.dart';
import 'package:fnesemu_core/src/core/dc/disc.dart';
import 'package:fnesemu_core/src/core/dc/module.dart';
import 'package:test/test.dart';

const identity = dcDiscSignature;
const dataTrack = CdromTrack(1, false, 0, 80);

Uint8List metadata() => Uint8List(2048)..setAll(0, identity.codeUnits);

Uint8List raw(Uint8List payload, {int mode = 1}) {
  final bytes = Uint8List(2352);
  bytes.fillRange(1, 11, 255);
  bytes[15] = mode;
  if (mode == 2) {
    bytes[18] = bytes[22] = 8;
  }
  bytes.setAll(mode == 1 ? 16 : 24, payload);
  return bytes;
}

void both(Uint8List bytes, int offset, int value, int width) {
  final view = ByteData.sublistView(bytes);
  if (width == 2) {
    view.setUint16(offset, value, Endian.little);
    view.setUint16(offset + 2, value, Endian.big);
  } else {
    view.setUint32(offset, value, Endian.little);
    view.setUint32(offset + 4, value, Endian.big);
  }
}

Uint8List record(List<int> name, int extent, int size, {int flags = 0}) {
  final length = 33 + name.length + (name.length.isEven ? 1 : 0);
  final bytes = Uint8List(length);
  bytes[0] = length;
  both(bytes, 2, extent, 4);
  both(bytes, 10, size, 4);
  bytes[25] = flags;
  both(bytes, 28, 1, 2);
  bytes[32] = name.length;
  bytes.setAll(33, name);
  return bytes;
}

// Directory records hold absolute LBAs: [base] is the track's start.
Map<int, Uint8List> iso(
    {String name = 'IP.BIN;1', int rootSize = 2048, int base = 0}) {
  final pvd = Uint8List(2048);
  pvd[0] = 1;
  pvd.setAll(1, 'CD001'.codeUnits);
  pvd[6] = 1;
  both(pvd, 80, 80, 4);
  both(pvd, 120, 1, 2);
  both(pvd, 124, 1, 2);
  both(pvd, 128, 2048, 2);
  pvd.setAll(156, record([0], base + 20, rootSize, flags: 2));
  pvd[881] = 1;
  final root = Uint8List(2048);
  root.setAll(0, record([0], base + 20, rootSize, flags: 2));
  root.setAll(34, record([1], base + 20, rootSize, flags: 2));
  root.setAll(68, record(name.codeUnits, base + 30, 32768));
  return {0: Uint8List(2048), 16: pvd, 20: root, 30: metadata()};
}

class Drive implements CdromDrive {
  Drive(this.sectors, {this.tracks = const [dataTrack], int? total})
      : total = total ?? tracks.last.startLba + tracks.last.sectors;
  final Map<int, Uint8List> sectors;
  final List<CdromTrack> tracks;
  final int total;
  final reads = <int>[];
  final events = CdromDriveEvents();
  int generation = 1, pending = 0;
  int? replaceAt;
  bool ready = true, replaceOnRead = false;
  @override
  CdromDriveStatus get status => CdromDriveStatus(
      ready ? CdromDriveState.ready : CdromDriveState.loading,
      generation,
      CdromToc(tracks, total));
  @override
  Uint8List? read(int lba) {
    reads.add(lba);
    if (replaceOnRead || replaceAt == lba) generation++;
    if (pending > 0) {
      pending--;
      return null;
    }
    return sectors[lba] ?? Uint8List(0);
  }

  @override
  CdromDriveEvent? takeEvent() => events.take();
  @override
  void clearEvents() => events.clear();
  @override
  void seek(int lba) => fail('Identification must not seek the guest drive');
}

Drive cooked(Map<int, Uint8List> blocks, {int start = 0, int mode = 1}) =>
    Drive({
      for (final entry in blocks.entries)
        start + entry.key: raw(entry.value, mode: mode)
    }, tracks: [
      CdromTrack(1, false, start, 80)
    ]);

void main() {
  for (final mode in [1, 2]) {
    test('exact boot metadata identifies Mode $mode without consuming events',
        () async {
      final drive = cooked({0: metadata()}, mode: mode);
      drive.events.add(CdromDriveState.ready, 1);
      expect((await DcModule().identifyDisc(drive))?.id, 'dc');
      expect(drive.reads, [0]);
      expect(drive.takeEvent()?.type, CdromDriveEventType.discReady);
    });
  }

  test('factory exposes the disc capability and selects DC by content',
      () async {
    expect(CoreFactory.system('dc').disc, 'dc');
    expect((await CoreFactory.systemOfDisc(cooked({0: metadata()})))?.id, 'dc');
    expect(DcModule().identifyRom('unknown.cdi', metadata()), isNull);
    expect(DcModule().identifyRom('1ST_READ.BIN', metadata()), isNull);
  });

  test('last data track is preferred and an audio track is never read',
      () async {
    final drive = Drive({
      100: raw(metadata())
    }, tracks: const [
      CdromTrack(1, false, 0, 50),
      CdromTrack(2, true, 50, 50),
      CdromTrack(3, false, 100, 80),
      CdromTrack(4, true, 180, 20)
    ]);
    expect((await DcModule().identifyDisc(drive))?.id, 'dc');
    expect(drive.reads, [100]);
  });

  test('first data track metadata is accepted when the last has no header',
      () async {
    final drive = Drive({0: raw(metadata())},
        tracks: const [dataTrack, CdromTrack(2, false, 80, 80)]);
    expect((await DcModule().identifyDisc(drive))?.id, 'dc');
    expect(drive.reads, [80, 0]);
  });

  for (final invalid in [
    'shift',
    'hardware',
    'maker',
    'sync',
    'mode',
    'form2',
    'subheader',
    'short'
  ]) {
    test('rejects invalid or misplaced boot identity: $invalid', () async {
      final bytes = raw(metadata(),
          mode: invalid == 'form2' || invalid == 'subheader' ? 2 : 1);
      switch (invalid) {
        case 'shift':
          bytes.fillRange(16, 48, 0);
          bytes.setAll(17, identity.codeUnits);
        case 'hardware':
          bytes[16] ^= 1;
        case 'maker':
          bytes[32] ^= 1;
        case 'sync':
          bytes[1] = 0;
        case 'mode':
          bytes[15] = 0;
        case 'form2':
          bytes[18] = bytes[22] = 0x28;
        case 'subheader':
          bytes[20] = 1;
      }
      final drive =
          Drive({0: invalid == 'short' ? bytes.sublist(0, 100) : bytes});
      expect(await DcModule().identifyDisc(drive), isNull);
    });
  }

  test('unready, audio-only and out-of-range tracks do not read sectors',
      () async {
    final drives = [
      cooked({0: metadata()})..ready = false,
      Drive({0: raw(metadata())}, tracks: const [CdromTrack(1, true, 0, 80)]),
      Drive({0: raw(metadata())}, total: 1),
      Drive({0: raw(metadata())}, tracks: const [CdromTrack(1, false, -1, 80)])
    ];
    for (final drive in drives) {
      expect(await DcModule().identifyDisc(drive), isNull);
      expect(drive.reads, isEmpty);
    }
  });

  test('pending reads are retried and a replacement medium cancels identity',
      () async {
    final pending = cooked({0: metadata()})..pending = 1;
    expect((await DcModule().identifyDisc(pending))?.id, 'dc');
    expect(pending.reads, [0, 0]);
    final changed = cooked({0: metadata()})..replaceOnRead = true;
    expect(await DcModule().identifyDisc(changed), isNull);
    expect(changed.reads, [0]);
  });

  for (final name in ['IP.BIN;1', 'IP0000.BIN;1']) {
    for (final start in [0, 200]) {
      test('ISO root $name identifies metadata with volume start $start',
          () async {
        final drive = cooked(iso(name: name, base: start), start: start);
        expect((await DcModule().identifyDisc(drive))?.id, 'dc');
        expect(drive.reads, [start, start + 16, start + 20, start + 30]);
      });
    }
  }

  test('ISO skips a boot descriptor and root block padding', () async {
    final blocks = iso(rootSize: 4096);
    blocks[17] = blocks[16]!;
    final boot = Uint8List.fromList(blocks[16]!)..[0] = 0;
    blocks[16] = boot;
    blocks[21] = blocks[20]!;
    blocks[20] = Uint8List(2048);
    expect((await DcModule().identifyDisc(cooked(blocks)))?.id, 'dc');
  });

  test('a marker in an unlisted ISO file does not identify the platform',
      () async {
    final blocks = iso(name: 'OTHER.BIN;1');
    expect(await DcModule().identifyDisc(cooked(blocks)), isNull);
  });
}
