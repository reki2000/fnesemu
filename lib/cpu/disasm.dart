// Project imports:
import 'util.dart';

enum _A {
  immed,
  zero,
  zerox,
  zeroy,
  abs,
  absx,
  absy,
  ind,
  indx,
  indy,
  none,
  rel,
}

final _ops = <int, List<Object>>{};

void setupDisasm() {
  _ops.addAll({
    0x00: ["BRK", _A.none],
    0x08: ["PHP", _A.none],
    0x10: ["BPL", _A.rel],
    0x18: ["CLC", _A.none],
    0x20: ["JSR", _A.abs],
    0x24: ["BIT", _A.zero],
    0x28: ["PLP", _A.none],
    0x2c: ["BIT", _A.abs],
    0x30: ["BMI", _A.rel],
    0x38: ["SEC", _A.none],
    0x40: ["RTI", _A.none],
    0x48: ["PHA", _A.none],
    0x4c: ["JMP", _A.abs],
    0x50: ["BVC", _A.rel],
    0x58: ["CLI", _A.none],
    0x60: ["RTS", _A.none],
    0x68: ["PLA", _A.none],
    0x6c: ["JMP", _A.ind],
    0x70: ["BVS", _A.rel],
    0x78: ["SEI", _A.none],
    0x84: ["STY", _A.zero],
    0x88: ["DEY", _A.none],
    0x8c: ["STY", _A.abs],
    0x90: ["BCC", _A.rel],
    0x94: ["STY", _A.zerox],
    0x98: ["TYA", _A.none],
    0x9c: ["SHY", _A.absx],
    0xa0: ["LDY", _A.immed],
    0xa4: ["LDY", _A.zero],
    0xa8: ["TAY", _A.none],
    0xac: ["LDY", _A.abs],
    0xb0: ["BCS", _A.rel],
    0xb4: ["LDY", _A.zerox],
    0xb8: ["CLV", _A.none],
    0xbc: ["LDY", _A.absx],
    0xc0: ["CPY", _A.immed],
    0xc4: ["CPY", _A.zero],
    0xc8: ["INY", _A.none],
    0xcc: ["CPY", _A.abs],
    0xd0: ["BNE", _A.rel],
    0xd8: ["CLD", _A.none],
    0xe0: ["CPX", _A.immed],
    0xe4: ["CPX", _A.zero],
    0xe8: ["INX", _A.none],
    0xec: ["CPX", _A.abs],
    0xf0: ["BEQ", _A.rel],
    0xf8: ["SED", _A.none],
    0x8a: ["TXA", _A.none],
    0xa2: ["LDX", _A.immed],
    0xaa: ["TAX", _A.none],
    0xca: ["DEX", _A.none],
    0xea: ["NOP", _A.none],
    0x9a: ["TXS", _A.none],
    0xba: ["TSX", _A.none],
    0x0a: ["ASL", _A.none],
    0x2a: ["ROL", _A.none],
    0x4a: ["LSR", _A.none],
    0x6a: ["ROR", _A.none],
  });

  var opcode = 0x00;
  for (var i in ["ORA", "AND", "EOR", "ADC", "STA", "LDA", "CMP", "SBC"]) {
    _ops[opcode + 0x01] = [i, _A.indx];
    _ops[opcode + 0x05] = [i, _A.zero];
    _ops[opcode + 0x09] = [i, _A.immed];
    _ops[opcode + 0x0d] = [i, _A.abs];
    _ops[opcode + 0x11] = [i, _A.indy];
    _ops[opcode + 0x15] = [i, _A.zerox];
    _ops[opcode + 0x19] = [i, _A.absy];
    _ops[opcode + 0x1d] = [i, _A.absx];
    opcode += 0x20;
  }

  opcode = 0x00;
  for (var i in ["SLO", "RLA", "SRE", "RRA", "SAX", "LAX", "DCP", "ISC"]) {
    _ops[opcode + 0x03] = [i, _A.indx];
    _ops[opcode + 0x07] = [i, _A.zero];
    _ops[opcode + 0x0f] = [i, _A.abs];
    opcode += 0x20;
  }

  opcode = 0x00;
  for (var i in ["ANC", "ANC", "ALR", "ARR", "XAA", "LAX", "AXS", "SBC"]) {
    _ops[opcode + 0x0b] = [i, _A.immed];
    opcode += 0x20;
  }

  opcode = 0x00;
  for (var i in ["ASL", "ROL", "LSR", "ROR", "STX", "LDX", "DEC", "INC"]) {
    _ops[opcode + 0x06] = [i, _A.zero];
    _ops[opcode + 0x0e] = [i, _A.abs];
    _ops[opcode + 0x16] = [i, _A.zerox];
    _ops[opcode + 0x1e] = [i, _A.absx];
    opcode += 0x20;
  }
}

String disasm(final int pc, int op, int a, int b) {
  final val = _ops[op];
  if (val == null) {
    return "---";
  }

  final inst = val[0];
  var set = "";

  final addr = hex16(pc);
  final x = hex8(op);
  final y = hex8(a);
  final z = hex8(b);

  final rel = pc + 2 + ((a + 128) & 0xff) - 128;

  switch (val[1]) {
    case _A.immed:
      return "$addr  $x $y     $inst #\$$y $set";
    case _A.zero:
      return "$addr  $x $y     $inst \$$y $set";
    case _A.zerox:
      return "$addr  $x $y     $inst \$$y, X $set";
    case _A.zeroy:
      return "$addr  $x $y     $inst \$$y, Y $set";
    case _A.abs:
      return "$addr  $x $y $z  $inst \$$z$y $set";
    case _A.absx:
      return "$addr  $x $y $z  $inst \$$z$y, X $set";
    case _A.absy:
      return "$addr  $x $y $z  $inst \$$z$y, Y $set";
    case _A.ind:
      return "$addr  $x $y $z  $inst \$($z$y) $set";
    case _A.indx:
      return "$addr  $x $y     $inst \$($y, X) $set";
    case _A.indy:
      return "$addr  $x $y     $inst \$($y), Y $set";
    case _A.rel:
      return "$addr  $x $y     $inst \$${hex16(rel)}";
    default:
      return "$addr  $x        $inst";
  }
}

int nextPC(final int op) {
  final val = _ops[op];
  if (val == null) {
    return 1;
  }
  switch (val[1]) {
    case _A.immed:
    case _A.zero:
    case _A.zerox:
    case _A.zeroy:
    case _A.indx:
    case _A.indy:
    case _A.rel:
      return 2;
    case _A.abs:
    case _A.absx:
    case _A.absy:
    case _A.ind:
      return 3;
    default:
      return 1;
  }
}
