// Project imports:
import '../../../util.dart';

enum _Operand {
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
  zerorel,
  zpind,
  blk,
  immedzero,
  immedabs,
  immedzerox,
  immedabsx,
}

class Disasm {
  static final _ops = _initOps();

  static Map<int, List<Object>> _initOps() {
    final ops = <int, List<Object>>{};
    if (ops.isEmpty) {
      ops.addAll({
        0x00: ["BRK", _Operand.none],
        0x08: ["PHP", _Operand.none],
        0x10: ["BPL", _Operand.rel],
        0x18: ["CLC", _Operand.none],
        0x20: ["JSR", _Operand.abs],
        0x24: ["BIT", _Operand.zero],
        0x28: ["PLP", _Operand.none],
        0x2c: ["BIT", _Operand.abs],
        0x30: ["BMI", _Operand.rel],
        0x38: ["SEC", _Operand.none],
        0x40: ["RTI", _Operand.none],
        0x48: ["PHA", _Operand.none],
        0x4c: ["JMP", _Operand.abs],
        0x50: ["BVC", _Operand.rel],
        0x58: ["CLI", _Operand.none],
        0x60: ["RTS", _Operand.none],
        0x68: ["PLA", _Operand.none],
        0x6c: ["JMP", _Operand.ind],
        0x70: ["BVS", _Operand.rel],
        0x78: ["SEI", _Operand.none],
        0x84: ["STY", _Operand.zero],
        0x88: ["DEY", _Operand.none],
        0x8c: ["STY", _Operand.abs],
        0x90: ["BCC", _Operand.rel],
        0x94: ["STY", _Operand.zerox],
        0x98: ["TYA", _Operand.none],
        0xa0: ["LDY", _Operand.immed],
        0xa4: ["LDY", _Operand.zero],
        0xa8: ["TAY", _Operand.none],
        0xac: ["LDY", _Operand.abs],
        0xb0: ["BCS", _Operand.rel],
        0xb4: ["LDY", _Operand.zerox],
        0xb8: ["CLV", _Operand.none],
        0xbc: ["LDY", _Operand.absx],
        0xc0: ["CPY", _Operand.immed],
        0xc4: ["CPY", _Operand.zero],
        0xc8: ["INY", _Operand.none],
        0xcc: ["CPY", _Operand.abs],
        0xd0: ["BNE", _Operand.rel],
        0xd8: ["CLD", _Operand.none],
        0xe0: ["CPX", _Operand.immed],
        0xe4: ["CPX", _Operand.zero],
        0xe8: ["INX", _Operand.none],
        0xec: ["CPX", _Operand.abs],
        0xf0: ["BEQ", _Operand.rel],
        0xf8: ["SED", _Operand.none],
        0x8a: ["TXA", _Operand.none],
        0xa2: ["LDX", _Operand.immed],
        0xaa: ["TAX", _Operand.none],
        0xca: ["DEX", _Operand.none],
        0xea: ["NOP", _Operand.none],
        0x9a: ["TXS", _Operand.none],
        0xba: ["TSX", _Operand.none],
        0x0a: ["ASL", _Operand.none],
        0x2a: ["ROL", _Operand.none],
        0x4a: ["LSR", _Operand.none],
        0x6a: ["ROR", _Operand.none],
        0x03: ["ST0", _Operand.immed],
        0x13: ["ST1", _Operand.immed],
        0x23: ["ST2", _Operand.immed],
        0x43: ["TMA", _Operand.immed],
        0x53: ["TAM", _Operand.immed],
        0x73: ["TII", _Operand.blk],
        0x83: ["TST", _Operand.immedzero],
        0x93: ["TST", _Operand.immedabs],
        0xa3: ["TST", _Operand.immedzerox],
        0xb3: ["TST", _Operand.immedabsx],
        0xc3: ["TDD", _Operand.blk],
        0xd3: ["TIN", _Operand.blk],
        0xe3: ["TIA", _Operand.blk],
        0xf3: ["TAI", _Operand.blk],
        0x02: ["SXY", _Operand.none],
        0x22: ["SAX", _Operand.none],
        0x42: ["SAY", _Operand.none],
        0x62: ["CLA", _Operand.none],
        0x82: ["CLX", _Operand.none],
        0xc2: ["CLY", _Operand.none],
        0x04: ["TSB", _Operand.zero],
        0x0c: ["TSB", _Operand.abs],
        0x14: ["TRB", _Operand.zero],
        0x1c: ["TRB", _Operand.abs],
        0x64: ["STZ", _Operand.zero],
        0x74: ["STZ", _Operand.zerox],
        0x9c: ["STZ", _Operand.abs],
        0x9e: ["STZ", _Operand.absx],
        0x54: ["CSL", _Operand.none],
        0xd4: ["CSH", _Operand.none],
        0xf4: ["SET", _Operand.none],
        0x44: ["BSR", _Operand.rel],
        0x34: ["BIT", _Operand.zerox],
        0x3c: ["BIT", _Operand.absx],
        0x89: ["BIT", _Operand.immed],
        0x1a: ["INC", _Operand.none],
        0x3a: ["DEC", _Operand.none],
        0x5a: ["PHY", _Operand.none],
        0x7a: ["PLY", _Operand.none],
        0xda: ["PHX", _Operand.none],
        0xfa: ["PLX", _Operand.none],
        0x7c: ["JMP", _Operand.absx],
        0x80: ["BRA", _Operand.rel],
      });

      var opcode = 0x00;
      for (var i in ["ORA", "AND", "EOR", "ADC", "STA", "LDA", "CMP", "SBC"]) {
        ops[opcode + 0x01] = [i, _Operand.indx];
        ops[opcode + 0x05] = [i, _Operand.zero];
        ops[opcode + 0x09] = [i, _Operand.immed];
        ops[opcode + 0x0d] = [i, _Operand.abs];
        ops[opcode + 0x11] = [i, _Operand.indy];
        ops[opcode + 0x15] = [i, _Operand.zerox];
        ops[opcode + 0x19] = [i, _Operand.absy];
        ops[opcode + 0x1d] = [i, _Operand.absx];
        ops[opcode + 0x12] = [i, _Operand.zpind];
        opcode += 0x20;
      }

      // opcode = 0x00;
      // for (var i in ["SLO", "RLA", "SRE", "RRA", "SAX", "LAX", "DCP", "ISC"]) {
      //   ops[opcode + 0x03] = [i, _Operand.indx];
      //   ops[opcode + 0x07] = [i, _Operand.zero];
      //   ops[opcode + 0x0f] = [i, _Operand.abs];
      //   opcode += 0x20;
      // }

      // opcode = 0x00;
      // for (var i in ["ANC", "ANC", "ALR", "ARR", "XAA", "LAX", "AXS", "SBC"]) {
      //   ops[opcode + 0x0b] = [i, _Operand.immed];
      //   opcode += 0x20;
      // }

      opcode = 0x00;
      for (var i in ["ASL", "ROL", "LSR", "ROR", "STX", "LDX", "DEC", "INC"]) {
        ops[opcode + 0x06] = [i, _Operand.zero];
        ops[opcode + 0x0e] = [i, _Operand.abs];
        ops[opcode + 0x16] = [
          i,
          (opcode + 0x16 == 0xb6) ? _Operand.zeroy : _Operand.zerox
        ];
        ops[opcode + 0x1e] = [
          i,
          (opcode + 0x1e == 0xbe) ? _Operand.absy : _Operand.absx
        ];
        opcode += 0x20;
      }

      for (var i in range(0, 8)) {
        ops[i * 0x10 + 0x07] = ["RMB$i", _Operand.zero];
        ops[i * 0x10 + 0x87] = ["SMB$i", _Operand.zero];
      }

      for (var i in range(0, 8)) {
        ops[i * 0x10 + 0x0f] = ["BBR$i", _Operand.zerorel];
        ops[i * 0x10 + 0x8f] = ["BBS$i", _Operand.zerorel];
      }
    }

    return ops;
  }

  static String disasm(final int pc, int op, int a, int b,
      {int c = 0, int d = 0}) {
    final addr = hex16(pc);
    final x = hex8(op);
    final y = hex8(a);
    final z = hex8(b);
    final blk0 = hex16((b << 8) | a);
    final blk1 = hex16(c);
    final blk2 = hex16(d);

    final val = _ops[op];
    if (val == null) {
      return "$addr  $x        ---";
    }

    final inst = val[0];
    var set = "";

    final rel = pc + 2 + ((a + 128) & 0xff) - 128;
    final rel2 = pc + 3 + ((b + 128) & 0xff) - 128;

    switch (val[1]) {
      case _Operand.immed:
        return "$addr  $x $y     $inst #\$$y $set";
      case _Operand.zero:
        return "$addr  $x $y     $inst \$$y $set";
      case _Operand.zerox:
        return "$addr  $x $y     $inst \$$y, X $set";
      case _Operand.zeroy:
        return "$addr  $x $y     $inst \$$y, Y $set";
      case _Operand.abs:
        return "$addr  $x $y $z  $inst \$$z$y $set";
      case _Operand.absx:
        return "$addr  $x $y $z  $inst \$$z$y, X $set";
      case _Operand.absy:
        return "$addr  $x $y $z  $inst \$$z$y, Y $set";
      case _Operand.ind:
        return "$addr  $x $y $z  $inst \$($z$y) $set";
      case _Operand.indx:
        return "$addr  $x $y     $inst \$($y, X) $set";
      case _Operand.indy:
        return "$addr  $x $y     $inst \$($y), Y $set";
      case _Operand.rel:
        return "$addr  $x $y     $inst \$${hex16(rel)}";
      case _Operand.zerorel:
        return "$addr  $x $y $z  $inst \$$y, \$${hex16(rel2)}";
      case _Operand.zpind:
        return "$addr  $x $y     $inst \$($y) $set";
      case _Operand.blk:
        return "$addr  $x $blk0 $blk1 $blk2  $inst $blk0,$blk1,$blk2 $set";
      case _Operand.immedzero:
        return "$addr  $x $y $z  $inst #\$$y, \$$z $set";
      case _Operand.immedabs:
        return "$addr  $x $y $z  $inst #\$$y, \$$z $set";
      case _Operand.immedzerox:
        return "$addr  $x $y $z  $inst #\$$y, \$$z, X $set";
      case _Operand.immedabsx:
        return "$addr  $x $y $z  $inst #\$$y, \$$z, X $set";

      default:
        return "$addr  $x        $inst";
    }
  }

  static int nextPC(final int op) {
    final val = _ops[op];
    if (val == null) {
      return 1;
    }
    switch (val[1]) {
      case _Operand.immed:
      case _Operand.zero:
      case _Operand.zerox:
      case _Operand.zeroy:
      case _Operand.indx:
      case _Operand.indy:
      case _Operand.rel:
      case _Operand.zpind:
        return 2;
      case _Operand.abs:
      case _Operand.absx:
      case _Operand.absy:
      case _Operand.ind:
      case _Operand.zerorel:
      case _Operand.immedzero:
      case _Operand.immedzerox:
        return 3;
      case _Operand.immedabs:
      case _Operand.immedabsx:
        return 4;
      case _Operand.blk:
        return 7;
      default:
        return 1;
    }
  }
}
