import 'package:fnesemu_core/src/core/dc/sh4_translator.dart';
import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

void main() {
  IrBlock? translate(Map<int, int> code) => Sh4Translator(
        fetch: (pc) => code[pc],
        protect: (_) {},
        fpuHelper: 0,
        prefetchHelper: 1,
      ).translate(0x100, tag: 0);

  test('single-precision FLOAT translates in a delay slot', () {
    // bra +0; float fpul,fr0
    final block = translate({0x100: 0xa000, 0x102: 0xf02d})!;
    expect((block.term as IrJump).pc, 0x104);
    expect(block.insts.where((i) => i.op == IrOp.call), isEmpty);
  });

  test('LDS to FPSCR ends the block on the tag of the new PR', () {
    // lds r1,fpscr; nop
    final block = translate({0x100: 0x416a, 0x102: 0x0009})!;
    final term = block.term as IrBranch;
    expect((term.pcTrue, term.pcFalse), (0x102, 0x102));
    expect((term.tagTrue, term.tagFalse), (Sh4Translator.tagDouble, 0));
    expect(block.cost, 1);
  });
}
