import 'package:fnesemu/util/int.dart';

/// addressing-mode kinds used only for disassembly formatting.
enum _Am {
  imp,
  acc,
  immM, // # width follows accumulator
  immX, // # width follows index
  imm8,
  dp,
  dpX,
  dpY,
  idp,
  idpX,
  idpY,
  ildp,
  ildpY,
  abs,
  absX,
  absY,
  lng,
  lngX,
  sr,
  srY,
  rel,
  rell,
  iabs,
  iabsX,
  ilabs,
  blk,
}

class Disasm {
  // opcode -> (mnemonic, addressing mode)
  static const _table = <int, (String, _Am)>{
    0x00: ("BRK", _Am.imm8), 0x02: ("COP", _Am.imm8),
    0xea: ("NOP", _Am.imp), 0x42: ("WDM", _Am.imm8),
    0xcb: ("WAI", _Am.imp), 0xdb: ("STP", _Am.imp),
    0xeb: ("XBA", _Am.imp), 0xfb: ("XCE", _Am.imp),
    0x18: ("CLC", _Am.imp), 0x38: ("SEC", _Am.imp),
    0x58: ("CLI", _Am.imp), 0x78: ("SEI", _Am.imp),
    0xd8: ("CLD", _Am.imp), 0xf8: ("SED", _Am.imp),
    0xb8: ("CLV", _Am.imp), 0xc2: ("REP", _Am.imm8),
    0xe2: ("SEP", _Am.imm8),
    // transfers
    0xaa: ("TAX", _Am.imp), 0xa8: ("TAY", _Am.imp),
    0x8a: ("TXA", _Am.imp), 0x98: ("TYA", _Am.imp),
    0x9b: ("TXY", _Am.imp), 0xbb: ("TYX", _Am.imp),
    0xba: ("TSX", _Am.imp), 0x9a: ("TXS", _Am.imp),
    0x5b: ("TCD", _Am.imp), 0x7b: ("TDC", _Am.imp),
    0x1b: ("TCS", _Am.imp), 0x3b: ("TSC", _Am.imp),
    // stack
    0x48: ("PHA", _Am.imp), 0xda: ("PHX", _Am.imp),
    0x5a: ("PHY", _Am.imp), 0x08: ("PHP", _Am.imp),
    0x0b: ("PHD", _Am.imp), 0x8b: ("PHB", _Am.imp),
    0x4b: ("PHK", _Am.imp), 0x68: ("PLA", _Am.imp),
    0xfa: ("PLX", _Am.imp), 0x7a: ("PLY", _Am.imp),
    0x28: ("PLP", _Am.imp), 0x2b: ("PLD", _Am.imp),
    0xab: ("PLB", _Am.imp), 0xf4: ("PEA", _Am.abs),
    0xd4: ("PEI", _Am.dp), 0x62: ("PER", _Am.rell),
    // inc/dec reg
    0x1a: ("INC", _Am.acc), 0x3a: ("DEC", _Am.acc),
    0xe8: ("INX", _Am.imp), 0xc8: ("INY", _Am.imp),
    0xca: ("DEX", _Am.imp), 0x88: ("DEY", _Am.imp),
    // branches
    0x90: ("BCC", _Am.rel), 0xb0: ("BCS", _Am.rel),
    0xd0: ("BNE", _Am.rel), 0xf0: ("BEQ", _Am.rel),
    0x10: ("BPL", _Am.rel), 0x30: ("BMI", _Am.rel),
    0x50: ("BVC", _Am.rel), 0x70: ("BVS", _Am.rel),
    0x80: ("BRA", _Am.rel), 0x82: ("BRL", _Am.rell),
    // jumps
    0x4c: ("JMP", _Am.abs), 0x6c: ("JMP", _Am.iabs),
    0x7c: ("JMP", _Am.iabsX), 0x5c: ("JML", _Am.lng),
    0xdc: ("JML", _Am.ilabs), 0x20: ("JSR", _Am.abs),
    0xfc: ("JSR", _Am.iabsX), 0x22: ("JSL", _Am.lng),
    0x60: ("RTS", _Am.imp), 0x6b: ("RTL", _Am.imp),
    0x40: ("RTI", _Am.imp),
    // block move
    0x54: ("MVN", _Am.blk), 0x44: ("MVP", _Am.blk),
    // loads/stores not covered by the ALU family pattern
    0xa2: ("LDX", _Am.immX), 0xa6: ("LDX", _Am.dp),
    0xb6: ("LDX", _Am.dpY), 0xae: ("LDX", _Am.abs),
    0xbe: ("LDX", _Am.absY),
    0xa0: ("LDY", _Am.immX), 0xa4: ("LDY", _Am.dp),
    0xb4: ("LDY", _Am.dpX), 0xac: ("LDY", _Am.abs),
    0xbc: ("LDY", _Am.absX),
    0x86: ("STX", _Am.dp), 0x96: ("STX", _Am.dpY),
    0x8e: ("STX", _Am.abs),
    0x84: ("STY", _Am.dp), 0x94: ("STY", _Am.dpX),
    0x8c: ("STY", _Am.abs),
    0x64: ("STZ", _Am.dp), 0x74: ("STZ", _Am.dpX),
    0x9c: ("STZ", _Am.abs), 0x9e: ("STZ", _Am.absX),
    0xe0: ("CPX", _Am.immX), 0xe4: ("CPX", _Am.dp),
    0xec: ("CPX", _Am.abs),
    0xc0: ("CPY", _Am.immX), 0xc4: ("CPY", _Am.dp),
    0xcc: ("CPY", _Am.abs),
    0x89: ("BIT", _Am.immM), 0x24: ("BIT", _Am.dp),
    0x34: ("BIT", _Am.dpX), 0x2c: ("BIT", _Am.abs),
    0x3c: ("BIT", _Am.absX),
    // shifts/rotates
    0x0a: ("ASL", _Am.acc), 0x06: ("ASL", _Am.dp),
    0x16: ("ASL", _Am.dpX), 0x0e: ("ASL", _Am.abs),
    0x1e: ("ASL", _Am.absX),
    0x4a: ("LSR", _Am.acc), 0x46: ("LSR", _Am.dp),
    0x56: ("LSR", _Am.dpX), 0x4e: ("LSR", _Am.abs),
    0x5e: ("LSR", _Am.absX),
    0x2a: ("ROL", _Am.acc), 0x26: ("ROL", _Am.dp),
    0x36: ("ROL", _Am.dpX), 0x2e: ("ROL", _Am.abs),
    0x3e: ("ROL", _Am.absX),
    0x6a: ("ROR", _Am.acc), 0x66: ("ROR", _Am.dp),
    0x76: ("ROR", _Am.dpX), 0x6e: ("ROR", _Am.abs),
    0x7e: ("ROR", _Am.absX),
    // memory inc/dec
    0xe6: ("INC", _Am.dp), 0xf6: ("INC", _Am.dpX),
    0xee: ("INC", _Am.abs), 0xfe: ("INC", _Am.absX),
    0xc6: ("DEC", _Am.dp), 0xd6: ("DEC", _Am.dpX),
    0xce: ("DEC", _Am.abs), 0xde: ("DEC", _Am.absX),
    // test-and-set/reset bits
    0x04: ("TSB", _Am.dp), 0x0c: ("TSB", _Am.abs),
    0x14: ("TRB", _Am.dp), 0x1c: ("TRB", _Am.abs),
  };

  // opcodes that share an addressing-mode pattern by low nibble group.
  static const _alu = <int, String>{
    0x00: "ORA", 0x20: "AND", 0x40: "EOR", 0x60: "ADC",
    0x80: "STA", 0xa0: "LDA", 0xc0: "CMP", 0xe0: "SBC",
  };
  static const _aluModes = <int, _Am>{
    0x01: _Am.idpX, 0x03: _Am.sr, 0x05: _Am.dp, 0x07: _Am.ildp,
    0x09: _Am.immM, 0x0d: _Am.abs, 0x0f: _Am.lng, 0x11: _Am.idpY,
    0x12: _Am.idp, 0x13: _Am.srY, 0x15: _Am.dpX, 0x17: _Am.ildpY,
    0x19: _Am.absY, 0x1d: _Am.absX, 0x1f: _Am.lngX,
  };

  static (String, _Am) _lookup(int op) {
    final t = _table[op];
    if (t != null) return t;

    // ALU family
    final hi = op & 0xe0;
    final lo = op.mask5;
    final name = _alu[hi];
    final mode = _aluModes[lo];
    if (name != null && mode != null) {
      // STA has no immediate
      if (!(name == "STA" && mode == _Am.immM)) {
        return (name, mode);
      }
    }
    return ("???", _Am.imp);
  }

  static int _len(_Am am, int mSize, int xSize) {
    switch (am) {
      case _Am.imp:
      case _Am.acc:
        return 0;
      case _Am.immM:
        return mSize;
      case _Am.immX:
        return xSize;
      case _Am.imm8:
      case _Am.dp:
      case _Am.dpX:
      case _Am.dpY:
      case _Am.idp:
      case _Am.idpX:
      case _Am.idpY:
      case _Am.ildp:
      case _Am.ildpY:
      case _Am.sr:
      case _Am.srY:
      case _Am.rel:
        return 1;
      case _Am.abs:
      case _Am.absX:
      case _Am.absY:
      case _Am.iabs:
      case _Am.iabsX:
      case _Am.ilabs:
      case _Am.rell:
      case _Am.blk:
        return 2;
      case _Am.lng:
      case _Am.lngX:
        return 3;
    }
  }

  static String _operand(_Am am, int a, int b, int c, int pc, int len) {
    final w = a | b.shl8;
    switch (am) {
      case _Am.imp:
        return "";
      case _Am.acc:
        return "A";
      case _Am.immM:
      case _Am.immX:
        return len == 2 ? "#\$${w.x4}" : "#\$${a.x2}";
      case _Am.imm8:
        return "#\$${a.x2}";
      case _Am.dp:
        return "\$${a.x2}";
      case _Am.dpX:
        return "\$${a.x2},X";
      case _Am.dpY:
        return "\$${a.x2},Y";
      case _Am.idp:
        return "(\$${a.x2})";
      case _Am.idpX:
        return "(\$${a.x2},X)";
      case _Am.idpY:
        return "(\$${a.x2}),Y";
      case _Am.ildp:
        return "[\$${a.x2}]";
      case _Am.ildpY:
        return "[\$${a.x2}],Y";
      case _Am.sr:
        return "\$${a.x2},S";
      case _Am.srY:
        return "(\$${a.x2},S),Y";
      case _Am.abs:
        return "\$${w.x4}";
      case _Am.absX:
        return "\$${w.x4},X";
      case _Am.absY:
        return "\$${w.x4},Y";
      case _Am.iabs:
        return "(\$${w.x4})";
      case _Am.iabsX:
        return "(\$${w.x4},X)";
      case _Am.ilabs:
        return "[\$${w.x4}]";
      case _Am.lng:
      case _Am.lngX:
        {
          final l = w | c.shl16;
          return "\$${l.x6}${am == _Am.lngX ? ',X' : ''}";
        }
      case _Am.rel:
        return "\$${(pc + 2 + a.rel8).mask16.x4}";
      case _Am.rell:
        return "\$${(pc + 3 + w.rel16).mask16.x4}";
      case _Am.blk:
        return "\$${b.x2},\$${a.x2}";
    }
  }

  /// returns (mnemonic text, instruction length in bytes)
  static (String, int) disasm(
      int pc, int op, int a, int b, int c, int mSize, int xSize) {
    final (name, am) = _lookup(op);
    final n = _len(am, mSize, xSize);
    final operand = _operand(am, a, b, c, pc, n);
    final text = operand.isEmpty ? name : "$name $operand";
    return (text, n + 1);
  }
}
