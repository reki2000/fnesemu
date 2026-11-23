import 'package:fnesemu_core/src/core/ss/scu_dsp_disasm.dart';
import 'package:fnesemu_core/src/core/ss/ss.dart';
import 'package:test/test.dart';

void main() {
  test('SCU DSP operations, transfers and control instructions', () {
    expect(ScuDspDisasm.disasm(0x00000000), 'nop');
    // ADD; MOV MC0,X; MOV MUL,P; MOV ALU,A
    expect(ScuDspDisasm.disasm(0x13440000),
        'add  mov mc0, x  mov mul, p  mov alu, a');
    expect(ScuDspDisasm.disasm(0x00003109), 'mov all, mc1');
    expect(ScuDspDisasm.disasm(0x000013ff), 'mov #-1, mc3');
    expect(ScuDspDisasm.disasm(0x80000005), 'mvi #5, mc0');
    expect(ScuDspDisasm.disasm(0xb0000020), 'mvi #32, pc');
    expect(ScuDspDisasm.disasm(0xd0000010), r'jmp $10');
    expect(ScuDspDisasm.disasm(0xd0080010), r'jmp nz, $10');
    expect(ScuDspDisasm.disasm(0xd1080010), r'jmp z, $10');
    expect(ScuDspDisasm.disasm(0xe8000000), 'lps');
    expect(ScuDspDisasm.disasm(0xf8000000), 'endi');
  });

  test('the debugger lists the SCU DSP and shows its program', () {
    final ss = Ss();
    expect(ss.cpuInfos.map((c) => c.name).last, 'SCU DSP');
    ss.scu.dsp.prog[4] = 0xf0000000;
    expect(ss.disasm(3, 4), ('04: f0000000 end', 1));
    ss.scu.dsp.data[1][2] = 0x11223344;
    expect(ss.read(3, 0x100 + 2 * 4 + 1), 0x22);
    expect(ss.programCounter(3), 0);
  });
}
