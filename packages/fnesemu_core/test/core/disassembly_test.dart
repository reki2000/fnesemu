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

  test('N64 exposes assembler text and full-width register rows', () {
    final core = N64();
    core.bus.write(0xa0000000, 0x2402ffff, 4);
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

  test('ss sound CPU disassembly, trace and all CPU register dumps', () {
    final core = Ss();
    core.scsp.ram
        .setAll(0x100, [0x4e, 0x71, 0x20, 0x3c, 0x12, 0x34, 0x56, 0x78]);
    expect(core.disasm(2, 0x100).$1.toLowerCase(), contains('nop'));
    expect(core.disasm(2, 0x100).$2, 2);
    expect(core.disasm(2, 0x102).$1.toLowerCase(), contains('move.l'));
    expect(core.disasm(2, 0x102).$2, 6);
    core.scsp.cpu.pc = 0x100;
    expect(core.trace(2).pc, 0x100);
    expect(core.trace(2).disasm.toLowerCase(), contains('nop'));
    final dump = core.dump();
    expect(dump, contains('68000 sound'));
    expect(dump, contains('d7:'));
    expect(dump, contains('a7:'));
    final rows =
        dump.split('\n').where((row) => row.startsWith(RegExp(r'r\d+:')));
    expect(rows.length, 4); // Two SH2s, 16 general registers each.
    for (final row in rows) {
      expect(RegExp(r'r\d+:').allMatches(row).length, 8);
    }
  });

  test('Thumb BL combines signed high and low halfwords and advances correctly',
      () {
    expect(Arm7Disasm.thumb(0xf000, 0x08000000, nextHalfword: 0xf802),
        'bl 08000008');
    expect(Arm7Disasm.thumb(0xf7ff, 0x08001000, nextHalfword: 0xfffe),
        'bl 08001000');
    expect(Arm7Disasm.thumb(0xf000, 0x08000000), '.hword 0xf000');
    expect(Arm7Disasm.thumb(0xde00, 0x08000000), '.hword 0xde00');
    final core = Gba();
    core.cpu.regs.thumb = true;
    core.bus.write16(0x02000000, 0xf000);
    core.bus.write16(0x02000002, 0xf802);
    expect(core.disasm(0, 0x02000000).$1, contains('bl 02000008'));
    expect(core.disasm(0, 0x02000000).$2, 4);
    expect(core.disasm(0, 0x02000002).$1, contains('bl 02000008'));
    expect(core.disasm(0, 0x02000002).$2, 2);
  });

  test(
      'ARM and Thumb shifts, signed loads and coprocessors use assembler syntax',
      () {
    expect(Arm7Disasm.arm(0xe1a00021, 0), 'mov r0, r1, lsr #32');
    expect(Arm7Disasm.arm(0xe1a00061, 0), 'mov r0, r1, rrx');
    expect(Arm7Disasm.arm(0xe7910102, 0), 'ldr r0, [r1, r2, lsl #2]');
    expect(Arm7Disasm.arm(0xee110f10, 0), 'mrc p15, 0, r0, c1, c0, 0');
    expect(Arm7Disasm.arm(0xed910101, 0), 'ldc p1, c0, [r1, #4]');
    expect(Arm7Disasm.thumb(0x0808, 0), 'lsr r0, r1, #32');
    expect(Arm7Disasm.thumb(0x5600, 0), 'ldrsb r0, [r0, r0]');
    expect(Arm7Disasm.thumb(0x5a00, 0), 'ldrh r0, [r0, r0]');
  });

  test('SNES reports byte lengths at nonzero addresses with M/X widths', () {
    final core = Snes();
    core.bus.wram.setAll(0x100, [0xea, 0xa9, 0x34, 0x12]);
    expect(core.disasm(0, 0x7e0100).$2, 1);
    core.cpu.regs.e = true;
    expect(core.disasm(0, 0x7e0101).$2, 2);
    core.cpu.regs.e = false;
    core.cpu.regs.p = 0;
    expect(core.disasm(0, 0x7e0101).$2, 3);
    expect(core.disasm(0, 0x7e0101).$1, contains('LDA #\$1234'));
  });

  test('register rows wrap a final partial row and preserve unsigned bits', () {
    final dump = registerRows([for (var i = 0; i < 17; i++) ('r$i', -1)]);
    expect(dump.split('\n').map((line) => line.split(' ').length), [8, 8, 1]);
    expect(dump, contains('r16:ffffffff'));
  });
}
