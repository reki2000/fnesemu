// Project imports:
import '../../../util/util.dart';

enum Operand {
  im,
  zp,
  zpx,
  zpy,
  abs,
  absx,
  absy,
  ind16,
  zpind,
  zpindx,
  zpindy,
  rel,
  zerorel,
  blk,
  imzp,
  imabs,
  imzpx,
  imabsx,
  im16,
  none,
}

class Disasm {
  static final _ops = _initOps();

  static Map<int, Pair<String, Operand>> _initOps() {
    final ops = <int, List<Object>>{};

    if (ops.isEmpty) {
      ops.addAll({
        0x00: ["BRK", Operand.none],
        0x08: ["PHP", Operand.none],
        0x10: ["BPL", Operand.rel],
        0x18: ["CLC", Operand.none],
        0x20: ["JSR", Operand.im16],
        0x24: ["BIT", Operand.zp],
        0x28: ["PLP", Operand.none],
        0x2c: ["BIT", Operand.abs],
        0x30: ["BMI", Operand.rel],
        0x38: ["SEC", Operand.none],
        0x40: ["RTI", Operand.none],
        0x48: ["PHA", Operand.none],
        0x4c: ["JMP", Operand.im16],
        0x50: ["BVC", Operand.rel],
        0x58: ["CLI", Operand.none],
        0x60: ["RTS", Operand.none],
        0x68: ["PLA", Operand.none],
        0x6c: ["JMP", Operand.ind16],
        0x70: ["BVS", Operand.rel],
        0x78: ["SEI", Operand.none],
        0x84: ["STY", Operand.zp],
        0x88: ["DEY", Operand.none],
        0x8c: ["STY", Operand.abs],
        0x90: ["BCC", Operand.rel],
        0x94: ["STY", Operand.zpx],
        0x98: ["TYA", Operand.none],
        0xa0: ["LDY", Operand.im],
        0xa4: ["LDY", Operand.zp],
        0xa8: ["TAY", Operand.none],
        0xac: ["LDY", Operand.abs],
        0xb0: ["BCS", Operand.rel],
        0xb4: ["LDY", Operand.zpx],
        0xb8: ["CLV", Operand.none],
        0xbc: ["LDY", Operand.absx],
        0xc0: ["CPY", Operand.im],
        0xc4: ["CPY", Operand.zp],
        0xc8: ["INY", Operand.none],
        0xcc: ["CPY", Operand.abs],
        0xd0: ["BNE", Operand.rel],
        0xd8: ["CLD", Operand.none],
        0xe0: ["CPX", Operand.im],
        0xe4: ["CPX", Operand.zp],
        0xe8: ["INX", Operand.none],
        0xec: ["CPX", Operand.abs],
        0xf0: ["BEQ", Operand.rel],
        0xf8: ["SED", Operand.none],
        0x8a: ["TXA", Operand.none],
        0xa2: ["LDX", Operand.im],
        0xaa: ["TAX", Operand.none],
        0xca: ["DEX", Operand.none],
        0xea: ["NOP", Operand.none],
        0x9a: ["TXS", Operand.none],
        0xba: ["TSX", Operand.none],
        0x0a: ["ASL", Operand.none],
        0x2a: ["ROL", Operand.none],
        0x4a: ["LSR", Operand.none],
        0x6a: ["ROR", Operand.none],
        0x03: ["ST0", Operand.im],
        0x13: ["ST1", Operand.im],
        0x23: ["ST2", Operand.im],
        0x43: ["TMA", Operand.im],
        0x53: ["TAM", Operand.im],
        0x73: ["TII", Operand.blk],
        0x83: ["TST", Operand.imzp],
        0x93: ["TST", Operand.imabs],
        0xa3: ["TST", Operand.imzpx],
        0xb3: ["TST", Operand.imabsx],
        0xc3: ["TDD", Operand.blk],
        0xd3: ["TIN", Operand.blk],
        0xe3: ["TIA", Operand.blk],
        0xf3: ["TAI", Operand.blk],
        0x02: ["SXY", Operand.none],
        0x22: ["SAX", Operand.none],
        0x42: ["SAY", Operand.none],
        0x62: ["CLA", Operand.none],
        0x82: ["CLX", Operand.none],
        0xc2: ["CLY", Operand.none],
        0x04: ["TSB", Operand.zp],
        0x0c: ["TSB", Operand.abs],
        0x14: ["TRB", Operand.zp],
        0x1c: ["TRB", Operand.abs],
        0x64: ["STZ", Operand.zp],
        0x74: ["STZ", Operand.zpx],
        0x9c: ["STZ", Operand.abs],
        0x9e: ["STZ", Operand.absx],
        0x54: ["CSL", Operand.none],
        0xd4: ["CSH", Operand.none],
        0xf4: ["SET", Operand.none],
        0x44: ["BSR", Operand.rel],
        0x34: ["BIT", Operand.zpx],
        0x3c: ["BIT", Operand.absx],
        0x89: ["BIT", Operand.im],
        0x1a: ["INC", Operand.none],
        0x3a: ["DEC", Operand.none],
        0x5a: ["PHY", Operand.none],
        0x7a: ["PLY", Operand.none],
        0xda: ["PHX", Operand.none],
        0xfa: ["PLX", Operand.none],
        0x7c: ["JMP", Operand.absx],
        0x80: ["BRA", Operand.rel],
      });

      var opcode = 0x00;
      for (var i in ["ORA", "AND", "EOR", "ADC", "STA", "LDA", "CMP", "SBC"]) {
        ops[opcode + 0x01] = [i, Operand.zpindx];
        ops[opcode + 0x05] = [i, Operand.zp];
        ops[opcode + 0x09] = [i, Operand.im];
        ops[opcode + 0x0d] = [i, Operand.abs];
        ops[opcode + 0x11] = [i, Operand.zpindy];
        ops[opcode + 0x15] = [i, Operand.zpx];
        ops[opcode + 0x19] = [i, Operand.absy];
        ops[opcode + 0x1d] = [i, Operand.absx];
        ops[opcode + 0x12] = [i, Operand.zpind];
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
        ops[opcode + 0x06] = [i, Operand.zp];
        ops[opcode + 0x0e] = [i, Operand.abs];
        ops[opcode + 0x16] = [i, Operand.zpx];
        ops[opcode + 0x1e] = [i, Operand.absx];
        opcode += 0x20;
      }
      ops[0xb6] = ["LDX", Operand.zpy];
      ops[0xbe] = ["LDX", Operand.absy];

      for (var i in range(0, 8)) {
        ops[i * 0x10 + 0x07] = ["RMB$i", Operand.zp];
        ops[i * 0x10 + 0x87] = ["SMB$i", Operand.zp];
      }

      for (var i in range(0, 8)) {
        ops[i * 0x10 + 0x0f] = ["BBR$i", Operand.zerorel];
        ops[i * 0x10 + 0x8f] = ["BBS$i", Operand.zerorel];
      }
    }

    return ops
        .map((op, e) => MapEntry(op, Pair(e[0] as String, e[1] as Operand)));
  }

  static Operand operand(int op) {
    final val = _ops[op];
    if (val == null) {
      return Operand.none;
    }

    return val.i1;
  }

  static String disasm(final int pc, int d0, int d1, int d2,
      {int d34 = 0, int d56 = 0}) {
    final d3 = d34 & 0xff;

    final addr = hex16(pc);
    final op = hex8(d0);
    final a1 = hex8(d1);
    final a2 = hex8(d2);
    final a3 = hex8(d3);

    final a12 = hex16((d2 << 8) | d1);
    final a34 = hex16(d34);
    final a56 = hex16(d56);

    final a23 = hex16(d3 << 8 | d2);

    final val = _ops[d0];
    if (val == null) {
      return "$addr  $op        ---";
    }

    final inst = val.i0;
    var set = "";

    final rel = pc + 2 + ((d1 + 128) & 0xff) - 128;
    final rel2 = pc + 3 + ((d2 + 128) & 0xff) - 128;

    final args = switch (val.i1) {
      Operand.im => "$a1     $inst #\$$a1 $set",
      Operand.im16 => "$a1 $a2  $inst \$$a2$a1 $set",
      Operand.zp => "$a1     $inst \$$a1 $set",
      Operand.zpx => "$a1     $inst \$$a1, X $set",
      Operand.zpy => "$a1     $inst \$$a1, Y $set",
      Operand.abs => "$a1 $a2  $inst \$$a2$a1 $set",
      Operand.absx => "$a1 $a2  $inst \$$a2$a1, X $set",
      Operand.absy => "$a1 $a2  $inst \$$a2$a1, Y $set",
      Operand.ind16 => "$a1 $a2  $inst \$($a2$a1) $set",
      Operand.zpindx => "$a1     $inst \$($a1, X) $set",
      Operand.zpindy => "$a1     $inst \$($a1), Y $set",
      Operand.rel => "$a1     $inst \$${hex16(rel)}",
      Operand.zerorel => "$a1 $a2  $inst \$$a1, \$${hex16(rel2)}",
      Operand.zpind => "$a1     $inst \$($a1) $set",
      Operand.blk => "$a12 $a34 $a56  $inst $a12,$a34,$a56 $set",
      Operand.imzp => "$a1 $a2  $inst #\$$a1, \$$a2 $set",
      Operand.imabs => "$a1 $a2 $a3 $inst #\$$a1, \$$a23 $set",
      Operand.imzpx => "$a1 $a2  $inst #\$$a1, \$$a2, X $set",
      Operand.imabsx => "$a1 $a2 $a3 $inst #\$$a1, \$$a23, X $set",
      _ => "       $inst",
    };

    return "$addr  $op $args";
  }

  static int nextPC(final int op) {
    final val = _ops[op];
    if (val == null) {
      return 1;
    }
    switch (val.i1) {
      case Operand.im:
      case Operand.zp:
      case Operand.zpx:
      case Operand.zpy:
      case Operand.zpindx:
      case Operand.zpindy:
      case Operand.rel:
      case Operand.zpind:
        return 2;
      case Operand.abs:
      case Operand.absx:
      case Operand.absy:
      case Operand.ind16:
      case Operand.zerorel:
      case Operand.imzp:
      case Operand.imzpx:
        return 3;
      case Operand.imabs:
      case Operand.imabsx:
        return 4;
      case Operand.blk:
        return 7;
      default:
        return 1;
    }
  }
}
