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

}
