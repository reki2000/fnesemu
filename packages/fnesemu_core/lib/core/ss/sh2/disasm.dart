/// SH-2 disassembler
class Sh2Disasm {
  static String _h(int v) => '0x${(v & 0xffffffff).toRadixString(16)}';

  static String disasm(int op, int pc) {
    final n = (op >> 8) & 15;
    final m = (op >> 4) & 15;
    final d4 = op & 15;
    final i8 = op & 255;
    final s8 = i8.toSigned(8);

    String disp8() => _h(pc + 4 + s8 * 2);
    String pcrel(int scale) =>
        _h((scale == 4 ? (pc + 4) & ~3 : pc + 4) + i8 * scale);

    switch (op >> 12) {
      case 0x0:
        switch (d4) {
          case 0x4:
            return 'mov.b r$m,@(r0,r$n)';
          case 0x5:
            return 'mov.w r$m,@(r0,r$n)';
          case 0x6:
            return 'mov.l r$m,@(r0,r$n)';
          case 0x7:
            return 'mul.l r$m,r$n';
          case 0xc:
            return 'mov.b @(r0,r$m),r$n';
          case 0xd:
            return 'mov.w @(r0,r$m),r$n';
          case 0xe:
            return 'mov.l @(r0,r$m),r$n';
          case 0xf:
            return 'mac.l @r$m+,@r$n+';
        }
        switch (op & 0xff) {
          case 0x02:
            return 'stc sr,r$n';
          case 0x12:
            return 'stc gbr,r$n';
          case 0x22:
            return 'stc vbr,r$n';
          case 0x03:
            return 'bsrf r$n';
          case 0x23:
            return 'braf r$n';
          case 0x0a:
            return 'sts mach,r$n';
          case 0x1a:
            return 'sts macl,r$n';
          case 0x2a:
            return 'sts pr,r$n';
          case 0x29:
            return 'movt r$n';
        }
        return switch (op) {
          0x0008 => 'clrt',
          0x0009 => 'nop',
          0x000b => 'rts',
          0x0018 => 'sett',
          0x0019 => 'div0u',
          0x001b => 'sleep',
          0x0028 => 'clrmac',
          0x002b => 'rte',
          _ => _unknown(op),
        };
      case 0x1:
        return 'mov.l r$m,@(${d4 * 4},r$n)';
      case 0x2:
        return switch (d4) {
          0x0 => 'mov.b r$m,@r$n',
          0x1 => 'mov.w r$m,@r$n',
          0x2 => 'mov.l r$m,@r$n',
          0x4 => 'mov.b r$m,@-r$n',
          0x5 => 'mov.w r$m,@-r$n',
          0x6 => 'mov.l r$m,@-r$n',
          0x7 => 'div0s r$m,r$n',
          0x8 => 'tst r$m,r$n',
          0x9 => 'and r$m,r$n',
          0xa => 'xor r$m,r$n',
          0xb => 'or r$m,r$n',
          0xc => 'cmp/str r$m,r$n',
          0xd => 'xtrct r$m,r$n',
          0xe => 'mulu.w r$m,r$n',
          0xf => 'muls.w r$m,r$n',
          _ => _unknown(op),
        };
      case 0x3:
        return switch (d4) {
          0x0 => 'cmp/eq r$m,r$n',
          0x2 => 'cmp/hs r$m,r$n',
          0x3 => 'cmp/ge r$m,r$n',
          0x4 => 'div1 r$m,r$n',
          0x5 => 'dmulu.l r$m,r$n',
          0x6 => 'cmp/hi r$m,r$n',
          0x7 => 'cmp/gt r$m,r$n',
          0x8 => 'sub r$m,r$n',
          0xa => 'subc r$m,r$n',
          0xb => 'subv r$m,r$n',
          0xc => 'add r$m,r$n',
          0xd => 'dmuls.l r$m,r$n',
          0xe => 'addc r$m,r$n',
          0xf => 'addv r$m,r$n',
          _ => _unknown(op),
        };
      case 0x4:
        if (d4 == 0xf) return 'mac.w @r$m+,@r$n+';
        return switch (op & 0xff) {
          0x00 => 'shll r$n',
          0x01 => 'shlr r$n',
          0x02 => 'sts.l mach,@-r$n',
          0x03 => 'stc.l sr,@-r$n',
          0x04 => 'rotl r$n',
          0x05 => 'rotr r$n',
          0x06 => 'lds.l @r$n+,mach',
          0x07 => 'ldc.l @r$n+,sr',
          0x08 => 'shll2 r$n',
          0x09 => 'shlr2 r$n',
          0x0a => 'lds r$n,mach',
          0x0b => 'jsr @r$n',
          0x0e => 'ldc r$n,sr',
          0x10 => 'dt r$n',
          0x11 => 'cmp/pz r$n',
          0x12 => 'sts.l macl,@-r$n',
          0x13 => 'stc.l gbr,@-r$n',
          0x15 => 'cmp/pl r$n',
          0x16 => 'lds.l @r$n+,macl',
          0x17 => 'ldc.l @r$n+,gbr',
          0x18 => 'shll8 r$n',
          0x19 => 'shlr8 r$n',
          0x1a => 'lds r$n,macl',
          0x1b => 'tas.b @r$n',
          0x1e => 'ldc r$n,gbr',
          0x20 => 'shal r$n',
          0x21 => 'shar r$n',
          0x22 => 'sts.l pr,@-r$n',
          0x23 => 'stc.l vbr,@-r$n',
          0x24 => 'rotcl r$n',
          0x25 => 'rotcr r$n',
          0x26 => 'lds.l @r$n+,pr',
          0x27 => 'ldc.l @r$n+,vbr',
          0x28 => 'shll16 r$n',
          0x29 => 'shlr16 r$n',
          0x2a => 'lds r$n,pr',
          0x2b => 'jmp @r$n',
          0x2e => 'ldc r$n,vbr',
          _ => _unknown(op),
        };
      case 0x5:
        return 'mov.l @(${d4 * 4},r$m),r$n';
      case 0x6:
        return switch (d4) {
          0x0 => 'mov.b @r$m,r$n',
          0x1 => 'mov.w @r$m,r$n',
          0x2 => 'mov.l @r$m,r$n',
          0x3 => 'mov r$m,r$n',
          0x4 => 'mov.b @r$m+,r$n',
          0x5 => 'mov.w @r$m+,r$n',
          0x6 => 'mov.l @r$m+,r$n',
          0x7 => 'not r$m,r$n',
          0x8 => 'swap.b r$m,r$n',
          0x9 => 'swap.w r$m,r$n',
          0xa => 'negc r$m,r$n',
          0xb => 'neg r$m,r$n',
          0xc => 'extu.b r$m,r$n',
          0xd => 'extu.w r$m,r$n',
          0xe => 'exts.b r$m,r$n',
          _ => 'exts.w r$m,r$n',
        };
      case 0x7:
        return 'add #$s8,r$n';
      case 0x8:
        return switch (n) {
          0x0 => 'mov.b r0,@($d4,r$m)',
          0x1 => 'mov.w r0,@(${d4 * 2},r$m)',
          0x4 => 'mov.b @($d4,r$m),r0',
          0x5 => 'mov.w @(${d4 * 2},r$m),r0',
          0x8 => 'cmp/eq #$s8,r0',
          0x9 => 'bt ${disp8()}',
          0xb => 'bf ${disp8()}',
          0xd => 'bt/s ${disp8()}',
          0xf => 'bf/s ${disp8()}',
          _ => _unknown(op),
        };
      case 0x9:
        return 'mov.w @(${pcrel(2)}),r$n';
      case 0xa:
        return 'bra ${_h(pc + 4 + (op & 0xfff).toSigned(12) * 2)}';
      case 0xb:
        return 'bsr ${_h(pc + 4 + (op & 0xfff).toSigned(12) * 2)}';
      case 0xc:
        return switch (n) {
          0x0 => 'mov.b r0,@($i8,gbr)',
          0x1 => 'mov.w r0,@(${i8 * 2},gbr)',
          0x2 => 'mov.l r0,@(${i8 * 4},gbr)',
          0x3 => 'trapa #$i8',
          0x4 => 'mov.b @($i8,gbr),r0',
          0x5 => 'mov.w @(${i8 * 2},gbr),r0',
          0x6 => 'mov.l @(${i8 * 4},gbr),r0',
          0x7 => 'mova @(${pcrel(4)}),r0',
          0x8 => 'tst #$i8,r0',
          0x9 => 'and #$i8,r0',
          0xa => 'xor #$i8,r0',
          0xb => 'or #$i8,r0',
          0xc => 'tst.b #$i8,@(r0,gbr)',
          0xd => 'and.b #$i8,@(r0,gbr)',
          0xe => 'xor.b #$i8,@(r0,gbr)',
          _ => 'or.b #$i8,@(r0,gbr)',
        };
      case 0xd:
        return 'mov.l @(${pcrel(4)}),r$n';
      case 0xe:
        return 'mov #$s8,r$n';
      default:
        return _unknown(op);
    }
  }

  static String _unknown(int op) =>
      '.word 0x${op.toRadixString(16).padLeft(4, '0')}';
}
