import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fnesemu_core/src/cdrom_drive.dart';
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

/// a CD with a SYSTEM.CNF which boots [id]
FakeCdromDrive _discOf(String id) {
  final sectors = List.generate(32, (_) => _sector(0));
  void put(int lba, Uint8List data) => sectors[lba].setAll(16, data);
  final pvd = Uint8List(2048)..setRange(1, 6, ascii.encode('CD001'));
  ByteData.sublistView(pvd)
    ..setUint32(80, 32, Endian.little)
    ..setUint32(156 + 2, 20, Endian.little)
    ..setUint32(156 + 10, 2048, Endian.little);
  pvd[156] = 34; // the root record, with a 1-byte name
  pvd[156 + 32] = 1;
  put(16, pvd);
  put(17, Uint8List(2048)..[0] = 0xff);
  final cnf = ascii.encode('BOOT2 = cdrom0:\\$id;1\r\n');
  final dir = Uint8List(2048);
  const name = 'SYSTEM.CNF;1';
  dir[0] = 33 + name.length;
  ByteData.sublistView(dir)
    ..setUint32(2, 30, Endian.little)
    ..setUint32(10, cnf.length, Endian.little);
  dir[32] = name.length;
  dir.setRange(33, 33 + name.length, ascii.encode(name));
  put(20, dir);
  put(30, cnf);
  return FakeCdromDrive(sectors);
}

/// a drive whose disc is changed through the tray
class _TrayDrive implements CdromDrive {
  CdromDrive disc;
  int discId = 1;
  final events = CdromDriveEvents();
  _TrayDrive(this.disc);

  void change(CdromDrive next) {
    events.add(CdromDriveState.trayOpen, ++discId);
    disc = next;
    events.add(CdromDriveState.ready, ++discId);
  }

  @override
  CdromDriveStatus get status =>
      CdromDriveStatus(disc.status.state, discId, disc.status.toc);

  @override
  CdromDriveEvent? takeEvent() => events.take();

  @override
  void clearEvents() => events.clear();

  @override
  void seek(int lba) => disc.seek(lba);

  @override
  Uint8List? read(int lba) => disc.read(lba);
}

void _write(Cdvd cdvd, int command, List<int> params) {
  for (final p in params) {
    cdvd.write(0x1f402005, p);
  }
  cdvd.write(0x1f402004, command);
}

class _CaseSkip implements Exception {
  const _CaseSkip();
}

void main() {
  // Aggregated cases: the per-case tests of this file are collected
  // in this table and executed by the aggregated test(s) at the end of
  // main; every case name stays visible here and in the run output.
  final aggCases = <(String, FutureOr<void> Function())>[];
  final aggTeardowns = <void Function()>[];
  void addTearDown(void Function() teardown) => aggTeardowns.add(teardown);
  void aggCase(String name, FutureOr<void> Function() body) =>
      aggCases.add((name, body));
  Future<void> runAggCases(
      Iterable<(String, FutureOr<void> Function())> cases) async {
    for (final (name, body) in cases) {
      print('case: $name');
      try {
        await body();
      } on _CaseSkip {
        print('skipped: $name');
      } finally {
        for (final teardown in aggTeardowns) {
          teardown();
        }
        aggTeardowns.clear();
      }
    }
  }

  aggCase('ReadCd delivers sectors and raises the interrupt when done', () {
    final cdvd = Cdvd()
      ..drive = FakeCdromDrive([
        for (var i = 0; i < 12; i++) _sector(0),
        _sector(1),
        _sector(2),
      ]);
    var irqs = 0;
    cdvd.onInterrupt = () => irqs++;
    expect(cdvd.discType, Cdvd.ps2Cd);

    _write(cdvd, 0x06, [12, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0]);
    expect(cdvd.read(0x1f402005) & 0x80, 0x80);
    final data = <int>[];
    for (var i = 0; i < 1000 && irqs == 0; i++) {
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

  aggCase('ReadDvd delivers blocks with the sector ID of a DVD', () {
    final cdvd = Cdvd()
      ..drive = FakeCdromDrive([
        for (var i = 0; i < 12; i++) _sector(1),
        _sector(2),
      ])
      ..dvd = true;
    expect(cdvd.discType, Cdvd.ps2Dvd);
    _write(cdvd, 0x08, [12, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
    final data = <int>[];
    for (var i = 0; i < 1000 && cdvd.istat & 2 == 0; i++) {
      cdvd.advance(50000);
      data.addAll(cdvd.takeData(4096));
    }
    expect(data.length, 2064);
    expect(data.sublist(0, 4), [0x20, 0x03, 0x00, 0x0c]);
    expect(data[12], 2);
    expect(data[2059], 2);
    expect(data[2060], 0);
  });

  aggCase('the logo sectors are delivered decrypted', () {
    // a logo of black pixels then 0x81, stored as ROR3(byte) ^ key
    const key = 0x5a;
    int stored(int v) => ((v >> 3 | v << 5) & 0xff) ^ key;
    final first = _sector(stored(0))..[16 + 1] = stored(0x81);
    final cdvd = Cdvd()
      ..drive = FakeCdromDrive([first, _sector(stored(0x81)), _sector(7)]);
    _write(cdvd, 0x06, [0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0]);
    final data = <int>[];
    for (var i = 0; i < 1000 && cdvd.istat & 2 == 0; i++) {
      cdvd.advance(50000);
      data.addAll(cdvd.takeData(4096));
    }
    expect(data.length, 4096);
    expect(data.sublist(0, 3), [0, 0x81, 0]);
    expect(data[2048], 0x81);
  });

  aggCase('GetToc delivers the physical format of a DVD', () {
    final cdvd = Cdvd()
      ..drive = FakeCdromDrive([_sector(1), _sector(2)])
      ..dvd = true;
    _write(cdvd, 0x09, [0]);
    final toc = cdvd.takeData(4096);
    expect(toc.length, 2064);
    expect(toc.sublist(4, 12), [0, 3, 0, 0, 0, 3, 0, 1]);
    for (var i = 0; i < 1000 && cdvd.istat & 2 == 0; i++) {
      cdvd.advance(50000);
    }
    expect(cdvd.istat & 2, 2);
  });

  aggCase('ReadCdda delivers raw sectors', () {
    final cdvd = Cdvd()..drive = FakeCdromDrive([_sector(1), _sector(2)]);
    _write(cdvd, 0x07, [1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
    final data = <int>[];
    for (var i = 0; i < 1000 && cdvd.istat & 2 == 0; i++) {
      cdvd.advance(50000);
      data.addAll(cdvd.takeData(4096));
    }
    expect(data.length, 2352);
    expect(data[15], 1);
    expect(data[16], 2);
  });

  aggCase('S commands answer with config, clock and sticky status', () {
    final cdvd = Cdvd()..drive = FakeCdromDrive([_sector(0)]);
    cdvd.write(0x1f402016, 0x41);
    expect(cdvd.read(0x1f402017), 0);
    final config = List.generate(16, (_) => cdvd.read(0x1f402018));
    expect(config.length, 16);
    expect(cdvd.read(0x1f402017), 0x40);

    cdvd.write(0x1f402016, 0x05);
    expect(cdvd.read(0x1f40200b), cdvd.read(0x1f40200a));
  });


  aggCase('the EE reads the disc type through its own CDVD window', () {
    final ps2 = Ps2();
    addTearDown(ps2.dispose);
    expect(ps2.bus.read8(0xbf40200f), Cdvd.noDisc);
    ps2.setCdromDrive(FakeCdromDrive([_sector(0)]));
    expect(ps2.bus.read8(0xbf40200f), Cdvd.ps2Cd);
    ps2.reset();
    expect(ps2.bus.read8(0xbf40200f), Cdvd.ps2Cd);
  });

  aggCase('a disc changed through the tray is looked up again', () async {
    final ps2 = Ps2();
    addTearDown(ps2.dispose);
    final drive = _TrayDrive(_discOf('ABCD_123.45'));
    ps2.setCdromDrive(drive);
    await ps2.discLookup;
    expect(ps2.iopIo.cdvd.discId, 'ABCD_123.45');
    drive.change(_discOf('EFGH_678.90'));
    ps2.iopIo.cdvd.advance(1); // the tray opened
    expect(ps2.iopIo.cdvd.discId, isNull);
    ps2.iopIo.cdvd.advance(1); // the new disc is ready
    await ps2.discLookup;
    expect(ps2.iopIo.cdvd.discId, 'EFGH_678.90');
  });

  /// the IOP clocks until the N command finishes
  int busyClocks(Cdvd cdvd) {
    var clocks = 0;
    while (cdvd.read(0x1f402005) & 0x80 != 0) {
      cdvd.advance(1000);
      cdvd.takeData(1 << 20);
      clocks += 1000;
    }
    return clocks;
  }

  aggCase('a seek spins the drive up, then nearby seeks are short', () {
    final cdvd = Cdvd()..drive = FakeCdromDrive([_sector(0)]);
    expect(cdvd.read(0x1f40200a), 0);
    _write(cdvd, 0x05, [100, 0, 0, 0]);
    expect(busyClocks(cdvd), closeTo(36864000 * 0.333, 1000));
    expect(cdvd.read(0x1f40200a), 0x0a); // spinning, paused
    _write(cdvd, 0x05, [110, 0, 0, 0]);
    expect(busyClocks(cdvd), lessThan(36864000 * 0.01));
    _write(cdvd, 0x05, [0, 0x10, 0, 0]); // 4096 sectors away
    expect(busyClocks(cdvd), closeTo(36864000 * 0.03, 1000));
    _write(cdvd, 0x05, [0, 0, 1, 0]); // 65536
    expect(busyClocks(cdvd), closeTo(36864000 * 0.1, 1000));
  });

  aggCase('Stop stops the drive and the sticky status keeps the spinning bit', () {
    final cdvd = Cdvd()..drive = FakeCdromDrive([_sector(0)]);
    _write(cdvd, 0x05, [1, 0, 0, 0]);
    busyClocks(cdvd);
    _write(cdvd, 0x03, []);
    busyClocks(cdvd);
    expect(cdvd.read(0x1f40200a), 0);
    expect(cdvd.read(0x1f40200b) & 2, 2);
  });

  aggCase('the PS2 RTC follows host time in JST, independent of host time zone', () {
    var now = DateTime.utc(2026, 11, 1, 0, 34, 56);
    final cdvd = Cdvd()..clock = () => now;

    List<int> readClock() {
      cdvd.write(0x1f402016, 0x08);
      return [for (var i = 0; i < 8; i++) cdvd.read(0x1f402018)];
    }

    expect(readClock(), [0, 0x56, 0x34, 0x09, 0, 0x01, 0x11, 0x26]);
    cdvd.advance(36864000 * 3);
    expect(readClock(), [0, 0x56, 0x34, 0x09, 0, 0x01, 0x11, 0x26]);
    now = now.add(const Duration(seconds: 4));
    expect(readClock(), [0, 0x00, 0x35, 0x09, 0, 0x01, 0x11, 0x26]);
  });


  aggCase('ReadKey encodes the game ID the way the BIOS browser decodes it', () {
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

  const chunkCount = 2;
  final chunkSize = (aggCases.length + chunkCount - 1) ~/ chunkCount;
  for (var part = 0; part < chunkCount; part++) {
    final partCases =
        aggCases.skip(part * chunkSize).take(chunkSize).toList();
    if (partCases.isEmpty) continue;
    test('aggregated cases ${part + 1} of $chunkCount', () async {
      await runAggCases(partCases);
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}
