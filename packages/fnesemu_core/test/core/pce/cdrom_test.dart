import 'dart:typed_data';

import 'package:fnesemu_core/src/cdrom_drive.dart';
import 'package:fnesemu_core/src/core/pce/component/cdrom.dart';
import 'package:fnesemu_core/src/core/pce/pce.dart';
import 'package:fnesemu_core/src/sram.dart';
import 'package:fnesemu_core/src/util/int.dart';
import 'package:test/test.dart';

import '../../support/fake_cdrom_drive.dart';

class TestDisc extends FakeCdromDrive {
  TestDisc() : super(_sectors(), starts: [0, 4], audioTracks: {2});

  static List<Uint8List> _sectors() =>
      [for (var lba = 0; lba < 6; lba++) _sector(lba + 150)];

  static Uint8List _sector(int sector) {
    final result = Uint8List(2352);
    if (sector < 154) {
      result[15] = 1;
      for (var i = 0; i < 2048; i++) {
        result[16 + i] = (i + sector).mask8;
      }
    } else {
      for (var i = 0; i < 2352; i += 4) {
        result[i + 1] = 0x40; // +16384 left
        result[i + 3] = 0xc0; // -16384 right
      }
    }
    return result;
  }
}

void main() {
  late Pce pce;
  late PceCdrom cd;
  late TestDisc disc;
  const io = 0xff * 0x2000;

  void command(List<int> bytes) {
    cd.write(0x1800, 0);
    expect(cd.read(0x1800), 0xd0);
    for (final byte in bytes) {
      cd.write(0x1801, byte);
      cd.write(0x1802, 0x80);
      expect(cd.read(0x1800) & 0x40, 0);
      cd.write(0x1802, 0);
    }
  }

  void finish([int status = 0]) {
    expect(cd.phase, CdPhase.status);
    expect(cd.read(0x1801), status);
    cd.write(0x1802, 0x80);
    cd.write(0x1802, 0);
    expect(cd.phase, CdPhase.message);
    expect(cd.read(0x1801), 0);
    cd.write(0x1802, 0x80);
    cd.write(0x1802, 0);
    expect(cd.read(0x1800), 0);
  }

  setUp(() {
    pce = Pce();
    disc = TestDisc();
    pce.setCdromDrive(disc);
    cd = pce.bus.cdrom;
  });

  test('backup RAM is locked by status read and reset, preserves saved data',
      () {
    final sram = Sram()..init('saved', Uint8List(2048)..[0] = 42);
    pce.setSram(sram);
    pce.setCdromDrive(disc);
    const address = 0xf7 * 8192;
    expect(pce.bus.read(address), 255);
    pce.bus.write(io + 0x1807, 0x80);
    expect(pce.bus.read(address), 42);
    pce.bus.write(address + 1, 77);
    expect(sram.data[1], 77);
    expect(pce.bus.read(address + 2048), 255);
    pce.bus.read(io + 0x1803);
    pce.bus.write(address + 1, 99);
    expect(sram.data[1], 77);
    pce.reset();
    pce.bus.write(io + 0x1807, 0x80);
    expect(pce.bus.read(address + 1), 77);
  });

  test('READ(6) transfers mode 1 payloads with lead-in and per-sector delay',
      () {
    command([8, 0, 0, 1, 2, 0]);
    expect(cd.read(0x1800), 0x88);
    cd.exec(21477270 ~/ 75 - 1);
    expect(disc.reads, isEmpty);
    cd.exec(1);
    expect(disc.reads, [151]);
    expect(cd.read(0x1800), 0xc8);
    cd.write(0x1802, 0x40);
    expect(pce.bus.pic.hold.mask1, 1);
    expect(cd.read(0x1801), 151);
    expect(cd.read(0x1801), 151); // no implicit ACK on $1801
    for (var i = 0; i < 2048; i++) {
      expect(cd.read(0x1808), (i + 151).mask8);
    }
    expect(cd.read(0x1800), 0x88);
    expect(pce.bus.pic.hold.mask1, 0);
    cd.exec(21477270 ~/ 75);
    for (var i = 0; i < 2048; i++) {
      expect(cd.read(0x1808), (i + 152).mask8);
    }
    expect(disc.reads, [151, 152]);
    finish();
  });

}
