/// Formatting of VU micro instruction pairs. It follows the decoding of
/// vu.dart and never reads machine state.
library;

import 'dart:typed_data';

class VuDisasm {
  static const _fields = 'xyzw';

  static String _hex(int value, int digits) =>
      '0x${value.toRadixString(16).padLeft(digits, '0')}';

  /// The destination fields of a mask, x in bit 3.
  static String _dest(int mask) => mask == 15
      ? ''
      : '.${[
          for (var c = 0; c < 4; c++)
            if (mask & (8 >> c) != 0) _fields[c]
        ].join()}';

  static String _vf(int n) => 'vf$n';
  static String _vi(int n) => 'vi${n & 15}';

  /// Formats the pair of [low] and [high] at byte address [address].
  static String pair(int low, int high, int address) {
    final flags = [
      if (high & 0x40000000 != 0) 'e',
      if (high & 0x20000000 != 0) 'm',
      if (high & 0x10000000 != 0) 'd',
      if (high & 0x08000000 != 0) 't',
    ];
    final first = '${upper(high)}${flags.map((f) => '[$f]').join()}';
    final second =
        high >>> 31 != 0 ? 'loi ${_float(low)}' : lower(low, address);
    return '$first : $second';
  }

  static String _float(int bits) {
    final data = ByteData(4)..setUint32(0, bits);
    return '${data.getFloat32(0)}';
  }

  /// The upper instruction of a pair.
  static String upper(int ir) {
    final mask = (ir >> 21) & 15;
    final ft = (ir >> 16) & 31, fs = (ir >> 11) & 31, fd = (ir >> 6) & 31;
    final op = ir & 63;
    final d = _dest(mask);
    if (op < 0x1c) {
      const names = ['add', 'sub', 'madd', 'msub', 'max', 'mini', 'mul'];
      final bc = _fields[op & 3];
      return '${names[op >> 2]}$bc$d ${_vf(fd)}, ${_vf(fs)}, ${_vf(ft)}$bc';
    }
    if (op < 0x28) {
      const names = [
        ('mul', 'q'), ('max', 'i'), ('mul', 'i'), ('mini', 'i'), //
        ('add', 'q'), ('madd', 'q'), ('add', 'i'), ('madd', 'i'), //
        ('sub', 'q'), ('msub', 'q'), ('sub', 'i'), ('msub', 'i'),
      ];
      final (name, scalar) = names[op - 0x1c];
      return '$name$scalar$d ${_vf(fd)}, ${_vf(fs)}, ${scalar.toUpperCase()}';
    }
    if (op < 0x30) {
      const names = [
        'add',
        'madd',
        'mul',
        'max',
        'sub',
        'msub',
        'opmsub',
        'mini'
      ];
      return '${names[op - 0x28]}$d ${_vf(fd)}, ${_vf(fs)}, ${_vf(ft)}';
    }
    if (op < 0x3c) return 'upper? ${_hex(ir, 8)}';
    final sub = (ir >> 6) & 31, col = ir & 3;
    final bc = _fields[col];
    if (sub < 4 || sub == 6) {
      const names = ['adda', 'suba', 'madda', 'msuba', '', '', 'mula'];
      return '${names[sub]}$bc$d ACC, ${_vf(fs)}, ${_vf(ft)}$bc';
    }
    if (sub == 4 || sub == 5) {
      const shifts = [0, 4, 12, 15];
      return '${sub == 4 ? 'itof' : 'ftoi'}${shifts[col]}$d ${_vf(ft)}, ${_vf(fs)}';
    }
    final key = (sub << 2) | col;
    final scalar = switch (key) {
      const (7 << 2 | 0) => ('mulaq', 'Q'),
      const (7 << 2 | 2) => ('mulai', 'I'),
      const (8 << 2 | 0) => ('addaq', 'Q'),
      const (8 << 2 | 1) => ('maddaq', 'Q'),
      const (8 << 2 | 2) => ('addai', 'I'),
      const (8 << 2 | 3) => ('maddai', 'I'),
      const (9 << 2 | 0) => ('subaq', 'Q'),
      const (9 << 2 | 1) => ('msubaq', 'Q'),
      const (9 << 2 | 2) => ('subai', 'I'),
      const (9 << 2 | 3) => ('msubai', 'I'),
      _ => null,
    };
    if (scalar != null) return '${scalar.$1}$d ACC, ${_vf(fs)}, ${scalar.$2}';
    return switch (key) {
      const (7 << 2 | 1) => 'abs$d ${_vf(ft)}, ${_vf(fs)}',
      const (7 << 2 | 3) => 'clipw.xyz ${_vf(fs)}, ${_vf(ft)}w',
      const (10 << 2 | 0) => 'adda$d ACC, ${_vf(fs)}, ${_vf(ft)}',
      const (10 << 2 | 1) => 'madda$d ACC, ${_vf(fs)}, ${_vf(ft)}',
      const (10 << 2 | 2) => 'mula$d ACC, ${_vf(fs)}, ${_vf(ft)}',
      const (11 << 2 | 0) => 'suba$d ACC, ${_vf(fs)}, ${_vf(ft)}',
      const (11 << 2 | 1) => 'msuba$d ACC, ${_vf(fs)}, ${_vf(ft)}',
      const (11 << 2 | 2) => 'opmula.xyz ACC, ${_vf(fs)}, ${_vf(ft)}',
      const (11 << 2 | 3) => 'nop',
      _ => 'upper? ${_hex(ir, 8)}',
    };
  }

  /// The lower instruction of a pair at byte address [address].
  static String lower(int ir, int address) {
    if (ir == 0x8000033c) return 'nop';
    final op = ir >>> 25;
    final mask = (ir >> 21) & 15, d = _dest(mask);
    final it = (ir >> 16) & 31, is_ = (ir >> 11) & 31;
    final imm11 = (ir & 0x7ff).toSigned(11);
    final target = _hex(((address >> 3) + 1 + imm11) * 8 & 0xffff, 4);
    final imm15 = ((mask << 11) | (ir & 0x7ff)) & 0x7fff;
    final imm12 = ((ir >> 10) & 0x800) | (ir & 0x7ff);
    final imm24 = _hex(ir & 0xffffff, 6);
    return switch (op) {
      0x00 => 'lq$d ${_vf(it)}, $imm11(${_vi(is_)})',
      0x01 => 'sq$d ${_vf(is_)}, $imm11(${_vi(it)})',
      0x04 => 'ilw$d ${_vi(it)}, $imm11(${_vi(is_)})',
      0x05 => 'isw$d ${_vi(it)}, $imm11(${_vi(is_)})',
      0x08 => 'iaddiu ${_vi(it)}, ${_vi(is_)}, ${_hex(imm15, 4)}',
      0x09 => 'isubiu ${_vi(it)}, ${_vi(is_)}, ${_hex(imm15, 4)}',
      0x10 => 'fceq vi1, $imm24',
      0x11 => 'fcset $imm24',
      0x12 => 'fcand vi1, $imm24',
      0x13 => 'fcor vi1, $imm24',
      0x14 => 'fseq ${_vi(it)}, ${_hex(imm12, 3)}',
      0x15 => 'fsset ${_hex(imm12, 3)}',
      0x16 => 'fsand ${_vi(it)}, ${_hex(imm12, 3)}',
      0x17 => 'fsor ${_vi(it)}, ${_hex(imm12, 3)}',
      0x18 => 'fmeq ${_vi(it)}, ${_vi(is_)}',
      0x1a => 'fmand ${_vi(it)}, ${_vi(is_)}',
      0x1b => 'fmor ${_vi(it)}, ${_vi(is_)}',
      0x1c => 'fcget ${_vi(it)}',
      0x20 => 'b $target',
      0x21 => 'bal ${_vi(it)}, $target',
      0x24 => 'jr ${_vi(is_)}',
      0x25 => 'jalr ${_vi(it)}, ${_vi(is_)}',
      0x28 => 'ibeq ${_vi(it)}, ${_vi(is_)}, $target',
      0x29 => 'ibne ${_vi(it)}, ${_vi(is_)}, $target',
      0x2c => 'ibltz ${_vi(is_)}, $target',
      0x2d => 'ibgtz ${_vi(is_)}, $target',
      0x2e => 'iblez ${_vi(is_)}, $target',
      0x2f => 'ibgez ${_vi(is_)}, $target',
      0x40 => _special(ir),
      _ => 'lower? ${_hex(ir, 8)}',
    };
  }

  static String _special(int ir) {
    final mask = (ir >> 21) & 15, d = _dest(mask);
    final it = (ir >> 16) & 31, is_ = (ir >> 11) & 31, id = (ir >> 6) & 15;
    final funct = ir & 0x3f;
    switch (funct) {
      case 0x30:
        return 'iadd ${_vi(id)}, ${_vi(is_)}, ${_vi(it)}';
      case 0x31:
        return 'isub ${_vi(id)}, ${_vi(is_)}, ${_vi(it)}';
      case 0x32:
        return 'iaddi ${_vi(it)}, ${_vi(is_)}, ${((ir >> 6) & 31).toSigned(5)}';
      case 0x34:
        return 'iand ${_vi(id)}, ${_vi(is_)}, ${_vi(it)}';
      case 0x35:
        return 'ior ${_vi(id)}, ${_vi(is_)}, ${_vi(it)}';
    }
    if (funct < 0x3c) return 'lower? ${_hex(ir, 8)}';
    final sub = (ir >> 6) & 31, col = funct & 3;
    final fsf = _fields[(ir >> 21) & 3], ftf = _fields[(ir >> 23) & 3];
    final s = '${_vf(is_)}$fsf';
    return switch ((sub << 2) | col) {
      const (0x0c << 2 | 0) => 'move$d ${_vf(it)}, ${_vf(is_)}',
      const (0x0c << 2 | 1) => 'mr32$d ${_vf(it)}, ${_vf(is_)}',
      const (0x0d << 2 | 0) => 'lqi$d ${_vf(it)}, (${_vi(is_)}++)',
      const (0x0d << 2 | 1) => 'sqi$d ${_vf(is_)}, (${_vi(it)}++)',
      const (0x0d << 2 | 2) => 'lqd$d ${_vf(it)}, (--${_vi(is_)})',
      const (0x0d << 2 | 3) => 'sqd$d ${_vf(is_)}, (--${_vi(it)})',
      const (0x0e << 2 | 0) => 'div Q, $s, ${_vf(it)}$ftf',
      const (0x0e << 2 | 1) => 'sqrt Q, ${_vf(it)}$ftf',
      const (0x0e << 2 | 2) => 'rsqrt Q, $s, ${_vf(it)}$ftf',
      const (0x0e << 2 | 3) => 'waitq',
      const (0x0f << 2 | 0) => 'mtir ${_vi(it)}, $s',
      const (0x0f << 2 | 1) => 'mfir$d ${_vf(it)}, ${_vi(is_)}',
      const (0x0f << 2 | 2) => 'ilwr$d ${_vi(it)}, (${_vi(is_)})',
      const (0x0f << 2 | 3) => 'iswr$d ${_vi(it)}, (${_vi(is_)})',
      const (0x10 << 2 | 0) => 'rnext$d ${_vf(it)}, R',
      const (0x10 << 2 | 1) => 'rget$d ${_vf(it)}, R',
      const (0x10 << 2 | 2) => 'rinit R, $s',
      const (0x10 << 2 | 3) => 'rxor R, $s',
      const (0x19 << 2 | 0) => 'mfp$d ${_vf(it)}, P',
      const (0x1a << 2 | 0) => 'xtop ${_vi(it)}',
      const (0x1a << 2 | 1) => 'xitop ${_vi(it)}',
      const (0x1b << 2 | 0) => 'xgkick ${_vi(is_)}',
      const (0x1c << 2 | 0) => 'esadd P, ${_vf(is_)}',
      const (0x1c << 2 | 1) => 'ersadd P, ${_vf(is_)}',
      const (0x1c << 2 | 2) => 'eleng P, ${_vf(is_)}',
      const (0x1c << 2 | 3) => 'erleng P, ${_vf(is_)}',
      const (0x1d << 2 | 0) => 'eatanxy P, ${_vf(is_)}',
      const (0x1d << 2 | 1) => 'eatanxz P, ${_vf(is_)}',
      const (0x1d << 2 | 2) => 'esum P, ${_vf(is_)}',
      const (0x1e << 2 | 0) => 'esqrt P, $s',
      const (0x1e << 2 | 1) => 'ersqrt P, $s',
      const (0x1e << 2 | 2) => 'ercpr P, $s',
      const (0x1e << 2 | 3) => 'waitp',
      const (0x1f << 2 | 0) => 'esin P, $s',
      const (0x1f << 2 | 1) => 'eatan P, $s',
      const (0x1f << 2 | 2) => 'eexp P, $s',
      _ => 'lower? ${_hex(ir, 8)}',
    };
  }
}
