import 'package:fnesemu_core/src/core/ps2/vu_disasm.dart';
import 'package:test/test.dart';

void main() {
  test('upper instructions with broadcast fields, Q, I and the accumulator',
      () {
    // ADDx.xyz vf1, vf2, vf3x: mask 0b1110, ft 3, fs 2, fd 1, op 0x00
    expect(VuDisasm.upper(0x0e << 21 | 3 << 16 | 2 << 11 | 1 << 6 | 0x00),
        'addx.xyz vf1, vf2, vf3x');
    // MULq vf4, vf5, Q with all fields
    expect(VuDisasm.upper(0x0f << 21 | 5 << 11 | 4 << 6 | 0x1c),
        'mulq vf4, vf5, Q');
    // MULAw ACC, vf6, vf7w: special, sub 6, col 3
    expect(VuDisasm.upper(0x0f << 21 | 7 << 16 | 6 << 11 | 6 << 6 | 0x3f),
        'mulaw ACC, vf6, vf7w');
    expect(VuDisasm.upper(0x000002ff), 'nop');
  });

  test('lower instructions, branches and the immediate of the I bit', () {
    expect(VuDisasm.lower(0x8000033c, 0), 'nop');
    // LQ.xyzw vf1, 2(vi3)
    expect(VuDisasm.lower(0x0f << 21 | 1 << 16 | 3 << 11 | 2, 0),
        'lq vf1, 2(vi3)');
    // IBNE vi1, vi2, -2 pairs from pair 4 lands on pair 3
    expect(VuDisasm.lower(0x29 << 25 | 1 << 16 | 2 << 11 | 0x7fe, 32),
        'ibne vi1, vi2, 0x0018');
    // XGKICK vi5
    expect(VuDisasm.lower(0x40 << 25 | 5 << 11 | 0x1b << 6 | 0x3c, 0),
        'xgkick vi5');
    expect(VuDisasm.pair(0x3f800000, 0x80000000 | 0x000002ff, 0),
        'nop : loi 1.0');
    expect(VuDisasm.pair(0x8000033c, 0x40000000 | 0x000002ff, 0),
        'nop[e] : nop');
  });
}
