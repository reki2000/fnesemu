import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/blob_store/blob_store.dart';
import 'package:fnesemu/gui/game_directory.dart';
import 'package:fnesemu/gui/storage.dart';
import 'package:idb_shim/idb_client_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Storage> open() async =>
      Storage.open(store: await BlobStore.open(factory: newIdbFactoryMemory()));

  GameDirectory dir(String id, [String? key]) => GameDirectory(id, id, key);

  test('the last opened directory comes first', () async {
    final storage = await open();
    await storage.rememberDirectory(dir('a'));
    await storage.rememberDirectory(dir('b'));
    await storage.rememberDirectory(dir('a'));
    expect(storage.gameDirectories.map((d) => d.id), ['a', 'b']);
  });

  test('an update keeps the place of the directory', () async {
    final storage = await open();
    await storage.rememberDirectory(dir('a'));
    await storage.rememberDirectory(dir('b'));
    await storage.updateDirectory(dir('a', 'renewed'));
    expect(storage.gameDirectories.map((d) => d.id), ['b', 'a']);
    expect(storage.gameDirectories.last.restoreKey, 'renewed');
  });

  test('a removed directory is forgotten', () async {
    final storage = await open();
    await storage.rememberDirectory(dir('a'));
    await storage.rememberDirectory(dir('b'));
    await storage.forgetDirectory('a');
    expect(storage.gameDirectories.map((d) => d.id), ['b']);
  });

  test('the older list, the last opened last, is read reversed', () async {
    final storage = await open();
    await storage.setSetting('game_directories',
        jsonEncode([dir('old').toJson(), dir('new').toJson()]));
    expect(storage.gameDirectories.map((d) => d.id), ['new', 'old']);
  });
}
