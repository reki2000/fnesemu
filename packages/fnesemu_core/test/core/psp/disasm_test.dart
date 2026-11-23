import 'package:fnesemu_core/src/core/psp/disasm.dart';
import 'package:test/test.dart';

String _dis(int word, [int pc = 0x08804000]) => AllegrexDisasm.disasm(word, pc);

void main() {
  test('integer instructions and their extensions', () {
    expect(_dis(0x27bdfff0), 'addiu sp, sp, -0x10');
    expect(_dis(0x03e00008), 'jr ra');
    expect(_dis(0x0c000010), 'jal 0x00000040');
    expect(_dis(0x1000ffff), 'b 0x08804000');
    expect(_dis(0x7c823a00), 'ext v0, a0, 8, 8');
    expect(_dis(0x7c021c20), 'seb v1, v0');
    expect(_dis(0x0085102c), 'max v0, a0, a1');
    expect(_dis(0x0000000c | 0x1234 << 6), 'syscall 0x1234');
  });

  test('FPU instructions', () {
    expect(_dis(0x46020800), 'add.s f0, f1, f2');
    expect(_dis(0x46020832), 'c.eq.s f1, f2');
    expect(_dis(0x45010004), 'bc1t 0x08804014');
  });

  test('VFPU instructions name their operands by matrix, line and lane', () {
    expect(_dis(0x60028180), 'vadd.q C000, C010, C020');
    expect(_dis(0xdc0000e4), 'vpfxs [x, y, z, w]');
    expect(_dis(0xffff0000), 'vnop');
    expect(_dis(0xd8800010), 'lv.q C000, 0x10(a0)');
    expect(_dis(0xf0088480), 'vmmul.q M000, M100, M200');
    expect(_dis(0xd0060000 | 0x8000 | 0x80 | 0x20), 'vzero.q R000');
    expect(_dis(0xdf000000 | 1 << 16 | 0x3c00), 'viim.s S010, 15360');
    expect(_dis(0xdf800000 | 1 << 16 | 0x3c00), 'vfim.s S010, 1.0');
  });
}
