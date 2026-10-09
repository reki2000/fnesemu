import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fnesemu/core/core_api.dart';
import 'package:fnesemu/core/nes/nes.dart';
import 'package:fnesemu/core/nes/fds/fds_mapper.dart';
import 'package:fnesemu/gui/key_handler.dart';
import 'package:fnesemu/gui/pad_input.dart';
import 'package:fnesemu/gui/virtual_pad.dart';

class _Controller extends CoreController {
  final Nes core;
  _Controller(this.core) : super((_) {}, (_) {}, (_) {}, Sram());
  @override
  List<PadButton> get buttons => core.buttons;
  @override
  void padDown(int id, PadButton button) => core.padDown(id, button);
  @override
  void padUp(int id, PadButton button) => core.padUp(id, button);
}

void main() {
  testWidgets('R keyboard and touch share Flip Disk without joypad input',
      (tester) async {
    final disk = Uint8List(16 + 65500 * 2)
      ..setAll(0, [0x46, 0x44, 0x53, 0x1a, 2]);
    final core = Nes(diskSystem: true)
      ..setBiosFiles([Uint8List(8192)])
      ..setRom(disk);
    final controller = _Controller(core);
    final input = PadInput(
        onDown: (button) => controller.padDown(0, button),
        onUp: (button) => controller.padUp(0, button));
    addTearDown(input.dispose);
    final keys = KeyHandler(controller: controller, input: input);
    HardwareKeyboard.instance.addHandler(keys.handle);
    addTearDown(() => HardwareKeyboard.instance.removeHandler(keys.handle));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Center(
                child:
                    VirtualPadWidget(controller: controller, input: input)))));
    final mapper = core.bus.mapper as FdsMapper;
    expect(find.text('Flip Disk'), findsOneWidget);
    expect(find.byKey(const ValueKey('action-key-C')), findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyR);
    expect(mapper.selectedSide, 1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyR);
    await tester.tap(find.byKey(const ValueKey('action-key-R')));
    expect(mapper.selectedSide, 0);
    expect(core.bus.joypad.isPressed.containsKey(Nes.flipDisk), isFalse);
    await tester.pumpWidget(const SizedBox());
  });
}
