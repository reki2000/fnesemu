import 'dart:typed_data';

import 'package:cdrom_image/cdrom_image.dart';
import 'package:cdrom_image/memory.dart';
import 'package:fnesemu_core/src/cdrom.dart';
import 'package:test/test.dart';

import '../../tool/cdrom_drive.dart';

(DiscFile, Iterable<DiscFile>) source(String name) =>
    memoryDisc(name, {name: MemoryDiscFile(name, Uint8List(2352 * 10))});

List<CdromDriveEvent> drain(CdromDrive drive) {
  final events = <CdromDriveEvent>[];
  while (true) {
    final event = drive.takeEvent();
    if (event == null) return events;
    events.add(event);
  }
}

void main() {
  late SimpleCdromDrive drive;
  setUp(() async {
    drive = SimpleCdromDrive();
    await drive.insert(source('a.bin'));
    drive.clearEvents();
  });

  test('completed swap retains open, close and ready in order', () async {
    await drive.insert(source('b.bin'));
    expect(drive.status.isReady, true);
    final events = drain(drive);
    expect(events.map((e) => e.type), [
      CdromDriveEventType.trayOpened,
      CdromDriveEventType.trayClosed,
      CdromDriveEventType.discReady,
    ]);
    expect(events.last.discId, drive.status.discId);
    expect(drive.takeEvent(), isNull);
  });

  test('eject stays open and closing empty does not report a ready disc',
      () async {
    await drive.eject();
    expect(drain(drive).map((e) => e.type), [CdromDriveEventType.trayOpened]);
    await drive.insert();
    expect(drain(drive).map((e) => e.type), [CdromDriveEventType.trayClosed]);
    expect(drive.status.state, CdromDriveState.empty);
  });

  test('close is reported before asynchronous TOC completion', () async {
    await drive.eject();
    drive.clearEvents();
    final inserting = drive.insert(source('b.bin'));
    expect(drive.takeEvent()?.type, CdromDriveEventType.trayClosed);
    expect(drive.takeEvent(), isNull);
    await inserting;
    expect(drive.takeEvent()?.type, CdromDriveEventType.discReady);
  });

  test('failed TOC read does not synthesize another tray opening', () async {
    await drive.insert(memoryDisc('missing.cue', {
      'missing.cue': MemoryDiscFile(
          'missing.cue',
          Uint8List.fromList(
              'FILE "missing.bin" BINARY\n TRACK 01 MODE1/2352\n INDEX 01 00:00:00\n'
                  .codeUnits)),
    }));
    expect(drain(drive).map((e) => e.type), [
      CdromDriveEventType.trayOpened,
      CdromDriveEventType.trayClosed,
      CdromDriveEventType.discError,
    ]);
  });

  test('multiple paused swaps retain order and identify stale readiness',
      () async {
    await drive.insert(source('b.bin'));
    await drive.insert(source('c.bin'));
    final events = drain(drive);
    expect(events.length, 6);
    expect(events[2].discId, isNot(drive.status.discId));
    expect(events[5].discId, drive.status.discId);
  });

  test('reset discards past events and retains current status', () async {
    await drive.insert(source('b.bin'));
    drive.clearEvents();
    expect(drive.takeEvent(), isNull);
    expect(drive.status.isReady, true);
  });
}
