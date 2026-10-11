import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/direction_pad.dart';
import 'package:fnesemu/gui/key_handler.dart';
import 'package:fnesemu/gui/pad_input.dart';
import 'package:fnesemu_core/app_api.dart';

Offset point(double degrees, [double radius = 54]) {
  final angle = degrees * math.pi / 180;
  return const Offset(80, 80) +
      Offset(math.sin(angle), -math.cos(angle)) * radius;
}

void main() {
  test('eight directions, clockwise boundaries and neutral hole', () {
    for (var sector = 0; sector < 8; sector++) {
      expect(DirectionPad.sectorAt(point(sector * 45)), sector);
      expect(DirectionPad.sectorAt(point(sector * 45 + 22.4)), sector);
      expect(
          DirectionPad.sectorAt(point(sector * 45 + 22.6)), (sector + 1) % 8);
    }
    expect(DirectionPad.sectorAt(point(0, 0)), isNull);
    expect(DirectionPad.sectorAt(point(0, 31)), isNull);
    expect(DirectionPad.sectorAt(point(0, 79)), isNull);
  });

  test('sources combine, transitions preserve held keys and clear releases all',
      () {
    final changes = <String>[];
    final input = PadInput(
        onDown: (b) => changes.add('+${b.name}'),
        onUp: (b) => changes.add('-${b.name}'));
    addTearDown(input.dispose);
    input.setSource('touch', {PadButton.up});
    input.setSource('touch', {PadButton.up, PadButton.right});
    expect(changes, ['+up', '+right']);
    input.setSource('keyboard', {PadButton.up});
    input.setSource('touch', {});
    expect(input.pressed, {PadButton.up});
    expect(changes, ['+up', '+right', '-right']);
    input.clear();
    expect(input.pressed, isEmpty);
    expect(changes.last, '-up');
    input.enabled = false;
    input.setSource('touch', {PadButton.right});
    expect(input.pressed, isEmpty);
  });

  testWidgets(
      'drag, cancel and keyboard combinations update the highlighted sector',
      (tester) async {
    final input = PadInput(onDown: (_) {}, onUp: (_) {});
    addTearDown(input.dispose);
    final controller = CoreController((_) {}, (_) {}, (_) {}, Sram());
    final keys = KeyHandler(controller: controller, input: input);
    HardwareKeyboard.instance.addHandler(keys.handle);
    addTearDown(() => HardwareKeyboard.instance.removeHandler(keys.handle));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Center(child: DirectionPad(input: input)))));
    final origin = tester.getTopLeft(find.byType(DirectionPad));
    int? highlighted() => tester
            .widget<CustomPaint>(find.byType(CustomPaint).last)
            .painter is DirectionPadPainter
        ? (tester.widget<CustomPaint>(find.byType(CustomPaint).last).painter!
                as DirectionPadPainter)
            .activeSector
        : null;
    final gesture = await tester.startGesture(origin + point(0));
    await tester.pump();
    expect(input.pressed, {PadButton.up});
    expect(highlighted(), 0);
    await gesture.moveTo(origin + point(45));
    await tester.pump();
    expect(input.pressed, {PadButton.up, PadButton.right});
    expect(highlighted(), 1);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await gesture.moveTo(origin + const Offset(80, 80));
    await tester.pump();
    expect(input.pressed, {PadButton.right});
    expect(highlighted(), 2);
    await gesture.cancel();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(highlighted(), 1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(highlighted(), 0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(highlighted(), isNull);
    final second = await tester.startGesture(origin + point(180));
    await second.cancel();
    expect(input.pressed, isEmpty);
    final third = await tester.startGesture(origin + point(270));
    input.clear();
    await third.moveTo(origin + point(315));
    expect(input.pressed, isEmpty);
    await third.up();
    await tester.pumpWidget(const SizedBox());
  });
}
