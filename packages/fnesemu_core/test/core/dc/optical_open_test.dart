import 'package:fnesemu_core/src/cdrom_drive.dart';
import 'package:fnesemu_core/src/core/dc/bus.dart';
import 'package:fnesemu_core/src/core/dc/optical_drive.dart';
import 'package:test/test.dart';

import '../../support/manual_cdrom_drive.dart';

void packet(DcOpticalDrive chip, List<int> bytes) {
  chip.read(0x9c, 1);
  chip.write(0x90, 1, 10);
  chip.write(0x94, 1, 0);
  chip.write(0x9c, 1, 0xa0);
  chip.tickMasterClocks(80);
  final data = List.filled(12, 0)..setRange(0, bytes.length, bytes);
  for (var i = 0; i < 12; i += 2) {
    chip.write(0x80, 2, data[i] | data[i + 1] << 8);
  }
  chip.tickMasterClocks(80);
}

List<int> drain(DcOpticalDrive chip) {
  final count = chip.read(0x90, 1) | chip.read(0x94, 1) << 8;
  return [
    for (var i = 0; i < count; i += 2)
      ...() {
        final word = chip.read(0x80, 2);
        return [word & 255, if (i + 1 < count) word >> 8];
      }()
  ];
}

void initialize(DcOpticalDrive chip) {
  packet(chip, [0x13, 0, 0, 0, 10]);
  drain(chip);
}

void main() {
  for (final state in [
    CdromDriveState.ready,
    CdromDriveState.empty,
    CdromDriveState.loading,
    CdromDriveState.error
  ]) {
    test('CD_OPEN waits for manual lid opening from $state', () {
      final drive = ManualCdromDrive(1, state: state);
      final chip = DcOpticalDrive(onInterrupt: (_) {})..attach(drive);
      initialize(chip);
      packet(chip, [0x16]);
      expect(chip.status, 0x80);
      expect(chip.interrupt, isFalse);
      expect(chip.read(0x8c, 1), 0); // BUSY, cleared TOC format.
      expect(chip.read(0x90, 1), 0);
      expect(chip.read(0x94, 1), 0);
      chip.tickMasterClocks(200000000 * 1000);
      expect(chip.status, 0x80); // No synthetic opening or timeout completion.
      expect(chip.clocksToEvent, 0);
      expect(drive.state, state);
      drive.change(CdromDriveState.trayOpen);
      expect(chip.read(0x18, 1, sideEffects: false), 0x80);
      chip.prepare();
      expect(chip.status, 0x40);
      expect(chip.read(0x88, 1), 3);
      expect(chip.read(0x84, 1), 0);
      expect(chip.read(0x8c, 1), 6);
      expect(chip.interrupt, isTrue);
      chip.read(0x9c, 1);
      expect(chip.interrupt, isFalse);
      packet(chip, [0x14, 0, 0, 0, 0, 0x98, 1]);
      expect(chip.status & 1, 1); // Old TOC cannot be requested after opening.
    });
  }

  test('CD_OPEN stops audio immediately and invalidates device DMA staging',
      () {
    final drive = ManualCdromDrive(1, audio: true);
    final chip = DcOpticalDrive(onInterrupt: (_) {})..attach(drive);
    initialize(chip);
    packet(chip, [0x20, 1, 0, 0, 150, 0, 0, 0, 0, 0, 152]);
    expect(chip.audio.playing, isTrue);
    final epoch = chip.dmaEpoch;
    packet(chip, [0x16]);
    expect(chip.audio.playing, isFalse);
    expect(chip.audio.resumable, isFalse);
    expect(chip.sampleAudio(), (0, 0));
    expect(chip.dmaEpoch, greaterThan(epoch));
    expect(chip.dmaActive, isFalse);
    expect(chip.dmaAvailable, 0);
  });

  test('an already open lid completes without requesting a host transition',
      () {
    final drive = ManualCdromDrive(1, state: CdromDriveState.trayOpen);
    final chip = DcOpticalDrive(onInterrupt: (_) {})..attach(drive);
    packet(
        chip, [0x16]); // Opening is allowed even before unit attention clears.
    expect(chip.status, 0x40);
    expect(chip.interrupt, isTrue);
    expect(drive.generation, 1);
  });

  test(
      'soft reset cancels a manual-open wait and retains no delayed completion',
      () {
    final drive = ManualCdromDrive(1);
    final chip = DcOpticalDrive(onInterrupt: (_) {})..attach(drive);
    packet(chip, [0x16]);
    chip.write(0x9c, 1, 8);
    chip.tickMasterClocks(80);
    expect(chip.status, 0);
    expect(chip.interrupt, isFalse);
    drive.change(CdromDriveState.trayOpen);
    chip.prepare();
    expect(chip.status, 0x41); // Ordinary media attention, not CD_OPEN success.
    packet(chip, [0x13, 0, 0, 0, 10]);
    final sense = drain(chip);
    expect(sense[2], 6);
    expect(sense[8], 0x28);
  });

  test('replacement without an observed open state aborts with media attention',
      () {
    final drive = ManualCdromDrive(1);
    final chip = DcOpticalDrive(onInterrupt: (_) {})..attach(drive);
    packet(chip, [0x16]);
    drive.change(CdromDriveState.ready);
    chip.prepare();
    expect(chip.status, 0x41);
    expect(chip.read(0x84, 1), 0x60);
  });

  test('lid status change works without queued events and retains nIEN masking',
      () {
    final bus = DcBus(), drive = ManualCdromDrive(1);
    bus.opticalDrive.attach(drive);
    packet(bus.opticalDrive, [0x16]);
    bus.opticalDrive.write(0x18, 1, 2);
    drive.change(CdromDriveState.trayOpen, emit: false);
    bus.opticalDrive.prepare();
    expect(bus.opticalDrive.status, 0x40);
    expect(bus.systemBus.externalStatus & 1, 0);
    bus.opticalDrive.write(0x18, 1, 0);
    expect(bus.systemBus.externalStatus & 1, 1);
    bus.opticalDrive.read(0x9c, 1);
    expect(bus.systemBus.externalStatus & 1, 0);
  });
}
