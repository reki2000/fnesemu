import 'dart:typed_data';

import 'package:fnesemu_core/app_api.dart';
import 'package:test/test.dart';
import 'pad_helper.dart';

class _InstructionCore extends Core {
  final List<ExecResult> instructions;
  int calls = 0;

  _InstructionCore(this.instructions);

  @override
  ExecResult exec(bool step) {
    expect(step, false);
    return instructions[calls++];
  }
}

void main() {
  test('default frame loop counts rendered lines and returns the last result',
      () {
    final instructions = [
      ExecResult(3, false, false),
      ExecResult(7, false, true),
      ExecResult(9, false, false),
      ExecResult(12, false, true),
      ExecResult(15, false, true),
    ];
    final core = _InstructionCore(instructions);
    expect(core.runFrame(2), same(instructions[3]));
    expect(core.calls, 4);
    expect(core.runFrame(1), same(instructions[4]));
    expect(core.calls, 5);
  });

  test('default frame loop stops early and does not execute zero lines', () {
    final stopped = ExecResult(8, true, false);
    final core = _InstructionCore([ExecResult(4, false, true), stopped]);
    expect(core.runFrame(0).elapsedClocks, 0);
    expect(core.calls, 0);
    expect(core.runFrame(3), same(stopped));
    expect(core.calls, 2);
  });

  test('unloaded core can be displayed and inspected without a dummy CPU', () {
    final core = Core();
    final debugger = Debugger(core);
    debugger.setDebugView(true);
    expect(core.jitEnabled, isFalse);
    expect(debugger.state.jitEnabled, isFalse);
    expect(core.cpuInfos, isEmpty);
    expect(core.buttons, isEmpty);
    expect(core.imageBuffer().buffer, isEmpty);
    expect(debugger.state.disasmAddress, isEmpty);
    expect(debugger.state.text, isEmpty);
    core.padDown(0, PadButton.up);
    core.padUp(0, PadButton.up);
  });

  test('missing mandatory operations fail instead of silently accepting ROMs',
      () {
    final core = Core();
    for (final operation in <void Function()>[
      () => core.systemClockHz,
      () => core.scanlinesInFrame,
      () => core.clocksInScanline,
      () => core.exec(false),
      () => core.runFrame(1),
      () => core.setRom(Uint8List(1)),
      core.reset,
    ]) {
      expect(operation, throwsUnimplementedError);
    }
  });

  test('run before loading does not leave the controller running', () async {
    final states = <bool>[];
    final controller = CoreController(
        (CoreControllerState state) => states.add(state.running),
        (_) => fail('unloaded core emitted audio'),
        (_) => fail('unloaded core emitted a frame'),
        Sram());
    await controller.run();
    await controller.stop();
    expect(controller.system, isEmpty);
    expect(states, isEmpty);
    expect(controller.debugger.cpuInfos, isEmpty);
  });
}
