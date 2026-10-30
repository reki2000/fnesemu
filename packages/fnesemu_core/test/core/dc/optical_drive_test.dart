import 'dart:typed_data';

import 'package:fnesemu_core/src/cdrom_drive.dart';
import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/sh4.dart';
import 'package:fnesemu_core/src/types.dart';
import 'package:fnesemu_core/src/util/uint8list.dart';
import 'package:test/test.dart';

import '../../support/cdda_fixture.dart';
import '../../support/fake_cdrom_drive.dart';
import '../../support/subcode_fixture.dart';

void main() {
  const base = 0xa05f7000;
  late Dc core;
  late DcBus bus;
  Uint8List sector(int seed) {
    final raw = Uint8List(2352);
    raw[15] = 1;
    for (var i = 0; i < 2048; i++) {
      raw[16 + i] = (i + seed) & 255;
    }
    return raw;
  }

  void packet(List<int> values, {int limit = 4096}) {
    final bytes = List<int>.filled(12, 0)..setRange(0, values.length, values);
    bus.read8(base + 0x9c);
    bus.write8(base + 0x84, 0);
    bus.write8(base + 0x90, limit & 255);
    bus.write8(base + 0x94, limit >> 8);
    bus.write8(base + 0x9c, 0xa0);
    expect(bus.read8(base + 0x18), 0x80);
    bus.tickMasterClocks(80);
    expect(bus.read8(base + 0x88), 1);
    expect(bus.read8(base + 0x18) & 8, 8);
    for (var i = 0; i < 12; i += 2) {
      bus.write16(base + 0x80, bytes[i] | bytes[i + 1] << 8);
    }
    bus.tickMasterClocks(80);
  }

  List<int> drain({List<int>? phases}) {
    final bytes = <int>[];
    for (var guard = 0; guard < 20000; guard++) {
      final status = bus.read8(base + 0x18);
      if (status & 0x80 != 0) {
        bus.tickMasterClocks(80);
        continue;
      }
      if (status & 8 == 0) return bytes;
      expect(bus.read8(base + 0x88), 2);
      bus.read8(base + 0x9c);
      final count = bus.read8(base + 0x90) | bus.read8(base + 0x94) << 8;
      expect(count, greaterThan(0));
      phases?.add(count);
      for (var i = 0; i < count; i += 2) {
        final word = bus.read16(base + 0x80);
        bytes.add(word & 255);
        if (i + 1 < count) bytes.add(word >> 8);
      }
    }
    fail('PIO transfer did not terminate');
  }

  void clearAttention() {
    packet([0x13, 0, 0, 0, 10]);
    drain();
  }

  setUp(() {
    core = Dc();
    bus = core.bus;
  });

  test(
      'task-file reset signature, mirrors, access widths and CPU reset ownership',
      () {
    expect(bus.read8(base + 0x18), 0);
    expect(bus.read8(base + 0x84), 1);
    expect(bus.read8(base + 0x88), 1);
    expect(bus.read8(base + 0x8c), 1);
    expect(bus.read8(base + 0x90), 0x14);
    expect(bus.read8(base + 0x94), 0xeb);
    for (final address in [0x005f7084, 0x025f7084, 0x805f7084, 0xa25f7084]) {
      expect(bus.read8(address), 1);
    }
    expect(() => bus.read16(base + 0x9c), throwsA(isA<DcUnsupported>()));
    expect(() => bus.read32(base + 0x80), throwsA(isA<DcUnsupported>()));
    expect(() => bus.read8(base + 0x80), throwsA(isA<DcUnsupported>()));
    expect(() => bus.read8(0xc05f7084), throwsA(isA<DcUnsupported>()));
    bus.write8(base + 0x98, 0xa0);
    Sh4(bus).reset(manual: true);
    expect(bus.read8(base + 0x98), 0xa0);
    core.reset();
    expect(bus.read8(base + 0x98), 0);
  });

  test('PIO mode response uses bounded DRQ phases and stable byte counts', () {
    packet([0x11, 0, 0, 0, 10], limit: 4);
    final phases = <int>[];
    expect(drain(phases: phases), [0, 0, 0, 0, 0, 180, 25, 0, 0, 8]);
    expect(phases, [4, 4, 2]);
    expect(bus.read8(base + 0x88), 3);
    expect(bus.read8(base + 0x18), 0x40);
  });

  test('alternate status and debugger peeks preserve IRQ and FIFO position',
      () {
    bus.systemBus.setExternal(8);
    bus.write32(0xa05f6914, 1);
    packet([0x11, 0, 4, 0, 2]);
    expect(bus.systemBus.externalStatus, 9);
    expect(bus.systemBus.irlPins, 13);
    expect(bus.read8(base + 0x18), 0x48);
    expect(bus.peek8(base + 0x9c), 0x48);
    expect(bus.cpuRead(base + 0x80, 2, peek: true), 0xb400);
    expect(bus.cpuRead(base + 0x80, 2, peek: true), 0xb400);
    expect(bus.systemBus.externalStatus, 9);
    bus.write8(base + 0x18, 2);
    expect(bus.systemBus.externalStatus, 8);
    bus.write8(base + 0x18, 0);
    expect(bus.systemBus.externalStatus, 9);
    bus.read8(base + 0x9c);
    expect(bus.systemBus.externalStatus, 8);
    expect(bus.read16(base + 0x80), 0xb400);
    expect(bus.systemBus.externalStatus,
        9); // Command completion is a new request.
    bus.read8(base + 0x9c);
    expect(bus.systemBus.externalStatus, 8);
  });

  test('odd allocation pads the final data word and zero allocation completes',
      () {
    packet([0x11, 0, 4, 0, 3]);
    expect(bus.read16(base + 0x80), 0xb400);
    expect(bus.read16(base + 0x80), 0x19);
    expect(bus.read8(base + 0x18), 0x40);
    packet([0x10, 0, 0, 0, 0], limit: 0);
    expect(bus.read8(base + 0x18), 0x40);
    expect(drain(), isEmpty);
  });

  test('FAD and binary MSF seek update position without reading sectors', () {
    final drive = _Drive([sector(1), sector(2), sector(3)]);
    core.setCdromDrive(drive);
    clearAttention();
    for (final command in [
      [0x21, 1, 0, 0, 152],
      [0x21, 2, 0, 2, 1],
    ]) {
      packet(command);
      expect(bus.read8(base + 0x18), 0x50);
      expect(bus.systemBus.externalStatus & 1, 1);
      packet([0x10, 0, 0, 0, 10]);
      final response = drain();
      expect(response[0], 1);
      expect(response.sublist(5, 8), [0, 0, command[1] == 1 ? 152 : 151]);
    }
    packet([0x21, 4]);
    packet([0x10, 0, 0, 0, 10]);
    expect(drain().sublist(5, 8), [0, 0, 151]);
    expect(drive.reads, isEmpty);
    expect(drive.seeks, [2, 1]);
  });

  test('invalid seeks preserve position and expose range or parameter sense',
      () {
    core.setCdromDrive(FakeCdromDrive([sector(1), sector(2)]));
    clearAttention();
    packet([0x21, 1, 0, 0, 151]);
    for (final command in [
      [0x21, 1, 0, 0, 149],
      [0x21, 1, 0, 0, 152],
      [0x21, 2, 0, 60, 0],
      [0x21, 2, 0, 2, 75],
      [0x21, 0],
    ]) {
      packet(command);
      expect(bus.read8(base + 0x18), 0x51);
      packet([0x13, 0, 0, 0, 10]);
      expect(drain()[8], command[1] == 1 ? 0x21 : 0x24);
      packet([0x10, 0, 0, 0, 10]);
      expect(drain().sublist(5, 8), [0, 0, 151]);
    }
  });

  test(
      'asynchronous seek waits for the adapter and reports completion or failure',
      () {
    final drive = _Drive([sector(1), sector(2)])..seeking = true;
    core.setCdromDrive(drive);
    clearAttention();
    packet([0x21, 1, 0, 0, 151]);
    expect(bus.read8(base + 0x18), 0x80);
    expect(bus.read8(base + 0x8c) & 15, 4);
    expect(bus.systemBus.externalStatus & 1, 0);
    bus.tickMasterClocks(10000);
    expect(bus.read8(base + 0x18), 0x80);
    drive.seeking = false;
    expect(bus.peek8(base + 0x18), 0x80);
    expect(bus.read8(base + 0x18), 0x50);
    packet([0x10, 0, 0, 0, 10]);
    expect(drain().sublist(5, 8), [0, 0, 151]);
    drive.seeking = true;
    packet([0x21, 1, 0, 0, 150]);
    drive.seeking = false;
    drive.seekError = true;
    bus.tickMasterClocks(1);
    expect(bus.read8(base + 0x18), 0x41);
    packet([0x13, 0, 0, 0, 10]);
    final sense = drain();
    expect(sense[2], 4);
    expect(sense[8], 0x15);
    packet([0x10, 0, 0, 0, 10]);
    expect(drain().sublist(5, 8), [0, 0, 151]);
  });

  test('reset and disc changes cancel an asynchronous seek', () {
    final drive = _Drive([sector(1), sector(2)])..seeking = true;
    core.setCdromDrive(drive);
    clearAttention();
    packet([0x21, 1, 0, 0, 151]);
    bus.write8(base + 0x9c, 8);
    bus.tickMasterClocks(80);
    drive.seeking = false;
    bus.tickMasterClocks(1);
    expect(bus.read8(base + 0x18), 0);
    clearAttention();
    drive.seeking = true;
    packet([0x21, 1, 0, 0, 151]);
    drive.discId++;
    bus.tickMasterClocks(1);
    expect(bus.read8(base + 0x18), 0x41);
    drive.seeking = false;
    packet([0x13, 0, 0, 0, 10]);
    expect(drain()[2], 6);
    packet([0x10, 0, 0, 0, 10]);
    expect(drain().sublist(5, 8), [0, 0, 150]);
  });

  test('CD_READ2 decodes its length and prefetch address in FAD and MSF', () {
    for (final msf in [false, true]) {
      final drive = _Drive([sector(3), sector(9), sector(17)]);
      core.setCdromDrive(drive);
      clearAttention();
      packet([
        0x31,
        msf ? 0x25 : 0x24,
        0,
        msf ? 2 : 0,
        msf ? 0 : 150,
        0,
        0,
        2,
        0,
        msf ? 2 : 0,
        msf ? 2 : 152
      ], limit: 510);
      expect(drain(),
          [...sector(3).sublist(16, 2064), ...sector(9).sublist(16, 2064)]);
      expect(drive.reads, [150, 151, 152]);
      packet([0x10, 0, 0, 0, 10]);
      expect(drain().sublist(5, 8), [0, 0, 151]);
    }
  });

  test('CD_READ2 validates prefetch bounds and ignores its speculative failure',
      () {
    final drive = _Drive([sector(5), sector(7)])..unreadableLba = 1;
    core.setCdromDrive(drive);
    clearAttention();
    for (final next in [149, 152]) {
      packet([0x31, 0x24, 0, 0, 150, 0, 0, 1, 0, 0, next]);
      expect(bus.read8(base + 0x18), 0x41);
      packet([0x13, 0, 0, 0, 10]);
      expect(drain()[8], 0x21);
    }
    packet([0x31, 0x25, 0, 2, 0, 0, 0, 1, 0, 2, 75]);
    packet([0x13, 0, 0, 0, 10]);
    expect(drain()[8], 0x24);
    expect(drive.reads, isEmpty);
    packet([0x31, 0x24, 0, 0, 150, 0, 0, 1, 0, 0, 151]);
    expect(drain(), sector(5).sublist(16, 2064));
    expect(bus.read8(base + 0x18), 0x50);
    packet([0x30, 0x24, 0, 0, 151, 0, 0, 0, 0, 0, 1]);
    expect(bus.read8(base + 0x18), 0x41);
    packet([0x13, 0, 0, 0, 10]);
    expect(drain()[8], 0x11);
  });

  test('CD_READ2 supports a 16-bit count and zero count performs no prefetch',
      () {
    final raw = sector(19);
    final drive = _Drive(List.filled(256, raw));
    core.setCdromDrive(drive);
    clearAttention();
    packet([0x31, 0x24, 0, 0, 150, 0, 0, 0, 0, 0, 150]);
    expect(drain(), isEmpty);
    expect(drive.reads, isEmpty);
    packet([0x31, 0x24, 0, 0, 150, 0, 1, 0, 0, 0, 150]);
    final bytes = drain();
    expect(bytes.length, 256 * 2048);
    expect(bytes.sublist(0, 2048), raw.sublist(16, 2064));
    expect(bytes.sublist(bytes.length - 2048), raw.sublist(16, 2064));
    expect(drive.reads, [...List.generate(256, (i) => 150 + i), 150]);
  });

  test('unknown ATA and packet commands report errors through REQ_ERROR', () {
    bus.write8(base + 0x9c, 0xff);
    bus.tickMasterClocks(80);
    expect(bus.read8(base + 0x84), 4);
    expect(bus.read8(base + 0x18), 0x41);
    packet([0xff]);
    expect(bus.read8(base + 0x84), 0x50);
    packet([0x13, 0, 0, 0, 10]);
    final sense = drain();
    expect(sense[0], 0xf0);
    expect(sense[2], 5);
    expect(sense.sublist(8), [0x20, 0]);
    packet([0x10, 0, 0, 0, 10]);
    expect(drain().first, 7);
    packet([0x13, 0, 0, 0, 10]);
    expect(drain()[2], 0);
  });

  test('unit attention is consumed once before no-disc not-ready response', () {
    packet([0]);
    expect(bus.read8(base + 0x84), 0x60);
    packet([0x13, 0, 0, 0, 10]);
    expect(drain()[8], 0x29);
    packet([0]);
    expect(bus.read8(base + 0x84), 0x20);
    packet([0x13, 0, 0, 0, 10]);
    expect(drain()[8], 0x3a);
  });

  test('GET_TOC returns primary-spec entries and leaves absent tracks all ones',
      () {
    core.setCdromDrive(FakeCdromDrive([sector(1), sector(2), sector(3)],
        starts: [0, 2], audioTracks: {2}));
    clearAttention();
    packet([0x14, 0, 0, 1, 0x98]);
    final toc = drain();
    expect(toc.length, 408);
    expect(toc.take(8), [0x41, 0, 0, 150, 1, 0, 0, 152]);
    expect(toc.sublist(8, 396), everyElement(255));
    expect(toc.sublist(396), [0x41, 1, 0, 0, 1, 2, 0, 0, 1, 0, 0, 153]);
  });

  test('CD_READ converts FAD to LBA and streams Mode 1 sectors', () {
    final drive = FakeCdromDrive([sector(3), sector(7), sector(11)]);
    core.setCdromDrive(drive);
    clearAttention();
    packet([0x30, 0x24, 0, 0, 150, 0, 0, 0, 0, 0, 2], limit: 1024);
    final phases = <int>[];
    expect(drain(phases: phases),
        [...sector(3).sublist(16, 2064), ...sector(7).sublist(16, 2064)]);
    expect(phases, [1024, 1024, 1024, 1024]);
    expect(drive.reads, [150, 151]);
    packet([0x10, 0, 0, 0, 10]);
    final status = drain();
    expect(status.take(5), [1, 0x10, 0x14, 1, 1]);
    expect(status.sublist(5, 8), [0, 0, 151]);
  });

  test('MSF addressing, raw audio reads and invalid FAD/type checks', () {
    final drive = FakeCdromDrive([sector(9), sector(17)],
        starts: [0, 1], audioTracks: {2});
    core.setCdromDrive(drive);
    clearAttention();
    packet([0x30, 0x25, 0, 2, 0, 0, 0, 0, 0, 0, 1]);
    expect(drain(), sector(9).sublist(16, 2064));
    packet([0x30, 0x22, 0, 0, 151, 0, 0, 0, 0, 0, 1]);
    expect(drain(), sector(17));
    packet([0x30, 0x24, 0, 0, 149, 0, 0, 0, 0, 0, 1]);
    expect(bus.read8(base + 0x84), 0x50);
    packet([0x13, 0, 0, 0, 10]);
    expect(drain()[8], 0x21);
    packet([0x30, 0x24, 0, 0, 151, 0, 0, 0, 0, 0, 1]);
    expect(bus.read8(base + 0x84), 0x50);
  });

  test(
      'sector arrival waits without DRQ, then resumes; failed reads report medium error',
      () {
    final drive = _Drive([sector(13)])..pending = true;
    core.setCdromDrive(drive);
    clearAttention();
    packet([0x30, 0x24, 0, 0, 150, 0, 0, 0, 0, 0, 1]);
    expect(bus.read8(base + 0x18), 0x80);
    bus.tickMasterClocks(200);
    expect(bus.read8(base + 0x18), 0x80);
    expect(bus.systemBus.externalStatus, 0);
    drive.pending = false;
    bus.tickMasterClocks(1);
    expect(drain(), sector(13).sublist(16, 2064));
    drive.failReads = true;
    packet([0x30, 0x24, 0, 0, 150, 0, 0, 0, 0, 0, 1]);
    expect(bus.read8(base + 0x84), 0x30);
  });

  test('media events cancel pending sectors and preserve generation isolation',
      () {
    final drive = _Drive([sector(13)])..pending = true;
    core.setCdromDrive(drive);
    clearAttention();
    packet([0x30, 0x24, 0, 0, 150, 0, 0, 0, 0, 0, 1]);
    drive.state = CdromDriveState.trayOpen;
    drive.discId++;
    drive.events.add(drive.state, drive.discId);
    bus.tickMasterClocks(1);
    expect(bus.read8(base + 0x18), 0x41);
    drive.pending = false;
    bus.tickMasterClocks(1000);
    expect(() => bus.read16(base + 0x80), throwsA(isA<DcUnsupported>()));
    packet([0x13, 0, 0, 0, 10]);
    expect(drain()[2], 6);
    packet([0x10, 0, 0, 0, 10]);
    expect(drain().first, 6);
  });

  test('SET_MODE accepts PIO output and validates before replacing parameters',
      () {
    packet([0x12, 0, 4, 0, 2]);
    expect(bus.read8(base + 0x88), 0);
    bus.read8(base + 0x9c);
    bus.write16(base + 0x80, 0x0201);
    packet([0x11, 0, 4, 0, 2]);
    expect(drain(), [1, 2]);
    packet([0x12, 0, 2, 0, 2]);
    bus.write16(base + 0x80, 9);
    expect(bus.read8(base + 0x84), 0x50);
    packet([0x11, 0, 2, 0, 4]);
    expect(drain(), [0, 0, 1, 2]);
  });

  test(
      'soft reset interrupts command phases, restores signature and preserves transfer modes',
      () {
    bus.write8(base + 0x84, 3);
    bus.write8(base + 0x88, 0x0c);
    bus.write8(base + 0x9c, 0xef);
    bus.tickMasterClocks(80);
    expect(bus.opticalDrive.pioTransferMode, 0x0c);
    bus.write8(base + 0x98, 0xa0);
    packet([0x11, 0, 0, 0, 10]);
    bus.write8(base + 0x9c, 8);
    expect(bus.read8(base + 0x18), 0x80);
    bus.tickMasterClocks(80);
    expect(bus.read8(base + 0x18), 0);
    expect(bus.read8(base + 0x94), 0xeb);
    expect(bus.read8(base + 0x98), 0xa0);
    expect(bus.opticalDrive.pioTransferMode, 0x0c);
    expect(bus.systemBus.externalStatus, 0);
  });

  test('data FIFO is a snapshot and stale ready events do not abort a transfer',
      () {
    final drive = _Drive([sector(13)]);
    core.setCdromDrive(drive);
    clearAttention();
    packet([0x30, 0x24, 0, 0, 150, 0, 0, 0, 0, 0, 1]);
    drive.sectors[0][16] = 99;
    drive.events.add(CdromDriveState.ready, 0);
    bus.tickMasterClocks(1);
    expect(drain().first, 13);
    drive.pending = true;
    packet([0x30, 0x24, 0, 0, 150, 0, 0, 0, 0, 0, 1]);
    drive.discId++;
    drive.events.add(CdromDriveState.ready, drive.discId);
    bus.tickMasterClocks(1);
    expect(bus.read8(base + 0x18), 0x41);
    expect(() => bus.read16(base + 0x80), throwsA(isA<DcUnsupported>()));
    clearAttention();
    drive.pending = false;
    packet([0x30, 0x24, 0, 0, 150, 0, 0, 0, 0, 0, 1]);
    expect(drain().first, 99);
  });

  test(
      'PIO output handles odd phase limits without inserting padding in parameters',
      () {
    packet([0x12, 0, 2, 0, 4], limit: 3);
    expect(bus.read8(base + 0x90), 3);
    bus.write16(base + 0x80, 2);
    bus.write16(base + 0x80, 0xff01); // High byte is not part of this phase.
    expect(bus.read8(base + 0x18), 0x80);
    bus.tickMasterClocks(80);
    expect(bus.read8(base + 0x90), 1);
    bus.write16(base + 0x80, 0xff23);
    packet([0x11, 0, 2, 0, 4]);
    expect(drain(), [2, 0, 1, 0x23]);
  });

  test(
      'new commands during PIO fail and device identify uses a distinct PIO response',
      () {
    packet([0x11, 0, 0, 0, 10]);
    bus.write8(base + 0x9c, 0xa1);
    expect(bus.read8(base + 0x84), 0x40);
    packet([0x13, 0, 0, 0, 10]);
    expect(drain()[8], 0x4e);
    bus.write8(base + 0x9c, 0xa1);
    bus.tickMasterClocks(80);
    final identify = drain();
    expect(identify.length, 80);
    expect(String.fromCharCodes(identify.sublist(16, 23)), 'fnesemu');
  });

  test(
      'invalid requests retain head position and unknown XA identity stops explicitly',
      () {
    core.setCdromDrive(FakeCdromDrive([sector(3)]));
    clearAttention();
    packet([0x30, 0x24, 0, 0, 149, 0, 0, 0, 0, 0, 1]);
    packet([0x10, 0, 0, 0, 10]);
    expect(drain().sublist(5, 8), [0, 0, 150]);
    final mode2 = sector(3)..[15] = 2;
    core.setCdromDrive(FakeCdromDrive([mode2]));
    clearAttention();
    expect(() => packet([0x30, 0x10, 0, 0, 150, 0, 0, 0, 0, 0, 1]),
        throwsA(isA<DcUnsupported>()));
  });

  test(
      'an I/O access observes media replacement before consuming old FIFO data',
      () {
    final drive = _Drive([sector(5)]);
    core.setCdromDrive(drive);
    clearAttention();
    packet([0x30, 0x24, 0, 0, 150, 0, 0, 0, 0, 0, 1]);
    drive.state = CdromDriveState.trayOpen;
    drive.discId++;
    drive.events.add(drive.state, drive.discId);
    // Debugger snapshots neither consume media events nor advance the FIFO.
    expect(bus.cpuRead(base + 0x80, 2, peek: true), 0x0605);
    expect(() => bus.read16(base + 0x80), throwsA(isA<DcUnsupported>()));
    expect(bus.read8(base + 0x84), 0x60);
  });

  test('a self-authored SH4 program issues a read packet and reads sector data',
      () {
    final ops = <int>[
      0x2100,
      ...List.filled(100, 9),
      for (var i = 0; i < 6; i++) ...[0x6245, 0x2321],
      ...List.filled(100, 9),
      0x6031,
      0x2502
    ];
    final program = Uint8List(0x80c);
    for (var i = 0; i < ops.length; i++) {
      program.setUint16LE(i * 2, ops[i]);
    }
    program
        .setRange(0x800, 0x80c, [0x30, 0x24, 0, 0, 150, 0, 0, 0, 0, 0, 1, 0]);
    core.setRom(program);
    core.setCdromDrive(FakeCdromDrive([sector(3)]));
    clearAttention();
    bus.write8(base + 0x90, 0);
    bus.write8(base + 0x94, 8);
    core.cpu.r[0] = 0xa0;
    core.cpu.r[1] = base + 0x9c;
    core.cpu.r[3] = base + 0x80;
    core.cpu.r[4] = 0x8c010800;
    core.cpu.r[5] = 0x8c020000;
    for (var i = 0; i < ops.length; i++) {
      expect(core.exec(false).stopped, isFalse, reason: core.stopReason);
    }
    expect(bus.ram.getUint32LE(0x20000), 0x0403);
  });
  group('Mode 2 sector extraction', () {
    Uint8List xa(bool form2) {
      final raw =
          Uint8List.fromList(List.generate(2352, (i) => (i * 7 + 3) & 255));
      raw[15] = 2;
      raw.setRange(16, 20, [1, 2, form2 ? 0x28 : 8, 0]);
      raw.setRange(20, 24, raw.sublist(16, 20));
      return raw;
    }

    void mount(List<Uint8List> sectors, {bool? isXa = true}) {
      core.setCdromDrive(FakeCdromDrive(sectors, isXa: isXa));
      clearAttention();
    }

    void readSector(int flags) =>
        packet([0x30, flags, 0, 0, 150, 0, 0, 0, 0, 0, 1]);

    test('Form 1 and Form 2 data omit subheaders and trailing check bytes', () {
      for (final form2 in [false, true]) {
        final raw = xa(form2);
        mount([raw]);
        readSector(form2 ? 0x2a : 0x28);
        expect(drain(), raw.sublist(24, form2 ? 2348 : 2072));
      }
    });
    test('all continuous XA field selections retain original byte order', () {
      final raw = xa(false);
      mount([raw]);
      for (final choice in [
        (0x28, 24, 2072),
        (0x48, 16, 24),
        (0x68, 16, 2072),
        (0x88, 12, 16),
        (0xc8, 12, 24),
        (0xe8, 12, 2072)
      ]) {
        readSector(choice.$1);
        expect(drain(), raw.sublist(choice.$2, choice.$3));
      }
    });
    test('raw Other selection returns every sector byte without reconstruction',
        () {
      final raw = xa(true);
      mount([raw]);
      readSector(0x1a);
      expect(drain(), raw);
    });
    test('any expected type follows each XA sector form in a mixed read', () {
      final first = xa(false), second = xa(true);
      mount([first, second]);
      packet([0x30, 0x20, 0, 0, 150, 0, 0, 0, 0, 0, 2], limit: 512);
      expect(
          drain(), [...first.sublist(24, 2072), ...second.sublist(24, 2348)]);
    });
    test(
        'mismatched forms, XA identity and noncontinuous selections report sense',
        () {
      for (final choice in [
        (false, true, 0x2a),
        (true, true, 0x28),
        (false, true, 0xa8),
        (false, false, 0x28),
        (false, true, 0x2c)
      ]) {
        mount([xa(choice.$1)], isXa: choice.$2);
        readSector(choice.$3);
        expect(bus.read8(base + 0x18) & 1, 1);
        packet([0x13, 0, 0, 0, 10]);
        final sense = drain();
        expect((sense[2], sense[8]), (5, 0x24));
      }
    });
    test('Mode 2 non-XA transfers all 2336 user bytes without a form check',
        () {
      final raw = xa(false);
      mount([raw], isXa: false);
      readSector(0x2c);
      expect(drain(), raw.sublist(16));
      raw[15] = 1;
      readSector(0xac);
      expect(drain(), raw.sublist(12));
    });
    test('ambiguous generic Mode 2 padding remains an explicit stop', () {
      mount([xa(false)]);
      expect(() => readSector(0x26), throwsA(isA<DcUnsupported>()));
      mount([xa(false)]);
      readSector(0x86);
      expect(drain(), xa(false).sublist(12, 16));
    });
    test(
        'generic Mode 2 Form 2 adds subheader and four deterministic dummy bytes',
        () {
      final raw = xa(true);
      mount([raw]);
      for (final flags in [0x26, 0x66, 0xa6, 0xe6]) {
        readSector(flags);
        expect(drain(),
            [...raw.sublist(flags & 0x80 != 0 ? 12 : 16, 2348), 0, 0, 0, 0]);
      }
    });
    test('unknown disc identity and contradictory subheaders are not guessed',
        () {
      mount([xa(false)], isXa: null);
      expect(() => readSector(0x28), throwsA(isA<DcUnsupported>()));
      final raw = xa(false)..[22] = 0x28;
      mount([raw]);
      expect(() => readSector(0x28), throwsA(isA<DcUnsupported>()));
    });
    test(
        'CD_READ2 applies the same XA extraction before its next-address prefetch',
        () {
      final raw = xa(false);
      final drive = FakeCdromDrive([raw, xa(true)], isXa: true);
      core.setCdromDrive(drive);
      clearAttention();
      packet([0x31, 0x28, 0, 0, 150, 0, 0, 1, 0, 0, 151]);
      expect(drain(), raw.sublist(24, 2072));
      expect(drive.reads, [150, 151]);
    });
  });

  group('REQ_SES explicit session metadata', () {
    void mount(List<CdromSession>? sessions) {
      core.setCdromDrive(FakeCdromDrive(List.generate(6, (i) => sector(i)),
          starts: [0, 2, 4], sessions: sessions));
      clearAttention();
    }

    test('session zero reports count and whole-disc lead-out FAD', () {
      mount(const [
        CdromSession(1, 1, 0),
        CdromSession(2, 2, 2),
        CdromSession(3, 3, 4)
      ]);
      packet([0x15, 0, 0, 0, 6]);
      expect(drain(), [1, 0, 3, 0, 0, 156]);
    });
    test('each specified session returns its first track and absolute FAD', () {
      mount(const [CdromSession(1, 1, 0), CdromSession(2, 3, 4)]);
      packet([0x15, 0, 1, 0, 6]);
      expect(drain(), [1, 0, 1, 0, 0, 150]);
      packet([0x15, 0, 2, 0, 6]);
      expect(drain(), [1, 0, 3, 0, 0, 154]);
    });
    test('allocation truncation and odd bounded PIO phases preserve bytes', () {
      mount(const [CdromSession(1, 1, 0)]);
      for (final length in [1, 3, 5, 6, 255]) {
        packet([0x15, 0, 0, 0, length], limit: 2);
        final phases = <int>[];
        expect(
            drain(phases: phases), [1, 0, 1, 0, 0, 156].take(length).toList());
        expect(phases.every((phase) => phase <= 2), isTrue);
      }
    });
    test('zero allocation completes without requiring unknown metadata', () {
      mount(null);
      packet([0x15, 0, 0, 0, 0]);
      expect(drain(), isEmpty);
      expect(bus.read8(base + 0x18) & 1, 0);
    });
    test('missing metadata is an explicit stop instead of an invented session',
        () {
      mount(null);
      expect(() => packet([0x15, 0, 1, 0, 6]), throwsA(isA<DcUnsupported>()));
    });
    test(
        'absent and out-of-range session numbers return illegal parameter sense',
        () {
      mount(const [CdromSession(1, 1, 0)]);
      for (final number in [2, 99, 100, 255]) {
        packet([0x15, 0, number, 0, 6]);
        expect(bus.read8(base + 0x18) & 1, 1);
        packet([0x13, 0, 0, 0, 10]);
        final sense = drain();
        expect(sense[2], 5);
        expect(sense[8], 0x24);
      }
    });
    test('inconsistent drive metadata is rejected before returning data', () {
      for (final sessions in <List<CdromSession>>[
        [],
        [const CdromSession(2, 1, 0)],
        [const CdromSession(1, 0, 0)],
        [const CdromSession(1, 1, -1)],
        [const CdromSession(1, 1, 6)],
        [const CdromSession(1, 1, 0), const CdromSession(2, 2, 3)],
        [const CdromSession(1, 1, 0), const CdromSession(2, 1, 0)],
      ]) {
        mount(sessions);
        expect(() => packet([0x15, 0, 0, 0, 6]), throwsA(isA<DcUnsupported>()));
      }
    });
    test('disc removal aborts a partially drained session response', () {
      final drive = _Drive(List.generate(6, (i) => sector(i)),
          sessions: const [CdromSession(1, 1, 0)]);
      core.setCdromDrive(drive);
      clearAttention();
      packet([0x15, 0, 1, 0, 6], limit: 2);
      expect(bus.read16(base + 0x80), 1);
      drive.state = CdromDriveState.trayOpen;
      drive.discId++;
      bus.tickMasterClocks(80);
      expect(bus.read8(base + 0x18) & 8, 0);
      expect(() => bus.read16(base + 0x80), throwsA(isA<DcUnsupported>()));
    });
  });
  test('CD_PLAY reaches AICA external stereo outputs and pause clears them',
      () {
    final raw = ByteData(2352);
    for (var i = 0; i < 588; i++) {
      raw.setInt16(i * 4, 16384, Endian.little);
      raw.setInt16(i * 4 + 2, -8192, Endian.little);
    }
    core.setCdromDrive(FakeCdromDrive(
        [raw.buffer.asUint8List(), raw.buffer.asUint8List()],
        audioTracks: {1}));
    clearAttention();
    bus.write32(0xa0702800, 15);
    bus.write32(0xa0702040, 0xf1f);
    bus.write32(0xa0702044, 0xf0f);
    packet([0x20, 1, 0, 0, 150, 0, 0, 0, 0, 0, 151]);
    expect(bus.opticalDrive.audio.playing, isTrue);
    expect(bus.read8(base + 0x8c) & 15, 3);
    final packets = <AudioBuffer>[];
    core.onAudio(packets.add);
    bus.tickMasterClocks((256 * 200000000 + 44099) ~/ 44100);
    final samples = packets.single.buffer;
    for (var i = 0; i < samples.length; i += 2) {
      expect(samples[i], 0.5);
      expect(samples[i + 1], -0.25);
    }
    packet([0x21, 4]);
    expect(bus.opticalDrive.audio.playing, isFalse);
    bus.tickMasterClocks(4536);
    expect(bus.aica.dsp.output(16), 0);
    expect(bus.aica.dsp.output(17), 0);
    packet([0x20, 7]);
    expect(bus.opticalDrive.audio.playing, isTrue);
    bus.tickMasterClocks(4536);
    expect(bus.aica.dsp.output(16), 16384);
    core.reset();
    expect(bus.opticalDrive.audio.playing, isFalse);
  });

  test('CD_PLAY rejects invalid ranges and resume without a saved range', () {
    core.setCdromDrive(FakeCdromDrive([sector(1), sector(2)]));
    clearAttention();
    for (final values in [
      [0x20, 7],
      [0x20, 1, 0, 0, 152],
      [0x20, 2, 0, 60, 0],
      [0x20, 1, 0, 0, 151, 0, 0, 0, 0, 0, 150],
    ]) {
      packet(values);
      expect(bus.read8(base + 0x18) & 1, 1);
      expect(bus.opticalDrive.audio.playing, isFalse);
    }
    packet([0x20, 2, 0, 2, 0]);
    expect(bus.opticalDrive.audio.playing, isTrue);
  });
  group('CD_SCAN transport', () {
    setUp(() {
      core.setCdromDrive(FakeCdromDrive(List.generate(4, sector)));
      clearAttention();
    });

    test('scan requires an existing play or play-pause range', () {
      packet([0x22, 0, 0, 0]);
      expect(bus.read8(base + 0x84) >> 4, 5);
      packet([0x21, 1, 0, 0, 151]);
      packet([0x22, 0, 0, 0]);
      expect(bus.read8(base + 0x84) >> 4, 5);
      packet([0x20, 1, 0, 0, 150]);
      packet([0x21, 3]);
      packet([0x22, 0, 0, 0]);
      expect(bus.read8(base + 0x84) >> 4, 5);
      expect(bus.read8(base + 0x8c) & 15, 2);
    });

    test('scan reports state five, current position and retained repeat count',
        () {
      packet([0x20, 1, 0, 0, 150, 0, 3, 0, 0, 0, 152]);
      packet([0x22, 0, 0, 0]);
      expect(bus.read8(base + 0x8c) & 15, 5);
      for (var i = 0; i < 294; i++) {
        bus.opticalDrive.sampleAudio();
      }
      packet([0x10, 0, 0, 0, 10]);
      final status = drain();
      expect(status[0], 5);
      expect(status[1], 0x13);
      expect(status.sublist(5, 8), [0, 0, 151]);
      packet([0x40, 1, 0, 0, 4]);
      expect(drain()[1], 0x11);
      packet([0x21, 4]);
      expect(bus.read8(base + 0x8c) & 15, 1);
      packet([0x40, 1, 0, 0, 4]);
      expect(drain()[1], 0x12);
      packet([0x20, 7]);
      expect(bus.read8(base + 0x8c) & 15, 3);
      expect(bus.opticalDrive.audio.scanning, isFalse);
    });

    test(
        'scan from a saved pause supports reverse direction and another scan command',
        () {
      packet([0x20, 1, 0, 0, 152]);
      packet([0x21, 4]);
      packet([0x22, 0, 1, 3]);
      expect(bus.read8(base + 0x8c) & 15, 5);
      for (var i = 0; i < 118; i++) {
        bus.opticalDrive.sampleAudio();
      }
      expect(bus.opticalDrive.audio.fad, 150);
      packet([0x22, 0, 0, 10]);
      expect(bus.read8(base + 0x8c) & 15, 5);
      for (var i = 0; i < 37; i++) {
        bus.opticalDrive.sampleAudio();
      }
      expect(bus.opticalDrive.audio.fad, 152);
    });

    test('resampled scan PCM reaches the AICA external stereo mixer', () {
      core.setCdromDrive(cddaRampDrive(3));
      clearAttention();
      bus.write32(0xa0702800, 15);
      bus.write32(0xa0702040, 0xf1f);
      bus.write32(0xa0702044, 0xf0f);
      packet([0x20, 1, 0, 0, 150]);
      packet([0x22, 0, 0, 0]);
      final packets = <AudioBuffer>[];
      core.onAudio(packets.add);
      bus.tickMasterClocks((256 * 200000000 + 44099) ~/ 44100);
      final output = packets.single.buffer;
      for (var frame = 0; frame < 256; frame++) {
        expect(output[frame * 2], frame * 2 / 32768);
        expect(output[frame * 2 + 1], -frame * 2 / 32768);
      }
    });

    test('scan is inhibited from automatic standby until it becomes paused',
        () {
      packet([0x12, 0, 4, 0, 2]);
      bus.write16(base + 0x80, 0x100);
      packet([0x20, 1, 0, 0, 150]);
      packet([0x22, 0, 0, 0]);
      bus.opticalDrive.tickMasterClocks(400000000);
      expect(bus.read8(base + 0x8c) & 15, 5);
      packet([0x21, 4]);
      bus.opticalDrive.tickMasterClocks(200000000);
      expect(bus.read8(base + 0x8c) & 15, 2);
    });

    test('seek, stop, read and fresh play clear the scan rate', () {
      for (final command in [
        [0x21, 1, 0, 0, 151],
        [0x21, 3],
        [0x30, 0x24, 0, 0, 150, 0, 0, 0, 0, 0, 1],
        [0x20, 1, 0, 0, 150],
      ]) {
        packet([0x20, 1, 0, 0, 150]);
        packet([0x22, 0, 0, 6]);
        packet(command);
        drain();
        expect(bus.opticalDrive.audio.scanning, isFalse);
      }
      packet([0x20, 1, 0, 0, 150]);
      packet([0x22, 0, 0, 6]);
      core.reset();
      expect(bus.opticalDrive.audio.scanning, isFalse);
    });
  });

  group('automatic standby', () {
    const second = 200000000;
    late _Drive drive;
    void timeout(int seconds) {
      packet([0x12, 0, 4, 0, 2]);
      bus.write16(base + 0x80, (seconds >> 8) | ((seconds & 255) << 8));
    }

    int state() => bus.read8(base + 0x8c) & 15;
    void advance(int clocks) => bus.opticalDrive.tickMasterClocks(clocks);

    setUp(() {
      drive = _Drive([sector(1), sector(2), sector(3)]);
      core.setCdromDrive(drive);
      clearAttention();
    });

    test(
        'default three-minute timer expires on its exact master-clock deadline',
        () {
      final deadline = bus.opticalDrive.clocksToEvent;
      expect(deadline, greaterThan(179 * second));
      expect(deadline, lessThanOrEqualTo(180 * second));
      advance(deadline - 1);
      expect(state(), 1);
      expect(bus.opticalDrive.clocksToEvent, 1);
      advance(1);
      expect(state(), 2);
      expect(bus.opticalDrive.clocksToEvent, 0);
    });

    test(
        'automatic home preserves task-file completion and emits no new interrupt',
        () {
      timeout(1);
      bus.read8(base + 0x9c);
      final before = bus.read8(base + 0x18);
      advance(second - 1);
      expect(state(), 1);
      advance(1);
      expect(state(), 2);
      expect(bus.read8(base + 0x18), before);
      expect(bus.systemBus.externalStatus & 1, 0);
      expect(drive.seeks, isEmpty);
      expect(drive.reads, isEmpty);
      packet([0x10, 0, 0, 0, 10]);
      final status = drain();
      expect(status[0], 2);
      expect(status.sublist(5, 8), [0, 0, 150]);
    });

    test(
        'zero disables timeout and the maximum unsigned period does not overflow',
        () {
      timeout(0);
      advance(65536 * second);
      expect(state(), 1);
      expect(bus.opticalDrive.clocksToEvent, 0);
      timeout(0xffff);
      expect(bus.opticalDrive.clocksToEvent, 65535 * second);
      advance(65535 * second - 1);
      expect(state(), 1);
      advance(1);
      expect(state(), 2);
    });

    test('pending sectors and a held PIO sector do not count as an idle pause',
        () {
      timeout(1);
      drive.pending = true;
      packet([0x30, 0x24, 0, 0, 150, 0, 0, 0, 0, 0, 1]);
      advance(2 * second);
      expect(state(), 1);
      expect(bus.read8(base + 0x18) & 0x80, 0x80);
      drive.pending = false;
      bus.opticalDrive.prepare();
      advance(2 * second);
      expect(bus.read8(base + 0x18) & 8, 8);
      expect(state(), 1);
      expect(drain().length, 2048);
      expect(bus.opticalDrive.clocksToEvent, second);
      advance(second);
      expect(state(), 2);
    });

    test(
        'seeking interrupts the pause interval and completion starts a fresh one',
        () {
      timeout(1);
      advance(second - 1000);
      drive.seeking = true;
      packet([0x21, 1, 0, 0, 151]);
      advance(2 * second);
      expect(state(), 4);
      drive.seeking = false;
      bus.opticalDrive.prepare();
      expect(state(), 1);
      expect(bus.opticalDrive.clocksToEvent, second);
      advance(second);
      expect(state(), 2);
    });

    test(
        'playing inhibits timeout and pause expiry discards the saved resume range',
        () {
      timeout(1);
      packet([0x20, 1, 0, 0, 150, 0, 15, 0, 0, 0, 151]);
      advance(2 * second);
      expect(state(), 3);
      packet([0x21, 4]);
      expect(bus.opticalDrive.audio.resumable, isTrue);
      expect(bus.opticalDrive.clocksToEvent, second);
      advance(second);
      expect(state(), 2);
      expect(bus.opticalDrive.audio.resumable, isFalse);
      expect(bus.opticalDrive.audio.status, 0x15);
    });

    test('an unrelated PIO response remains drainable across the deadline', () {
      timeout(1);
      packet([0x11, 0, 0, 0, 10]);
      final before = bus.read8(base + 0x18);
      advance(bus.opticalDrive.clocksToEvent);
      expect(state(), 2);
      expect(bus.read8(base + 0x18), before);
      expect(drain(), [0, 0, 0, 0, 0, 1, 0x19, 0, 0, 8]);
    });

    test(
        'changed timeout restarts counting and invalid mode writes preserve it',
        () {
      timeout(1);
      advance(second - 1000);
      packet([0x12, 0, 2, 0, 2]);
      bus.write16(base + 0x80, 8);
      expect(bus.read8(base + 0x84) >> 4, 5);
      expect(bus.opticalDrive.clocksToEvent, 840);
      timeout(2);
      expect(bus.opticalDrive.clocksToEvent, 2 * second);
      advance(2 * second - 1);
      expect(state(), 1);
      advance(1);
      expect(state(), 2);
    });

    test('the shared bus observes the idle timer deadline', () {
      timeout(1);
      advance(second - 7);
      bus.tickMasterClocks(6);
      expect(state(), 1);
      bus.tickMasterClocks(1);
      expect(state(), 2);
    });

    test(
        'media changes restart counting and reset restores the default interval',
        () {
      timeout(1);
      advance(second ~/ 2);
      drive.discId++;
      bus.opticalDrive.prepare();
      expect(bus.opticalDrive.clocksToEvent, second);
      bus.write8(base + 0x9c, 8);
      bus.tickMasterClocks(80);
      expect(bus.opticalDrive.clocksToEvent, 180 * second);
    });
  });

  group('stop/home and repeat status', () {
    late _Drive drive;
    List<int> status() {
      packet([0x10, 0, 0, 0, 10]);
      return drain();
    }

    setUp(() {
      drive = _Drive([sector(1), sector(2), sector(3)]);
      core.setCdromDrive(drive);
      clearAttention();
    });

    test(
        'stop returns home, enters standby and invalidates the saved play range',
        () {
      packet([0x20, 1, 0, 0, 151, 0, 3, 0, 0, 0, 152]);
      expect(bus.opticalDrive.audio.playing, isTrue);
      packet([0x21, 3, 255, 255, 255]);
      expect(bus.read8(base + 0x18), 0x50);
      expect(bus.read8(base + 0x8c) & 15, 2);
      expect(bus.opticalDrive.audio.playing, isFalse);
      expect(bus.opticalDrive.audio.resume(), isFalse);
      final result = status();
      expect(result[0], 2);
      expect(result[1], 0x10);
      expect(result.sublist(5, 8), [0, 0, 150]);
      expect(drive.seeks, [1, 0]);
      expect(drive.reads, isEmpty);
      packet([0x20, 7]);
      expect(bus.read8(base + 0x84) >> 4, 5);
      expect(bus.read8(base + 0x8c) & 15, 2);
    });

    test(
        'home seek holds busy until completion and debugger reads do not complete it',
        () {
      packet([0x21, 1, 0, 0, 152]);
      drive.seeking = true;
      packet([0x21, 3]);
      expect(bus.read8(base + 0x18), 0x80);
      expect(bus.read8(base + 0x8c) & 15, 4);
      bus.tickMasterClocks(10000);
      expect(bus.read8(base + 0x18), 0x80);
      drive.seeking = false;
      expect(bus.peek8(base + 0x18), 0x80);
      expect(bus.read8(base + 0x18), 0x50);
      final result = status();
      expect(result[0], 2);
      expect(result.sublist(5, 8), [0, 0, 150]);
    });

    test('home seek failures retain the previous head and do not enter standby',
        () {
      packet([0x21, 1, 0, 0, 152]);
      drive.seekError = true;
      packet([0x21, 3]);
      expect(bus.read8(base + 0x84) >> 4, 4);
      packet([0x13, 0, 0, 0, 10]);
      expect(drain()[8], 0x15);
      final result = status();
      expect(result[0], 1);
      expect(result.sublist(5, 8), [0, 0, 152]);
    });

    test('pause, ordinary seek, data read and new play leave standby', () {
      for (final command in [
        [0x21, 4],
        [0x21, 1, 0, 0, 151],
        [0x30, 0x24, 0, 0, 150, 0, 0, 0, 0, 0, 1],
        [0x20, 1, 0, 0, 150],
      ]) {
        packet([0x21, 3]);
        expect(bus.read8(base + 0x8c) & 15, 2);
        packet(command);
        drain();
        expect(bus.read8(base + 0x8c) & 15, command[0] == 0x20 ? 3 : 1);
      }
    });

    test(
        'ATA abort cancels home without turning a later ordinary seek into standby',
        () {
      drive.seeking = true;
      packet([0x21, 3]);
      bus.write8(base + 0x9c, 0);
      expect(bus.read8(base + 0x84) & 4, 4);
      drive.seeking = false;
      bus.tickMasterClocks(1);
      expect(bus.read8(base + 0x8c) & 15, 1);
      packet([0x21, 1, 0, 0, 151]);
      final result = status();
      expect(result[0], 1);
      expect(result.sublist(5, 8), [0, 0, 151]);
    });

    test('soft reset cancels an in-flight home operation and clears standby',
        () {
      drive.seeking = true;
      packet([0x21, 3]);
      bus.write8(base + 0x9c, 8);
      bus.tickMasterClocks(80);
      drive.seeking = false;
      bus.tickMasterClocks(1);
      expect(bus.read8(base + 0x18), 0);
      clearAttention();
      expect(status()[0], 1);
    });

    test('media changes cancel home and do not leak standby into the new disc',
        () {
      drive.seeking = true;
      packet([0x21, 3]);
      drive.discId++;
      bus.tickMasterClocks(1);
      expect(bus.read8(base + 0x18) & 1, 1);
      drive.seeking = false;
      clearAttention();
      expect(status()[0], 1);
      packet([0x21, 3]);
      expect(status()[0], 2);
      drive.discId++;
      bus.tickMasterClocks(1);
      clearAttention();
      expect(status()[0], 1);
    });

    test('REQ_STAT reports remaining repeat cycles in the format low nibble',
        () {
      packet([0x20, 1, 0, 0, 150, 0, 2, 0, 0, 0, 151]);
      expect(status()[1], 0x12);
      packet([0x21, 4]);
      expect(status()[1], 0x12);
      bus.opticalDrive.audio.resume();
      for (var i = 0; i < 588; i++) {
        bus.opticalDrive.sampleAudio();
      }
      expect(status()[1], 0x11);
      for (var i = 0; i < 588; i++) {
        bus.opticalDrive.sampleAudio();
      }
      expect(status()[1], 0x10);
      packet([0x21, 3]);
      expect(status()[1], 0x10);
      packet([0x20, 1, 0, 0, 150, 0, 15, 0, 0, 0, 151]);
      expect(status()[1], 0x1f);
    });
  });

  group('CD_SCD explicit subchannels', () {
    CdromSubcode metadata() => CdromSubcode(
        raw: Uint8List.fromList(List.generate(96, (i) => i ^ 0xa5)),
        position: const CdromSubcodePosition(
            control: 4, track: 2, index: 3, trackFrames: 0x123456));

    late _SubcodeDrive drive;
    setUp(() {
      drive = _SubcodeDrive([sector(1), sector(2)])..subcode = metadata();
      core.setCdromDrive(drive);
      clearAttention();
    });

    test(
        'Q response preserves explicit index, control and binary frame positions',
        () {
      packet([0x40, 1, 0, 0, 14]);
      expect(drain(),
          [0, 0x15, 0, 14, 0x41, 2, 3, 0x12, 0x34, 0x56, 0, 0, 0, 150]);
      expect(drive.subcodeReads, [0]);
    });

    test('raw P-W bytes cross odd bounded PIO phases unchanged', () {
      final phases = <int>[];
      packet([0x40, 0, 0, 0, 100], limit: 7);
      expect(drain(phases: phases), [0, 0x15, 0, 100, ...metadata().raw!]);
      expect(phases.first, 7);
      expect(phases.last, 2);
      packet([0x40, 0, 0, 0, 9]);
      expect(drain(), [0, 0x15, 0, 100, ...metadata().raw!.take(5)]);
    });

    test('zero and header-only allocations do not require provider metadata',
        () {
      core.setCdromDrive(FakeCdromDrive([sector(1)]));
      clearAttention();
      packet([0x40, 1]);
      expect(drain(), isEmpty);
      packet([0x40, 1, 0, 0, 4]);
      expect(drain(), [0, 0x15, 0, 14]);
      packet([0x40, 0, 0, 0, 3]);
      expect(drain(), [0, 0x15, 0]);
    });

    test('missing capability stops explicitly instead of inventing Q indexes',
        () {
      core.setCdromDrive(FakeCdromDrive([sector(1)]));
      clearAttention();
      expect(() => packet([0x40, 1, 0, 0, 14]), throwsA(isA<DcUnsupported>()));
    });

    test('pending provider retains command position until the metadata arrives',
        () {
      drive.subcodePending = true;
      packet([0x40, 1, 0, 0, 14]);
      expect(bus.read8(base + 0x18) & 0x80, 0x80);
      bus.tickMasterClocks(10000);
      expect(bus.read8(base + 0x18) & 8, 0);
      drive.subcodePending = false;
      bus.tickMasterClocks(1);
      expect(drain().last, 150);
      expect(drive.subcodeReads, everyElement(0));
    });

    test('media changes discard a pending subchannel response', () {
      drive.subcodePending = true;
      packet([0x40, 1, 0, 0, 14]);
      final reads = drive.subcodeReads.length;
      drive.state = CdromDriveState.trayOpen;
      drive.discId++;
      bus.tickMasterClocks(1);
      drive.subcodePending = false;
      bus.tickMasterClocks(1000);
      expect(bus.read8(base + 0x18) & 1, 1);
      expect(drive.subcodeReads.length, reads);
    });

    test('unreadable subchannels produce medium-error sense', () {
      drive.subcode = const CdromSubcode(readable: false);
      packet([0x40, 1, 0, 0, 14]);
      expect(bus.read8(base + 0x84) >> 4, 3);
      packet([0x13, 0, 0, 0, 10]);
      expect(drain()[8], 0x11);
    });

    test('invalid metadata stops before consuming the end status', () {
      final audio = bus.opticalDrive.audio..start(150, 151, 0);
      for (var i = 0; i < 588; i++) {
        audio.sample(drive);
      }
      drive.subcode = const CdromSubcode();
      expect(() => packet([0x40, 1, 0, 0, 14]), throwsA(isA<DcUnsupported>()));
      expect(audio.status, 0x13);
      drive.subcode = metadata();
      bus.tickMasterClocks(1);
      expect(drain()[1], 0x13);
      expect(audio.status, 0x15);
    });

    test('play, pause, completion and one-shot status are exposed in headers',
        () {
      final audio = bus.opticalDrive.audio..start(150, 151, 0);
      packet([0x40, 1, 0, 0, 4]);
      expect(drain()[1], 0x11);
      packet([0x21, 4]);
      packet([0x40, 1, 0, 0, 4]);
      expect(drain()[1], 0x12);
      audio.resume();
      for (var i = 0; i < 588; i++) {
        audio.sample(drive);
      }
      packet([0x40, 1, 0, 0, 1]);
      expect(drain(), [0]);
      expect(audio.status, 0x13);
      packet([0x40, 1, 0, 0, 4]);
      expect(drain()[1], 0x13);
      packet([0x40, 1, 0, 0, 4]);
      expect(drain()[1], 0x15);
    });

    test('an initial playback seek error exposes one abnormal completion', () {
      drive.seekError = true;
      packet([0x20, 1, 0, 0, 150]);
      expect(bus.read8(base + 0x84) >> 4, 4);
      expect(bus.opticalDrive.audio.playing, isFalse);
      packet([0x40, 1, 0, 0, 4]);
      expect(drain()[1], 0x14);
      packet([0x40, 1, 0, 0, 4]);
      expect(drain()[1], 0x15);
    });

    test(
        'raw-only Q records supply actual absolute position rather than request FAD',
        () {
      drive.subcode = CdromSubcode(
          raw: packedSubcode(
              [0x61, 0x07, 0x03, 0, 0x12, 0x34, 0, 0x01, 0x23, 0x45]));
      packet([0x40, 1, 0, 0, 14]);
      expect(drain(), [0, 0x15, 0, 14, 0x61, 7, 3, 0, 3, 166, 0, 0, 24, 126]);
      expect(drive.subcodeReads, [0]);
    });

    test('raw-only catalog records decode digits and their recorded frame', () {
      drive.subcode = CdromSubcode(
          raw: packedSubcode(
              [0x02, 0x12, 0x34, 0x56, 0x78, 0x90, 0x12, 0x30, 0, 0x74]));
      packet([0x40, 2, 0, 0, 24]);
      expect(drain(), [
        0,
        0x15,
        0,
        24,
        2,
        0,
        0,
        0,
        0x80,
        ...'1234567890123'.codeUnits,
        0,
        74
      ]);
    });

    test('bad Q CRC preserves raw data but cannot fabricate a position', () {
      final raw = packedSubcode([0x41, 1, 1, 0, 0, 0, 0, 0, 2, 0])
        ..[95] ^= 0x40;
      drive.subcode = CdromSubcode(raw: raw);
      packet([0x40, 0, 0, 0, 100]);
      expect(drain(), [0, 0x15, 0, 100, ...raw]);
      expect(() => packet([0x40, 1, 0, 0, 14]), throwsA(isA<DcUnsupported>()));
    });

    test('explicit cached position may accompany an ADR=2 raw record', () {
      drive.subcode = CdromSubcode(
          raw: packedSubcode(
              [0x02, 0x12, 0x34, 0x56, 0x78, 0x90, 0x12, 0x30, 0, 0x74]),
          position: const CdromSubcodePosition(
              control: 6, track: 1, index: 2, trackFrames: 5, discFrames: 777));
      packet([0x40, 1, 0, 0, 14]);
      expect(drain(), [0, 0x15, 0, 14, 0x61, 1, 2, 0, 0, 5, 0, 0, 3, 9]);
    });

    test('out-of-range explicit absolute positions and short raw records stop',
        () {
      for (final absolute in [-1, 0x1000000]) {
        drive.subcode = CdromSubcode(
            position: CdromSubcodePosition(
                control: 4,
                track: 1,
                index: 1,
                trackFrames: 0,
                discFrames: absolute));
        expect(
            () => packet([0x40, 1, 0, 0, 14]), throwsA(isA<DcUnsupported>()));
      }
      for (final format in [1, 2]) {
        drive.subcode = CdromSubcode(raw: Uint8List(12));
        expect(() => packet([0x40, format, 0, 0, 24]),
            throwsA(isA<DcUnsupported>()));
      }
    });

    test('reserved subcode formats are illegal parameters', () {
      for (var format = 4; format < 16; format++) {
        packet([0x40, format, 0, 0, 24]);
        expect(bus.read8(base + 0x84) >> 4, 5);
      }
    });

    test('MCN response preserves ASCII digits and the identifier record frame',
        () {
      drive.subcode = const CdromSubcode(
          catalog: CdromSubcodeIdentifier('1234567890123', frame: 74));
      packet([0x40, 2, 0, 0, 24]);
      expect(drain(), [
        0,
        0x15,
        0,
        24,
        2,
        0,
        0,
        0,
        0x80,
        ...'1234567890123'.codeUnits,
        0,
        74
      ]);
    });

    test('raw-only ISRC records decode into the SPI recording response', () {
      drive.subcode = CdromSubcode(
          raw: packedSubcode(isrcPayload('US1AZ9912345', frame: 56)));
      packet([0x40, 3, 0, 0, 24]);
      expect(drain(), [
        0,
        0x15,
        0,
        24,
        3,
        0,
        0,
        0,
        0x80,
        ...'US1AZ9912345'.codeUnits,
        0,
        56,
        0
      ]);
    });

    test(
        'raw zero ISRC clears validity but RID records remain unsupported metadata',
        () {
      drive.subcode =
          CdromSubcode(raw: packedSubcode(isrcPayload('', frame: 9)));
      packet([0x40, 3, 0, 0, 24]);
      final absent = drain();
      expect(absent[8], 0);
      expect(absent.sublist(9, 21), everyElement(0x30));
      expect(absent[22], 9);
      drive.subcode = CdromSubcode(
          raw: packedSubcode(isrcPayload('US1AZ9912345', selector: 3)));
      expect(() => packet([0x40, 3, 0, 0, 24]), throwsA(isA<DcUnsupported>()));
    });

    test(
        'explicit cached recording metadata takes precedence over a raw record',
        () {
      drive.subcode = CdromSubcode(
          raw: packedSubcode(isrcPayload('US1AZ9912345', frame: 56)),
          recording: const CdromSubcodeIdentifier('JPABC0012345', frame: 7));
      packet([0x40, 3, 0, 0, 24]);
      expect(drain(), [
        0,
        0x15,
        0,
        24,
        3,
        0,
        0,
        0,
        0x80,
        ...'JPABC0012345'.codeUnits,
        0,
        7,
        0
      ]);
    });

    test('ISRC response follows the detailed table including binary Aframe',
        () {
      drive.subcode = const CdromSubcode(
          recording: CdromSubcodeIdentifier('US1AZ9912345', frame: 37));
      packet([0x40, 3, 0, 0, 24]);
      expect(drain(), [
        0,
        0x15,
        0,
        24,
        3,
        0,
        0,
        0,
        0x80,
        ...'US1AZ9912345'.codeUnits,
        0,
        37,
        0
      ]);
    });

    test(
        'explicitly absent identifiers clear validity without inventing a code',
        () {
      drive.subcode = const CdromSubcode(
          catalog: CdromSubcodeIdentifier('', frame: 0),
          recording: CdromSubcodeIdentifier('', frame: 0));
      for (final format in [2, 3]) {
        packet([0x40, format, 0, 0, 24]);
        final response = drain();
        expect(response[8], 0);
        expect(response.sublist(9, format == 2 ? 22 : 21), everyElement(0x30));
      }
      drive.subcode = const CdromSubcode(
          catalog: CdromSubcodeIdentifier('0000000000000', frame: 1));
      packet([0x40, 2, 0, 0, 24]);
      expect(drain()[8], 0);
    });

    test(
        'identifier allocation truncation retains the full length and odd phases',
        () {
      drive.subcode = const CdromSubcode(
          catalog: CdromSubcodeIdentifier('9876543210987', frame: 50));
      final phases = <int>[];
      packet([0x40, 2, 0, 0, 13], limit: 5);
      expect(drain(phases: phases),
          [0, 0x15, 0, 24, 2, 0, 0, 0, 0x80, ...'9876'.codeUnits]);
      expect(phases, [5, 5, 3]);
    });

    test('identifier headers do not require an optional subcode adapter', () {
      core.setCdromDrive(FakeCdromDrive([sector(1)]));
      clearAttention();
      for (final format in [2, 3]) {
        packet([0x40, format, 0, 0, 4]);
        expect(drain(), [0, 0x15, 0, 24]);
        packet([0x40, format]);
        expect(drain(), isEmpty);
      }
    });

    test(
        'unknown identifiers stay distinct from an explicit not-detected result',
        () {
      for (final format in [2, 3]) {
        drive.subcode = const CdromSubcode();
        expect(() => packet([0x40, format, 0, 0, 24]),
            throwsA(isA<DcUnsupported>()));
      }
    });

    test('malformed identifiers and out-of-range frames stop before output',
        () {
      for (final value in [
        '123',
        '123456789012A',
        '12345678901234',
        '1234567890123\n'
      ]) {
        drive.subcode =
            CdromSubcode(catalog: CdromSubcodeIdentifier(value, frame: 0));
        expect(
            () => packet([0x40, 2, 0, 0, 24]), throwsA(isA<DcUnsupported>()));
      }
      for (final value in ['us1AZ9912345', 'US1AZ991234X', 'US-1AZ-99-12345']) {
        drive.subcode =
            CdromSubcode(recording: CdromSubcodeIdentifier(value, frame: 0));
        expect(
            () => packet([0x40, 3, 0, 0, 24]), throwsA(isA<DcUnsupported>()));
      }
      for (final frame in [-1, 75]) {
        drive.subcode = CdromSubcode(
            catalog: CdromSubcodeIdentifier('1234567890123', frame: frame));
        expect(
            () => packet([0x40, 2, 0, 0, 24]), throwsA(isA<DcUnsupported>()));
      }
    });
  });
}

class _Drive extends FakeCdromDrive {
  _Drive(super.sectors, {super.sessions});
  bool pending = false, failReads = false;
  bool seeking = false, seekError = false;
  int unreadableLba = -1;
  final seeks = <int>[];
  @override
  void seek(int lba) => seeks.add(lba);
  int discId = 1;
  CdromDriveState state = CdromDriveState.ready;
  @override
  CdromDriveStatus get status => CdromDriveStatus(state, discId, toc,
      isSeeking: seeking, seekError: seekError);
  @override
  Uint8List? read(int lba) => pending
      ? null
      : failReads || lba == unreadableLba
          ? Uint8List(0)
          : super.read(lba);
}

class _SubcodeDrive extends _Drive implements CdromSubcodeDrive {
  _SubcodeDrive(super.sectors);
  CdromSubcode subcode = const CdromSubcode();
  bool subcodePending = false;
  final subcodeReads = <int>[];

  @override
  CdromSubcode? readSubcode(int lba) {
    subcodeReads.add(lba);
    return subcodePending ? null : subcode;
  }
}
