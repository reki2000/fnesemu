import 'dart:typed_data';

import 'package:fnesemu_core/src/core/snes/component/cx4.dart';
import 'package:test/test.dart';

void main() {
  test('the data rom tables end at the documented values', () {
    final t = Cx4.dataRom;
    expect(t[0x000], 0xffffff); // div(0) overflows
    expect(t[0x0ff], 0x008080);
    expect(t[0x1ff], 0xff7fdf); // sqrt
    expect(t[0x27f], 0xfffb10); // sin
    expect(t[0x2ff], 0x75ceb4); // asin
    expect(t[0x37f], 0x517bb5); // tan
    expect(t[0x380], 0xffffff); // cos(0) overflows
    expect(t[0x3ff], 0x03243a);
  });

  test('a program adds, multiplies and stores to the registers', () {
    // the program at rom offset 0 ($00:8000)
    final rom = Uint8List(0x8000);
    final program = [
      0x6405, // mov A,#05
      0x8603, // add A,A*100h+#03     A = 0x0503
      0xe060, // mov R0,A
      0x9c02, // smul MH:ML,A,#02
      0x0000, // nop
      0x6002, // mov A,ML
      0xe061, // mov R1,A             R1 = 0x0a06
      0x6403, // mov A,#03
      0x5402, // cmp A,#02            C = 1
      0x2501, // skipc1
      0x6400, // mov A,#00 (skipped)
      0xe062, // mov R2,A             R2 = 3
      0xfc00, // stop
    ];
    for (var i = 0; i < program.length; i++) {
      rom[i * 2] = program[i] & 0xff;
      rom[i * 2 + 1] = program[i] >> 8;
    }
    final cx4 = Cx4((addr) => rom[addr & 0x7fff], rom)..reset();
    cx4.write(0x7f49, 0x00);
    cx4.write(0x7f4a, 0x80);
    cx4.write(0x7f4b, 0x00);
    cx4.write(0x7f4d, 0);
    cx4.write(0x7f4e, 0);
    cx4.write(0x7f4f, 0); // run
    int reg(int n) =>
        cx4.read(0x7f80 + n * 3) |
        cx4.read(0x7f81 + n * 3) << 8 |
        cx4.read(0x7f82 + n * 3) << 16;
    expect(reg(0), 0x0503);
    expect(reg(1), 0x0a06);
    expect(reg(2), 3);
  });
}
