import 'dart:async';
import 'dart:typed_data';

import 'package:fnesemu_core/app_api.dart';
import 'package:fnesemu_core/src/util/state.dart';
import 'package:test/test.dart';

// a ROM whose entry point loops on itself
Uint8List _rom() => Uint8List(0x8000)..setAll(0x100, [0, 0xc3, 0, 1]);

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for the controller');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('save and load without a core throw a StateError', () async {
    final controller = CoreController((_) {}, (_) {}, (_) {}, Sram());
    await expectLater(controller.saveState(), throwsStateError);
    await expectLater(controller.loadState(Uint8List(0)), throwsStateError);
  });

  test('a state round trips through the controller', () async {
    final controller = CoreController((_) {}, (_) {}, (_) {}, Sram());
    await controller.init('gb', rom: _rom());
    final state = await controller.saveState();
    expect(state, isNotEmpty);
    await controller.loadState(state);
    expect(await controller.saveState(), state);
    await controller.stop();
  });

  test('a foreign state is passed to the caller as an error', () async {
    final controller = CoreController((_) {}, (_) {}, (_) {}, Sram());
    await controller.init('gb', rom: _rom());
    await expectLater(
        controller.loadState(Uint8List(64)), throwsA(isA<StateMismatch>()));
    // the core still saves its own state afterwards
    expect(await controller.saveState(), isNotEmpty);
    await controller.stop();
  });

  test('save and load resume a running emulation', () async {
    final transitions = <bool>[];
    final controller = CoreController(
        (state) => transitions.add(state.running), (_) {}, (_) {}, Sram());
    await controller.init('gb', rom: _rom());
    unawaited(controller.run());
    await _until(() => transitions.isNotEmpty && transitions.last);
    final state = await controller.saveState();
    // the capture stopped the emulation and resumed it
    expect(transitions, containsAllInOrder([true, false, true]));
    await controller.loadState(state);
    expect(transitions.last, isTrue);
    await controller.stop();
    await _until(() => transitions.last == false);
  });
}
