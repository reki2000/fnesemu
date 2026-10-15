// The N64 CPU needs Int64List and full-width literals, unsupported by dart2js.
@TestOn('!dart2js')
library;

import 'package:fnesemu_core/src/core/n64/n64.dart';
import 'package:test/test.dart';

void main() {
  test('N64 exposes assembler text and full-width register rows', () {
    final core = N64();
    core.bus.write(0, 0x2402ffff, 4);
    expect(core.disasm(0, 0x80000000).$1, contains('addiu r2, r0, -1'));
    expect(core.disasm(0, 0x80000000).$2, 4);
    core.cpu.r[8] = -1;
    core.cpu.hi = 0x123456789abcdef0;
    core.cpu.fpu.setWord(1, 0xabcdef01);
    final dump = core.dump();
    final rows =
        dump.split('\n').where((row) => row.startsWith(RegExp(r'r\d+:')));
    expect(rows.length, 4);
    for (final row in rows) {
      expect(RegExp(r'r\d+:').allMatches(row).length, 8);
    }
    expect(dump, contains('r8:ffffffffffffffff'));
    expect(dump, contains('HI:123456789abcdef0'));
    expect(dump, contains('f1:abcdef01'));
    expect(dump, contains('CP0[31]:'));
    core.cpu.fpu.wide = true;
    core.cpu.fpu.setLong(31, -1);
    expect(core.dump(), contains('f31:ffffffffffffffff'));
  });
}
