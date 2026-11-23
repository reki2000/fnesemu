/// Cx4 (HG51B169) instruction formatting after the fullsnes documentation
/// of the opcodes, following the decoding of cx4.dart. Never reads
/// machine state.
library;

class Cx4Disasm {
  static String _hex(int value, int digits) =>
      '\$${value.toRadixString(16).padLeft(digits, '0')}';

  /// The register an operand byte names.
  static String register(int n) => switch (n) {
        0x00 => 'a',
        0x01 => 'mh',
        0x02 => 'ml',
        0x03 => 'ext_dta',
        0x08 => 'rom_dta',
        0x0c => 'ram_dta',
        0x13 => 'ext_ptr',
        0x1c => 'ram_ptr',
        0x2e => '[ext_ptr]',
        >= 0x50 && < 0x60 => 'k${n - 0x50}',
        >= 0x60 && < 0x70 => 'r${n - 0x60}',
        _ => 'reg${_hex(n, 2)}',
      };

  static const _flags = ['-', 'c', 'z', 'n'];

  /// Formats the 16-bit instruction [op].
  static String disasm(int op) {
    op &= 0xffff;
    final imm = op & 0x400 != 0, ss = (op >> 8) & 3, n = op & 0xff;
    final src = imm ? '#${_hex(n, 2)}' : register(n);
    final a = const ['a', 'a<<1', 'a<<8', 'a<<16'][ss];
    final target = '${op & 0x200 != 0 ? 'page:' : ''}${_hex(n, 2)}';
    final ram = imm ? '[ram_ptr+${_hex(n, 2)}]' : '[${register(n)}]';
    return switch (op >> 11) {
      0x00 => 'nop',
      0x01 => '${imm ? 'jz' : 'jmp'} $target',
      0x02 => '${imm ? 'js' : 'jc'} $target',
      0x03 => 'wait',
      0x04 => imm ? 'skip${op & 1 != 0 ? '' : 'n'}${_flags[ss]}' : 'nop',
      0x05 => '${imm ? 'callz' : 'call'} $target',
      0x06 => '${imm ? 'calls' : 'callc'} $target',
      0x07 => imm ? 'ret' : 'nop',
      0x08 => imm ? 'nop' : 'inc ext_ptr',
      0x09 => 'cmp $src, $a',
      0x0a => 'cmp $a, $src',
      0x0b => imm ? 'nop' : const ['nop', 'sxb a', 'sxw a', 'nop'][ss],
      0x0c => switch (ss) {
          0 => 'mov a, $src',
          1 => 'mov ext_dta, $src',
          3 => 'mov prg_page, $src',
          _ => 'nop',
        },
      0x0d => 'movb ram_dta.b$ss, $ram',
      0x0e => imm ? 'nop' : 'mov rom_dta, datarom[${register(n)}]',
      0x0f => 'mov prg_page.${ss & 1 == 0 ? 'lo' : 'hi'}, $src',
      0x10 => 'add a, $a, $src',
      0x11 => 'sub a, $src, $a',
      0x12 => 'sub a, $a, $src',
      0x13 => 'smul a, $src',
      0x15 => 'xor a, $a, $src',
      0x16 => 'and a, $a, $src',
      0x17 => 'or a, $a, $src',
      0x18 => 'shr a, $src',
      0x19 => 'sar a, $src',
      0x1a => 'ror a, $src',
      0x1b => 'shl a, $src',
      0x1c => imm ? 'nop' : 'mov ${register(n)}, a',
      0x1d => 'movb $ram, ram_dta.b$ss',
      0x1e => imm ? 'nop' : 'xchg ${register(n)}, a',
      0x1f => imm ? 'stop' : 'nop',
      _ => 'unknown ${_hex(op, 4)}',
    };
  }
}
