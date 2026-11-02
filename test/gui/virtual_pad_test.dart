import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/core_view.dart';
import 'package:fnesemu/gui/direction_pad.dart';
import 'package:fnesemu/gui/pad_input.dart';
import 'package:fnesemu/gui/ticker_image.dart';
import 'package:fnesemu/gui/virtual_pad.dart';
import 'package:fnesemu_core/app_api.dart';

class _Controller extends CoreController {
  _Controller() : super((_) {}, (_) {}, (_) {}, Sram());
  @override
  List<PadButton> get buttons => [
        PadButton.up,
        PadButton.down,
        PadButton.left,
        PadButton.right,
        // the key slots S Z X C / A D W / Q E / 1 2 3 4 / R / Enter Shift
        ...[
          'B', 'Y', 'A', 'C', 'Select', 'D', 'W', 'L', 'R', //
          '1', '2', '3', '4', 'X', 'Start', 'Shift'
        ].map(PadButton.new)
      ];
}

void main() {
  testWidgets(
      'staggered rows, uniform single-letter widths and inside key labels',
      (tester) async {
    final input = PadInput();
    addTearDown(input.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Center(
                child: VirtualPadWidget(
                    controller: _Controller(), input: input)))));
    Rect button(String key) =>
        tester.getRect(find.byKey(ValueKey('action-key-$key')));
    expect(button('Q').left - button('1').left,
        moreOrLessEquals(VirtualPadWidget.keyWidth / 2));
    expect(button('A').left - button('Q').left,
        moreOrLessEquals(VirtualPadWidget.keyWidth / 2));
    expect(button('Z').left - button('A').left,
        moreOrLessEquals(VirtualPadWidget.keyWidth / 2));
    expect(button('Q').top - button('1').top,
        moreOrLessEquals(VirtualPadWidget.keyHeight + VirtualPadWidget.gap));
    expect(button('A').top - button('Q').top,
        moreOrLessEquals(VirtualPadWidget.keyHeight + VirtualPadWidget.gap));
    expect(button('Z').top - button('A').top,
        moreOrLessEquals(VirtualPadWidget.keyHeight + VirtualPadWidget.gap));
    for (final key in [
      'Q',
      'W',
      'E',
      'R',
      'D',
      'Z',
      'X',
      'C',
      '1',
      '2',
      '3',
      '4'
    ]) {
      expect(button(key).width, moreOrLessEquals(VirtualPadWidget.keyWidth));
      final label = find.descendant(
          of: find.byKey(ValueKey('action-key-$key')),
          matching: find.text(key));
      final rect = tester.getRect(label.last);
      expect(button(key).contains(rect.topLeft), isTrue);
      expect(rect.top, lessThan(button(key).top + 10));
      expect(rect.left, lessThan(button(key).left + 10));
    }
    expect(button('A').width, greaterThan(VirtualPadWidget.keyWidth));
    expect(button('Shift').top, button('Z').top);
    expect(button('Enter').top, button('Z').top);
    expect(button('Shift').right, lessThan(button('Enter').left));
    expect(button('Enter').right, lessThan(button('Z').left));
    expect(
        tester.getSize(find.byType(VirtualPadWidget)).height,
        moreOrLessEquals(
            4 * VirtualPadWidget.keyHeight + 3 * VirtualPadWidget.gap));
    final select = await tester.startGesture(button('Shift').center);
    final start = await tester.startGesture(button('Enter').center, pointer: 2);
    expect(input.pressed.map((button) => button.name),
        containsAll(['Shift', 'Start']));
    await select.up();
    await start.up();
    final touch = await tester.startGesture(button('X').center);
    await tester.pump();
    expect(input.pressed.single.name, 'A');
    await touch.up();
    expect(input.pressed, isEmpty);
    expect(tester.takeException(), isNull);
  });
  for (final width in [320.0, 393.0, 600.0, 900.0]) {
    testWidgets('controls fit and remain touchable at width $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final input = PadInput();
      addTearDown(input.dispose);
      final container = ImageContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: CoreView(
                  controller: _Controller(),
                  container: container,
                  input: input))));
      final direction = tester.getRect(find.byType(DirectionPad));
      Rect button(String key) =>
          tester.getRect(find.byKey(ValueKey('action-key-$key')));
      for (final key in ['1', 'Q', 'A', 'Z', 'C', 'Shift', 'Enter']) {
        final rect = button(key);
        expect(rect.left, greaterThanOrEqualTo(direction.right));
        expect(rect.right, lessThanOrEqualTo(width));
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.bottom, lessThanOrEqualTo(852));
      }
      if (width <= 393) {
        expect(button('Enter').top, greaterThan(button('Z').bottom));
      } else {
        expect(button('Enter').top, button('Z').top);
        expect(button('Enter').right, lessThan(button('Z').left));
      }
      final touch = await tester.startGesture(button('Enter').center);
      expect(input.pressed.single.name, 'Start');
      await touch.up();
      expect(input.pressed, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
