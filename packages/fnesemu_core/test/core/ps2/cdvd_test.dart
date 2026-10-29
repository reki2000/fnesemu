import 'dart:typed_data';

import 'package:fnesemu_core/src/core/ps2/iop/cdvd.dart';
import 'package:fnesemu_core/src/core/ps2/ps2.dart';
import 'package:test/test.dart';

import '../../support/fake_cdrom_drive.dart';

Uint8List _sector(int fill) {
  final raw = Uint8List(2352);
  raw[15] = 1;
  raw.fillRange(16, 16 + 2048, fill);
  return raw;
}

void _write(Cdvd cdvd, int command, List<int> params) {
  for (final p in params) {
    cdvd.write(0x1f402005, p);
  }
  cdvd.write(0x1f402004, command);
}

void main() {
  test('ReadCd delivers sectors and raises the interrupt when done', () {
    final cdvd = Cdvd()..drive = FakeCdromDrive([_sector(1), _sector(2)]);
    var irqs = 0;
    cdvd.onInterrupt = () => irqs++;
    expect(cdvd.discType, Cdvd.ps2Cd);

    _write(cdvd, 0x06, [0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0]);
    expect(cdvd.read(0x1f402005) & 0x80, 0x80);
    final data = <int>[];
    for (var i = 0; i < 200 && irqs == 0; i++) {
      cdvd.advance(50000);
      data.addAll(cdvd.takeData(4096));
    }
    expect(irqs, 1);
    expect(cdvd.istat & 3, 3);
    expect(data.length, 4096);
    expect(data[0], 1);
    expect(data[2048], 2);
    expect(cdvd.read(0x1f402005) & 0xc0, 0x40);

    cdvd.write(0x1f402008, 3);
    expect(cdvd.istat, 0);
  });

  test('ReadDvd delivers blocks with the sector ID of a DVD', () {
    final cdvd = Cdvd()
      ..drive = FakeCdromDrive([_sector(1), _sector(2)])
      ..dvd = true;
    expect(cdvd.discType, Cdvd.ps2Dvd);
    _write(cdvd, 0x08, [1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
    final data = <int>[];
    for (var i = 0; i < 200 && cdvd.istat & 2 == 0; i++) {
      cdvd.advance(50000);
      data.addAll(cdvd.takeData(4096));
    }
    expect(data.length, 2064);
    expect(data.sublist(0, 4), [0x20, 0x03, 0x00, 0x01]);
    expect(data[12], 2);
    expect(data[2059], 2);
    expect(data[2060], 0);
  });

  test('GetToc delivers the physical format of a DVD', () {
    final cdvd = Cdvd()
      ..drive = FakeCdromDrive([_sector(1), _sector(2)])
      ..dvd = true;
    _write(cdvd, 0x09, [0]);
    final toc = cdvd.takeData(4096);
    expect(toc.length, 2064);
    expect(toc.sublist(4, 12), [0, 3, 0, 0, 0, 3, 0, 1]);
    for (var i = 0; i < 10 && cdvd.istat & 2 == 0; i++) {
      cdvd.advance(50000);
    }
    expect(cdvd.istat & 2, 2);
  });

  test('ReadCdda delivers raw sectors', () {
    final cdvd = Cdvd()..drive = FakeCdromDrive([_sector(1), _sector(2)]);
    _write(cdvd, 0x07, [1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
    final data = <int>[];
    for (var i = 0; i < 200 && cdvd.istat & 2 == 0; i++) {
      cdvd.advance(50000);
      data.addAll(cdvd.takeData(4096));
    }
    expect(data.length, 2352);
    expect(data[15], 1);
    expect(data[16], 2);
  });

  test('S commands answer with config, clock and sticky status', () {
    final cdvd = Cdvd()..drive = FakeCdromDrive([_sector(0)]);
    cdvd.write(0x1f402016, 0x41);
    expect(cdvd.read(0x1f402017), 0);
    final config = List.generate(16, (_) => cdvd.read(0x1f402018));
    expect(config.length, 16);
    expect(cdvd.read(0x1f402017), 0x40);

    cdvd.write(0x1f402016, 0x05);
    expect(cdvd.read(0x1f40200b), cdvd.read(0x1f40200a));
  });

  test('an empty drive reports no disc', () {
    final cdvd = Cdvd();
    expect(cdvd.discType, Cdvd.noDisc);
    _write(cdvd, 0x06, [0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
    expect(cdvd.read(0x1f402006), 1);
  });

  test('the EE reads the disc type through its own CDVD window', () {
    final ps2 = Ps2();
    expect(ps2.bus.read8(0xbf40200f), Cdvd.noDisc);
    ps2.setCdromDrive(FakeCdromDrive([_sector(0)]));
    expect(ps2.bus.read8(0xbf40200f), Cdvd.ps2Cd);
    ps2.reset();
    expect(ps2.bus.read8(0xbf40200f), Cdvd.ps2Cd);
  });

  test('ReadKey encodes the game ID the way the BIOS browser decodes it', () {
    final cdvd = Cdvd()
      ..drive = FakeCdromDrive([_sector(0)])
      ..discId = 'ABCD_123.45';
    _write(cdvd, 0x0c, [0, 0, 0, 0x4b, 0, 0, 0]);
    cdvd.advance(1000000);
    expect(cdvd.read(0x1f402038), 7);
    final k = [
      for (final a in [0x20, 0x28, 0x30])
        for (var i = 0; i < 5; i++) cdvd.read(0x1f402000 + a + i)
    ];
    final letters = [
      k[3] >> 4 | (k[4] & 7) << 4,
      k[2] >> 5 | (k[3] & 15) << 3,
      k[1] >> 6 | (k[2] & 31) << 2,
      k[0] >> 7 | (k[1] & 63) << 1,
    ];
    final number = k[4] >> 3 | (k[14] >> 3) << 5 | (k[0] & 127) << 10;
    expect(String.fromCharCodes(letters), 'ABCD');
    expect(number, 12345);
  });
}
