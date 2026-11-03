import 'package:fnesemu_core/src/core/gba/arm7tdmi/arm_disasm.dart';
import 'package:fnesemu_core/src/core/gba/gba.dart';
import 'package:fnesemu_core/src/core/n64/disasm.dart';
import 'package:fnesemu_core/src/core/n64/n64.dart';
import 'package:fnesemu_core/src/core/snes/snes.dart';
import 'package:fnesemu_core/src/core/ss/ss.dart';
import 'package:fnesemu_core/src/util/register_dump.dart';
import 'package:test/test.dart';

void main() {
  test('VR4300 integer, branch, memory and coprocessor instructions', () {
    const cases = <int, String>{
      0: 'nop',
      0x2402ffff: 'addiu r2, r0, -1',
      0x6422ffff: 'daddiu r2, r1, -1',
      0x0022182d: 'daddu r3, r1, r2',
      0x000219fc: 'dsll32 r3, r2, 7',
      0x1022ffff: 'beq r1, r2, 0x80001000',
      0x0433fffe: 'bgezall r1, 0x80000ffc',
      0xdc22fff8: 'ld r2, -8(r1)',
      0xd4220008: 'ldc1 f2, 8(r1)',
      0xbc220010: 'cache 0x2, 16(r1)',
      0x40026000: 'mfc0 r2, status',
      0x42000018: 'eret',
      0x462218c0: 'add.d f3, f3, f2',
      0x46021832: 'c.eq.s f3, f2',
      0x4503ffff: 'bc1tl 0x80001000',
      0x44821800: 'mtc1 r2, f3',
      0x7c000000: '.word 0x7c000000',
    };
    for (final entry in cases.entries) {
      expect(Vr4300Disasm.disasm(entry.key, 0x80001000), entry.value,
          reason: entry.key.toRadixString(16));
    }
    expect(Vr4300Disasm.disasm(0x08000004, 0x8ffffffc), 'j 0x90000010');
  });

}
