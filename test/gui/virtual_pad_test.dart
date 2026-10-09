import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/pad_input.dart';
import 'package:fnesemu/gui/virtual_pad.dart';
import 'package:fnesemu_core/core/core_controller.dart';
import 'package:fnesemu_core/core/pad_button.dart';
import 'package:fnesemu_core/core/sram.dart';

class _Controller extends CoreController {
  _Controller() : super((_) {}, (_) {}, (_) {}, Sram());
  @override
  List<PadButton> get buttons => [
        PadButton.up,
        PadButton.down,
        PadButton.left,
        PadButton.right,
        ...['Select', 'Start', 'B', 'A', 'C', 'L', 'Y', 'R', 'X', 'D']
            .map(PadButton.new)
      ];
}

void main() {
  testWidgets(
      'staggered rows, uniform single-letter widths and inside key labels',
      (tester) async {
    final input = PadInput(onDown: (_) {}, onUp: (_) {});
    addTearDown(input.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Center(
                child: VirtualPadWidget(
                    controller: _Controller(), input: input)))));
    Rect button(String key) =>
        tester.getRect(find.byKey(ValueKey('action-key-$key')));
    expect(button('A').left - button('Q').left,
        moreOrLessEquals(VirtualPadWidget.keyWidth / 2));
    expect(button('Z').left - button('A').left,
        moreOrLessEquals(VirtualPadWidget.keyWidth / 2));
    expect(button('A').top - button('Q').top,
        moreOrLessEquals(VirtualPadWidget.keyHeight + VirtualPadWidget.gap));
    expect(button('Z').top - button('A').top,
        moreOrLessEquals(VirtualPadWidget.keyHeight + VirtualPadWidget.gap));
    for (final key in ['Q', 'W', 'E', 'R', 'D', 'Z', 'X', 'C']) {
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
    final touch = await tester.startGesture(button('X').center);
    await tester.pump();
    expect(input.pressed.single.name, 'A');
    await touch.up();
    expect(input.pressed, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
