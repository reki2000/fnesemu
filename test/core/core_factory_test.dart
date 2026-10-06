import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/core/cdrom_drive.dart';
import 'package:fnesemu/core/core_factory.dart';

/// a ready drive whose sectors are filled with zero except [sectors]
class _Drive implements CdromDrive {
  final List<CdromTrack> tracks;
  final Map<int, String> sectors;

  _Drive(this.tracks, this.sectors);

  @override
  CdromDriveStatus get status =>
      CdromDriveStatus(CdromDriveState.ready, 1, CdromToc(tracks, 100000));

  @override
  void seek(int lba) {}

  @override
  Uint8List? read(int lba) {
    final sector = Uint8List(2352);
    final s = sectors[lba];
    if (s != null) sector.setAll(16, s.codeUnits);
    return sector;
  }
}

void main() {
  const data = CdromTrack(1, false, 0, 50000);

  test('system of a disc', () async {
    Future<String?> of(List<CdromTrack> tracks, Map<int, String> sectors) async =>
        (await CoreFactory.systemOfDisc(_Drive(tracks, sectors)))?.id;

    expect(await of([data], {0: "SEGADISCSYSTEM  "}), "mdcd");
    expect(await of([data], {0: "SEGA SEGASATURN "}), "ss");
    expect(
        await of([data], {4: "Licensed  by Sony Computer Entertainment Inc."}),
        "ps");
    expect(await of([data], {16: "\x01CD001\x01\x00PLAYSTATION"}), "ps");
    // the data track follows an audio track
    expect(
        await of([
          const CdromTrack(1, true, 0, 1000),
          const CdromTrack(2, false, 1000, 50000)
        ], {
          1001: "PC Engine CD-ROM SYSTEM"
        }),
        "pcecd");
    expect(await of([data], {}), isNull);
    expect(await of([const CdromTrack(1, true, 0, 1000)], {}), isNull);
  });

  test('system of a file', () {
    String of(String name, [Uint8List? body]) =>
        CoreFactory.systemOfFile(name, body ?? Uint8List(0x200)).id;

    expect(of("a.nes"), "nes");
    expect(of("a.SFC"), "snes");
    expect(of("a.exe"), "ps");
    expect(of("a.32x"), "32x");
    expect(of("a.md", Uint8List(0x200)..setAll(0x100, "32X".codeUnits)),
        "32x");
    expect(() => of("a.ps"), throwsException);
    expect(() => of("a.txt"), throwsException);
  });

  test('every system has its core', () {
    for (final s in CoreFactory.systems) {
      expect(CoreFactory.of(s.id), isNotNull, reason: s.id);
    }
  });
}
