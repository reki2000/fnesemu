import 'dart:typed_data';

import 'package:fnesemu/cdrom/async_cdrom_drive.dart';
import 'package:fnesemu/cdrom/image_file.dart';
import 'package:fnesemu/core/disc_swap.dart';
import 'package:test/test.dart';

MemoryDiscSource source(String name) => MemoryDiscSource(
    name, {name: MemoryImageFile(name, Uint8List(2352 * 10))});

void main() {
  late AsyncCdromDrive drive;
  late List<String> events;
  late DiscSwapWatcher watcher;

  setUp(() async {
    drive = AsyncCdromDrive();
    await drive.eject(source("a.bin"));
    events = [];
    watcher = DiscSwapWatcher(100,
        onRemoved: () => events.add("removed"),
        onInserted: () => events.add("inserted"))
      ..attach(drive);
  });

  test('the disc at attach is not reported', () {
    watcher.poll(1000);
    expect(events, isEmpty);
  });

  test('a swap finished before the next poll is seen as removed then inserted',
      () async {
    await drive.eject(source("b.bin")); // trayOpen..ready within one frame
    expect(drive.status.isReady, true);

    watcher.poll(10);
    expect(events, ["removed"]); // kept open for the hold time
    watcher.poll(50);
    expect(events, ["removed"]);
    watcher.poll(50);
    expect(events, ["removed", "inserted"]);
    watcher.poll(1000);
    expect(events, ["removed", "inserted"]);
  });

  test('eject without a disc stays removed; the next insert is reported',
      () async {
    await drive.eject();
    watcher.poll(1000);
    expect(events, ["removed"]);

    await drive.eject(source("c.bin"));
    watcher.poll(1000);
    expect(events, ["removed", "inserted"]);
  });

  test('inserted waits for the drive to be ready', () async {
    final ejecting = drive.eject(source("b.bin"));
    watcher.poll(1000);
    expect(events, ["removed"]); // tray open / loading
    await ejecting;
    watcher.poll(1);
    expect(events, ["removed", "inserted"]);
  });

  test('sync takes the current disc as the initial one', () async {
    await drive.eject(source("b.bin"));
    watcher.sync();
    watcher.poll(1000);
    expect(events, isEmpty);
  });
}
