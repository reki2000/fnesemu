import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/blob_store/blob_store.dart';
import 'package:fnesemu/gui/storage.dart';
import 'package:fnesemu/gui/game_directory.dart';
import 'package:fnesemu/gui/recent_game.dart';
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

  test('directory permissions and ROM source paths survive reopening',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = await BlobStore.open(factory: newIdbFactoryMemory());
    final storage = await Storage.open(store: store);
    addTearDown(store.close);
    addTearDown(storage.dispose);
    await storage.rememberDirectory(
        const GameDirectory('first', 'fixtures', 'original-token'));
    await storage.rememberDirectory(
        const GameDirectory('second', 'other', 'other-token'));
    await storage.rememberDirectory(
        const GameDirectory('first', 'fixtures', 'renewed-token'));
    await storage.recordRecent('gb', 'fixture.gb',
        rom: Uint8List.fromList([1, 2, 3]));
    await storage.recordRecent('gb', 'fixture.gb',
        rom: Uint8List.fromList([1, 2, 3]),
        folder: 'first',
        path: 'archive.zip');
    final restored = await Storage.open(store: store);
    addTearDown(restored.dispose);
    expect(restored.gameDirectories.length, 2);
    expect(restored.gameDirectories.first.restoreKey, 'renewed-token');
    expect(restored.recentGames.single.isDisc, isFalse);
    expect(restored.recentGames.single.count, 2);
    expect(restored.recentGames.single.folder, 'first');
    expect(restored.recentGames.single.sourcePath, 'archive.zip');
    final legacy = RecentGame.fromJson({
      'id': 'fixture',
      'core': 'ss',
      'name': 'fixture.cue',
      'folder': 'first',
      'count': 1,
      'lastPlayed': 1
    });
    expect(legacy.isDisc, isTrue);
    expect(legacy.sourcePath, 'fixture.cue');
  });

  test('retain every history entry and its ROM blob', () async {
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
    expect(storage.recentGames.length, 21);
    expect(storage.recentGames.first.name, 'first.gb');
    expect(await store.get(first.blobKey), rom);
    expect(
        (await store.keys())
            .where((key) => key.contains('/recent-rom/'))
            .length,
        21);
  });
}
