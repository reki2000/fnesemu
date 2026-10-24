import 'dart:typed_data';

import 'package:fnesemu_core/core_factory.dart';
import 'package:fnesemu_core/src/cdrom_drive.dart';
import 'package:fnesemu_core/src/core/md/module.dart';
import 'package:fnesemu_core/src/core/pce/module.dart';
import 'package:fnesemu_core/src/core/ps/module.dart';
import 'package:fnesemu_core/src/core/ss/module.dart';
import 'package:test/test.dart';

/// a ready drive whose sectors are filled with zero except [sectors]
class _Drive implements CdromDrive {
  final List<CdromTrack> tracks;
  final Map<int, String> sectors;

  _Drive(this.tracks, this.sectors);

  @override
  CdromDriveStatus get status =>
      CdromDriveStatus(CdromDriveState.ready, 1, CdromToc(tracks, 100000));

  @override
  CdromDriveEvent? takeEvent() => null;

  @override
  void clearEvents() {}

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
    Future<String?> of(
            List<CdromTrack> tracks, Map<int, String> sectors) async =>
        (await CoreFactory.systemOfDisc(_Drive(tracks, sectors)))?.id;

    expect(await of([data], {0: mdCdSignature}), "mdcd");
    expect(await of([data], {0: ssSignature}), "ss");
    expect(await of([data], {4: psLicenseSignature}), "ps");
    expect(await of([data], {16: '\x01CD001\x01\x00$psSignature'}), "ps");
    // the data track follows an audio track
    expect(
        await of([
          const CdromTrack(1, true, 0, 1000),
          const CdromTrack(2, false, 1000, 50000)
        ], {
          1001: pceCdSignature
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
    expect(of("a.md", Uint8List(0x200)..setAll(0x100, "32X".codeUnits)), "32x");
    expect(() => of("a.ps"), throwsException);
    expect(() => of("a.txt"), throwsException);
  });

  test('every system has its core', () {
    for (final s in CoreFactory.systems) {
      expect(CoreFactory.of(s.id), isNotNull, reason: s.id);
    }
  });

  test('md cdrom and 32x BIOS files are told apart by size', () {
    expect(MdModule.biosRole(Uint8List(0x20000)), ('mdcd', 'md cdrom'));
    expect(MdModule.biosRole(Uint8List(0x100))?.$1, '32x');
    expect(MdModule.biosRole(Uint8List(0x800))?.$2, 'sh-2 master');
    expect(MdModule.biosRole(Uint8List(0x400))?.$2, 'sh-2 slave');
    expect(MdModule.biosRole(Uint8List(0x200)), isNull);
  });
  test('MD BIOS updates classify in the core and preserve existing roles', () {
    final master = Uint8List(0x800),
        slave = Uint8List(0x400),
        main = Uint8List(0x100);
    final updates = MdModule.biosUpdates([(main, 'new.bin')],
        saved32x: [('master.bin', master), ('slave.bin', slave)]);
    expect(updates.keys, ['32x']);
    expect(updates['32x']!.map((file) => file.$1),
        ['new.bin', 'master.bin', 'slave.bin']);
    final cd = MdModule.biosUpdates([(Uint8List(0x20000), 'cd.bin')],
        saved32x: [('master.bin', master)]);
    expect(cd.keys, ['mdcd']);
    expect(() => MdModule.biosUpdates([(Uint8List(7), 'invalid.bin')]),
        throwsFormatException);
    expect(
        () => MdModule.biosUpdates([
              (Uint8List(0x20000), 'first.bin'),
              (Uint8List(0x20000), 'second.bin')
            ]),
        throwsArgumentError);
  });
}
