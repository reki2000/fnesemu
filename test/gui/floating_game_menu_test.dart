import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/core/core_controller.dart';
import 'package:fnesemu/core/sram.dart';
import 'package:fnesemu/gui/core_view.dart';
import 'package:fnesemu/gui/floating_game_menu.dart';
import 'package:fnesemu/gui/ticker_image.dart';

void main() {
  testWidgets(
      'opening, background and resume button keep geometry and consume input',
      (tester) async {
    final expanded = ValueNotifier(false);
    addTearDown(expanded.dispose);
    var pauses = 0, resumes = 0, gameTaps = 0;
    void resume() {
      resumes++;
      expanded.value = false;
    }

    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ValueListenableBuilder(
      valueListenable: expanded,
      builder: (_, open, __) => FloatingGameMenu(
        expanded: open,
        canResume: true,
        busy: false,
        onToggle: () {
          if (open) {
            resume();
          } else {
            pauses++;
            expanded.value = true;
          }
        },
        onResume: resume,
        toolbar: SizedBox(
            height: 80,
            child: Align(
                alignment: Alignment.topLeft,
                child: IconButton(
                    tooltip: 'Resume',
                    onPressed: resume,
                    icon: const Icon(Icons.play_arrow)))),
        child: GestureDetector(
            key: const ValueKey('game'),
            behavior: HitTestBehavior.opaque,
            onTap: () => gameTaps++,
            child: const ColoredBox(color: Colors.blue)),
      ),
    ))));
    await tester.pump();
    final anchor =
        tester.getTopLeft(find.byKey(const ValueKey('game-menu-toggle')));
    final geometry = tester.getRect(find.byKey(const ValueKey('game')));
    await tester.tap(find.byKey(const ValueKey('game-menu-toggle')));
    await tester.pump();
    expect(pauses, 1);
    expect(tester.getTopLeft(find.byKey(const ValueKey('game-menu-toggle'))),
        anchor);
    expect(tester.getRect(find.byKey(const ValueKey('game'))), geometry);
    // Empty toolbar space must not act as a background resume gesture.
    await tester.tapAt(const Offset(300, 70));
    await tester.pump();
    expect(resumes, 0);
    await tester.tapAt(const Offset(400, 300));
    await tester.pump();
    expect(resumes, 1);
    expect(gameTaps, 0);
    expect(find.byKey(const ValueKey('game-menu-backdrop')), findsNothing);
    await tester.tapAt(const Offset(400, 300));
    expect(gameTaps, 1);
    await tester.tap(find.byKey(const ValueKey('game-menu-toggle')));
    await tester.pump();
    await tester.tap(find.byTooltip('Resume'));
    await tester.pump();
    expect(resumes, 2);
    await tester.tap(find.byKey(const ValueKey('game-menu-toggle')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('game-menu-toggle')));
    await tester.pump();
    expect(resumes, 3);
  });

  testWidgets('busy actions block background, menu toggle and game touches',
      (tester) async {
    var callbacks = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: FloatingGameMenu(
      expanded: true,
      canResume: true,
      busy: true,
      onToggle: () => callbacks++,
      onResume: () => callbacks++,
      toolbar: const Text('Loading'),
      child: GestureDetector(
          onTap: () => callbacks++,
          child: const ColoredBox(color: Colors.blue)),
    ))));
    await tester.tapAt(const Offset(400, 300));
    await tester.tap(find.byKey(const ValueKey('game-menu-toggle')));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(callbacks, 0);
  });

  testWidgets('no game has no resume backdrop, and Escape toggles the menu',
      (tester) async {
    var toggles = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: FloatingGameMenu(
      expanded: true,
      canResume: false,
      busy: false,
      onToggle: () => toggles++,
      onResume: () => fail('no game to resume'),
      toolbar: const Text('Open ROM'),
      child: const SizedBox.expand(),
    ))));
    await tester.pump();
    expect(find.byKey(const ValueKey('game-menu-backdrop')), findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
    expect(toggles, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(toggles, 2);
  });

  testWidgets('Escape dismisses a popup before toggling the game menu',
      (tester) async {
    final expanded = ValueNotifier(true);
    addTearDown(expanded.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ValueListenableBuilder(
      valueListenable: expanded,
      builder: (_, open, __) => FloatingGameMenu(
        expanded: open,
        canResume: true,
        busy: false,
        onToggle: () => expanded.value = !open,
        onResume: () => expanded.value = false,
        toolbar: PopupMenuButton<String>(
          tooltip: 'Settings',
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'setting', child: Text('Setting')),
          ],
        ),
        child: const SizedBox.expand(),
      ),
    ))));
    await tester.pump();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Setting'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Setting'), findsNothing);
    expect(expanded.value, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(expanded.value, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(expanded.value, isTrue);
  });

  for (final size in [const Size(320, 640), const Size(640, 320)]) {
    testWidgets('menu and game fit $size without resizing on menu open',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = CoreController((_) {}, (_) {}, (_) {}, Sram());
      final expanded = ValueNotifier(false);
      addTearDown(expanded.dispose);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ValueListenableBuilder(
        valueListenable: expanded,
        builder: (_, open, __) => FloatingGameMenu(
          expanded: open,
          canResume: true,
          busy: false,
          onToggle: () => expanded.value = !open,
          onResume: () => expanded.value = false,
          toolbar: Wrap(
              children: List.generate(
                  9,
                  (i) => IconButton(
                      onPressed: () {}, icon: const Icon(Icons.settings)))),
          child: CoreView(controller: controller, container: ImageContainer()),
        ),
      ))));
      final rect = tester.getRect(find.byType(CustomPaint).first);
      expect(rect.width, lessThanOrEqualTo(size.width));
      expect(rect.bottom, lessThanOrEqualTo(size.height));
      await tester.tap(find.byKey(const ValueKey('game-menu-toggle')));
      await tester.pump();
      expect(tester.getRect(find.byType(CustomPaint).first), rect);
      expect(tester.takeException(), isNull);
    });
  }
}
