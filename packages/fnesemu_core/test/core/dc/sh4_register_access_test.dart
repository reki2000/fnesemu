import 'package:fnesemu_core/src/core/dc/sh4_translator.dart';
import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

void main() {
  // mov.l @(12,r7),r1; mov.l r1,@(4,r7); mov.l r1,@(0,r7); nop
  const code = {0x100: 0x5173, 0x102: 0x1711, 0x104: 0x1710, 0x106: 0x0009};
  IrBlock translate(int? base) => Sh4Translator(
        fetch: (pc) => code[pc],
        protect: (_) {},
        fpuHelper: 0,
        prefetchHelper: 1,
        registerReadHelper: 2,
        registerWriteHelper: 3,
        loadTlbHelper: 4,
        entryValue: (word) => word == Sh4Translator.regs + 7 ? base : null,
      ).translate(0x100, tag: 0)!;
  List<int> calls(IrBlock block) => [
        for (final inst in block.insts)
          if (inst.op == IrOp.call) inst.imm
      ];

  test('CCN registers at the entry value of the base register use helpers', () {
    // TEA is read and PTEL written through helpers; a PTEH write changes
    // the address space and stays with the interpreter.
    expect(calls(translate(0xff000000)), [2, 3]);
  });

  test('other base values keep the ordinary accesses', () {
    expect(calls(translate(0x8c000000)), isEmpty);
    expect(calls(translate(null)), isEmpty);
  });

  test('LDTLB calls its helper and ends the block', () {
    final translator = Sh4Translator(
      fetch: (pc) => const {0x100: 0x0038, 0x102: 0x0009}[pc],
      protect: (_) {},
      fpuHelper: 0,
      prefetchHelper: 1,
      loadTlbHelper: 4,
    );
    final block = translator.translate(0x100, tag: 0)!;
    expect(calls(block), [4]);
    expect((block.term as IrJump).pc, 0x102);
    expect(translator.translate(0x100, tag: Sh4Translator.tagUser), isNull);
  });
}
