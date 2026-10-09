import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/core/storage_key.dart';
import 'package:fnesemu/gui/blob_store/blob_store.dart';
import 'package:fnesemu/gui/storage.dart';
import 'package:idb_shim/idb_client_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('storage key', () {
    expect(StorageKey.of("nes", StorageKey.sram, "abc"), "nes/sram/abc");
    expect(StorageKey.kindOf("ps/sram/memcard1"), StorageKey.sram);
    expect(StorageKey.kindOf("ss/bios/jp"), StorageKey.bios);
    expect(StorageKey.kindOf("invalid"), "");
  });

  test('blob store round trip', () async {
    final store = await BlobStore.open(factory: newIdbFactoryMemory());
    final data = Uint8List.fromList([0, 1, 2, 0xff]);

    await store.put("nes/sram/x", data);
    expect(await store.get("nes/sram/x"), data);
    expect(await store.keys(), ["nes/sram/x"]);

    await store.delete("nes/sram/x");
    expect(await store.get("nes/sram/x"), isNull);
  });

  test('sram is saved and preloaded on the next open', () async {
    final factory = newIdbFactoryMemory();

    final s1 =
        await Storage.open(store: await BlobStore.open(factory: factory));
    var saved = 0;
    final events = <String>[];
    s1.onSramSaved = () => saved++;
    s1.onEvent = events.add;
    s1.init("nes/sram/x", Uint8List(4));
    s1.write8(1, 0x55);
    s1.saveIfDirty();
    s1.dispose();
    for (var i = 0; i < 100 && saved == 0; i++) {
      await Future.delayed(const Duration(milliseconds: 10));
    }
    // a save is shown as a badge, not as a message
    expect(saved, 1);
    expect(events, isEmpty);

    final s2 =
        await Storage.open(store: await BlobStore.open(factory: factory));
    s2.init("nes/sram/x", Uint8List(4));
    expect(s2.read8(1), 0x55);
    s2.dispose();
  });

  test('settings are saved without a core and loaded at open', () async {
    expect(StorageKey.setting("disc_dir"), "settings/disc_dir");
    expect(StorageKey.kindOf("settings/disc_dir"), StorageKey.settings);

    final factory = newIdbFactoryMemory();
    final s1 =
        await Storage.open(store: await BlobStore.open(factory: factory));
    expect(s1.setting("disc_dir"), isNull);
    await s1.setSetting("disc_dir", "/home/user/ディスク");
    expect(s1.setting("disc_dir"), "/home/user/ディスク");
    s1.dispose();

    final s2 =
        await Storage.open(store: await BlobStore.open(factory: factory));
    expect(s2.setting("disc_dir"), "/home/user/ディスク");
    s2.dispose();
  });

  test('bios files are replaced, and listed at the next open', () async {
    final factory = newIdbFactoryMemory();
    final a = Uint8List.fromList([1]);
    final b = Uint8List.fromList([2, 2]);

    final s1 =
        await Storage.open(store: await BlobStore.open(factory: factory));
    expect(s1.biosNames("32x"), isEmpty);
    await s1.setBios("32x", [("old.bin", a)]);
    await s1.setBios("32x", [("m.bin", b), ("a.bin", a)]);
    await s1.setBios("ps", [("bios.bin", b)]);
    expect(s1.biosNames("32x"), ["a.bin", "m.bin"]);
    s1.dispose();

    final s2 =
        await Storage.open(store: await BlobStore.open(factory: factory));
    expect(s2.biosNames("32x"), ["a.bin", "m.bin"]);
    expect(await s2.bios("32x"), [a, b]);
    expect(await s2.bios("ps"), [b]);
    expect(await s2.bios("ss"), isEmpty);
    s2.dispose();
  });
}
