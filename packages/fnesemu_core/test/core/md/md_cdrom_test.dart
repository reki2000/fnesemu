import 'dart:typed_data';

import 'package:fnesemu_core/core_factory.dart';
import 'package:fnesemu_core/src/cdrom.dart';
import 'package:fnesemu_core/src/core/md/cd/cdc.dart';
import 'package:fnesemu_core/src/core/md/cd/cdd.dart';
import 'package:fnesemu_core/src/core/md/cd/md_cdrom.dart';
import 'package:fnesemu_core/src/core/md/cd/pcm.dart';
import 'package:fnesemu_core/src/core/md/md.dart';
import 'package:fnesemu_core/src/sram.dart';
import 'package:test/test.dart';

import '../../support/fake_cdrom_drive.dart';

/// a raw mode 1 sector of [data] at [lba], without EDC/ECC
Uint8List mode1Sector(Uint8List data, int lba) {
  final (m, s, f) = Msf.ofLba(lba).parts();
  int bcd(int value) => ((value ~/ 10) << 4) | (value % 10);
  return Uint8List(cdSectorSize)
    ..setAll(0, cdSync)
    ..setAll(12, [bcd(m), bcd(s), bcd(f), 1])
    ..setAll(16, data);
}

Uint8List bios() {
  final bytes = Uint8List(0x20000);
  final view = ByteData.sublistView(bytes);
  view.setUint32(0, 0xff8000);
  view.setUint32(4, 0x200);
  bytes.setAll(0x100, mdBootSignature.codeUnits);
  bytes.setAll(0x1f0, 'JUE'.codeUnits);
  bytes.setAll(0x200, [0x60, 0xfe]); // BRA.S forever
  return bytes;
}

void subProgram(MdCdrom cd) {
  final view = ByteData.sublistView(cd.programRam);
  view.setUint32(0, 0x7ff00);
  view.setUint32(4, 0x100);
  // MOVEQ #42,D0; BRA.S forever
  cd.programRam.setAll(0x100, [0x70, 0x2a, 0x60, 0xfe]);
}

/// ticks through the seek latency and the tick the drive reports playing
/// before the first sector
void finishSeek(CdDrive drive) {
  while (drive.status == 2) {
    drive.tick();
  }
  if (drive.status == 1) drive.tick();
}

void command(CdDrive drive, List<int> packet) {
  drive.command.fillRange(0, 10, 0);
  drive.command.setAll(0, packet);
  drive.command[9] =
      (~drive.command.take(9).fold<int>(0, (a, b) => a + b)) & 15;
  drive.submit();
}

void main() {

  group('MD CD-ROM bus', () {

    test('PRG RAM bank selection, bus request and write protection', () {
      final cd = MdCdrom(bios());
      cd.writeMain8(0x20000, 0x12);
      cd.writeMain8(0xa12003, 0xc0);
      cd.writeMain8(0x20000, 0x34);
      expect(cd.programRam[0], 0x12);
      expect(cd.programRam[0x60000], 0x34);
      cd.writeMain8(0xa12002, 1);
      cd.writeSub8(0x100, 0x99);
      cd.writeSub8(0x200, 0x88);
      expect(cd.programRam[0x100], 0);
      expect(cd.programRam[0x200], 0x88);
      cd.writeMain8(0xa12001, 1);
      expect(cd.readMain8(0x20000), 0xff);
      cd.writeMain8(0x20000, 0x77);
      expect(cd.programRam[0x60000], 0x34);
      cd.writeMain8(0xa12001, 3);
      expect(cd.readMain8(0x20000), 0x34);
    });

    test('backup RAM uses odd byte lanes and survives reset', () {
      final cd = MdCdrom(bios());
      final sram = Sram();
      cd.setSram(sram);
      expect(sram.id, 'md_cdrom_bram');
      expect(sram.data.length, 8192);
      cd.writeSub8(0xfe0000, 0x99);
      cd.writeSub8(0xfe0001, 0x42);
      expect(cd.readSub16(0xfe0000), 0xff42);
      expect(sram.read8(0), 0x42);
      cd.reset();
      expect(cd.readSub8(0xfe0001), 0x42);
    });

  });

  group('execution and reset', () {

  });

  group('CDD / CDC', () {

    test('TOC checksums, track queries and lead-in-aware data reads', () {
      final disc = FakeCdromDrive(
          List.generate(4, (i) => mode1Sector(Uint8List(2048)..[0] = i + 1, i)),
          starts: [0, 2],
          audioTracks: {2});
      final received = <Uint8List>[];
      int interrupts = 0;
      final drive = CdDrive(received.add, () => interrupts++)
        ..mount(disc)
        ..hostClock = true;
      command(drive, [2, 0, 0, 4]);
      expect(drive.response.sublist(2, 6), [0, 1, 0, 2]);
      expect(drive.response.fold<int>(0, (a, b) => a + b) & 15, 15);
      command(drive, [3, 0, 0, 0, 0, 2, 0, 0]);
      finishSeek(drive);
      final seekInterrupts = interrupts;
      drive.tick();
      expect(disc.reads, [150]);
      expect(received.single[16], 1);
      drive.tick();
      drive.tick(); // audio track is not sent to the decoder
      expect(received.length, 2);
      expect(interrupts - seekInterrupts, 3);
      command(drive, [6]);
      final position = drive.lba;
      drive.tick();
      expect(drive.lba, position);
    });

  });

}
