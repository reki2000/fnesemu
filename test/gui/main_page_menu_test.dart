import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

// Replace the platform picker used internally by mp_bigfile_picker.
// ignore: depend_on_referenced_packages
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/app.dart';
import 'package:fnesemu/gui/blob_store/blob_store.dart';
import 'package:fnesemu/gui/floating_game_menu.dart';
import 'package:fnesemu/gui/sound_player.dart';
import 'package:fnesemu/gui/storage.dart';
import 'package:idb_shim/idb_client_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sound_player_test.dart' show FakeAudioStream;

class TestFilePicker extends FilePicker {
  Future<FilePickerResult?> Function()? select;
  @override
  Future<FilePickerResult?> pickFiles(
          {String? dialogTitle,
          String? initialDirectory,
          FileType type = FileType.any,
          List<String>? allowedExtensions,
          Function(FilePickerStatus)? onFileLoading,
          bool allowCompression = true,
          int compressionQuality = 30,
          bool allowMultiple = false,
          bool withData = false,
          bool withReadStream = false,
          bool lockParentWindow = false,
          bool readSequential = false}) =>
      select!();
}

void main() {
  testWidgets(
      'ROM boot, menu pause, picker cancellation and backdrop resume work together',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final picker = TestFilePicker();
    FilePicker.platform = picker;
    late Directory temp;
    late Storage storage;
    await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('fnesemu-menu-test');
      final rom = Uint8List(0x8000)..setAll(0x100, [0, 0xc3, 0, 1]);
      final file = File('${temp.path}/fixture.gb');
      await file.writeAsBytes(rom);
      picker.select = () async => FilePickerResult([
            PlatformFile(name: 'fixture.gb', size: rom.length, path: file.path),
          ]);
      storage = await Storage.open(
          store: await BlobStore.open(factory: newIdbFactoryMemory()));
    });
    addTearDown(() async {
      storage.dispose();
      await temp.delete(recursive: true);
    });
    final audio = FakeAudioStream();
    await tester.pumpWidget(MaterialApp(
        home: MainPage(
            storage: storage, soundPlayer: SoundPlayer(audioStream: audio))));
    expect(
        tester.widget<FloatingGameMenu>(find.byType(FloatingGameMenu)).expanded,
        isTrue);
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Load ROM'));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump();
    expect(
        tester.widget<FloatingGameMenu>(find.byType(FloatingGameMenu)).expanded,
        isFalse);
    expect(audio.starts, 1);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('game-menu-toggle')));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('game-menu-backdrop')), findsOneWidget);
    expect(audio.closes, 1);

    final cancelled = Completer<FilePickerResult?>();
    picker.select = () => cancelled.future;
    await tester.tap(find.byTooltip('Load ROM'));
    await tester.pump();
    expect(tester.widget<FloatingGameMenu>(find.byType(FloatingGameMenu)).busy,
        isTrue);
    await tester.tapAt(const Offset(600, 400));
    await tester.pump();
    expect(audio.starts, 1);
    cancelled.complete(null);
    await tester.pump();
    await tester.pump();
    expect(tester.widget<FloatingGameMenu>(find.byType(FloatingGameMenu)).busy,
        isFalse);
    expect(
        tester.widget<FloatingGameMenu>(find.byType(FloatingGameMenu)).expanded,
        isTrue);

    await tester.runAsync(() async {
      await tester.tapAt(const Offset(600, 400));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(
        tester.widget<FloatingGameMenu>(find.byType(FloatingGameMenu)).expanded,
        isFalse);
    expect(audio.starts, 2);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox());
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
  });
}
