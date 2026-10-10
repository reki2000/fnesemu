import 'dart:typed_data';

import 'package:fnesemu_core/core/cdrom_drive.dart';
import 'package:fnesemu_core/core/pce/component/cdrom.dart';
import 'package:fnesemu_core/core/pce/pce.dart';
import 'package:fnesemu_core/core/sram.dart';
import 'package:fnesemu_core/util/int.dart';
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

  test('Super CD RAM is writable and independent of CD and SGX work RAM', () {
    for (var bank = 0x68; bank <= 0x87; bank++) {
      pce.bus.write(bank * 8192, bank);
      pce.bus.write(bank * 8192 + 8191, bank ^ 255);
    }
    pce.bus.vpc.enabled = true;
    for (var bank = 0xf8; bank <= 0xfb; bank++) {
      pce.bus.write(bank * 8192, bank);
    }
    for (var bank = 0x68; bank <= 0x87; bank++) {
      expect(pce.bus.read(bank * 8192), bank);
      expect(pce.bus.read(bank * 8192 + 8191), bank ^ 255);
    }
    for (var bank = 0xf8; bank <= 0xfb; bank++) {
      expect(pce.bus.read(bank * 8192), bank);
    }
    expect(List.generate(4, (i) => pce.bus.read(io + 0x18c0 + i)),
        [0, 0xaa, 0x55, 3]);
    expect(pce.bus.read(io + 0x18c4), 255);
    expect(pce.bus.read(io + 0x1000) & 0x80, 0);
    pce.setCdromDrive(EmptyCdromDrive());
    expect(pce.bus.read(io + 0x18c1), 255);
    expect(pce.bus.read(io + 0x1000) & 0x80, 0x80);
    expect(pce.bus.read(0x68 * 8192), 255);
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

  test('CPU execution clocks the drive and delivers mixed audio buffers', () {
    final bios = Uint8List(0x40000)..fillRange(0, 0x40000, 0xea);
    bios.setRange(0, 4, [0x78, 0x4c, 0x01, 0xe0]); // SEI; JMP $E001
    bios[0x1ffe] = 0;
    bios[0x1fff] = 0xe0;
    pce.setRom(bios);
    var audioSamples = 0;
    pce.onAudio((audio) {
      expect(audio.channels, 2);
      audioSamples += audio.buffer.length;
    });
    command([8, 0, 0, 0, 1, 0]);
    while (pce.cpu.clocks < 21477270 ~/ 75 + 100) {
      expect(pce.exec(false).stopped, isFalse);
    }
    expect(cd.phase, CdPhase.data);
    expect(cd.read(0x1800), 0xc8);
    expect(disc.reads, [150]);
    expect(audioSamples, greaterThan(0));
  });

  test('IRQ2 mask releases and restores a pending CD interrupt', () {
    command([0, 0, 0, 0, 0, 0]);
    cd.write(0x1802, 0x20);
    expect(pce.cpu.holdIrq2, isTrue);
    pce.bus.pic.mask = 1;
    expect(pce.cpu.holdIrq2, isFalse);
    expect(pce.bus.pic.hold.mask1, 1);
    pce.bus.pic.mask = 0;
    expect(pce.cpu.holdIrq2, isTrue);
    finish();
    expect(pce.cpu.holdIrq2, isFalse);
  });

  test('TOC returns BCD tracks, lead-out and data/audio control', () {
    command([0xde, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    expect([cd.read(0x1808), cd.read(0x1808)], [1, 2]);
    finish();
    command([0xde, 2, 2, 0, 0, 0, 0, 0, 0, 0]);
    expect(List.generate(4, (_) => cd.read(0x1808)), [0, 2, 4, 0]);
    finish();
    command([0xde, 2, 0xaa, 0, 0, 0, 0, 0, 0, 0]);
    expect(List.generate(4, (_) => cd.read(0x1808)), [0, 2, 6, 0]);
    finish();
  });

  test('invalid reads report check condition and request sense clears error',
      () {
    command([8, 0, 0, 5, 2, 0]);
    finish(2);
    command([3, 0, 0, 0, 18, 0]);
    final sense = List.generate(18, (_) => cd.read(0x1808));
    expect(sense[2], 5);
    expect(sense[12], 0x21);
    finish();
    command([3, 0, 0, 0, 18, 0]);
    expect(List.generate(18, (_) => cd.read(0x1808))[2], 0);
    finish();
  });

  test('drive reset cancels pending read and permits another command', () {
    command([8, 0, 0, 0, 1, 0]);
    cd.write(0x1804, 2);
    cd.exec(21477270);
    expect(disc.reads, isEmpty);
    expect(cd.phase, CdPhase.idle);
    cd.write(0x1804, 0);
    command([0, 0, 0, 0, 0, 0]);
    finish();
  });

  test('ADPCM DMA transfers a sector, wraps address, clears DMA at completion',
      () {
    cd.write(0x1808, 0xfe);
    cd.write(0x1809, 0xff);
    cd.write(0x180d, 3); // latch write pointer
    command([8, 0, 0, 0, 1, 0]);
    cd.write(0x180b, 1);
    cd.exec(21477270 ~/ 75);
    cd.exec(33 * 2048);
    for (var i = 0; i < 2048; i++) {
      expect(cd.adpcmRam[(0xfffe + i).mask16], (150 + i).mask8);
    }
    expect(cd.read(0x180b).mask2, 0);
    finish();
  });

  test('ADPCM RAM reads lag one byte behind through the read buffer', () {
    for (var i = 0; i < 4; i++) {
      cd.adpcmRam[0x100 + i] = 0x10 + i;
    }
    cd.write(0x1808, 0x01);
    cd.write(0x1809, 0x01);
    cd.write(0x180d, 8); // latch read pointer at address - 1
    cd.write(0x180d, 0);
    int read() {
      final value = cd.read(0x180a);
      expect(cd.read(0x180c) & 0x80, 0x80); // busy until the buffer refills
      cd.exec(19 * 3);
      expect(cd.read(0x180c) & 0x80, 0);
      return value;
    }

    read(); // dummy read primes the buffer with ram[$100]
    expect([read(), read(), read()], [0x10, 0x11, 0x12]);
  });

  test('CD-DA plays stereo PCM and pause silences the output', () {
    command([0xd8, 1, 2, 0, 0, 0, 0, 0, 0, 0x80]);
    finish();
    final output = Float32List(20);
    cd.mixAudio(output, 44100);
    expect(output[0], closeTo(0.25, 0.00001));
    expect(output[1], closeTo(-0.25, 0.00001));
    expect(disc.reads, [154]);
    command([0xda, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    finish();
    final paused = Float32List(20);
    cd.mixAudio(paused, 44100);
    expect(paused.every((value) => value == 0), isTrue);
  });

  test('ADPCM playback decodes nibbles and raises end interrupt', () {
    cd.write(0x1808, 0);
    cd.write(0x1809, 0);
    cd.write(0x180d, 3);
    cd.write(0x180a, 0x77);
    cd.write(0x180d, 0);
    cd.write(0x180d, 12); // read address zero
    cd.write(0x1808, 1);
    cd.write(0x180d, 0x10); // length one
    cd.write(0x180e, 15);
    cd.write(0x1802, 8);
    cd.write(0x180d, 0x60);
    final output = Float32List(4);
    cd.mixAudio(output, 32087);
    expect(output[0], greaterThan(0));
    expect(cd.read(0x180c) & 9, 1);
    expect(pce.bus.pic.hold.mask1, 1);
  });
}
