import 'dart:io';
import 'dart:typed_data';

import 'package:fnesemu/core/disc.dart';
import 'package:fnesemu/disc/cue.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('cue_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  CueDisc makeDisc(String cueContent, Map<String, Uint8List> bins) {
    for (final entry in bins.entries) {
      File('${tempDir.path}/${entry.key}').writeAsBytesSync(entry.value);
    }
    final cueFile = File('${tempDir.path}/test.cue')
      ..writeAsStringSync(cueContent);
    return CueDisc(cueFile.path);
  }

  Uint8List makeBin(int sectors, {int fill = 0}) =>
      Uint8List(sectors * Disc.sectorSize)
        ..fillRange(0, sectors * Disc.sectorSize, fill);

  // MSF 0:02:00 = lead-in offset; read() subtracts this from the sector arg.
  const leadInSectors = 2 * 75; // 150

  // ---------------------------------------------------------------------------
  // Single-track data disc
  // ---------------------------------------------------------------------------
  group('single-track data disc', () {
    late CueDisc disc;

    setUp(() {
      disc = makeDisc('''
FILE "data.bin" BINARY
  TRACK 01 MODE2/2352
    INDEX 01 00:00:00
''', {'data.bin': makeBin(10)});
    });

    test('trackCount is 1', () => expect(disc.trackCount, 1));
    test('isEmpty is false', () => expect(disc.isEmpty, false));
    test('track 1 startLBA is 0', () => expect(disc.startLba(1), 0));
    test('totalSectors is 10', () => expect(disc.totalSectors, 10));
  });

  // ---------------------------------------------------------------------------
  // read()
  // ---------------------------------------------------------------------------
  group('read()', () {
    test('lead-in area returns empty Uint8List', () {
      final disc = makeDisc('''
FILE "data.bin" BINARY
  TRACK 01 MODE2/2352
    INDEX 01 00:00:00
''', {'data.bin': makeBin(5)});

      expect(disc.read(0).length, 0);
      expect(disc.read(leadInSectors - 1).length, 0);
    });

    test('reads sector data at correct file offset', () {
      final bin = Uint8List(3 * Disc.sectorSize);
      bin.fillRange(0 * Disc.sectorSize, 1 * Disc.sectorSize, 0xAA);
      bin.fillRange(1 * Disc.sectorSize, 2 * Disc.sectorSize, 0xBB);
      bin.fillRange(2 * Disc.sectorSize, 3 * Disc.sectorSize, 0xCC);

      final disc = makeDisc('''
FILE "data.bin" BINARY
  TRACK 01 MODE2/2352
    INDEX 01 00:00:00
''', {'data.bin': bin});

      final s0 = disc.read(leadInSectors + 0);
      expect(s0.length, Disc.sectorSize);
      expect(s0.every((b) => b == 0xAA), true, reason: 'LBA 0 should be 0xAA');

      final s1 = disc.read(leadInSectors + 1);
      expect(s1.length, Disc.sectorSize);
      expect(s1.every((b) => b == 0xBB), true, reason: 'LBA 1 should be 0xBB');

      final s2 = disc.read(leadInSectors + 2);
      expect(s2.length, Disc.sectorSize);
      expect(s2.every((b) => b == 0xCC), true, reason: 'LBA 2 should be 0xCC');
    });

    test('out-of-range sector returns empty Uint8List', () {
      final disc = makeDisc('''
FILE "data.bin" BINARY
  TRACK 01 MODE2/2352
    INDEX 01 00:00:00
''', {'data.bin': makeBin(5)});

      // disc has 5 sectors at LBA 0-4; LBA 5 is out of range
      expect(disc.read(leadInSectors + 5).length, 0);
      expect(disc.read(leadInSectors + 100).length, 0);
    });
  });

  // ---------------------------------------------------------------------------
  // MSF → LBA conversion (tested indirectly via INDEX 01)
  // ---------------------------------------------------------------------------
  group('INDEX MSF → LBA', () {
    int trackStartLba(String msf, int fileSectors) => makeDisc('''
FILE "data.bin" BINARY
  TRACK 01 MODE2/2352
    INDEX 01 $msf
''', {'data.bin': makeBin(fileSectors)}).startLba(1);

    test('00:00:00 → 0', () => expect(trackStartLba('00:00:00', 10), 0));
    test('00:01:00 → 75', () => expect(trackStartLba('00:01:00', 100), 75));
    test(
        '01:00:00 → 4500', () => expect(trackStartLba('01:00:00', 5000), 4500));
    test('00:00:74 → 74', () => expect(trackStartLba('00:00:74', 100), 74));
    test('00:02:00 → 150', () => expect(trackStartLba('00:02:00', 200), 150));
  });

  // ---------------------------------------------------------------------------
  // Two-track disc
  // ---------------------------------------------------------------------------
  group('two-track disc (data + audio)', () {
    // 10 sectors data, 10 sectors audio in one file
    // TRACK 02 INDEX 01 at 00:00:10 = LBA 10
    late CueDisc disc;

    setUp(() {
      disc = makeDisc('''
FILE "disc.bin" BINARY
  TRACK 01 MODE2/2352
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    INDEX 01 00:00:10
''', {'disc.bin': makeBin(20)});
    });

    test('trackCount is 2', () => expect(disc.trackCount, 2));
    test('track 1 startLBA is 0', () => expect(disc.startLba(1), 0));
    test('track 2 startLBA is 10', () => expect(disc.startLba(2), 10));
    test('totalSectors is 20', () => expect(disc.totalSectors, 20));
  });

  // ---------------------------------------------------------------------------
  // PREGAP (implicit silence, not stored in file)
  // ---------------------------------------------------------------------------
  group('PREGAP', () {
    test('PREGAP 00:02:00 offsets track startLBA by 150', () {
      final disc = makeDisc('''
FILE "data.bin" BINARY
  TRACK 01 MODE2/2352
    PREGAP 00:02:00
    INDEX 01 00:02:00
''', {'data.bin': makeBin(10)});
      // 150 silent sectors before INDEX 01 00:00:00
      expect(disc.startLba(1), 150);
    });
  });

  // ---------------------------------------------------------------------------
  // Quoted filenames (with spaces)
  // ---------------------------------------------------------------------------
  group('quoted filenames', () {
    test('filename with spaces is parsed correctly', () {
      final disc = makeDisc('''
FILE "my disc.bin" BINARY
  TRACK 01 MODE2/2352
    INDEX 01 00:00:00
''', {'my disc.bin': makeBin(5)});
      expect(disc.trackCount, 1);
    });
  });

  // ---------------------------------------------------------------------------
  // Error handling
  // ---------------------------------------------------------------------------
  group('error handling', () {
    test('missing .cue file does not throw', () {
      expect(() => CueDisc('${tempDir.path}/nonexistent.cue'), returnsNormally);
    });

    test('missing binary file does not throw', () {
      final cueFile = File('${tempDir.path}/test.cue')..writeAsStringSync('''
FILE "nonexistent.bin" BINARY
  TRACK 01 MODE2/2352
    INDEX 01 00:00:00
''');
      expect(() => CueDisc(cueFile.path), returnsNormally);
    });

    test('disc with missing binary is empty', () {
      final cueFile = File('${tempDir.path}/test.cue')..writeAsStringSync('''
FILE "nonexistent.bin" BINARY
  TRACK 01 MODE2/2352
    INDEX 01 00:00:00
''');
      expect(CueDisc(cueFile.path).isEmpty, true);
    });
  });
}
