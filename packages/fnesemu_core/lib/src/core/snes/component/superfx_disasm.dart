/// Super FX (GSU) instruction formatting after the fullsnes documentation
/// of the opcodes. An ALT1 / ALT2 / ALT3 prefix and the instruction it
/// selects are shown as one instruction, as are WITH and the TO or FROM
/// that it turns into MOVE or MOVES. Never reads machine state.
library;

class SuperFxDisasm {
  static String _hex(int value, int digits) =>
      '\$${value.toRadixString(16).padLeft(digits, '0')}';

  static const _branches = [
    'bra', 'bge', 'blt', 'bne', 'beq', 'bpl', 'bmi', 'bcc', 'bcs', //
    'bvc', 'bvs',
  ];

  /// Formats the instruction in [bytes] (at least five) at the 16-bit
  /// address [pc]; returns the text and the length.
  static (String, int) disasm(List<int> bytes, int pc) {
    final first = bytes[0] & 0xff;
    if (first >= 0x3d && first <= 0x3f) {
      final alt = first - 0x3c;
      final (text, length) = _plain(bytes.sublist(1), pc + 1, alt);
      return (text, length + 1);
    }
    if (first >> 4 == 2) {
      final next = bytes[1] & 0xff;
      if (next >> 4 == 1) return ('move r${next & 15}, r${first & 15}', 2);
      if (next >> 4 == 0xb) return ('moves r${first & 15}, r${next & 15}', 2);
    }
    return _plain(bytes, pc, 0);
  }

  /// One instruction under the ALT mode [alt]: 1 for ALT1, 2 for ALT2 and
  /// 3 for both.
  static (String, int) _plain(List<int> bytes, int pc, int alt) {
    final op = bytes[0] & 0xff, n = op & 15;
    final alt1 = alt & 1 != 0, alt2 = alt & 2 != 0;
    final byte1 = bytes[1] & 0xff;
    final word1 = byte1 | (bytes[2] & 0xff) << 8;
    String operand() => alt2 ? '#$n' : 'r$n';
    final text = switch (op >> 4) {
      0x0 => switch (op) {
          0x00 => 'stop',
          0x01 => 'nop',
          0x02 => 'cache',
          0x03 => 'lsr',
          0x04 => 'rol',
          _ => '${_branches[op - 5]} '
              '${_hex((pc + 2 + byte1.toSigned(8)) & 0xffff, 4)}',
        },
      0x1 => 'to r$n',
      0x2 => 'with r$n',
      0x3 => switch (n) {
          < 0xc => '${alt1 ? 'stb' : 'stw'} (r$n)',
          0xc => 'loop',
          _ => 'alt${n - 0xc}',
        },
      0x4 => switch (n) {
          < 0xc => '${alt1 ? 'ldb' : 'ldw'} (r$n)',
          0xc => alt1 ? 'rpix' : 'plot',
          0xd => 'swap',
          0xe => alt1 ? 'cmode' : 'color',
          _ => 'not',
        },
      0x5 => '${alt1 ? 'adc' : 'add'} ${operand()}',
      0x6 => switch (alt) {
          1 => 'sbc r$n',
          2 => 'sub #$n',
          3 => 'cmp r$n',
          _ => 'sub r$n',
        },
      0x7 => n == 0 ? 'merge' : '${alt1 ? 'bic' : 'and'} ${operand()}',
      0x8 => '${alt1 ? 'umult' : 'mult'} ${operand()}',
      0x9 => switch (n) {
          0x0 => 'sbk',
          <= 0x4 => 'link #$n',
          0x5 => 'sex',
          0x6 => alt1 ? 'div2' : 'asr',
          0x7 => 'ror',
          <= 0xd => '${alt1 ? 'ljmp' : 'jmp'} r$n',
          0xe => 'lob',
          _ => alt1 ? 'lmult' : 'fmult',
        },
      0xa => alt1
          ? 'lms r$n, (${_hex(byte1 * 2, 3)})'
          : alt2
              ? 'sms (${_hex(byte1 * 2, 3)}), r$n'
              : 'ibt r$n, #${_hex(byte1, 2)}',
      0xb => 'from r$n',
      0xc => n == 0 ? 'hib' : '${alt1 ? 'xor' : 'or'} ${operand()}',
      0xd => n < 0xf ? 'inc r$n' : (!alt2 ? 'getc' : (!alt1 ? 'ramb' : 'romb')),
      0xe =>
        n < 0xf ? 'dec r$n' : const ['getb', 'getbh', 'getbl', 'getbs'][alt],
      _ => alt1
          ? 'lm r$n, (${_hex(word1, 4)})'
          : alt2
              ? 'sm (${_hex(word1, 4)}), r$n'
              : 'iwt r$n, #${_hex(word1, 4)}',
    };
    final length = switch (op >> 4) {
      0x0 => op >= 0x05 ? 2 : 1,
      0xa => 2,
      0xf => 3,
      _ => 1,
    };
    return (text, length);
  }
}
