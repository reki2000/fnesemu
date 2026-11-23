import 'dart:typed_data';

import 'package:fnesemu_core/src/core/snes/component/cx4.dart';
import 'package:fnesemu_core/src/core/snes/component/cx4_disasm.dart';
import 'package:test/test.dart';

void main() {
  test('Cx4 instructions name their registers, immediates and shifts', () {
    expect(Cx4Disasm.disasm(0x6405), r'mov a, #$05');
    expect(Cx4Disasm.disasm(0x8603), r'add a, a<<8, #$03');
    expect(Cx4Disasm.disasm(0xe060), 'mov r0, a');
    expect(Cx4Disasm.disasm(0x9c02), r'smul a, #$02');
    expect(Cx4Disasm.disasm(0x6002), 'mov a, ml');
    expect(Cx4Disasm.disasm(0x5402), r'cmp a, #$02');
    expect(Cx4Disasm.disasm(0x2501), 'skipc');
    expect(Cx4Disasm.disasm(0x0a10), r'jmp page:$10');
    expect(Cx4Disasm.disasm(0xfc00), 'stop');
  });

  test('the program words and the PC of a finished command', () {
    final rom = Uint8List(0x8000);
    const program = [0x6405, 0xe060, 0xfc00]; // mov A,#05; mov R0,A; stop
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
    expect([for (var i = 0; i < 3; i++) cx4.debugWord(i)], program);
    expect(cx4.debugPc, 3);
    expect(cx4.debugRegisters, contains('r0:000005'));
  });
}
