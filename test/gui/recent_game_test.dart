import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/blob_store/blob_store.dart';
import 'package:fnesemu/gui/storage.dart';
import 'package:idb_shim/idb_client_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('history ranks by frequency then recency and restores ROM bytes',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = await BlobStore.open(factory: newIdbFactoryMemory());
    final storage = await Storage.open(store: store);
    addTearDown(store.close);
    addTearDown(storage.dispose);
    final rom = Uint8List.fromList([1, 2, 3]);
    await storage.recordRecent('gb', 'fixture.gb', rom: rom);
    await storage.recordRecent('gb', 'fixture.gb', rom: rom);
    await storage.recordRecent('ss', 'fixture.cue', folder: '/fixture');
    await storage.recordRecent('nes', 'fixture.nes', rom: rom);
    expect(storage.recentGames.map((game) => game.core), ['gb', 'nes', 'ss']);
    expect(storage.recentGames.first.count, 2);
    final restored = await Storage.open(store: store);
    addTearDown(restored.dispose);
    expect(restored.recentGames.first.count, 2);
    expect(await restored.recentRom(restored.recentGames.first), rom);
    expect(restored.recentGames.last.folder, '/fixture');
    await restored.recordRecent('ss', 'fixture.cue', folder: '/fixture');
    expect(restored.recentGames.first.core, 'ss');
    expect(restored.recentGames.first.count, 2);
  });

  test('retain the latest twenty and delete evicted ROM blobs', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await BlobStore.open(factory: newIdbFactoryMemory());
    final storage = await Storage.open(store: store);
    addTearDown(store.close);
    addTearDown(storage.dispose);
    final rom = Uint8List.fromList([1, 2, 3]);
    for (var i = 0; i < 4; i++) {
      await storage.recordRecent('gb', 'first.gb', rom: rom);
    }
    final first = storage.recentGames.first;
    for (var i = 0; i < 20; i++) {
      await storage.recordRecent('gb', 'fixture-$i.gb', rom: rom);
    }
    expect(storage.recentGames.length, 20);
    expect(storage.recentGames.first.name, 'fixture-19.gb');
    expect(await store.get(first.blobKey), isNull);
    expect(
        (await store.keys())
            .where((key) => key.contains('/recent-rom/'))
            .length,
        20);
  });
}
