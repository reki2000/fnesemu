import 'package:fnesemu/util/int.dart';

/// Compact ARM7TDMI disassembler used by the debugger view.
/// Covers the common instruction classes; rare/edge encodings fall back to a
/// raw word rendering.
class Arm7Disasm {
  static const _cond = [
    "eq", "ne", "cs", "cc", "mi", "pl", "vs", "vc", //
    "hi", "ls", "ge", "lt", "gt", "le", "", "nv"
  ];
  static const _dp = [
    "and", "eor", "sub", "rsb", "add", "adc", "sbc", "rsc", //
    "tst", "teq", "cmp", "cmn", "orr", "mov", "bic", "mvn"
  ];
  static const _reg = [
    "r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7", //
    "r8", "r9", "r10", "r11", "r12", "sp", "lr", "pc"
  ];
  static const _shift = ["lsl", "lsr", "asr", "ror"];

  /// disassemble one ARM instruction at [pc]. returns "mnemonic operands".
  static String arm(int op, int pc) {
    final c = _cond[op >>> 28];

    if (op & 0x0ffffff0 == 0x012fff10) return "bx$c ${_reg[op.mask4]}";

    final kind = op.shr25.mask3;
    if (kind == 0x5) {
      // 0b101: branch
      final l = op.bit24 ? "l" : "";
      final off = op.mask24.toSigned(24).shl2;
      return "b$l$c ${(pc + 8 + off).x8}";
    }
    if (kind == 0x4) return _armBlock(op, c); // 0b100
    if (kind == 0x2 || kind == 0x3) return _armSingle(op, c); // 0b010/0b011
    if (kind == 0x7) {
      // 0b111
      return op.bit24 ? "swi$c ${op.mask24.x6}" : "und";
    }

    // 0b000 / 0b001
    if (kind == 0x0 && (op & 0x90) == 0x90) {
      if ((op & 0x60) == 0) {
        if (!op.bit24) return _armMul(op, c);
        final b = op.bit22 ? "b" : "";
        return "swp$b$c ${_reg[op.shr12.mask4]}, ${_reg[op.mask4]}, [${_reg[op.shr16.mask4]}]";
      }
      return _armHalf(op, c);
    }
    return _armDataProc(op, c);
  }

  static String _armDataProc(int op, String c) {
    final opcode = op.shr21.mask4;
    final s = op.bit20;
    final rn = op.shr16.mask4;
    final rd = op.shr12.mask4;

    if (!s && (opcode & 0xc) == 0x8) {
      // PSR transfer
      final spsr = op.bit22 ? "spsr" : "cpsr";
      if (!op.bit21) return "mrs$c ${_reg[rd]}, $spsr";
      return "msr$c $spsr, ${_op2(op)}";
    }

    final sFlag = s ? "s" : "";
    final mnem = _dp[opcode];
    if (opcode >= 0x8 && opcode <= 0xb) {
      return "$mnem$c ${_reg[rn]}, ${_op2(op)}"; // tst/teq/cmp/cmn
    }
    if (opcode == 0xd || opcode == 0xf) {
      return "$mnem$sFlag$c ${_reg[rd]}, ${_op2(op)}"; // mov/mvn
    }
    return "$mnem$sFlag$c ${_reg[rd]}, ${_reg[rn]}, ${_op2(op)}";
  }

  static String _op2(int op) {
    if (op.bit25) {
      final imm = op.mask8;
      final rot = op.shr8.mask4 * 2;
      final v = rot == 0 ? imm : (imm >>> rot | imm.shl(32 - rot)).mask32;
      return "#0x${v.x8}";
    }
    final rm = _reg[op.mask4];
    final type = _shift[op.shr5.mask2];
    if (op.bit4) {
      return "$rm, $type ${_reg[op.shr8.mask4]}";
    }
    final amount = op.shr7.mask5;
    if (amount == 0 && op.shr5.mask2 == 0) return rm; // lsl #0
    return "$rm, $type #$amount";
  }

  static String _armMul(int op, String c) {
    final s = op.bit20 ? "s" : "";
    if (op.bit23) {
      final sign = op.bit22 ? "s" : "u";
      final acc = op.bit21 ? "mlal" : "mull";
      return "$sign$acc$s$c ${_reg[op.shr12.mask4]}, ${_reg[op.shr16.mask4]}, ${_reg[op.mask4]}, ${_reg[op.shr8.mask4]}";
    }
    if (op.bit21) {
      return "mla$s$c ${_reg[op.shr16.mask4]}, ${_reg[op.mask4]}, ${_reg[op.shr8.mask4]}, ${_reg[op.shr12.mask4]}";
    }
    return "mul$s$c ${_reg[op.shr16.mask4]}, ${_reg[op.mask4]}, ${_reg[op.shr8.mask4]}";
  }

  static String _armSingle(int op, String c) {
    final l = op.bit20 ? "ldr" : "str";
    final b = op.bit22 ? "b" : "";
    final rd = _reg[op.shr12.mask4];
    final rn = _reg[op.shr16.mask4];
    final up = op.bit23 ? "" : "-";
    String off;
    if (!op.bit25) {
      off = "#$up${op.mask12}";
    } else {
      off = "$up${_reg[op.mask4]}";
    }
    final pre = op.bit24;
    final wb = op.bit21 ? "!" : "";
    return pre
        ? "$l$b$c $rd, [$rn, $off]$wb"
        : "$l$b$c $rd, [$rn], $off";
  }

  static String _armHalf(int op, String c) {
    final l = op.bit20;
    final sh = op.shr5.mask2;
    final ty = l
        ? (sh == 1 ? "ldrh" : sh == 2 ? "ldrsb" : "ldrsh")
        : "strh";
    final rd = _reg[op.shr12.mask4];
    final rn = _reg[op.shr16.mask4];
    final up = op.bit23 ? "" : "-";
    final off = op.bit22
        ? "#$up${op.shr8.mask4.shl4 | op.mask4}"
        : "$up${_reg[op.mask4]}";
    final pre = op.bit24;
    final wb = op.bit21 ? "!" : "";
    return pre ? "$ty$c $rd, [$rn, $off]$wb" : "$ty$c $rd, [$rn], $off";
  }

  static String _armBlock(int op, String c) {
    final l = op.bit20 ? "ldm" : "stm";
    final u = op.bit23 ? "i" : "d";
    final p = op.bit24 ? "b" : "a";
    final rn = _reg[op.shr16.mask4];
    final wb = op.bit21 ? "!" : "";
    final s = op.bit22 ? "^" : "";
    final list = _regList(op.mask16);
    return "$l$u$p$c $rn$wb, {$list}$s";
  }

  static String _regList(int list) {
    final parts = <String>[];
    for (int i = 0; i < 16; i++) {
      if (list & (1 << i) != 0) parts.add(_reg[i]);
    }
    return parts.join(", ");
  }

  /// disassemble one THUMB instruction at [pc].
  static String thumb(int op, int pc) {
    final hi = op.shr13;
    switch (hi) {
      case 0:
        if ((op & 0x1800) == 0x1800) {
          final sub = op.bit9 ? "sub" : "add";
          final imm = op.bit10;
          final v = imm ? "#${op.shr6.mask3}" : _reg[op.shr6.mask3];
          return "$sub ${_reg[op.mask3]}, ${_reg[op.shr3.mask3]}, $v";
        }
        final ty = _shift[op.shr11.mask2];
        return "$ty ${_reg[op.mask3]}, ${_reg[op.shr3.mask3]}, #${op.shr6.mask5}";
      case 1:
        final ops = ["mov", "cmp", "add", "sub"];
        return "${ops[op.shr11.mask2]} ${_reg[op.shr8.mask3]}, #${op.mask8}";
      case 2:
        return _thumbCase2(op, pc);
      case 3:
        final l = op.bit11 ? "ldr" : "str";
        final b = op.bit12 ? "b" : "";
        final off = op.shr6.mask5;
        return "$l$b ${_reg[op.mask3]}, [${_reg[op.shr3.mask3]}, #${b == "" ? off.shl2 : off}]";
      case 4:
        if (!op.bit12) {
          final l = op.bit11 ? "ldrh" : "strh";
          return "$l ${_reg[op.mask3]}, [${_reg[op.shr3.mask3]}, #${op.shr6.mask5.shl1}]";
        }
        final l = op.bit11 ? "ldr" : "str";
        return "$l ${_reg[op.shr8.mask3]}, [sp, #${op.mask8.shl2}]";
      case 5:
        if (!op.bit12) {
          final base = op.bit11 ? "sp" : "pc";
          return "add ${_reg[op.shr8.mask3]}, $base, #${op.mask8.shl2}";
        }
        if ((op & 0x0f00) == 0) {
          final sub = op.bit7 ? "-" : "";
          return "add sp, #$sub${op.mask7.shl2}";
        }
        final pop = op.bit11;
        final extra = op.bit8 ? (pop ? ", pc" : ", lr") : "";
        return "${pop ? "pop" : "push"} {${_regList(op.mask8)}$extra}";
      case 6:
        if (!op.bit12) {
          final l = op.bit11 ? "ldmia" : "stmia";
          return "$l ${_reg[op.shr8.mask3]}!, {${_regList(op.mask8)}}";
        }
        if (op & 0x0f00 == 0x0f00) return "swi #${op.mask8}";
        final off = op.mask8.toSigned(8).shl1;
        return "b${_cond[op.shr8.mask4]} ${(pc + 4 + off).x8}";
      default: // 7
        if (!op.bit12) {
          final off = op.mask11.toSigned(11).shl1;
          return "b ${(pc + 4 + off).x8}";
        }
        return op.bit11 ? "bl (lo)" : "bl (hi)";
    }
  }

  static String _thumbCase2(int op, int pc) {
    if (op.bit12) {
      // load/store register offset / sign-extended
      final rd = _reg[op.mask3];
      final rb = _reg[op.shr3.mask3];
      final ro = _reg[op.shr6.mask3];
      if (!op.bit9) {
        final l = op.bit11 ? "ldr" : "str";
        final b = op.bit10 ? "b" : "";
        return "$l$b $rd, [$rb, $ro]";
      }
      const sh = ["strh", "ldrh", "ldrsb", "ldrsh"];
      return "${sh[op.shr10.mask2]} $rd, [$rb, $ro]";
    }
    if (op.bit11) {
      return "ldr ${_reg[op.shr8.mask3]}, [pc, #${op.mask8.shl2}]";
    }
    if (!op.bit10) {
      const alu = [
        "and", "eor", "lsl", "lsr", "asr", "adc", "sbc", "ror", //
        "tst", "neg", "cmp", "cmn", "orr", "mul", "bic", "mvn"
      ];
      return "${alu[op.shr6.mask4]} ${_reg[op.mask3]}, ${_reg[op.shr3.mask3]}";
    }
    // hi register / bx
    const ops = ["add", "cmp", "mov", "bx"];
    final code = op.shr8.mask2;
    final rd = op.mask3 | op.shr4 & 8;
    final rs = op.shr3.mask3 | op.shr3 & 8;
    if (code == 3) return "bx ${_reg[rs]}";
    return "${ops[code]} ${_reg[rd]}, ${_reg[rs]}";
  }
}
