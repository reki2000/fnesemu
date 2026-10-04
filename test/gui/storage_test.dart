import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/core/storage_key.dart';
import 'package:fnesemu/gui/blob_store/blob_store.dart';
import 'package:fnesemu/gui/storage.dart';
import 'package:fnesemu/util/uint8list.dart';
import 'package:idb_shim/idb_client_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    SharedPreferences.setMockInitialValues({});
    final factory = newIdbFactoryMemory();

    final s1 =
        await Storage.open(store: await BlobStore.open(factory: factory));
    s1.init("nes/sram/x", Uint8List(4));
    s1.write8(1, 0x55);
    s1.saveIfDirty();
    s1.dispose();
    await Future.delayed(Duration.zero);

    final s2 =
        await Storage.open(store: await BlobStore.open(factory: factory));
    s2.init("nes/sram/x", Uint8List(4));
    expect(s2.read8(1), 0x55);
    s2.dispose();
  });

  test('migrates shared preferences', () async {
    final mem = Uint8List.fromList([1, 2, 3]);
    SharedPreferences.setMockInitialValues(
        {"psx_mem1": mem.toBase64(), "0123abcd": mem.toBase64()});

    final store = await BlobStore.open(factory: newIdbFactoryMemory());
    final s = await Storage.open(store: store);

    expect(await store.get("ps/sram/memcard1"), mem);
    expect(await store.get("nes/sram/0123abcd"), mem);
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    s.dispose();
  });
}
