import 'package:fnesemu_core/src/core/dc/sh4_translator.dart';
import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

void main() {
  for (final (opcode, expectedTrue, expectedFalse) in [
    (0x8901, 0x106, 0x102), // BT
    (0x8b01, 0x102, 0x106), // BF
    (0x8d01, 0x106, 0x104), // BT/S
    (0x8f01, 0x104, 0x106), // BF/S
  ]) {
    test('SH-4 branch ${opcode.toRadixString(16)} tests T directly', () {
      final t = Sh4Translator(
        fetch: (pc) => switch (pc) {
          0x100 => opcode,
          0x102 => 0x0009, // delay-slot NOP
          _ => null,
        },
        protect: (_) {},
        fpuHelper: 0,
        prefetchHelper: 0,
      );
      final block = t.translate(0x100, 0)!;
      final term = block.term as IrBranch;
      expect((term.pcTrue, term.pcFalse),
          (expectedTrue, expectedFalse));
      expect(block.insts[term.cond.index].op, IrOp.and);
      expect(irFusedCompareConsumers(block)[term.cond.index],
          block.insts.length);
    });
  }
}
