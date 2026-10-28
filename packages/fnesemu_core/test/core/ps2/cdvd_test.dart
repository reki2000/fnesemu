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
}
