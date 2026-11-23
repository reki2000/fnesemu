import 'package:fnesemu_core/src/core/snes/snes.dart';
import 'package:test/test.dart';

import 'test_rom.dart';

void main() {
  test('the debugger lists the SA-1 of a cartridge that has one', () {
    // The main CPU points the SA-1 reset vector at $8100 and releases it;
    // the SA-1 program then loops at $810a.
    final rom = loRom(romType: 0x34, sramSizeByte: 3);
    put(rom, 0x0000, [
      0xa9, 0x00, 0x8d, 0x03, 0x22, // LDA #$00; STA $2203
      0xa9, 0x81, 0x8d, 0x04, 0x22, // LDA #$81; STA $2204
      0x9c, 0x00, 0x22, // STZ $2200
      0x80, 0xfe, // BRA *
    ]);
    put(rom, 0x0100, [
      0xa9, 0xff, 0x8d, 0x2a, 0x22, // LDA #$ff; STA $222a
      0xa9, 0x42, 0x8d, 0x00, 0x30, // LDA #$42; STA $3000
      0x80, 0xfe, // BRA *
    ]);
    final snes = Snes()..setRom(rom);
    expect(snes.cpuInfos.map((c) => c.name), ['65816', 'SPC700', 'SA-1']);
    for (var i = 0; i < 2; i++) {
      snes.runFrame(snes.scanlinesInFrame);
    }
    expect(snes.programCounter(2) & 0xffff, 0x810a);
    expect(snes.disasm(2, snes.programCounter(2)).$1, contains('BRA'));
    expect(snes.read(2, 0x00810a), 0x80);
    expect(snes.trace(2).pc & 0xffff, 0x810a);

    expect((Snes()..setRom(loRom())).cpuInfos.length, 2);
  });
}
