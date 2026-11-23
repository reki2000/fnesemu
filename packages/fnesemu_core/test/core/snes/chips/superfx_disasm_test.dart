import 'package:fnesemu_core/src/core/snes/component/superfx_disasm.dart';
import 'package:fnesemu_core/src/core/snes/snes.dart';
import 'package:test/test.dart';

import '../test_rom.dart';

(String, int) _dis(List<int> bytes, [int pc = 0x8100]) =>
    SuperFxDisasm.disasm([...bytes, 0, 0, 0, 0, 0], pc);

void main() {
  test('Super FX instructions, ALT forms and prefixes', () {
    expect(_dis([0xa1, 0x05]), ('ibt r1, #\$05', 2));
    expect(_dis([0xf3, 0x34, 0x12]), ('iwt r3, #\$1234', 3));
    expect(_dis([0x3d, 0xf3, 0x34, 0x12]), ('lm r3, (\$1234)', 4));
    expect(_dis([0x3e, 0x52]), ('add #2', 2));
    expect(_dis([0x3f, 0x62]), ('cmp r2', 2));
    expect(_dis([0x3d, 0x4c]), ('rpix', 2));
    expect(_dis([0x21, 0x13]), ('move r3, r1', 2));
    expect(_dis([0x21, 0xb3]), ('moves r1, r3', 2));
    expect(_dis([0x08, 0xfe]), ('bne \$8100', 2));
    expect(_dis([0x3e, 0xdf]), ('ramb', 2));
  });

  test('the debugger lists the Super FX and disassembles at its pipeline', () {
    final rom = loRom(romType: 0x13, sramSizeByte: 3);
    put(rom, 0x0100, [0xa1, 0x05, 0x00, 0x01]); // IBT R1,#5 / STOP / NOP
    final snes = Snes()..setRom(rom);
    expect(snes.cpuInfos.map((c) => c.name), ['65816', 'SPC700', 'SuperFX']);
    expect(snes.disasm(2, 0x8100).$1, endsWith('ibt r1, #\$05'));
    expect(snes.read(2, 0x8101), 0x05);
    snes.bus.write(0x301e, 0x00);
    snes.bus.write(0x301f, 0x81);
    snes.bus.superFx!.run(1000);
    expect(snes.trace(2).regs, contains('r1:0005'));
  });
}
