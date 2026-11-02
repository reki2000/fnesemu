import 'dart:convert';
import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps2/iso9660.dart';
import 'package:test/test.dart';

import '../../support/fake_cdrom_drive.dart';

/// a raw mode 1 sector whose user data starts with a volume descriptor [id]
Uint8List _descriptor(String id) => Uint8List(2352)
  ..[15] = 1
  ..setRange(17, 22, ascii.encode(id));

void main() {
  test('finds and reads a file in the root directory', () async {
    final sectors = <int, Uint8List>{};
    final pvd = Uint8List(2048);
    pvd.setRange(1, 6, ascii.encode('CD001'));
    ByteData.sublistView(pvd)
      ..setUint32(156 + 2, 20, Endian.little)
      ..setUint32(156 + 10, 2048, Endian.little);
    sectors[16] = pvd;
    final dir = Uint8List(2048);
    const name = 'SYSTEM.CNF;1';
    dir[0] = 33 + name.length;
    ByteData.sublistView(dir)
      ..setUint32(2, 30, Endian.little)
      ..setUint32(10, 5, Endian.little);
    dir[32] = name.length;
    dir.setRange(33, 33 + name.length, ascii.encode(name));
    sectors[20] = dir;
    sectors[30] = Uint8List(2048)..setRange(0, 5, ascii.encode('BOOT2'));

    final iso = Iso9660((lba) async => sectors[lba] ?? Uint8List(2048));
    final file = await iso.findRootFile('system.cnf');
    expect(file, (lba: 30, size: 5));
    expect(ascii.decode(await iso.readFile(file!)), 'BOOT2');
    expect(await iso.findRootFile('MISSING'), isNull);
  });

  test('takes the BOOT2 file name from SYSTEM.CNF', () {
    expect(bootFileName('BOOT2 = cdrom0:\\ABCD_123.45;1\r\nVER = 1.00\r\n'),
        'ABCD_123.45');
    expect(bootFileName('VMODE = NTSC\n'), isNull);
  });

  test('a UDF bridge disc is a DVD', () async {
    List<Uint8List> disc(List<String> ids) =>
        [for (var i = 0; i < 16; i++) Uint8List(2352), ...ids.map(_descriptor)];
    expect(await isDvd(FakeCdromDrive(disc(['CD001', 'BEA01']))), isTrue);
    expect(await isDvd(FakeCdromDrive(disc(['CD001', 'CD001']))), isFalse);
  });
}
