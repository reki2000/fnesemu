import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/blob_store/blob_store.dart';
import 'package:fnesemu/gui/state_slot.dart';
import 'package:fnesemu/gui/storage.dart';
import 'package:idb_shim/idb_client_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final savedAt = DateTime.fromMillisecondsSinceEpoch(1762000000000);
  final state = Uint8List.fromList(List.generate(1024, (i) => i * 7 & 0xff));
  final thumbnail = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);

  group('state slot blob', () {
    test('the header carries the time and thumbnail, the state round trips',
        () {
      final blob =
          StateSlotBlob.build(state, thumbnail: thumbnail, savedAt: savedAt);
      final info = StateSlotBlob.header(blob, 4);
      expect(info.slot, 4);
      expect(info.savedAt, savedAt);
      expect(info.thumbnail, thumbnail);
      expect(StateSlotBlob.state(blob), state);
      // the compressed form is smaller than the state of mostly zeroes
      final zeros = StateSlotBlob.build(Uint8List(4096), savedAt: savedAt);
      expect(zeros.length, lessThan(4096));
    });

    test('a blob without a thumbnail has none in its header', () {
      final blob = StateSlotBlob.build(state, savedAt: savedAt);
      expect(StateSlotBlob.header(blob, 0).thumbnail, isNull);
      expect(StateSlotBlob.state(blob), state);
    });

    test('foreign and corrupt blobs are rejected', () {
      expect(() => StateSlotBlob.header(Uint8List(64), 0),
          throwsFormatException);
      expect(() => StateSlotBlob.state(Uint8List(64)), throwsFormatException);

      final blob =
          StateSlotBlob.build(state, thumbnail: thumbnail, savedAt: savedAt);
      final badVersion = Uint8List.fromList(blob)..[4] = 99;
      expect(() => StateSlotBlob.header(badVersion, 0), throwsFormatException);

      final truncated = Uint8List.sublistView(blob, 0, 20);
      expect(() => StateSlotBlob.header(truncated, 0), throwsFormatException);

      final corruptState = Uint8List.fromList(blob);
      for (var i = StateSlotBlob.headerSize + thumbnail.length;
          i < corruptState.length;
          i++) {
        corruptState[i] ^= 0xff;
      }
      expect(() => StateSlotBlob.state(corruptState), throwsFormatException);
    });
  });

  group('storage state slots', () {
    late IdbFactory factory;
    late Storage storage;

    setUp(() async {
      factory = newIdbFactoryMemory();
      storage =
          await Storage.open(store: await BlobStore.open(factory: factory));
    });

    tearDown(() => storage.dispose());

    test('save, list and load round trip, and survive a reopen', () async {
      final id = Storage.gameId('gb', 'game.gb', rom: Uint8List(0x8000));
      expect(await storage.stateSlots('gb', id),
          List.filled(Storage.stateSlotCount, null));

      await storage.saveStateSlot('gb', id, 3, state,
          thumbnail: thumbnail, savedAt: savedAt);
      final slots = await storage.stateSlots('gb', id);
      expect(slots.where((slot) => slot != null), hasLength(1));
      expect(slots[3]!.savedAt, savedAt);
      expect(slots[3]!.thumbnail, thumbnail);
      expect(await storage.loadStateSlot('gb', id, 3), state);
      expect((await storage.stateSlot('gb', id, 3))!.savedAt, savedAt);
      expect(await storage.stateSlot('gb', id, 0), isNull);

      final reopened =
          await Storage.open(store: await BlobStore.open(factory: factory));
      addTearDown(reopened.dispose);
      expect(await reopened.loadStateSlot('gb', id, 3), state);
    });

    test('saving over a slot replaces it', () async {
      final id = Storage.gameId('gb', 'game.gb', rom: Uint8List(0x8000));
      final other = Uint8List.fromList([9, 9, 9]);
      await storage.saveStateSlot('gb', id, 0, state, savedAt: savedAt);
      await storage.saveStateSlot('gb', id, 0, other,
          savedAt: savedAt.add(const Duration(minutes: 1)));
      expect(await storage.loadStateSlot('gb', id, 0), other);
      expect((await storage.stateSlot('gb', id, 0))!.savedAt,
          savedAt.add(const Duration(minutes: 1)));
    });

    test('slots are isolated per game and per core', () async {
      final rom = Uint8List(0x8000);
      final a = Storage.gameId('gb', 'a.gb', rom: rom);
      final b = Storage.gameId('gb', 'b.gb', rom: rom);
      await storage.saveStateSlot('gb', a, 0, state, savedAt: savedAt);
      expect(await storage.stateSlot('gb', b, 0), isNull);
      expect(await storage.stateSlot('nes', a, 0), isNull);
      await expectLater(
          storage.loadStateSlot('gb', b, 0), throwsStateError);
    });

    test('loading an empty slot throws, a corrupt blob fails clearly',
        () async {
      final id = Storage.gameId('gb', 'game.gb', rom: Uint8List(0x8000));
      await expectLater(storage.loadStateSlot('gb', id, 9), throwsStateError);

      final store = await BlobStore.open(factory: factory);
      await store.put('gb/state/$id/1', Uint8List.fromList([1, 2, 3]));
      await expectLater(
          storage.loadStateSlot('gb', id, 1), throwsFormatException);
      // listing treats the unreadable blob as empty and reports it
      final events = <String>[];
      storage.onEvent = events.add;
      expect((await storage.stateSlots('gb', id))[1], isNull);
      expect(events, hasLength(1));
    });

    test('the game id is the identity of the recent entry', () async {
      final rom = Uint8List(0x8000);
      await storage.recordRecent('gb', 'game.gb', rom: rom);
      expect(storage.recentGames.single.id,
          Storage.gameId('gb', 'game.gb', rom: rom));
    });
  });
}
