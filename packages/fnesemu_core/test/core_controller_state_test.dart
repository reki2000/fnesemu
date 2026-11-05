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

  test('DC startup restores saved flash after loading the factory image',
      () async {
    final saved = Uint8List(0x20000)..fillRange(0, 0x20000, 0xff);
    saved[0] = 0x56;
    final sram = _SavedDcFlashSram(saved);
    final controller = CoreController((_) {}, (_) {}, (_) {}, sram);
    final factory = Uint8List(0x20000)..fillRange(0, 0x20000, 0xff);
    factory[0] = 0x12;

    await controller.init('dc', bios: [Uint8List(2 * 1024 * 1024), factory]);
    expect(sram.id, 'dc/sram/system_flash');
    expect(sram.read8(0), 0x56);
    await controller.stop();
  });

  test('PS and SS attach backup storage after loading their BIOS', () async {
    final sram = Sram();
    final controller = CoreController((_) {}, (_) {}, (_) {}, sram);

    await controller.init('ps', bios: [Uint8List(512 * 1024)]);
    expect(sram.id, 'ps/sram/memcard1');
    expect(sram.data.length, 128 * 1024);

    await controller.init('ss', bios: [Uint8List(512 * 1024)]);
    expect(sram.id, 'ss_bram');
    expect(sram.data.length, 0x8000);
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

/// Simulates the app's preloaded persistent DC system flash.
class _SavedDcFlashSram extends Sram {
  _SavedDcFlashSram(this.saved);

  final Uint8List saved;

  @override
  void init(String id, Uint8List initialData) {
    super.init(id, id == 'dc/sram/system_flash' ? saved : initialData);
  }
}
