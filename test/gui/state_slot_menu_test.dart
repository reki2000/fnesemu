// Uses real temporary files through the native picker adapter.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/app.dart';
import 'package:fnesemu/gui/blob_store/blob_store.dart';
import 'package:fnesemu/gui/floating_game_menu.dart';
import 'package:fnesemu/gui/game_list.dart';
import 'package:fnesemu/gui/sound_player.dart';
import 'package:fnesemu/gui/state_slot_dialog.dart';
import 'package:fnesemu/gui/storage.dart';
import 'package:idb_shim/idb_client_memory.dart';
import 'package:mp_bigfile_picker/mp_bigfile_picker.dart';

import 'main_page_menu_test.dart' show TestFilePicker, waitFor;
import 'sound_player_test.dart' show FakeAudioStream;

Future<void> _untilSaved(Storage storage, String gameId, int slot) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (await storage.stateSlot('gb', gameId, slot) == null) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for the state save');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _until(
    WidgetTester tester, bool Function() ready, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for $what');
    }
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    // advance fake time so route transitions can finish
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _untilFound(WidgetTester tester, Finder finder) =>
    _until(tester, () => finder.evaluate().isNotEmpty, '$finder');

Future<void> _waitForGameList(WidgetTester tester) async {
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
  testWidgets('state slots: toolbar dialogs, F1 quick save and F2 quick load',
      (tester) async {
    final picker = TestFilePicker();
    debugDirectoryDialog = picker.dialog;
    addTearDown(() => debugDirectoryDialog = null);
    late Directory temp;
    late Storage storage;
    late Uint8List rom;
    await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('fnesemu-state-test');
      rom = Uint8List(0x8000)..setAll(0x100, [0, 0xc3, 0, 1]);
      await File('${temp.path}/fixture.gb').writeAsBytes(rom);
      picker.select = () async => temp.path;
      storage = await Storage.open(
          store: await BlobStore.open(factory: newIdbFactoryMemory()));
    });
    addTearDown(() async {
      storage.dispose();
      await temp.delete(recursive: true);
    });
    final gameId = Storage.gameId('gb', 'fixture.gb', rom: rom);
    final audio = FakeAudioStream();
    await tester.pumpWidget(MaterialApp(
        home: MainPage(
            storage: storage, soundPlayer: SoundPlayer(audioStream: audio))));

    // without a game, the state buttons are disabled
    expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('save-state')))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('load-state')))
            .onPressed,
        isNull);

    // boot the fixture ROM through the directory picker
    await tester.runAsync(() => tester.tap(find.byTooltip('CD / ROM')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Select directory...'));
      await _waitForGameList(tester);
    });
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.text('fixture.gb'));
      await waitFor(() => audio.starts == 1);
    });
    await tester.pump();
    expect(
        tester.widget<FloatingGameMenu>(find.byType(FloatingGameMenu)).expanded,
        isFalse);

    // F1 quick-saves to slot 0 while the game runs
    await tester.runAsync(() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.f1);
      await _untilSaved(storage, gameId, 0);
    });
    await tester.pump();
    // the menu stayed closed and the game kept running
    expect(
        tester.widget<FloatingGameMenu>(find.byType(FloatingGameMenu)).expanded,
        isFalse);

    // open the menu and save to slot 3 through the dialog
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('game-menu-toggle')));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('save-state')))
            .onPressed,
        isNotNull);
    await tester.ensureVisible(find.byTooltip('Save state'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.byTooltip('Save state')));
    await _untilFound(tester, find.byType(StateSlotDialog));
    expect(find.byType(StateSlotDialog), findsOneWidget);
    expect(find.text('Save state'), findsWidgets);
    // all ten slots are listed and selectable, empty ones marked as such
    for (var slot = 0; slot < Storage.stateSlotCount; slot++) {
      await tester.scrollUntilVisible(find.text('Slot $slot'), 100,
          scrollable: find.descendant(
          of: find.byType(StateSlotDialog),
          matching: find.byType(Scrollable)));
      await tester.pump();
      final tile = tester.widget<ListTile>(
          find.byKey(ValueKey('state-slot-$slot')));
      expect(tile.enabled, isTrue, reason: 'save slot $slot');
    }
    expect(find.text('Empty'), findsWidgets);
    await tester.scrollUntilVisible(find.text('Slot 3'), -100,
        scrollable: find.descendant(
          of: find.byType(StateSlotDialog),
          matching: find.byType(Scrollable)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('state-slot-3')));
    await _until(tester, () => find.byType(StateSlotDialog).evaluate().isEmpty,
        'the save dialog to close');
    expect(find.byType(StateSlotDialog), findsNothing);
    await tester.runAsync(() => _untilSaved(storage, gameId, 3));

    // the load dialog disables the empty slots and shows the saved ones
    await tester.ensureVisible(find.byTooltip('Load state'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.byTooltip('Load state')));
    await _untilFound(tester, find.byType(StateSlotDialog));
    expect(find.byType(StateSlotDialog), findsOneWidget);
    for (final (slot, enabled) in [(0, true), (1, false), (3, true)]) {
      await tester.scrollUntilVisible(find.text('Slot $slot'),
          slot > 3 ? 100 : -100,
          scrollable: find.descendant(
          of: find.byType(StateSlotDialog),
          matching: find.byType(Scrollable)));
      await tester.pump();
      expect(
          tester
              .widget<ListTile>(find.byKey(ValueKey('state-slot-$slot')))
              .enabled,
          enabled,
          reason: 'load slot $slot');
    }
    // loading slot 3 closes the dialog and resumes the game
    await tester.tap(find.byKey(const ValueKey('state-slot-3')));
    await _until(
        tester,
        () =>
            find.byType(StateSlotDialog).evaluate().isEmpty &&
            !tester
                .widget<FloatingGameMenu>(find.byType(FloatingGameMenu))
                .expanded,
        'the load to resume the game');
    expect(find.byType(StateSlotDialog), findsNothing);
    await tester.runAsync(() => waitFor(() => audio.starts >= 2));

    // F2 asks for a confirmation and loads slot 0
    await tester.runAsync(() => tester.sendKeyEvent(LogicalKeyboardKey.f2));
    await _untilFound(tester, find.text('Load the state from slot 0?'));
    expect(find.text('Load the state from slot 0?'), findsOneWidget);
    await tester.tap(find.text('Load'));
    await _until(
        tester,
        () => find.text('Load the state from slot 0?').evaluate().isEmpty,
        'the quick load to finish');
    expect(find.text('Load the state from slot 0?'), findsNothing);
    expect(
        tester.widget<FloatingGameMenu>(find.byType(FloatingGameMenu)).expanded,
        isFalse);

    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox());
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
  });
}
