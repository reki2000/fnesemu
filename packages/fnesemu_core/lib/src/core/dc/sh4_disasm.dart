import '../../util/int.dart';

/// SH-4 mnemonics from the SH-4 Programming Manual and this core's decoder.
/// FPSCR selects the arithmetic precision and FMOV register-pair interpretation.
String dcSh4Disasm(int opcode, int address, {int fpscr = 0}) {
  final op = opcode & 0xffff, n = (opcode >> 8) & 15, m = (opcode >> 4) & 15;
  final imm = op & 255, low = op & 15, code = op & 0xf0ff;
  String hex(int value) => '0x${value.mask32.x8}';
  String fallback() => '.word 0x${op.x4}';
  final fixed = const <int, String>{
    0x0008: 'clrt',
    0x0009: 'nop',
    0x000b: 'rts',
    0x0018: 'sett',
    0x0019: 'div0u',
    0x001b: 'sleep',
    0x0028: 'clrmac',
    0x002b: 'rte',
    0x0038: 'ldtlb',
    0x0048: 'clrs',
    0x0058: 'sets'
  }[op];
  if (fixed != null) return fixed;
  final one = const <int, String>{
    0x0029: 'movt',
    0x4000: 'shll',
    0x4001: 'shlr',
    0x4004: 'rotl',
    0x4005: 'rotr',
    0x4008: 'shll2',
    0x4009: 'shlr2',
    0x4010: 'dt',
    0x4011: 'cmp/pz',
    0x4015: 'cmp/pl',
    0x4018: 'shll8',
    0x4019: 'shlr8',
    0x4020: 'shal',
    0x4021: 'shar',
    0x4024: 'rotcl',
    0x4025: 'rotcr',
    0x4028: 'shll16',
    0x4029: 'shlr16'
  }[code];
  if (one != null) return '$one r$n';
  final indirect = const <int, String>{
    0x0083: 'pref',
    0x0093: 'ocbi',
    0x00a3: 'ocbp',
    0x00b3: 'ocbwb',
    0x400b: 'jsr',
    0x402b: 'jmp',
    0x401b: 'tas.b'
  }[code];
  if (indirect != null) return '$indirect @r$n';
  if (code == 0x00c3) return 'movca.l r0,@r$n';
  if (code == 0x0003 || code == 0x0023) {
    return '${code == 3 ? 'bsrf' : 'braf'} r$n';
  }
  const controls = [
    'sr',
    'gbr',
    'vbr',
    'ssr',
    'spc',
    null,
    null,
    null,
    'r0_bank',
    'r1_bank',
    'r2_bank',
    'r3_bank',
    'r4_bank',
    'r5_bank',
    'r6_bank',
    'r7_bank'
  ];
  final selector = (op >> 4) & 15;
  final control = controls[selector];
  if (control != null) {
    switch (op & 0xf00f) {
      case 0x0002:
        return 'stc $control,r$n';
      case 0x4003:
        return 'stc.l $control,@-r$n';
      case 0x400e:
        return 'ldc r$n,$control';
      case 0x4007:
        return 'ldc.l @r$n+,$control';
    }
  }
  final special = const <int, String>{
    0: 'mach',
    1: 'macl',
    2: 'pr',
    5: 'fpul',
    6: 'fpscr'
  }[selector];
  if (special != null) {
    switch (op & 0xf00f) {
      case 0x000a:
        return 'sts $special,r$n';
      case 0x4002:
        return 'sts.l $special,@-r$n';
      case 0x400a:
        return 'lds r$n,$special';
      case 0x4006:
        return 'lds.l @r$n+,$special';
    }
  }
  final extraControl = switch (code) {
    0x003a => 'stc sgr,r$n',
    0x4032 => 'stc.l sgr,@-r$n',
    0x00fa => 'stc dbr,r$n',
    0x40f2 => 'stc.l dbr,@-r$n',
    0x40fa => 'ldc r$n,dbr',
    0x40f6 => 'ldc.l @r$n+,dbr',
    _ => null,
  };
  if (extraControl != null) return extraControl;
  final binary = const <int, String>{
    0x6003: 'mov',
    0x300c: 'add',
    0x300e: 'addc',
    0x300f: 'addv',
    0x3008: 'sub',
    0x300a: 'subc',
    0x300b: 'subv',
    0x3000: 'cmp/eq',
    0x3002: 'cmp/hs',
    0x3003: 'cmp/ge',
    0x3006: 'cmp/hi',
    0x3007: 'cmp/gt',
    0x200c: 'cmp/str',
    0x2008: 'tst',
    0x2009: 'and',
    0x200a: 'xor',
    0x200b: 'or',
    0x6007: 'not',
    0x600b: 'neg',
    0x600a: 'negc',
    0x6008: 'swap.b',
    0x6009: 'swap.w',
    0x600c: 'extu.b',
    0x600d: 'extu.w',
    0x600e: 'exts.b',
    0x600f: 'exts.w',
    0x200d: 'xtrct',
    0x400c: 'shad',
    0x400d: 'shld',
    0x0007: 'mul.l',
    0x200e: 'mulu.w',
    0x200f: 'muls.w',
    0x3005: 'dmulu.l',
    0x300d: 'dmuls.l',
    0x2007: 'div0s',
    0x3004: 'div1'
  }[op & 0xf00f];
  if (binary != null) return '$binary r$m,r$n';
  if (op & 0xf00f == 0x000f || op & 0xf00f == 0x400f) {
    return 'mac.${op >> 12 == 0 ? 'l' : 'w'} @r$m+,@r$n+';
  }
  const sizes = ['b', 'w', 'l'];
  final shape = op & 0xf00f;
  if ([0x2000, 0x2001, 0x2002, 0x2004, 0x2005, 0x2006].contains(shape)) {
    return 'mov.${sizes[low & 3]} r$m,${low & 4 != 0 ? '@-' : '@'}r$n';
  }
  if ([0x6000, 0x6001, 0x6002, 0x6004, 0x6005, 0x6006].contains(shape)) {
    return 'mov.${sizes[low & 3]} @r$m${low & 4 != 0 ? '+' : ''},r$n';
  }
  if (op >> 12 == 0 && low >= 4 && low <= 6) {
    return 'mov.${sizes[low - 4]} r$m,@(r0,r$n)';
  }
  if (op >> 12 == 0 && low >= 12 && low <= 14) {
    return 'mov.${sizes[low - 12]} @(r0,r$m),r$n';
  }
  if (op >> 12 == 1) return 'mov.l r$m,@(${low * 4},r$n)';
  if (op >> 12 == 5) return 'mov.l @(${low * 4},r$m),r$n';
  if (op >> 12 == 7 || op >> 12 == 14) {
    return '${op >> 12 == 7 ? 'add' : 'mov'} #${imm.rel8},r$n';
  }
  if (op >> 12 == 9 || op >> 12 == 13) {
    final size = op >> 12 == 9 ? 2 : 4;
    final target = (size == 2 ? address + 4 : (address & ~3) + 4) + imm * size;
    return 'mov.${size == 2 ? 'w' : 'l'} @(${imm * size},pc),r$n ; ${hex(target)}';
  }
  if (op >> 12 == 10 || op >> 12 == 11) {
    return '${op >> 12 == 10 ? 'bra' : 'bsr'} ${hex(address + 4 + (((op & 0xfff) ^ 0x800) - 0x800) * 2)}';
  }
  final high = op >> 8;
  final branch =
      <int, String>{0x89: 'bt', 0x8b: 'bf', 0x8d: 'bt/s', 0x8f: 'bf/s'}[high];
  if (branch != null) return '$branch ${hex(address + 4 + imm.rel8 * 2)}';
  if (high == 0x88) return 'cmp/eq #${imm.rel8},r0';
  if ([0x80, 0x81, 0x84, 0x85].contains(high)) {
    final size = high & 1, displacement = low * (1 << size);
    return high & 4 == 0
        ? 'mov.${sizes[size]} r0,@($displacement,r$m)'
        : 'mov.${sizes[size]} @($displacement,r$m),r0';
  }
  if ([0xc0, 0xc1, 0xc2, 0xc4, 0xc5, 0xc6].contains(high)) {
    final size = high & 3, displacement = imm * (1 << size);
    return high & 4 == 0
        ? 'mov.${sizes[size]} r0,@($displacement,gbr)'
        : 'mov.${sizes[size]} @($displacement,gbr),r0';
  }
  if (high == 0xc3) return 'trapa #$imm';
  if (high == 0xc7) {
    return 'mova @(${imm * 4},pc),r0 ; ${hex((address & ~3) + 4 + imm * 4)}';
  }
  if (high >= 0xc8 && high <= 0xcb) {
    return '${['tst', 'and', 'xor', 'or'][high - 0xc8]} #$imm,r0';
  }
  if (high >= 0xcc && high <= 0xcf) {
    return '${[
      'tst.b',
      'and.b',
      'xor.b',
      'or.b'
    ][high - 0xcc]} #$imm,@(r0,gbr)';
  }
  if (op >> 12 == 15) return _floating(op, fpscr) ?? fallback();
  return fallback();
}

String? _floating(int op, int fpscr) {
  final n = (op >> 8) & 15, m = (op >> 4) & 15, low = op & 15;
  final wide = fpscr & 0x80000 != 0, pair = fpscr & 0x100000 != 0;
  String? arithmetic(int index) =>
      wide ? (index.isEven ? 'dr$index' : null) : 'fr$index';
  String move(int index) =>
      pair ? '${index.isEven ? 'dr' : 'xd'}${index & 14}' : 'fr$index';
  if (low >= 6 && low <= 12) {
    final suffix = pair ? 'd' : 's';
    return switch (low) {
      6 => 'fmov.$suffix @(r0,r$m),${move(n)}',
      7 => 'fmov.$suffix ${move(m)},@(r0,r$n)',
      8 => 'fmov.$suffix @r$m,${move(n)}',
      9 => 'fmov.$suffix @r$m+,${move(n)}',
      10 => 'fmov.$suffix ${move(m)},@r$n',
      11 => 'fmov.$suffix ${move(m)},@-r$n',
      _ => 'fmov ${move(m)},${move(n)}',
    };
  }
  if (op == 0xfbfd || op == 0xf3fd) {
    return wide
        ? null
        : op == 0xfbfd
            ? 'frchg'
            : 'fschg';
  }
  if (op & 0xf0ff == 0xf00d) return 'fsts fpul,fr$n';
  if (op & 0xf0ff == 0xf01d) return 'flds fr$n,fpul';
  if (!wide && op & 0xf0ff == 0xf08d) return 'fldi0 fr$n';
  if (!wide && op & 0xf0ff == 0xf09d) return 'fldi1 fr$n';
  if (!wide && op & 0xf0ff == 0xf0ed) {
    return 'fipr fv${(n & 3) * 4},fv${(n >> 2) * 4}';
  }
  if (!wide && op & 0xf3ff == 0xf1fd) return 'ftrv xmtrx,fv${(n >> 2) * 4}';
  if (!wide && op & 0xf1ff == 0xf0fd) return 'fsca fpul,dr$n';
  final rn = arithmetic(n), rm = arithmetic(m);
  if (low <= 5) {
    if (rn == null || rm == null) return null;
    return '${[
      'fadd',
      'fsub',
      'fmul',
      'fdiv',
      'fcmp/eq',
      'fcmp/gt'
    ][low]} $rm,$rn';
  }
  if (low == 14 && !wide) return 'fmac fr0,fr$m,fr$n';
  if (rn == null) return null;
  return switch (op & 0xf0ff) {
    0xf02d => 'float fpul,$rn',
    0xf03d => 'ftrc $rn,fpul',
    0xf04d => 'fneg $rn',
    0xf05d => 'fabs $rn',
    0xf06d => 'fsqrt $rn',
    0xf07d => wide ? null : 'fsrra fr$n',
    0xf0ad => wide ? 'fcnvsd fpul,$rn' : null,
    0xf0bd => wide ? 'fcnvds $rn,fpul' : null,
    _ => null,
  };
}
