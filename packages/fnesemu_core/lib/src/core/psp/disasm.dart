/// Allegrex instruction formatting: the MIPS32 integer core with its
/// extensions, the FPU and the multimedia coprocessor (VFPU). It follows
/// the decoding of allegrex.dart and vfpu.dart and never reads machine
/// state.
library;

import 'dart:math' as math;

class AllegrexDisasm {
  static const regs = [
    'zero', 'at', 'v0', 'v1', 'a0', 'a1', 'a2', 'a3', //
    't0', 't1', 't2', 't3', 't4', 't5', 't6', 't7', //
    's0', 's1', 's2', 's3', 's4', 's5', 's6', 's7', //
    't8', 't9', 'k0', 'k1', 'gp', 'sp', 'fp', 'ra', //
  ];

  static const _fpuCompare = [
    'f', 'un', 'eq', 'ueq', 'olt', 'ult', 'ole', 'ule', //
    'sf', 'ngle', 'seq', 'ngl', 'lt', 'nge', 'le', 'ngt', //
  ];

  static const _vfpuCompare = [
    'fl', 'eq', 'lt', 'le', 'tr', 'ne', 'ge', 'gt', //
    'ez', 'en', 'ei', 'es', 'nz', 'nn', 'ni', 'ns', //
  ];

  /// The three-operand operations by (major opcode << 4) | function.
  static const _arith = {
    0x180: 'vadd',
    0x181: 'vsub',
    0x187: 'vdiv',
    0x190: 'vmul',
    0x191: 'vdot',
    0x192: 'vscl',
    0x194: 'vhdp',
    0x195: 'vcrs',
    0x196: 'vdet',
    0x1b2: 'vmin',
    0x1b3: 'vmax',
    0x1b5: 'vscmp',
    0x1b6: 'vsge',
    0x1b7: 'vslt',
  };

  /// The one-source operations of VFPU4 with the rs field zero, by the
  /// selector at bits 22-16.
  static const _unary = {
    0x00: 'vmov',
    0x01: 'vabs',
    0x02: 'vneg',
    0x03: 'vidt',
    0x04: 'vsat0',
    0x05: 'vsat1',
    0x06: 'vzero',
    0x07: 'vone',
    0x10: 'vrcp',
    0x11: 'vrsq',
    0x12: 'vsin',
    0x13: 'vcos',
    0x14: 'vexp2',
    0x15: 'vlog2',
    0x16: 'vsqrt',
    0x17: 'vasin',
    0x18: 'vnrcp',
    0x1a: 'vnsin',
    0x1c: 'vrexp2',
    0x20: 'vrnds',
    0x21: 'vrndi',
    0x22: 'vrndf1',
    0x23: 'vrndf2',
    0x32: 'vf2h',
    0x33: 'vh2f',
    0x38: 'vuc2i',
    0x39: 'vc2i',
    0x3a: 'vus2i',
    0x3b: 'vs2i',
    0x3c: 'vi2uc',
    0x3d: 'vi2c',
    0x3e: 'vi2us',
    0x3f: 'vi2s',
    0x40: 'vsrt1',
    0x41: 'vsrt2',
    0x42: 'vbfy1',
    0x43: 'vbfy2',
    0x44: 'vocp',
    0x45: 'vsocp',
    0x46: 'vfad',
    0x47: 'vavg',
    0x48: 'vsrt3',
    0x49: 'vsrt4',
    0x4a: 'vsgn',
    0x50: 'vmfvc',
    0x51: 'vmtvc',
    0x59: 'vt4444',
    0x5a: 'vt5551',
    0x5b: 'vt5650',
  };

  /// The names of the vcst constants, from selector 0x60.
  static const _constants = [
    '0', 'huge', 'sqrt2', 'sqrt1_2', '2_sqrtpi', '2_pi', '1_pi', 'pi_4', //
    'pi_2', 'pi', 'e', 'log2e', 'log10e', 'ln2', 'ln10', '2pi', //
    'pi_6', 'log10two', 'log2ten', 'sqrt3_2', //
  ];

  /// The constants a source prefix substitutes, by swizzle plus four
  /// when the absolute-value bit is set.
  static const _prefixConstants = [
    '0', '1', '2', '1/2', '3', '1/3', '1/4', '1/6', //
  ];

  static String _hex(int value) =>
      '0x${(value & 0xffffffff).toRadixString(16).padLeft(8, '0')}';

  static String _imm(int value) => value < 0
      ? '-0x${(-value).toRadixString(16)}'
      : '0x${value.toRadixString(16)}';

  static String _unknown(int word) => 'unknown ${_hex(word)}';

  /// A single element: S, the matrix, the column and the row.
  static String single(int o) => 'S${(o >> 2) & 7}${o & 3}${(o >> 5) & 3}';

  /// A vector of [n] lanes: a column (C, the matrix, the column and the
  /// first row) or a row (R, the matrix, the row and the first column).
  static String vector(int o, int n) {
    if (n == 1) return single(o);
    final half = (o >> 6) & 1;
    final start = n == 2 ? half * 2 : (n == 3 ? half : 0);
    return '${o & 0x20 == 0 ? 'C' : 'R'}${(o >> 2) & 7}${o & 3}$start';
  }

  /// A matrix of [n] by [n]: M, or E for the transposed form, then the
  /// matrix and the offsets of its first row and column.
  static String matrix(int o, int n) {
    final half = (o >> 6) & 1;
    final start = n == 2 ? half * 2 : (n == 3 ? half : 0);
    return '${o & 0x20 == 0 ? 'M' : 'E'}${(o >> 2) & 7}${o & 3}$start';
  }

  static String _control(int index) => switch (index) {
        128 => 'vpfxs',
        129 => 'vpfxt',
        130 => 'vpfxd',
        131 => 'vcc',
        >= 136 && <= 143 => 'rcx${index - 136}',
        < 128 => single(index),
        _ => 'vc$index',
      };

  /// Formats [word] fetched at [pc].
  static String disasm(int word, int pc) {
    word &= 0xffffffff;
    final op = word >>> 26;
    final rs = (word >> 21) & 31, rt = (word >> 16) & 31;
    final rd = (word >> 11) & 31, sa = (word >> 6) & 31;
    final s = regs[rs], t = regs[rt], d = regs[rd];
    final offset = (word & 0xffff).toSigned(16);
    final branch = _hex(pc + 4 + offset * 4);
    final memory = '${_imm(offset)}($s)';
    return switch (op) {
      0x00 => _special(word),
      0x01 => switch (rt) {
          0x00 => 'bltz $s, $branch',
          0x01 => 'bgez $s, $branch',
          0x02 => 'bltzl $s, $branch',
          0x03 => 'bgezl $s, $branch',
          0x10 => 'bltzal $s, $branch',
          0x11 => 'bgezal $s, $branch',
          0x12 => 'bltzall $s, $branch',
          0x13 => 'bgezall $s, $branch',
          0x1f => 'synci $memory',
          _ => _unknown(word),
        },
      0x02 => 'j ${_hex((pc + 4) & 0xf0000000 | (word & 0x3ffffff) << 2)}',
      0x03 => 'jal ${_hex((pc + 4) & 0xf0000000 | (word & 0x3ffffff) << 2)}',
      0x04 => rs == 0 && rt == 0 ? 'b $branch' : 'beq $s, $t, $branch',
      0x05 => 'bne $s, $t, $branch',
      0x06 => 'blez $s, $branch',
      0x07 => 'bgtz $s, $branch',
      0x14 => 'beql $s, $t, $branch',
      0x15 => 'bnel $s, $t, $branch',
      0x16 => 'blezl $s, $branch',
      0x17 => 'bgtzl $s, $branch',
      0x08 => 'addi $t, $s, ${_imm(offset)}',
      0x09 =>
        rs == 0 ? 'li $t, ${_imm(offset)}' : 'addiu $t, $s, ${_imm(offset)}',
      0x0a => 'slti $t, $s, ${_imm(offset)}',
      0x0b => 'sltiu $t, $s, ${_imm(offset)}',
      0x0c => 'andi $t, $s, ${_imm(word & 0xffff)}',
      0x0d => 'ori $t, $s, ${_imm(word & 0xffff)}',
      0x0e => 'xori $t, $s, ${_imm(word & 0xffff)}',
      0x0f => 'lui $t, ${_imm(word & 0xffff)}',
      0x10 => switch (rs) {
          0x00 => 'mfc0 $t, \$$rd',
          0x04 => 'mtc0 $t, \$$rd',
          0x0b => '${word & 0x20 != 0 ? 'ei' : 'di'} $t',
          0x10 when word & 0x3f == 0x18 => 'eret',
          _ => _unknown(word),
        },
      0x11 => _fpu(word, pc),
      0x1c => switch (word & 0x3f) {
          0x00 => 'madd $s, $t',
          0x01 => 'maddu $s, $t',
          0x02 => 'mul $d, $s, $t',
          0x04 => 'msub $s, $t',
          0x05 => 'msubu $s, $t',
          0x20 => 'clz $d, $s',
          0x21 => 'clo $d, $s',
          _ => _unknown(word),
        },
      0x1f => switch (word & 0x3f) {
          0x00 => 'ext $t, $s, $sa, ${rd + 1}',
          0x04 => 'ins $t, $s, $sa, ${rd - sa + 1}',
          0x20 => switch (sa) {
              0x02 => 'wsbh $d, $t',
              0x03 => 'wsbw $d, $t',
              0x10 => 'seb $d, $t',
              0x14 => 'bitrev $d, $t',
              0x18 => 'seh $d, $t',
              _ => _unknown(word),
            },
          _ => _unknown(word),
        },
      0x20 => 'lb $t, $memory',
      0x21 => 'lh $t, $memory',
      0x22 => 'lwl $t, $memory',
      0x23 => 'lw $t, $memory',
      0x24 => 'lbu $t, $memory',
      0x25 => 'lhu $t, $memory',
      0x26 => 'lwr $t, $memory',
      0x28 => 'sb $t, $memory',
      0x29 => 'sh $t, $memory',
      0x2a => 'swl $t, $memory',
      0x2b => 'sw $t, $memory',
      0x2e => 'swr $t, $memory',
      0x2f => 'cache 0x${rt.toRadixString(16)}, $memory',
      0x30 => 'll $t, $memory',
      0x31 => 'lwc1 f$rt, $memory',
      0x33 => 'pref $rt, $memory',
      0x38 => 'sc $t, $memory',
      0x39 => 'swc1 f$rt, $memory',
      0x12 => _cop2(word, pc),
      0x18 || 0x19 || 0x1b => _vfpuArith(word),
      0x32 || 0x35 || 0x36 || 0x3a || 0x3d || 0x3e => _vfpuMemory(word),
      0x34 => _vfpu4(word),
      0x37 => _vfpu5(word),
      0x3c => _vfpu6(word),
      0x3f => switch (word) {
          0xffff0000 => 'vnop',
          0xffff0320 => 'vsync',
          0xffff040d => 'vflush',
          _ when word >>> 16 == 0xffff =>
            'vsync 0x${(word & 0xffff).toRadixString(16)}',
          _ => _unknown(word),
        },
      _ => _unknown(word),
    };
  }

  static String _special(int word) {
    final rs = (word >> 21) & 31, rt = (word >> 16) & 31;
    final rd = (word >> 11) & 31, sa = (word >> 6) & 31;
    final s = regs[rs], t = regs[rt], d = regs[rd];
    if (word == 0) return 'nop';
    return switch (word & 0x3f) {
      0x00 => 'sll $d, $t, $sa',
      0x02 => rs == 1 ? 'rotr $d, $t, $sa' : 'srl $d, $t, $sa',
      0x03 => 'sra $d, $t, $sa',
      0x04 => 'sllv $d, $t, $s',
      0x06 => sa & 1 != 0 ? 'rotrv $d, $t, $s' : 'srlv $d, $t, $s',
      0x07 => 'srav $d, $t, $s',
      0x08 => 'jr $s',
      0x09 => rd == 31 ? 'jalr $s' : 'jalr $d, $s',
      0x0a => 'movz $d, $s, $t',
      0x0b => 'movn $d, $s, $t',
      0x0c => 'syscall 0x${((word >> 6) & 0xfffff).toRadixString(16)}',
      0x0d => 'break 0x${((word >> 6) & 0xfffff).toRadixString(16)}',
      0x0f => 'sync',
      0x10 => 'mfhi $d',
      0x11 => 'mthi $s',
      0x12 => 'mflo $d',
      0x13 => 'mtlo $s',
      0x16 => 'clz $d, $s',
      0x17 => 'clo $d, $s',
      0x18 => 'mult $s, $t',
      0x19 => 'multu $s, $t',
      0x1a => 'div $s, $t',
      0x1b => 'divu $s, $t',
      0x1c => 'madd $s, $t',
      0x1d => 'maddu $s, $t',
      0x20 => 'add $d, $s, $t',
      0x21 => rt == 0 ? 'move $d, $s' : 'addu $d, $s, $t',
      0x22 => 'sub $d, $s, $t',
      0x23 => 'subu $d, $s, $t',
      0x24 => 'and $d, $s, $t',
      0x25 => rt == 0 ? 'move $d, $s' : 'or $d, $s, $t',
      0x26 => 'xor $d, $s, $t',
      0x27 => 'nor $d, $s, $t',
      0x2a => 'slt $d, $s, $t',
      0x2b => 'sltu $d, $s, $t',
      0x2c => 'max $d, $s, $t',
      0x2d => 'min $d, $s, $t',
      0x2e => 'msub $s, $t',
      0x2f => 'msubu $s, $t',
      _ => _unknown(word),
    };
  }

  static String _fpu(int word, int pc) {
    final rs = (word >> 21) & 31, rt = (word >> 16) & 31;
    final fs = (word >> 11) & 31, fd = (word >> 6) & 31, fn = word & 0x3f;
    final t = regs[rt];
    switch (rs) {
      case 0x00:
        return 'mfc1 $t, f$fs';
      case 0x01:
        return 'dmfc1 $t, f$fs';
      case 0x02:
        return 'cfc1 $t, fcr$fs';
      case 0x04:
        return 'mtc1 $t, f$fs';
      case 0x05:
        return 'dmtc1 $t, f$fs';
      case 0x06:
        return 'ctc1 $t, fcr$fs';
      case 0x08:
        final cc = (rt >> 2) & 7;
        final target = _hex(pc + 4 + (word & 0xffff).toSigned(16) * 4);
        return 'bc1${rt & 1 != 0 ? 't' : 'f'}${rt & 2 != 0 ? 'l' : ''} '
            '${cc == 0 ? '' : '\$fcc$cc, '}$target';
      case 0x14:
        return switch (fn) {
          0x20 => 'cvt.s.w f$fd, f$fs',
          0x21 => 'cvt.d.w f$fd, f$fs',
          _ => _unknown(word),
        };
      case 0x10 || 0x11:
        final f = rs == 0x10 ? 's' : 'd';
        if (fn >= 0x30) {
          final cc = (fd >> 2) & 7;
          return 'c.${_fpuCompare[fn & 0xf]}.$f '
              '${cc == 0 ? '' : '\$fcc$cc, '}f$fs, f$rt';
        }
        final name = switch (fn) {
          0x00 => 'add',
          0x01 => 'sub',
          0x02 => 'mul',
          0x03 => 'div',
          0x04 => 'sqrt',
          0x05 => 'abs',
          0x06 => 'mov',
          0x07 => 'neg',
          0x0c => 'round.w',
          0x0d => 'trunc.w',
          0x0e => 'ceil.w',
          0x0f => 'floor.w',
          0x20 => 'cvt.s',
          0x21 => 'cvt.d',
          0x24 => 'cvt.w',
          _ => null,
        };
        if (name == null) return _unknown(word);
        return fn <= 0x03 ? '$name.$f f$fd, f$fs, f$rt' : '$name.$f f$fd, f$fs';
      default:
        return _unknown(word);
    }
  }

  static String _cop2(int word, int pc) {
    final rs = (word >> 21) & 31, t = regs[(word >> 16) & 31];
    final reg = ((word >> 11) & 0x1f) | (((word >> 6) & 3) << 5);
    return switch (rs) {
      0 => 'mfv $t, ${single(reg)}',
      4 => 'mtv $t, ${single(reg)}',
      2 => 'cfc2 $t, \$${(word >> 11) & 31}',
      6 => 'ctc2 $t, \$${(word >> 11) & 31}',
      3 => 'mfvc $t, ${_control(word & 0xff)}',
      7 => 'mtvc $t, ${_control(word & 0xff)}',
      8 =>
        'bv${(word >> 16) & 1 == 0 ? 'f' : 't'}${(word >> 17) & 1 != 0 ? 'l' : ''} '
            '${(word >> 18) & 7}, ${_hex(pc + 4 + (word & 0xffff).toSigned(16) * 4)}',
      _ => _unknown(word),
    };
  }

  static int _size(int word) => ((word >> 15) & 1) * 2 + ((word >> 7) & 1) + 1;

  static String _suffix(int n) => const ['', '.s', '.p', '.t', '.q'][n];

  static String _vfpuArith(int word) {
    final op = word >>> 26, func = (word >> 23) & 7, n = _size(word);
    final vd = word & 0x7f, vs = (word >> 8) & 0x7f, vt = (word >> 16) & 0x7f;
    if (op == 0x1b && func == 0) {
      final cond = word & 0xf;
      return 'vcmp${_suffix(n)} ${_vfpuCompare[cond]}, '
          '${vector(vs, n)}, ${vector(vt, n)}';
    }
    final key = (op << 4) | func;
    final name = _arith[key];
    if (name == null) return _unknown(word);
    final dest = switch (key) {
      0x191 || 0x194 || 0x196 => single(vd),
      _ => vector(vd, n),
    };
    final second = key == 0x192 ? single(vt) : vector(vt, n);
    return '$name${_suffix(n)} $dest, ${vector(vs, n)}, $second';
  }

  static String _vfpuMemory(int word) {
    final op = word >>> 26;
    final reg = (((word >> 16) & 0x1f) | ((word & 3) << 5)) & 0x7f;
    final offset = ((word & 0xffff) & ~3).toSigned(16);
    final at = '${_imm(offset)}(${regs[(word >> 21) & 31]})';
    final right = (word >> 1) & 1 != 0;
    return switch (op) {
      0x32 => 'lv.s ${single(reg)}, $at',
      0x3a => 'sv.s ${single(reg)}, $at',
      0x36 => 'lv.q ${vector(reg, 4)}, $at',
      0x3e => 'sv.q ${vector(reg, 4)}, $at',
      0x35 => 'lv${right ? 'r' : 'l'}.q ${vector(reg, 4)}, $at',
      _ => 'sv${right ? 'r' : 'l'}.q ${vector(reg, 4)}, $at',
    };
  }

  static String _vfpu4(int word) {
    final family = (word >> 23) & 7, sel = (word >> 16) & 0x7f;
    final vd = word & 0x7f, vs = (word >> 8) & 0x7f, n = _size(word);
    final x = _suffix(n);
    if (family == 4) {
      const names = ['vf2in', 'vf2iz', 'vf2iu', 'vf2id'];
      return '${names[(word >> 21) & 3]}$x ${vector(vd, n)}, '
          '${vector(vs, n)}, ${(word >> 16) & 31}';
    }
    if (family == 5) {
      final sub = (word >> 21) & 3;
      if (sub == 0) {
        return 'vi2f$x ${vector(vd, n)}, ${vector(vs, n)}, ${(word >> 16) & 31}';
      }
      if (sub == 1) {
        return 'vcmov${(word >> 19) & 1 == 0 ? 't' : 'f'}$x '
            '${vector(vd, n)}, ${vector(vs, n)}, ${(word >> 16) & 7}';
      }
      return _unknown(word);
    }
    if (family != 0) return _unknown(word);
    if (sel >= 0x60 && sel <= 0x73) {
      return 'vcst$x ${vector(vd, n)}, ${_constants[sel - 0x60]}';
    }
    final name = _unary[sel];
    if (name == null) return _unknown(word);
    int half(int m) => m < 2 ? 1 : m ~/ 2;
    return switch (sel) {
      0x03 ||
      0x06 ||
      0x07 ||
      0x21 ||
      0x22 ||
      0x23 =>
        '$name$x ${vector(vd, n)}',
      0x20 => '$name$x ${single(vs)}',
      0x46 || 0x47 => '$name$x ${single(vd)}, ${vector(vs, n)}',
      0x32 ||
      0x3e ||
      0x3f ||
      0x59 ||
      0x5a ||
      0x5b =>
        '$name$x ${vector(vd, half(n))}, ${vector(vs, n)}',
      0x3c || 0x3d => '$name$x ${single(vd)}, ${vector(vs, n)}',
      0x33 ||
      0x3a ||
      0x3b =>
        '$name$x ${vector(vd, math.min(n * 2, 4))}, ${vector(vs, n)}',
      0x38 || 0x39 => '$name$x ${vector(vd, 4)}, ${single(vs)}',
      0x50 => '$name ${single(vd)}, ${_control(128 + (vs & 0x7f))}',
      0x51 => '$name ${_control(128 + (vd & 0x7f))}, ${single(vs)}',
      _ => '$name$x ${vector(vd, n)}, ${vector(vs, n)}',
    };
  }

  static String _vfpu5(int word) {
    final func = (word >> 23) & 7;
    final reg = (word >> 16) & 0x7f;
    return switch (func) {
      0 => 'vpfxs ${_sourcePrefix(word)}',
      2 => 'vpfxt ${_sourcePrefix(word)}',
      4 => 'vpfxd ${_destPrefix(word)}',
      6 => 'viim.s ${single(reg)}, ${(word & 0xffff).toSigned(16)}',
      7 => 'vfim.s ${single(reg)}, ${_half(word & 0xffff)}',
      _ => _unknown(word),
    };
  }

  /// A source prefix: per lane a swizzle or a constant, with absolute
  /// value and negation.
  static String _sourcePrefix(int word) {
    final lanes = [
      for (var i = 0; i < 4; i++)
        () {
          final swizzle = (word >> (i * 2)) & 3;
          final abs = (word >> (8 + i)) & 1 != 0;
          final constant = (word >> (12 + i)) & 1 != 0;
          final negate = (word >> (16 + i)) & 1 != 0;
          final value = constant
              ? _prefixConstants[swizzle + (abs ? 4 : 0)]
              : (abs ? '|${'xyzw'[swizzle]}|' : 'xyzw'[swizzle]);
          return '${negate ? '-' : ''}$value';
        }(),
    ];
    return '[${lanes.join(', ')}]';
  }

  /// A destination prefix: per lane a saturation or a write mask.
  static String _destPrefix(int word) {
    final lanes = [
      for (var i = 0; i < 4; i++)
        (word >> (8 + i)) & 1 != 0
            ? 'm'
            : switch ((word >> (i * 2)) & 3) {
                1 => '0:1',
                3 => '-1:1',
                _ => '',
              },
    ];
    return '[${lanes.join(', ')}]';
  }

  static String _half(int bits) {
    final sign = bits & 0x8000 != 0 ? -1.0 : 1.0;
    final exponent = (bits >> 10) & 0x1f, mantissa = bits & 0x3ff;
    if (exponent == 0x1f) {
      return mantissa == 0 ? '${sign < 0 ? '-' : ''}inf' : 'nan';
    }
    final value = exponent == 0
        ? mantissa / 1024 * math.pow(2.0, -14)
        : (1 + mantissa / 1024) * math.pow(2.0, exponent - 15);
    return '${sign * value}';
  }

  static String _vfpu6(int word) {
    final func = (word >> 23) & 7, sel = (word >> 16) & 0x7f;
    final vd = word & 0x7f, vs = (word >> 8) & 0x7f, vt = (word >> 16) & 0x7f;
    final n = _size(word), x = _suffix(n);
    if (func == 7 && sel >= 0x20) {
      final imm = sel & 0x1f;
      final cosLane = imm & 3, sinLane = (imm >> 2) & 3;
      final sine = imm & 0x10 != 0 ? '-s' : 's';
      final lanes = [
        for (var i = 0; i < n; i++)
          i == cosLane
              ? 'c'
              : (sinLane == cosLane || i == sinLane ? sine : '0'),
      ];
      return 'vrot$x ${vector(vd, n)}, ${single(vs)}, [${lanes.join(', ')}]';
    }
    if (func == 7) {
      return switch (sel) {
        0 => 'vmmov$x ${matrix(vd, n)}, ${matrix(vs, n)}',
        3 => 'vmidt$x ${matrix(vd, n)}',
        6 => 'vmzero$x ${matrix(vd, n)}',
        7 => 'vmone$x ${matrix(vd, n)}',
        _ => _unknown(word),
      };
    }
    if (func == 0) {
      return 'vmmul$x ${matrix(vd, n)}, ${matrix(vs, n)}, ${matrix(vt, n)}';
    }
    if (func == 4) {
      return 'vmscl$x ${matrix(vd, n)}, ${matrix(vs, n)}, ${single(vt)}';
    }
    if (func >= 1 && func <= 3) {
      final count = func + 1;
      final homogeneous = n == func;
      return '${homogeneous ? 'vhtfm' : 'vtfm'}$count${_suffix(count)} '
          '${vector(vd, count)}, ${matrix(vs, count)}, '
          '${vector(vt, homogeneous ? func : count)}';
    }
    if (func == 5) {
      return n == 4
          ? 'vqmul.q ${vector(vd, 4)}, ${vector(vs, 4)}, ${vector(vt, 4)}'
          : 'vcrsp.t ${vector(vd, 3)}, ${vector(vs, 3)}, ${vector(vt, 3)}';
    }
    return _unknown(word);
  }
}
