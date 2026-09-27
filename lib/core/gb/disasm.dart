import 'package:fnesemu/util/int.dart';

/// disassembler of the SM83 instruction set
class Disasm {
  static const _r = ["B", "C", "D", "E", "H", "L", "(HL)", "A"];
  static const _alu = [
    "ADD A,", "ADC A,", "SUB ", "SBC A,", "AND ", "XOR ", "OR ", "CP " //
  ];
  static const _rot = ["RLC", "RRC", "RL", "RR", "SLA", "SRA", "SWAP", "SRL"];

  // d8: immediate byte, d16: immediate word, a16: address,
  // a8: high page address, r8: relative / signed byte
  static const _ops = [
    // 0x00
    "NOP", "LD BC,d16", "LD (BC),A", "INC BC", "INC B", "DEC B", "LD B,d8",
    "RLCA", "LD (a16),SP", "ADD HL,BC", "LD A,(BC)", "DEC BC", "INC C",
    "DEC C", "LD C,d8", "RRCA",
    // 0x10
    "STOP d8", "LD DE,d16", "LD (DE),A", "INC DE", "INC D", "DEC D",
    "LD D,d8", "RLA", "JR r8", "ADD HL,DE", "LD A,(DE)", "DEC DE", "INC E",
    "DEC E", "LD E,d8", "RRA",
    // 0x20
    "JR NZ,r8", "LD HL,d16", "LD (HL+),A", "INC HL", "INC H", "DEC H",
    "LD H,d8", "DAA", "JR Z,r8", "ADD HL,HL", "LD A,(HL+)", "DEC HL",
    "INC L", "DEC L", "LD L,d8", "CPL",
    // 0x30
    "JR NC,r8", "LD SP,d16", "LD (HL-),A", "INC SP", "INC (HL)", "DEC (HL)",
    "LD (HL),d8", "SCF", "JR C,r8", "ADD HL,SP", "LD A,(HL-)", "DEC SP",
    "INC A", "DEC A", "LD A,d8", "CCF",
  ];

  static const _opsC0 = [
    // 0xc0
    "RET NZ", "POP BC", "JP NZ,a16", "JP a16", "CALL NZ,a16", "PUSH BC",
    "ADD A,d8", "RST 00H", "RET Z", "RET", "JP Z,a16", "PREFIX", "CALL Z,a16",
    "CALL a16", "ADC A,d8", "RST 08H",
    // 0xd0
    "RET NC", "POP DE", "JP NC,a16", "-", "CALL NC,a16", "PUSH DE",
    "SUB d8", "RST 10H", "RET C", "RETI", "JP C,a16", "-", "CALL C,a16",
    "-", "SBC A,d8", "RST 18H",
    // 0xe0
    "LDH (a8),A", "POP HL", "LD (C),A", "-", "-", "PUSH HL", "AND d8",
    "RST 20H", "ADD SP,r8", "JP HL", "LD (a16),A", "-", "-", "-", "XOR d8",
    "RST 28H",
    // 0xf0
    "LDH A,(a8)", "POP AF", "LD A,(C)", "DI", "-", "PUSH AF", "OR d8",
    "RST 30H", "LD HL,SP+r8", "LD SP,HL", "LD A,(a16)", "EI", "-", "-",
    "CP d8", "RST 38H",
  ];

  static String _template(int op) {
    if (op < 0x40) {
      return _ops[op];
    }
    if (op < 0x80) {
      return op == 0x76 ? "HALT" : "LD ${_r[op.shr3.mask3]},${_r[op.mask3]}";
    }
    if (op < 0xc0) {
      return "${_alu[op.shr3.mask3]}${_r[op.mask3]}";
    }
    return _opsC0[op - 0xc0];
  }

  static String _cb(int op) {
    final r = _r[op.mask3];
    final bit = op.shr3.mask3;
    return switch (op.shr6) {
      0 => "${_rot[bit]} $r",
      1 => "BIT $bit,$r",
      2 => "RES $bit,$r",
      _ => "SET $bit,$r",
    };
  }

  /// returns (mnemonic, instruction length)
  static (String, int) disasm(int Function(int) read, int pc) {
    final op = read(pc);

    if (op == 0xcb) {
      return (_cb(read((pc + 1).mask16)), 2);
    }

    final t = _template(op);
    final d1 = read((pc + 1).mask16);
    final d2 = read((pc + 2).mask16);

    if (t.contains("d16")) {
      return (t.replaceFirst("d16", "\$${(d2.shl8 | d1).x4}"), 3);
    }
    if (t.contains("a16")) {
      return (t.replaceFirst("a16", "\$${(d2.shl8 | d1).x4}"), 3);
    }
    if (t.contains("a8")) {
      return (t.replaceFirst("a8", "\$ff${d1.x2}"), 2);
    }
    if (t.contains("d8")) {
      return (t.replaceFirst("d8", "\$${d1.x2}"), 2);
    }
    if (t.contains("r8")) {
      if (t.startsWith("JR")) {
        return (t.replaceFirst("r8", "\$${(pc + 2 + d1.rel8).x4}"), 2);
      }
      final v = d1.rel8;
      return (t.replaceFirst("r8", v < 0 ? "-\$${(-v).x2}" : "\$${v.x2}"), 2);
    }

    return (t, 1);
  }
}
