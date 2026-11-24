/// SPC700 instruction formatting after the opcode map of the fullsnes
/// documentation; never reads machine state.
library;

class Spc700Disasm {
  /// The instruction of each opcode. Operand tokens name a byte after the
  /// opcode by its index: {bN} a direct page address, {iN} an immediate,
  /// {wN} an absolute address, {mN} a 13-bit address and a bit number,
  /// {rN} a relative branch target and {uN} a PCALL page offset.
  static const _ops = [
    'nop', // 00
    'tcall 0', // 01
    'set1 {b1}.0', // 02
    'bbs {b1}.0, {r2}', // 03
    'or a, {b1}', // 04
    'or a, {w1}', // 05
    'or a, (x)', // 06
    'or a, [{b1}+x]', // 07
    'or a, {i1}', // 08
    'or {b2}, {b1}', // 09
    'or1 c, {m1}', // 0a
    'asl {b1}', // 0b
    'asl {w1}', // 0c
    'push psw', // 0d
    'tset1 {w1}', // 0e
    'brk', // 0f
    'bpl {r1}', // 10
    'tcall 1', // 11
    'clr1 {b1}.0', // 12
    'bbc {b1}.0, {r2}', // 13
    'or a, {b1}+x', // 14
    'or a, {w1}+x', // 15
    'or a, {w1}+y', // 16
    'or a, [{b1}]+y', // 17
    'or {b2}, {i1}', // 18
    'or (x), (y)', // 19
    'decw {b1}', // 1a
    'asl {b1}+x', // 1b
    'asl a', // 1c
    'dec x', // 1d
    'cmp x, {w1}', // 1e
    'jmp [{w1}+x]', // 1f
    'clrp', // 20
    'tcall 2', // 21
    'set1 {b1}.1', // 22
    'bbs {b1}.1, {r2}', // 23
    'and a, {b1}', // 24
    'and a, {w1}', // 25
    'and a, (x)', // 26
    'and a, [{b1}+x]', // 27
    'and a, {i1}', // 28
    'and {b2}, {b1}', // 29
    'or1 c, /{m1}', // 2a
    'rol {b1}', // 2b
    'rol {w1}', // 2c
    'push a', // 2d
    'cbne {b1}, {r2}', // 2e
    'bra {r1}', // 2f
    'bmi {r1}', // 30
    'tcall 3', // 31
    'clr1 {b1}.1', // 32
    'bbc {b1}.1, {r2}', // 33
    'and a, {b1}+x', // 34
    'and a, {w1}+x', // 35
    'and a, {w1}+y', // 36
    'and a, [{b1}]+y', // 37
    'and {b2}, {i1}', // 38
    'and (x), (y)', // 39
    'incw {b1}', // 3a
    'rol {b1}+x', // 3b
    'rol a', // 3c
    'inc x', // 3d
    'cmp x, {b1}', // 3e
    'call {w1}', // 3f
    'setp', // 40
    'tcall 4', // 41
    'set1 {b1}.2', // 42
    'bbs {b1}.2, {r2}', // 43
    'eor a, {b1}', // 44
    'eor a, {w1}', // 45
    'eor a, (x)', // 46
    'eor a, [{b1}+x]', // 47
    'eor a, {i1}', // 48
    'eor {b2}, {b1}', // 49
    'and1 c, {m1}', // 4a
    'lsr {b1}', // 4b
    'lsr {w1}', // 4c
    'push x', // 4d
    'tclr1 {w1}', // 4e
    'pcall {u1}', // 4f
    'bvc {r1}', // 50
    'tcall 5', // 51
    'clr1 {b1}.2', // 52
    'bbc {b1}.2, {r2}', // 53
    'eor a, {b1}+x', // 54
    'eor a, {w1}+x', // 55
    'eor a, {w1}+y', // 56
    'eor a, [{b1}]+y', // 57
    'eor {b2}, {i1}', // 58
    'eor (x), (y)', // 59
    'cmpw ya, {b1}', // 5a
    'lsr {b1}+x', // 5b
    'lsr a', // 5c
    'mov x, a', // 5d
    'cmp y, {w1}', // 5e
    'jmp {w1}', // 5f
    'clrc', // 60
    'tcall 6', // 61
    'set1 {b1}.3', // 62
    'bbs {b1}.3, {r2}', // 63
    'cmp a, {b1}', // 64
    'cmp a, {w1}', // 65
    'cmp a, (x)', // 66
    'cmp a, [{b1}+x]', // 67
    'cmp a, {i1}', // 68
    'cmp {b2}, {b1}', // 69
    'and1 c, /{m1}', // 6a
    'ror {b1}', // 6b
    'ror {w1}', // 6c
    'push y', // 6d
    'dbnz {b1}, {r2}', // 6e
    'ret', // 6f
    'bvs {r1}', // 70
    'tcall 7', // 71
    'clr1 {b1}.3', // 72
    'bbc {b1}.3, {r2}', // 73
    'cmp a, {b1}+x', // 74
    'cmp a, {w1}+x', // 75
    'cmp a, {w1}+y', // 76
    'cmp a, [{b1}]+y', // 77
    'cmp {b2}, {i1}', // 78
    'cmp (x), (y)', // 79
    'addw ya, {b1}', // 7a
    'ror {b1}+x', // 7b
    'ror a', // 7c
    'mov a, x', // 7d
    'cmp y, {b1}', // 7e
    'reti', // 7f
    'setc', // 80
    'tcall 8', // 81
    'set1 {b1}.4', // 82
    'bbs {b1}.4, {r2}', // 83
    'adc a, {b1}', // 84
    'adc a, {w1}', // 85
    'adc a, (x)', // 86
    'adc a, [{b1}+x]', // 87
    'adc a, {i1}', // 88
    'adc {b2}, {b1}', // 89
    'eor1 c, {m1}', // 8a
    'dec {b1}', // 8b
    'dec {w1}', // 8c
    'mov y, {i1}', // 8d
    'pop psw', // 8e
    'mov {b2}, {i1}', // 8f
    'bcc {r1}', // 90
    'tcall 9', // 91
    'clr1 {b1}.4', // 92
    'bbc {b1}.4, {r2}', // 93
    'adc a, {b1}+x', // 94
    'adc a, {w1}+x', // 95
    'adc a, {w1}+y', // 96
    'adc a, [{b1}]+y', // 97
    'adc {b2}, {i1}', // 98
    'adc (x), (y)', // 99
    'subw ya, {b1}', // 9a
    'dec {b1}+x', // 9b
    'dec a', // 9c
    'mov x, sp', // 9d
    'div ya, x', // 9e
    'xcn a', // 9f
    'ei', // a0
    'tcall 10', // a1
    'set1 {b1}.5', // a2
    'bbs {b1}.5, {r2}', // a3
    'sbc a, {b1}', // a4
    'sbc a, {w1}', // a5
    'sbc a, (x)', // a6
    'sbc a, [{b1}+x]', // a7
    'sbc a, {i1}', // a8
    'sbc {b2}, {b1}', // a9
    'mov1 c, {m1}', // aa
    'inc {b1}', // ab
    'inc {w1}', // ac
    'cmp y, {i1}', // ad
    'pop a', // ae
    'mov (x)+, a', // af
    'bcs {r1}', // b0
    'tcall 11', // b1
    'clr1 {b1}.5', // b2
    'bbc {b1}.5, {r2}', // b3
    'sbc a, {b1}+x', // b4
    'sbc a, {w1}+x', // b5
    'sbc a, {w1}+y', // b6
    'sbc a, [{b1}]+y', // b7
    'sbc {b2}, {i1}', // b8
    'sbc (x), (y)', // b9
    'movw ya, {b1}', // ba
    'inc {b1}+x', // bb
    'inc a', // bc
    'mov sp, x', // bd
    'das a', // be
    'mov a, (x)+', // bf
    'di', // c0
    'tcall 12', // c1
    'set1 {b1}.6', // c2
    'bbs {b1}.6, {r2}', // c3
    'mov {b1}, a', // c4
    'mov {w1}, a', // c5
    'mov (x), a', // c6
    'mov [{b1}+x], a', // c7
    'cmp x, {i1}', // c8
    'mov {w1}, x', // c9
    'mov1 {m1}, c', // ca
    'mov {b1}, y', // cb
    'mov {w1}, y', // cc
    'mov x, {i1}', // cd
    'pop x', // ce
    'mul ya', // cf
    'bne {r1}', // d0
    'tcall 13', // d1
    'clr1 {b1}.6', // d2
    'bbc {b1}.6, {r2}', // d3
    'mov {b1}+x, a', // d4
    'mov {w1}+x, a', // d5
    'mov {w1}+y, a', // d6
    'mov [{b1}]+y, a', // d7
    'mov {b1}, x', // d8
    'mov {b1}+y, x', // d9
    'movw {b1}, ya', // da
    'mov {b1}+x, y', // db
    'dec y', // dc
    'mov a, y', // dd
    'cbne {b1}+x, {r2}', // de
    'daa a', // df
    'clrv', // e0
    'tcall 14', // e1
    'set1 {b1}.7', // e2
    'bbs {b1}.7, {r2}', // e3
    'mov a, {b1}', // e4
    'mov a, {w1}', // e5
    'mov a, (x)', // e6
    'mov a, [{b1}+x]', // e7
    'mov a, {i1}', // e8
    'mov x, {w1}', // e9
    'not1 {m1}', // ea
    'mov y, {b1}', // eb
    'mov y, {w1}', // ec
    'notc', // ed
    'pop y', // ee
    'sleep', // ef
    'beq {r1}', // f0
    'tcall 15', // f1
    'clr1 {b1}.7', // f2
    'bbc {b1}.7, {r2}', // f3
    'mov a, {b1}+x', // f4
    'mov a, {w1}+x', // f5
    'mov a, {w1}+y', // f6
    'mov a, [{b1}]+y', // f7
    'mov x, {b1}', // f8
    'mov x, {b1}+y', // f9
    'mov {b2}, {b1}', // fa
    'mov y, {b1}+x', // fb
    'inc y', // fc
    'mov y, a', // fd
    'dbnz y, {r1}', // fe
    'stop', // ff
  ];

  static final _token = RegExp(r'\{([bwirmu])(\d)\}');

  static String _hex(int value, int digits) =>
      '\$${value.toRadixString(16).padLeft(digits, '0')}';

  /// The length of the instruction with [opcode].
  static int length(int opcode) {
    var length = 1;
    for (final m in _token.allMatches(_ops[opcode & 0xff])) {
      final index = int.parse(m[2]!);
      final end = index + (m[1] == 'w' || m[1] == 'm' ? 2 : 1);
      if (end > length) length = end;
    }
    return length;
  }

  /// Formats the instruction in [bytes] (at least three) at [pc]; returns
  /// the text and the length.
  static (String, int) disasm(List<int> bytes, int pc) {
    final n = length(bytes[0]);
    final text = _ops[bytes[0] & 0xff].replaceAllMapped(_token, (m) {
      final index = int.parse(m[2]!);
      final b = bytes[index] & 0xff;
      int w() => b | (bytes[index + 1] & 0xff) << 8;
      return switch (m[1]) {
        'b' => _hex(b, 2),
        'i' => '#${_hex(b, 2)}',
        'w' => '!${_hex(w(), 4)}',
        'm' => '${_hex(w() & 0x1fff, 4)}.${w() >> 13}',
        'r' => _hex((pc + n + b.toSigned(8)) & 0xffff, 4),
        _ => _hex(0xff00 | b, 4),
      };
    });
    return (text, n);
  }
}
