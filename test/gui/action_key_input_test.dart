import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/gui/key_handler.dart';
import 'package:fnesemu/gui/pad_input.dart';
import 'package:fnesemu/gui/virtual_pad.dart';
import 'package:fnesemu_core/app_api.dart';

// what the core does with the button is tested in the core (fds_test)
const flipDisk = PadButton('Flip Disk');

/// a core whose R key slot is [flipDisk], and the C, Q, W, E slots are unused
class _Controller extends CoreController {
  _Controller() : super((_) {}, (_) {}, (_) {}, Sram());
  @override
  List<PadButton> get buttons => [
        PadButton.up, PadButton.down, PadButton.left, PadButton.right, //
        const PadButton('A'), const PadButton('B'),
        const PadButton('Select'), const PadButton('Start'),
        PadButton.none, PadButton.none, PadButton.none, PadButton.none,
        flipDisk,
      ];
}

void main() {
  testWidgets('R keyboard and touch share the button of the R slot',
      (tester) async {
    final controller = _Controller();
    final input = PadInput();
    addTearDown(input.dispose);
    // the core reads the flip key through the input; record its changes
    final events = <String>[];
    input.addListener(() => events
        .add(input.isPressed(0, flipDisk) ? 'down Flip Disk' : 'up Flip Disk'));
    final keys = KeyHandler(controller: controller, input: input);
    HardwareKeyboard.instance.addHandler(keys.handle);
    addTearDown(() => HardwareKeyboard.instance.removeHandler(keys.handle));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Center(
                child:
                    VirtualPadWidget(controller: controller, input: input)))));
    expect(find.text('Flip Disk'), findsOneWidget);
    expect(find.byKey(const ValueKey('action-key-C')), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyR);
    expect(events, ['down Flip Disk', 'up Flip Disk']);

    events.clear();
    await tester.tap(find.byKey(const ValueKey('action-key-R')));
    expect(events, ['down Flip Disk', 'up Flip Disk']);
    await tester.pumpWidget(const SizedBox());
  });
}
