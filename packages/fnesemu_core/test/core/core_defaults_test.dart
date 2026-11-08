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

  test('missing mandatory operations fail instead of silently accepting ROMs',
      () {
    final core = Core();
    for (final operation in <void Function()>[
      () => core.systemClockHz,
      () => core.scanlinesInFrame,
      () => core.clocksInScanline,
      () => core.clocksPerFrame,
      () => core.exec(false),
      () => core.runFrame(1),
      () => core.setRom(Uint8List(1)),
      core.reset,
    ]) {
      expect(operation, throwsUnimplementedError);
    }
  });

}
