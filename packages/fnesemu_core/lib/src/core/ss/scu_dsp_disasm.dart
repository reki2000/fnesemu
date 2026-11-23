/// SCU DSP instruction formatting, following the decoding of
/// scu_dsp.dart. An operation word shows its ALU, X-bus, Y-bus and D1-bus
/// parts side by side. Never reads machine state.
library;

class ScuDspDisasm {
  static String _hex(int value, int digits) =>
      '\$${value.toRadixString(16).padLeft(digits, '0')}';

  static const _sources = ['m0', 'm1', 'm2', 'm3', 'mc0', 'mc1', 'mc2', 'mc3'];

  static const _destinations = [
    'mc0', 'mc1', 'mc2', 'mc3', 'rx', 'pl', 'ra0', 'wa0', //
    'dst8', 'dst9', 'lop', 'top', 'ct0', 'ct1', 'ct2', 'ct3', //
  ];

  static const _alu = [
    '', 'and', 'or', 'xor', 'add', 'sub', 'ad2', 'alu7', //
    'sr', 'rr', 'sl', 'rl', 'alu12', 'alu13', 'alu14', 'rl8', //
  ];

  /// The condition of a conditional MVI or JMP: Z, S, C and T0 by bits 0,
  /// 1, 2 and 4, met when one is set (bit 5 set) or none is (bit 5 clear).
  static String condition(int cond) {
    final flags = [
      if (cond & 1 != 0) 'z',
      if (cond & 2 != 0) 's',
      if (cond & 4 != 0) 'c',
      if (cond & 0x10 != 0) 't0',
    ].join();
    return '${cond & 0x20 != 0 ? '' : 'n'}$flags';
  }

  /// Formats the instruction word [op].
  static String disasm(int op) {
    op &= 0xffffffff;
    return switch (op >>> 30) {
      0 => _operation(op),
      1 => 'undefined ${_hex(op, 8)}',
      2 => _mvi(op),
      _ => _special(op),
    };
  }

  static String _operation(int op) {
    final parts = <String>[_alu[(op >> 26) & 15]];
    final xop = (op >> 23) & 7, xsrc = _sources[(op >> 20) & 7];
    if (xop & 4 != 0) parts.add('mov $xsrc, x');
    if (xop & 3 == 2) parts.add('mov mul, p');
    if (xop & 3 == 3) parts.add('mov $xsrc, p');
    final yop = (op >> 17) & 7, ysrc = _sources[(op >> 14) & 7];
    if (yop & 4 != 0) parts.add('mov $ysrc, y');
    if (yop & 3 == 1) parts.add('clr a');
    if (yop & 3 == 2) parts.add('mov alu, a');
    if (yop & 3 == 3) parts.add('mov $ysrc, a');
    final dst = _destinations[(op >> 8) & 15];
    switch ((op >> 12) & 3) {
      case 1:
        parts.add('mov #${(op & 0xff).toSigned(8)}, $dst');
      case 3:
        final src = switch (op & 15) {
          < 8 => _sources[op & 7],
          9 => 'all',
          10 => 'alh',
          _ => 'src${op & 15}',
        };
        parts.add('mov $src, $dst');
    }
    final text = parts.where((p) => p.isNotEmpty).join('  ');
    return text.isEmpty ? 'nop' : text;
  }

  static String _mvi(int op) {
    final dst = (op >> 26) & 15;
    final name = dst == 12 ? 'pc' : _destinations[dst];
    if (op & 0x2000000 != 0) {
      final imm = (op & 0x7ffff).toSigned(19);
      final cond = (op >> 19) & 0x3f;
      return cond & 0x1f == 0
          ? 'mvi #$imm, $name'
          : 'mvi #$imm, $name, ${condition(cond)}';
    }
    return 'mvi #${(op & 0x1ffffff).toSigned(25)}, $name';
  }

  static String _special(int op) {
    switch ((op >> 28) & 3) {
      case 0:
        final shift = (op >> 15) & 7;
        final add = shift == 0 ? 0 : (1 << (shift - 1)) * 4;
        final ram = (op >> 8) & 7;
        final count =
            op & 0x2000 != 0 ? _sources[op & 7] : '#${_hex(op & 0xff, 2)}';
        final name = 'dma${op & 0x4000 != 0 ? 'h' : ''}$add';
        final local = ram < 4 ? 'm$ram' : 'prg';
        return op & 0x1000 != 0
            ? '$name $local, d0, $count'
            : '$name d0, $local, $count';
      case 1:
        final cond = (op >> 19) & 0x3f;
        final target = _hex(op & 0xff, 2);
        return cond & 0x1f == 0
            ? 'jmp $target'
            : 'jmp ${condition(cond)}, $target';
      case 2:
        return op & 0x8000000 != 0 ? 'lps' : 'btm';
      default:
        return op & 0x8000000 != 0 ? 'endi' : 'end';
    }
  }
}
