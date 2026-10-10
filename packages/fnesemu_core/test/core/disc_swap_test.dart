import 'dart:typed_data';

import 'package:cdrom_image/cdrom_image.dart';
import 'package:cdrom_image/memory.dart';
import 'package:fnesemu_core/core/disc_swap.dart';
import 'package:test/test.dart';

import '../../tool/cdrom_drive.dart';

DiscSource source(String name) => memoryDisc(
    name, {name: MemoryDiscFile(name, Uint8List(2352 * 10))});

void main() {
  late SimpleCdromDrive drive;
  late List<String> events;
  late DiscSwapWatcher watcher;

  setUp(() async {
    drive = SimpleCdromDrive();
    await drive.insert(source("a.bin"));
    events = [];
    watcher = DiscSwapWatcher(100,
        onTrayOpen: () => events.add("open"),
        onInserted: () => events.add("inserted"),
        onClosedEmpty: () => events.add("empty"))
      ..attach(drive);
  });

  test('the state at attach is not reported', () {
    watcher.poll(1000);
    expect(events, isEmpty);
  });

  test('a swap finished before the next poll is seen as open then inserted',
      () async {
    await drive.insert(source("b.bin")); // trayOpen..ready within one frame
    expect(drive.status.isReady, true);

    watcher.poll(10);
    expect(events, ["open"]); // kept open for the hold time
    watcher.poll(50);
    expect(events, ["open"]);
    watcher.poll(50);
    expect(events, ["open", "inserted"]);
    watcher.poll(1000);
    expect(events, ["open", "inserted"]);
  });

  test('eject keeps the tray open; insert closes it', () async {
    await drive.eject();
    watcher.poll(1000);
    expect(events, ["open"]);
    watcher.poll(1000);
    expect(events, ["open"]);

    await drive.insert(source("c.bin"));
    watcher.poll(1000);
    expect(events, ["open", "inserted"]);
  });

  test('closing the tray without a disc is reported', () async {
    await drive.eject();
    watcher.poll(1000);
    await drive.insert();
    watcher.poll(1000);
    expect(events, ["open", "empty"]);
  });

  test('a swap to no disc is open then empty', () async {
    await drive.insert();
    watcher.poll(10);
    expect(events, ["open"]);
    watcher.poll(1000);
    expect(events, ["open", "empty"]);
  });

  test('inserted waits for the drive to be ready', () async {
    final inserting = drive.insert(source("b.bin"));
    watcher.poll(1000);
    expect(events, ["open"]); // tray open / loading
    await inserting;
    watcher.poll(1); // closing the tray takes the hold time again
    expect(events, ["open"]);
    watcher.poll(100);
    expect(events, ["open", "inserted"]);
  });

  test('sync takes the current state as the initial one', () async {
    await drive.insert(source("b.bin"));
    watcher.sync();
    watcher.poll(1000);
    expect(events, isEmpty);
  });
}
