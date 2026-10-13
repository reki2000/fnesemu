import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/app.dart';
import 'package:fnesemu/gui/blob_store/blob_store.dart';
import 'package:fnesemu/gui/floating_game_menu.dart';
import 'package:fnesemu/gui/game_list.dart';
import 'package:fnesemu/gui/sound_player.dart';
import 'package:fnesemu/gui/storage.dart';
import 'package:idb_shim/idb_client_memory.dart';
import 'package:mp_bigfile_picker/mp_bigfile_picker.dart';

import 'sound_player_test.dart' show FakeAudioStream;

// replaces the directory dialog of mp_bigfile_picker
class TestFilePicker {
  Future<String?> Function()? select;
  String? initialDirectory;

  Future<String?> dialog({String? dialogTitle, String? initialDirectory}) {
    this.initialDirectory = initialDirectory;
    return select!();
  }
}

Future<void> waitFor(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for game startup');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> waitForGameList(WidgetTester tester) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (find.byType(GameListDialog).evaluate().isEmpty ||
      tester.widget<GameListDialog>(find.byType(GameListDialog)).scan.value ==
          null) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for directory scan');
    }
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  testWidgets(
      'ROM boot, menu pause, picker cancellation and backdrop resume work together',
      (tester) async {
    final picker = TestFilePicker();
    debugDirectoryDialog = picker.dialog;
    addTearDown(() => debugDirectoryDialog = null);
    late Directory temp;
    late Storage storage;
    await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('fnesemu-menu-test');
      final rom = Uint8List(0x8000)..setAll(0x100, [0, 0xc3, 0, 1]);
      final file = File('${temp.path}/fixture.gb');
      await file.writeAsBytes(rom);
      await File('${temp.path}/notes.txt').writeAsString('fixture');
      picker.select = () async => temp.path;
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
    final fpsRect = tester.getRect(find.byKey(const ValueKey('fps-indicator')));
    expect(fpsRect.top, 8);
    expect(fpsRect.right, 792);
    expect(find.byTooltip('Load ROM'), findsNothing);
    await tester.runAsync(() => tester.tap(find.byTooltip('CD / ROM')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Select directory...'));
      await waitForGameList(tester);
    });
    await tester.pump();
    expect(find.text('fixture.gb'), findsOneWidget);
    expect(find.text('notes.txt'), findsOneWidget);
    expect(storage.romDirectories.single.restoreKey, temp.path);
    await tester.runAsync(() async {
      await tester.tap(find.text('fixture.gb'));
      await waitFor(() => audio.starts == 1);
    });
    await tester.pump();
    expect(
        tester.widget<FloatingGameMenu>(find.byType(FloatingGameMenu)).expanded,
        isFalse);
    expect(audio.starts, 1);
    expect(
        tester.getRect(find.byKey(const ValueKey('fps-indicator'))), fpsRect);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('game-menu-toggle')));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('game-menu-backdrop')), findsOneWidget);
    expect(audio.closes, 1);

    await tester.runAsync(() async {
      await File('${temp.path}/fresh.gb')
          .writeAsBytes(await File('${temp.path}/fixture.gb').readAsBytes());
      await tester.tap(find.byTooltip('CD / ROM'));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('Rescan'), findsNothing);
    expect(find.textContaining('Games in'), findsNothing);
    // a remembered directory is shown by its absolute path
    expect(find.text(temp.path), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text(temp.path));
      await waitForGameList(tester);
    });
    await tester.pump();
    expect(find.text('fresh.gb'), findsOneWidget);
    // waiting for the selection is not shown as working
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.runAsync(() => tester.tap(find.text('Cancel')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(storage.romDirectories.length, 1);

    expect(storage.recentGames.single.core, 'gb');
    await tester.runAsync(() =>
        storage.recordRecent('ss', 'unavailable.cue', folder: '/unavailable'));
    await tester.pump();
    await tester.runAsync(() => tester.tap(find.byTooltip('History')));
    await tester.pumpAndSettle();
    expect(find.text('GB fixture.gb'), findsOneWidget);
    final unavailable = find.ancestor(
        of: find.text('SS unavailable.cue'),
        matching: find.byWidgetPredicate((widget) => widget is PopupMenuItem));
    expect(tester.widget<PopupMenuItem>(unavailable).enabled, isFalse);
    await tester.runAsync(() async {
      await tester.tap(find.text('GB fixture.gb'));
      await waitFor(() => audio.starts == 2);
    });
    await tester.pump();
    expect(
        storage.recentGames.where((game) => game.core == 'gb').single.count, 2);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('game-menu-toggle')));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    final cancelled = Completer<String?>();
    picker.select = () => cancelled.future;
    await tester.tap(find.byTooltip('CD / ROM'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select directory...'));
    await tester.pump();
    // the picker opens at the directory selected last time
    expect(picker.initialDirectory, temp.path);
    expect(tester.widget<FloatingGameMenu>(find.byType(FloatingGameMenu)).busy,
        isTrue);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.tapAt(const Offset(600, 400));
    await tester.pump();
    expect(audio.starts, 2);
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
    expect(audio.starts, 3);

    // Register dumps are below the game, outside the floating menu.
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('game-menu-toggle')));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    await tester.tap(find.byTooltip('Enable Debug Options'));
    await tester.pump();
    await tester.pump();
    final menu = tester.widget<FloatingGameMenu>(find.byType(FloatingGameMenu));
    expect(menu.expanded, isFalse);
    expect(
        tester.getRect(find.byKey(const ValueKey('fps-indicator'))).right,
        lessThanOrEqualTo(tester
            .getRect(find.byKey(const ValueKey('debug-game-area')))
            .right));
    final dump = find.descendant(
        of: find.byKey(const ValueKey('debug-game-area')),
        matching: find.byType(SelectableText));
    expect(dump, findsOneWidget);
    expect(tester.widget<SelectableText>(dump).data, contains('BC:'));
    expect(tester.widget<SelectableText>(dump).data, contains('PC:'));
    expect(
        find.descendant(
            of: find.byWidget(menu.toolbar),
            matching: find.byType(SelectableText)),
        findsNothing);
    final scrolls = find.ancestor(of: dump, matching: find.byType(Scrollable));
    expect(scrolls, findsWidgets);
    expect(find.byKey(const ValueKey('game-menu-backdrop')), findsNothing);
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Run (F5)'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    final closes = audio.closes;
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Pause (F4)'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(audio.closes, closes + 1);
    expect(
        tester.widget<FloatingGameMenu>(find.byType(FloatingGameMenu)).expanded,
        false);
    await tester.runAsync(() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.f6);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(
        tester.widget<FloatingGameMenu>(find.byType(FloatingGameMenu)).expanded,
        false);
    final starts = audio.starts;
    await tester.runAsync(() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.f5);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(audio.starts, starts + 1);

    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox());
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
  });
}
