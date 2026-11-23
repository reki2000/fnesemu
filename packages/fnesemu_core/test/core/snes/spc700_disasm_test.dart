import 'package:fnesemu_core/src/core/snes/component/spc700.dart';
import 'package:fnesemu_core/src/core/snes/component/spc700_disasm.dart';
import 'package:fnesemu_core/src/core/snes/snes.dart';
import 'package:test/test.dart';

void main() {
  test('the IPL boot ROM disassembles as documented', () {
    final lines = <String>[];
    var pc = 0xffc0;
    while (pc < 0xffd4) {
      final at = pc - 0xffc0;
      final bytes = [for (var i = 0; i < 3; i++) iplRom[(at + i) % 64]];
      final (text, length) = Spc700Disasm.disasm(bytes, pc);
      lines.add(text);
      pc += length;
    }
    expect(lines, [
      'mov x, #\$ef',
      'mov sp, x',
      'mov a, #\$00',
      'mov (x), a',
      'dec x',
      'bne \$ffc5',
      'mov \$f4, #\$aa',
      'mov \$f5, #\$bb',
      'cmp \$f4, #\$cc',
      'bne \$ffcf',
    ]);
  });

  test('two-operand, bit and absolute forms', () {
    expect(Spc700Disasm.disasm([0xfa, 0x10, 0x20], 0), ('mov \$20, \$10', 3));
    expect(Spc700Disasm.disasm([0xaa, 0x34, 0xa2], 0),
        ('mov1 c, \$0234.5', 3));
    expect(Spc700Disasm.disasm([0x3f, 0x00, 0x08], 0), ('call !\$0800', 3));
    expect(Spc700Disasm.disasm([0x4f, 0x80, 0x00], 0), ('pcall \$ff80', 2));
    expect(Spc700Disasm.disasm([0x03, 0x12, 0xfd], 0x200),
        ('bbs \$12.0, \$0200', 3));
  });

  test('the debugger lists the sound CPU and reads its boot ROM', () {
    final snes = Snes();
    expect(snes.cpuInfos.map((c) => c.name), ['65816', 'SPC700']);
    expect(snes.programCounter(1), 0xffc0);
    expect(snes.disasm(1, 0xffc0), ('ffc0: cd ef    mov x, #\$ef', 2));
    expect(snes.read(1, 0xffc1), 0xef);
  });
}
