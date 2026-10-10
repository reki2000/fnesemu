import 'dart:typed_data';

import 'package:fnesemu_core/core/cdrom.dart';
import 'package:fnesemu_core/core/core_factory.dart';
import 'package:fnesemu_core/core/md/cd/cdc.dart';
import 'package:fnesemu_core/core/md/cd/cdd.dart';
import 'package:fnesemu_core/core/md/cd/md_cdrom.dart';
import 'package:fnesemu_core/core/md/cd/pcm.dart';
import 'package:fnesemu_core/core/md/md.dart';
import 'package:fnesemu_core/core/sram.dart';
import 'package:test/test.dart';

import '../../support/fake_cdrom_drive.dart';

/// a raw mode 1 sector of [data] at [lba], without EDC/ECC
Uint8List mode1Sector(Uint8List data, int lba) {
  final (m, s, f) = lbaToMsf(lba, addLeadIn: true);
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
  bytes.setAll(0x100, 'SEGA BOOT'.codeUnits);
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
    test('BIOS and HINT vector are visible to main CPU only', () {
      final md = Md()..setRom(bios());
      expect(md.cpuM68.pc, 0x200);
      expect(md.cdrom, isNotNull);
      expect(md.busM68.read16(0x200), 0x60fe);
      expect(md.busM68.read16(0xa10000) & 0x20, 0);
      md.busM68.write16(0xa12006, 0x3456);
      expect(md.busM68.read16(0x72), 0x3456);
      expect(md.cdrom!.bus.read16(0x200), 0);
      expect(md.cpuInfos.map((c) => c.no), [0, 1, 2]);
      expect(CoreFactory.of('mdcd'), isA<Md>());
    });

    test('cartridge loads detach CD and retain the normal MD bus', () {
      final md = Md()..setRom(bios());
      final cartridge = Uint8List.fromList(bios());
      cartridge.setAll(0x100, 'CARTRIDGE       '.codeUnits);
      md.setRom(cartridge);
      expect(md.cdrom, isNull);
      expect(md.cpuInfos.length, 2);
      expect(md.busM68.read16(0xa10000) & 0x20, 0x20);
    });

    test('explicit CD mode validates BIOS size', () {
      expect(() => (Md(cdBoot: true)..setRom(Uint8List(512))),
          throwsArgumentError);
    });

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

    test('2M Word RAM ownership transfers in both directions', () {
      final cd = MdCdrom(bios());
      cd.writeMain8(0x200000, 0x12);
      expect(cd.readSub8(0x80000), 0xff);
      cd.writeSub8(0x80000, 0x99);
      expect(cd.readMain8(0x200000), 0x12);
      cd.writeMain8(0xa12003, 2);
      expect(cd.readMain8(0x200000), 0xff);
      expect(cd.readSub8(0x80000), 0x12);
      cd.writeSub8(0x80000, 0x34);
      cd.writeSub8(0xff8003, 1);
      expect(cd.readMain8(0x200000), 0x34);
      expect(cd.readMain8(0xa12003) & 3, 1);
    });

    test('1M banks preserve data across mode changes and support dot writes',
        () {
      final cd = MdCdrom(bios());
      cd.writeMain8(0x200000, 0x12);
      cd.writeMain8(0x200002, 0x34);
      cd.writeSub8(0xff8003, 5);
      expect(cd.readMain8(0x200000), 0x34);
      expect(cd.readSub8(0xc0000), 0x12);
      expect(cd.readSub8(0x80000), 1);
      expect(cd.readSub8(0x80001), 2);
      cd.writeSub8(0x80001, 0xa);
      expect(cd.readSub8(0xc0000), 0x1a);
      cd.writeSub8(0xff8003, 4);
      expect(cd.readMain8(0x200000), 0x1a);
      cd.writeSub8(0xff8003, 1);
      expect(cd.readMain8(0x200000), 0x1a);
      expect(cd.readMain8(0x200002), 0x34);
    });

    test('1M cell window converts bitmap rows at all five image heights', () {
      final cd = MdCdrom(bios());
      cd.writeSub8(0xff8003, 4);
      for (final (base, cells) in [
        (0, 32),
        (0x10000, 16),
        (0x18000, 8),
        (0x1c000, 4),
        (0x1e000, 4)
      ]) {
        cd.writeMain8(0x200000 + base + 256, 0x12); // row 1, column 0
        cd.writeMain8(0x200000 + base + 4, 0x34); // row 0, next tile
        expect(cd.readMain8(0x220000 + base + 4), 0x12);
        expect(cd.readMain8(0x220000 + base + cells * 32), 0x34);
        cd.writeMain8(0x220000 + base + 5, 0x56);
        expect(cd.readMain8(0x200000 + base + 257), 0x56);
      }
    });

    test('communications respect CPU byte and command/status ownership', () {
      final cd = MdCdrom(bios());
      cd.writeMain8(0xa1200e, 0xab);
      cd.writeMain8(0xa1200f, 0xff);
      cd.writeSub8(0xff800e, 0xff);
      cd.writeSub8(0xff800f, 0xcd);
      expect(cd.readMain16(0xa1200e), 0xabcd);
      cd.writeMain8(0xa12010, 0x12);
      cd.writeSub8(0xff8010, 0x99);
      expect(cd.readSub8(0xff8010), 0x12);
      cd.writeSub8(0xff8020, 0x34);
      cd.writeMain8(0xa12020, 0x99);
      expect(cd.readMain8(0xa12020), 0x34);
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

    test('font expansion produces the four groups of packed pixels', () {
      final cd = MdCdrom(bios());
      cd.bus.write16(0xff804c, 0x00a3);
      cd.bus.write16(0xff804e, 0x8001);
      expect(cd.bus.read16(0xff8050), 0xa333);
      expect(cd.bus.read16(0xff8052), 0x3333);
      expect(cd.bus.read16(0xff8056), 0x333a);
    });
  });

  group('execution and reset', () {
    test('sub CPU starts from PRG RAM and pauses without accumulating debt',
        () {
      final cd = MdCdrom(bios());
      subProgram(cd);
      expect(cd.advance(100, 12500000), isTrue);
      expect(cd.cpu.d[0], 0);
      cd.writeMain8(0xa12001, 1);
      expect(cd.cpu.pc, 0x100);
      expect(cd.advance(200, 12500000), isTrue);
      expect(cd.cpu.d[0], 42);
      cd.writeMain8(0xa12001, 3);
      final pc = cd.cpu.pc;
      cd.advance(100000, 12500000);
      expect(cd.cpu.pc, pc);
      expect(cd.cpu.clocks, 100000);
      cd.writeMain8(0xa12001, 1);
      cd.advance(100012, 12500000);
      expect(cd.cpu.clocks, lessThan(100040));
    });

    test('timer interrupts and stopwatch run in sub CPU clock units', () {
      final cd = MdCdrom(bios());
      subProgram(cd);
      ByteData.sublistView(cd.programRam).setUint32(0x6c, 0x180);
      cd.programRam.setAll(0x180, [0x60, 0xfe]);
      cd.writeMain8(0xa12001, 1);
      cd.cpu.sr = 0x2000;
      cd.writeSub8(0xff8033, 8);
      cd.writeSub8(0xff8031, 1);
      cd.advance(400, 12500000);
      expect(cd.cpu.pc, 0x180);
      expect(cd.cpu.maskedIntLevel, 3);
      expect(cd.readSub16(0xff800c), 1);
      cd.writeSub8(0xff800d, 0);
      expect(cd.readSub16(0xff800c), 0);
    });

    test('Md schedules and exposes the sub CPU to the debugger', () {
      final md = Md(cdBoot: true)..setRom(bios());
      subProgram(md.cdrom!);
      md.busM68.write8(0xa12001, 1);
      bool executed = false;
      for (int i = 0; i < 500; i++) {
        final result = md.exec(false);
        expect(result.stopped, isFalse);
        executed |= result.executed(2);
      }
      expect(executed, isTrue);
      expect(md.cdrom!.cpu.d[0], 42);
      expect(md.read(2, 0x100), 0x70);
      expect(md.disasm(2, 0x100).$1, contains('moveq'));
      expect(md.trace(2).cycle, md.cdrom!.cpu.clocks);
      md.reset();
      expect(md.cdrom!.running, isFalse);
      expect(md.cdrom!.programRam[0x100], 0x70);
    });
  });

  group('CDD / CDC', () {
    test('reset and stop response packets remain latched across drive ticks',
        () {
      final drive = CdDrive((_) {}, () {})
        ..mount(FakeCdromDrive([Uint8List(2352)]))
        ..hostClock = true;
      expect(drive.response, [0, 0, 0, 0, 0, 0, 0, 0, 0, 15]);
      drive.tick();
      expect(drive.response[0], 0);
      command(drive, [1]);
      expect(drive.response[0], 0);
      drive.tick();
      expect(drive.response[0], 0);
      command(drive, [0]);
      expect(drive.response[0], 9);
    });

    test('playing in the lead-in reaches sector zero without skipping data',
        () {
      final disc = FakeCdromDrive([mode1Sector(Uint8List(2048), 0)]);
      final drive = CdDrive((_) {}, () {})
        ..mount(disc)
        ..hostClock = true;
      command(drive, [3, 0, 0, 0, 0, 1, 7, 3]); // absolute MSF 00:01:73
      expect(drive.lba, -2);
      finishSeek(drive);
      drive.tick();
      drive.tick();
      expect(disc.reads, isEmpty);
      drive.tick();
      expect(disc.reads, [150]);
    });

    test('pregap sectors reach the decoder with their headers', () {
      final received = <Uint8List>[];
      final drive = CdDrive(received.add, () {})
        ..mount(FakeCdromDrive([mode1Sector(Uint8List(2048), 0)]))
        ..hostClock = true;
      command(drive, [3, 0, 0, 0, 0, 1, 7, 3]); // absolute MSF 00:01:73
      finishSeek(drive);
      expect(received, isEmpty); // nothing before the host sees playing
      drive.tick();
      drive.tick();
      expect(received.map((s) => s.sublist(12, 16)), [
        [0, 1, 0x73, 1],
        [0, 1, 0x74, 1]
      ]);
    });

    test('TOC checksums, track queries and lead-in-aware data reads', () {
      final disc = FakeCdromDrive(
          List.generate(
              4, (i) => mode1Sector(Uint8List(2048)..[0] = i + 1, i)),
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

    test('tray commands expose open and closed states', () {
      final drive = CdDrive((_) {}, () {})
        ..mount(FakeCdromDrive([Uint8List(2352)]))
        ..hostClock = true;
      command(drive, [0xd]);
      expect(drive.status, 5);
      command(drive, [3, 0, 0, 0, 0, 2, 0, 0]);
      expect(drive.status, 5);
      command(drive, [0xc]);
      expect(drive.status, 9);
      expect(drive.response[0], 0);
      command(drive, [3, 0, 0, 0, 0, 2, 0, 0]);
      expect(drive.status, 2);
      finishSeek(drive);
      expect(drive.status, 1);
    });

    test('invalid packets and empty media never access tracks', () {
      final drive = CdDrive((_) => fail('unexpected sector'), () {});
      drive.hostClock = true;
      drive.command[0] = 3;
      drive.submit();
      expect(drive.status, 0xb);
      command(drive, [2, 0, 0, 5, 9, 9]);
      expect(drive.status, 0xb);
      expect(drive.sample(44100), (0, 0));
    });

    test('decoder exposes Mode 1 data via the correct host CPU', () {
      int interrupts = 0;
      final cdc = CdCdc(() => interrupts++, (_, __, ___) {});
      void write(int reg, int value) {
        cdc.register = reg;
        cdc.writeRegister(value);
      }

      write(1, 0x62);
      write(10, 0x84);
      final sector = mode1Sector(
          Uint8List(2048)..setAll(0, [0x12, 0x34, 0x56, 0x78]), 0);
      cdc.decode(sector);
      expect(cdc.header, [0, 2, 0, 1]);
      expect(interrupts, 1);
      // PT advanced by one raw sector; decoded data follows its four-byte header.
      write(2, 3);
      write(3, 0);
      write(4, (2352 + 4) & 255);
      write(5, (2352 + 4) >> 8);
      cdc.destination = 3;
      write(6, 0);
      expect(cdc.readHost(2), 0xffff);
      expect(cdc.readHost(3), 0x1234);
      expect(cdc.readHost(3), 0x5678);
      expect(cdc.transferEnd, isTrue);
      expect(interrupts, 2);
    });

    test('CDC status and transfer flags follow decoder and host reads', () {
      final cdc = CdCdc(() {}, (_, __, ___) {});
      int read(int reg) {
        cdc.register = reg;
        return cdc.readRegister();
      }
      void write(int reg, int value) {
        cdc.register = reg;
        cdc.writeRegister(value);
      }

      expect(read(0), 0xff);
      expect(cdc.register, 0);
      expect(read(15), 0x80);
      write(1, 0x42);
      write(10, 0x84);
      write(11, 0x08);
      expect(read(12), 0x80);
      expect(read(14), 0x08);
      cdc.decode(mode1Sector(Uint8List(2048), 0));
      expect(read(15), 0);
      expect(read(15), 0x80);
      expect(read(1) & 0x20, 0x20);

      write(2, 1);
      write(3, 0);
      write(4, 2352 & 255);
      write(5, 2352 >> 8);
      cdc.destination = 3;
      write(6, 0);
      expect(read(1) & 0x0a, 0);
      expect(cdc.dataReady, isTrue);
      cdc.readHost(3);
      expect(read(1) & 0x4a, 0x0a);
      expect(cdc.transferEnd, isTrue);
      write(7, 0);
      expect(read(1) & 0x40, 0x40);
    });

    test('DMA advances across an eight-byte PRG RAM address unit', () {
      final cd = MdCdrom(bios());
      final cdc = cd.cdc;
      void write(int reg, int value) {
        cdc.register = reg;
        cdc.writeRegister(value);
      }

      cdc.ram.setAll(0, List.generate(16, (i) => i + 1));
      write(1, 2);
      write(2, 15);
      write(3, 0);
      cdc.destination = 5;
      cdc.dmaAddress = 1;
      write(6, 0);
      for (int i = 0; i < 64; i++) {
        cdc.tick(1);
      }
      expect(cd.programRam.sublist(8, 24), List.generate(16, (i) => i + 1));
      expect(cdc.dmaAddress, 3);
      expect(cdc.transferEnd, isTrue);
    });

    test('CD-DA decodes signed stereo little-endian samples', () {
      final sector = Uint8List(2352);
      ByteData.sublistView(sector).setInt16(0, 16384, Endian.little);
      ByteData.sublistView(sector).setInt16(2, -16384, Endian.little);
      final drive = CdDrive((_) {}, () {})
        ..mount(FakeCdromDrive([sector], audioTracks: {1}))
        ..hostClock = true;
      command(drive, [3, 0, 0, 0, 0, 2, 0, 0]);
      finishSeek(drive);
      drive.tick();
      expect(drive.sample(44100), (0.5, -0.5));
      command(drive, [6]);
      expect(drive.sample(44100), (0, 0));
    });
  });

  test('RF5C164 banked waveform writes, panning and loop marker', () {
    final pcm = CdPcm();
    pcm.write(0xff000f, 0x80); // enabled, wave bank 0
    pcm.write(0xff2001, 0xc0); // +64
    pcm.write(0xff2003, 0xff); // loop
    pcm.write(0xff000f, 0xc0); // channel 0
    pcm.write(0xff0001, 255); // envelope
    pcm.write(0xff0003, 0x0f); // left only
    pcm.write(0xff0005, 0);
    pcm.write(0xff0007, 8); // step 1.0
    pcm.write(0xff0011, 0xfe); // channel 0 on
    final first = pcm.sample(CdPcm.sampleHz);
    expect(first.$1, greaterThan(0));
    expect(first.$2, 0);
    expect(pcm.sample(CdPcm.sampleHz).$1, first.$1);
    pcm.reset();
    expect(pcm.sample(CdPcm.sampleHz), (0, 0));
    expect(pcm.ram[0], 0xc0);
  });

  test('stamp conversion renders a tile and finishes with IRQ1', () {
    final cd = MdCdrom(bios());
    cd.writeMain8(0xa12003, 2);
    subProgram(cd);
    cd.writeMain8(0xa12001, 1);
    cd.cpu.sr = 0x2000;
    ByteData.sublistView(cd.programRam).setUint32(0x64, 0x180);
    cd.programRam.setAll(0x180, [0x60, 0xfe]);
    cd.writeSub8(0xff8033, 2);
    cd.wordRam.fillRange(128, 256, 0xaa); // stamp 1
    final data = ByteData.sublistView(cd.wordRam);
    data.setUint16(0x1000, 1); // map cell 0
    data.setUint16(0x2004, 0x0800); // dx = 1.0
    cd.bus.write16(0xff805a, 0x400); // map base 0x1000
    cd.bus.write16(0xff805e, 0xc00); // destination 0x3000
    cd.bus.write16(0xff8062, 8);
    cd.bus.write16(0xff8064, 1);
    cd.bus.write16(0xff8066, 0x800); // trace base 0x2000
    expect(cd.wordRam.sublist(0x3000, 0x3004), [0xaa, 0xaa, 0xaa, 0xaa]);
    expect(cd.bus.read16(0xff8058) & 0x8000, 0x8000);
    cd.advance(100, 12500000);
    expect(cd.bus.read16(0xff8064), 0);
    expect(cd.bus.read16(0xff8058) & 0x8000, 0);
    expect(cd.cpu.pc, 0x180);
  });
}
