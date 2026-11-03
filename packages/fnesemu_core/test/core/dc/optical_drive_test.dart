import 'dart:typed_data';

import 'package:fnesemu_core/src/cdrom_drive.dart';
import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/dc.dart';
import 'package:fnesemu_core/src/core/dc/disc.dart';
import 'package:fnesemu_core/src/core/dc/fault.dart';
import 'package:fnesemu_core/src/core/dc/optical_drive.dart';
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

  test('two-session audio then data reports the extended disc format', () {
    for (final choice in [
      (const {1}, const [CdromSession(1, 1, 0), CdromSession(2, 2, 1)], 0x20),
      (
        const <int>{},
        const [CdromSession(1, 1, 0), CdromSession(2, 2, 1)],
        0x10
      ),
      (const {1}, null, 0x10),
    ]) {
      core.setCdromDrive(FakeCdromDrive([sector(0), sector(1)],
          starts: const [0, 1], audioTracks: choice.$1, sessions: choice.$2));
      clearAttention();
      packet([0x10, 0, 0, 0, 10]);
      expect(drain()[1] & 0xf0, choice.$3);
    }
    core.setCdromDrive(FakeCdromDrive([sector(0), sector(1), sector(2)],
        starts: const [0, 1, 2],
        audioTracks: const {1},
        sessions: const [CdromSession(1, 1, 0), CdromSession(2, 2, 1)]));
    clearAttention();
    packet([0x10, 0, 0, 0, 10]);
    expect(drain()[1] & 0xf0, 0x10);
  });

  setUp(() {
    core = Dc();
    addTearDown(core.dispose);
    bus = core.bus;
  });

  test(
      'verified boot media exposes a persistent virtual data area without relocating sectors',
      () {
    core.setRom(Uint8List.fromList([9, 0, 0xfd, 0xaf, 9, 0]));
    bus.g1.bypassBiosVerification = true;
    final boot = sector(7)
      ..setRange(16, 16 + dcDiscSignature.length, dcDiscSignature.codeUnits);
    final drive = FakeCdromDrive([sector(0), boot, sector(42)],
        starts: const [0, 1],
        audioTracks: const {1},
        sessions: const [CdromSession(1, 1, 0), CdromSession(2, 2, 1)]);
    core.setCdromDrive(drive);
    clearAttention();
    // A title signature alone does not activate the profile: the guest must
    // read its boot header and explicitly request the virtual area.
    packet([0x14, 1, 0, 1, 0x98]);
    expect(drain(), isEmpty);
    expect(bus.read8(base + 0x18) & 1, 1);
    packet([0x30, 0x24, 0, 0, 151, 0, 0, 0, 0, 0, 1]);
    expect(drain(), boot.sublist(16, 2064));
    packet([0x10, 0, 0, 0, 10]);
    expect(drain()[1] & 0xf0, 0x20);
    packet([0x14, 1, 0, 1, 0x98], limit: 64);
    final toc = drain();
    expect(toc.length, 408);
    expect(toc.sublist(0, 4), everyElement(255));
    expect(toc.sublist(4, 8), [0x41, 0, 0, 151]);
    expect(toc.sublist(396), [0x41, 2, 0, 0, 0x41, 2, 0, 0, 0x41, 0, 0, 153]);
    final saved = core.saveState();
    core.reset();
    core.loadState(saved);
    // An ATA device reset retains the presentation of the attached image.
    bus.write8(base + 0x9c, 8);
    bus.tickMasterClocks(80);
    clearAttention();
    packet([0x10, 0, 0, 0, 10]);
    expect(drain()[1] & 0xf0, 0x80);
    packet([0x14, 0, 0, 1, 0x98]);
    final low = drain();
    expect(low.sublist(0, 4), [1, 0, 0, 150]);
    expect(low.sublist(4, 8), everyElement(255));
    packet([0x30, 0x24, 0, 0, 152, 0, 0, 0, 0, 0, 1]);
    expect(drain(), sector(42).sublist(16, 2064));
    expect(drive.reads.last, 152);
    drive.events.add(CdromDriveState.ready, drive.status.discId);
    bus.opticalDrive.prepare();
    clearAttention();
    packet([0x14, 1, 0, 1, 0x98]);
    expect(drain(), isEmpty);
    core.setCdromDrive(FakeCdromDrive([sector(0)]));
    clearAttention();
    packet([0x10, 0, 0, 0, 10]);
    expect(drain()[1] & 0xf0, 0x10);
    packet([0x14, 1, 0, 1, 0x98]);
    expect(drain(), isEmpty);
    expect(bus.read8(base + 0x18) & 1, 1);
  });

  test(
      'virtual data area requires both compatibility mode and a valid boot header',
      () {
    for (final compatibility in [false, true]) {
      bus.g1.bypassBiosVerification = compatibility;
      final boot = sector(1);
      if (!compatibility) {
        boot.setRange(
            16, 16 + dcDiscSignature.length, dcDiscSignature.codeUnits);
      }
      core.setCdromDrive(FakeCdromDrive([sector(0), boot],
          starts: const [0, 1],
          audioTracks: const {1},
          sessions: const [CdromSession(1, 1, 0), CdromSession(2, 2, 1)]));
      clearAttention();
      packet([0x30, 0x24, 0, 0, 151, 0, 0, 0, 0, 0, 1]);
      drain();
      packet([0x14, 1, 0, 1, 0x98]);
      expect(drain(), isEmpty);
      expect(bus.read8(base + 0x18) & 1, 1);
    }
  });

  test('virtual data area accepts a Form 1 boot header but not Form 2 data',
      () {
    bus.g1.bypassBiosVerification = true;
    for (final form2 in [false, true]) {
      final raw = Uint8List(2352)..[15] = 2;
      raw[18] = raw[22] = form2 ? 0x20 : 0;
      raw.setRange(24, 24 + dcDiscSignature.length, dcDiscSignature.codeUnits);
      core.setCdromDrive(FakeCdromDrive([sector(0), raw],
          starts: const [0, 1],
          audioTracks: const {1},
          sessions: const [CdromSession(1, 1, 0), CdromSession(2, 2, 1)]));
      clearAttention();
      packet([0x30, form2 ? 0x2a : 0x28, 0, 0, 151, 0, 0, 0, 0, 0, 1]);
      expect(drain(), raw.sublist(24, form2 ? 2348 : 2072));
      packet([0x14, 1, 0, 1, 0x98]);
      expect(drain().length, form2 ? 0 : 408);
    }
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
  });

  group('REQ_SES explicit session metadata', () {
    void mount(List<CdromSession>? sessions) {
      core.setCdromDrive(FakeCdromDrive(List.generate(6, (i) => sector(i)),
          starts: [0, 2, 4], sessions: sessions));
      clearAttention();
    }

  });

  group('CD_SCAN transport', () {
    setUp(() {
      core.setCdromDrive(FakeCdromDrive(List.generate(4, sector)));
      clearAttention();
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
