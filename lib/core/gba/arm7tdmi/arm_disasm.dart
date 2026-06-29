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

    if ((op & 0x0ffffff0) == 0x012fff10) return "bx$c ${_reg[op & 0xf]}";

    final kind = (op >> 25) & 7;
    if (kind == 0x5) {
      // 0b101: branch
      final l = (op >> 24) & 1 != 0 ? "l" : "";
      final off = (op & 0xffffff).toSigned(24) << 2;
      return "b$l$c ${((pc + 8 + off) & 0xffffffff).x8}";
    }
    if (kind == 0x4) return _armBlock(op, c); // 0b100
    if (kind == 0x2 || kind == 0x3) return _armSingle(op, c); // 0b010/0b011
    if (kind == 0x7) {
      // 0b111
      return (op >> 24) & 1 != 0 ? "swi$c ${(op & 0xffffff).x6}" : "und";
    }

    // 0b000 / 0b001
    if (kind == 0x0 && (op & 0x90) == 0x90) {
      if ((op & 0x60) == 0) {
        if ((op >> 24) & 1 == 0) return _armMul(op, c);
        final b = (op >> 22) & 1 != 0 ? "b" : "";
        return "swp$b$c ${_reg[(op >> 12) & 0xf]}, ${_reg[op & 0xf]}, [${_reg[(op >> 16) & 0xf]}]";
      }
      return _armHalf(op, c);
    }
    return _armDataProc(op, c);
  }

  static String _armDataProc(int op, String c) {
    final opcode = (op >> 21) & 0xf;
    final s = (op >> 20) & 1 != 0;
    final rn = (op >> 16) & 0xf;
    final rd = (op >> 12) & 0xf;

    if (!s && (opcode & 0xc) == 0x8) {
      // PSR transfer
      final spsr = (op >> 22) & 1 != 0 ? "spsr" : "cpsr";
      if ((op >> 21) & 1 == 0) return "mrs$c ${_reg[rd]}, $spsr";
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
    if ((op >> 25) & 1 != 0) {
      final imm = op & 0xff;
      final rot = ((op >> 8) & 0xf) * 2;
      final v = rot == 0 ? imm : ((imm >>> rot) | (imm << (32 - rot))) & 0xffffffff;
      return "#0x${v.x8}";
    }
    final rm = _reg[op & 0xf];
    final type = _shift[(op >> 5) & 3];
    if ((op >> 4) & 1 != 0) {
      return "$rm, $type ${_reg[(op >> 8) & 0xf]}";
    }
    final amount = (op >> 7) & 0x1f;
    if (amount == 0 && (op >> 5) & 3 == 0) return rm; // lsl #0
    return "$rm, $type #$amount";
  }

  static String _armMul(int op, String c) {
    final s = (op >> 20) & 1 != 0 ? "s" : "";
    if ((op >> 23) & 1 != 0) {
      final sign = (op >> 22) & 1 != 0 ? "s" : "u";
      final acc = (op >> 21) & 1 != 0 ? "mlal" : "mull";
      return "$sign$acc$s$c ${_reg[(op >> 12) & 0xf]}, ${_reg[(op >> 16) & 0xf]}, ${_reg[op & 0xf]}, ${_reg[(op >> 8) & 0xf]}";
    }
    if ((op >> 21) & 1 != 0) {
      return "mla$s$c ${_reg[(op >> 16) & 0xf]}, ${_reg[op & 0xf]}, ${_reg[(op >> 8) & 0xf]}, ${_reg[(op >> 12) & 0xf]}";
    }
    return "mul$s$c ${_reg[(op >> 16) & 0xf]}, ${_reg[op & 0xf]}, ${_reg[(op >> 8) & 0xf]}";
  }

  static String _armSingle(int op, String c) {
    final l = (op >> 20) & 1 != 0 ? "ldr" : "str";
    final b = (op >> 22) & 1 != 0 ? "b" : "";
    final rd = _reg[(op >> 12) & 0xf];
    final rn = _reg[(op >> 16) & 0xf];
    final up = (op >> 23) & 1 != 0 ? "" : "-";
    String off;
    if ((op >> 25) & 1 == 0) {
      off = "#$up${op & 0xfff}";
    } else {
      off = "$up${_reg[op & 0xf]}";
    }
    final pre = (op >> 24) & 1 != 0;
    final wb = (op >> 21) & 1 != 0 ? "!" : "";
    return pre
        ? "$l$b$c $rd, [$rn, $off]$wb"
        : "$l$b$c $rd, [$rn], $off";
  }

  static String _armHalf(int op, String c) {
    final l = (op >> 20) & 1 != 0;
    final sh = (op >> 5) & 3;
    final ty = l
        ? (sh == 1 ? "ldrh" : sh == 2 ? "ldrsb" : "ldrsh")
        : "strh";
    final rd = _reg[(op >> 12) & 0xf];
    final rn = _reg[(op >> 16) & 0xf];
    final up = (op >> 23) & 1 != 0 ? "" : "-";
    final off = (op >> 22) & 1 != 0
        ? "#$up${(((op >> 8) & 0xf) << 4) | (op & 0xf)}"
        : "$up${_reg[op & 0xf]}";
    final pre = (op >> 24) & 1 != 0;
    final wb = (op >> 21) & 1 != 0 ? "!" : "";
    return pre ? "$ty$c $rd, [$rn, $off]$wb" : "$ty$c $rd, [$rn], $off";
  }

  static String _armBlock(int op, String c) {
    final l = (op >> 20) & 1 != 0 ? "ldm" : "stm";
    final u = (op >> 23) & 1 != 0 ? "i" : "d";
    final p = (op >> 24) & 1 != 0 ? "b" : "a";
    final rn = _reg[(op >> 16) & 0xf];
    final wb = (op >> 21) & 1 != 0 ? "!" : "";
    final s = (op >> 22) & 1 != 0 ? "^" : "";
    final list = _regList(op & 0xffff);
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
    final hi = op >> 13;
    switch (hi) {
      case 0:
        if ((op & 0x1800) == 0x1800) {
          final sub = (op >> 9) & 1 != 0 ? "sub" : "add";
          final imm = (op >> 10) & 1 != 0;
          final v = imm ? "#${(op >> 6) & 7}" : _reg[(op >> 6) & 7];
          return "$sub ${_reg[op & 7]}, ${_reg[(op >> 3) & 7]}, $v";
        }
        final ty = _shift[(op >> 11) & 3];
        return "$ty ${_reg[op & 7]}, ${_reg[(op >> 3) & 7]}, #${(op >> 6) & 0x1f}";
      case 1:
        final ops = ["mov", "cmp", "add", "sub"];
        return "${ops[(op >> 11) & 3]} ${_reg[(op >> 8) & 7]}, #${op & 0xff}";
      case 2:
        return _thumbCase2(op, pc);
      case 3:
        final l = (op >> 11) & 1 != 0 ? "ldr" : "str";
        final b = (op >> 12) & 1 != 0 ? "b" : "";
        final off = (op >> 6) & 0x1f;
        return "$l$b ${_reg[op & 7]}, [${_reg[(op >> 3) & 7]}, #${b == "" ? off << 2 : off}]";
      case 4:
        if ((op & 0x1000) == 0) {
          final l = (op >> 11) & 1 != 0 ? "ldrh" : "strh";
          return "$l ${_reg[op & 7]}, [${_reg[(op >> 3) & 7]}, #${((op >> 6) & 0x1f) << 1}]";
        }
        final l = (op >> 11) & 1 != 0 ? "ldr" : "str";
        return "$l ${_reg[(op >> 8) & 7]}, [sp, #${(op & 0xff) << 2}]";
      case 5:
        if ((op & 0x1000) == 0) {
          final base = (op >> 11) & 1 != 0 ? "sp" : "pc";
          return "add ${_reg[(op >> 8) & 7]}, $base, #${(op & 0xff) << 2}";
        }
        if ((op & 0x0f00) == 0) {
          final sub = (op >> 7) & 1 != 0 ? "-" : "";
          return "add sp, #$sub${(op & 0x7f) << 2}";
        }
        final pop = (op >> 11) & 1 != 0;
        final extra = (op >> 8) & 1 != 0 ? (pop ? ", pc" : ", lr") : "";
        return "${pop ? "pop" : "push"} {${_regList(op & 0xff)}$extra}";
      case 6:
        if ((op & 0x1000) == 0) {
          final l = (op >> 11) & 1 != 0 ? "ldmia" : "stmia";
          return "$l ${_reg[(op >> 8) & 7]}!, {${_regList(op & 0xff)}}";
        }
        if ((op & 0x0f00) == 0x0f00) return "swi #${op & 0xff}";
        final off = (op & 0xff).toSigned(8) << 1;
        return "b${_cond[(op >> 8) & 0xf]} ${((pc + 4 + off) & 0xffffffff).x8}";
      default: // 7
        if ((op & 0x1000) == 0) {
          final off = (op & 0x7ff).toSigned(11) << 1;
          return "b ${((pc + 4 + off) & 0xffffffff).x8}";
        }
        return (op >> 11) & 1 != 0 ? "bl (lo)" : "bl (hi)";
    }
  }

  static String _thumbCase2(int op, int pc) {
    if ((op & 0x1000) != 0) {
      // load/store register offset / sign-extended
      final rd = _reg[op & 7];
      final rb = _reg[(op >> 3) & 7];
      final ro = _reg[(op >> 6) & 7];
      if ((op & 0x0200) == 0) {
        final l = (op >> 11) & 1 != 0 ? "ldr" : "str";
        final b = (op >> 10) & 1 != 0 ? "b" : "";
        return "$l$b $rd, [$rb, $ro]";
      }
      const sh = ["strh", "ldrh", "ldrsb", "ldrsh"];
      return "${sh[(op >> 10) & 3]} $rd, [$rb, $ro]";
    }
    if ((op & 0x0800) != 0) {
      return "ldr ${_reg[(op >> 8) & 7]}, [pc, #${(op & 0xff) << 2}]";
    }
    if ((op & 0x0400) == 0) {
      const alu = [
        "and", "eor", "lsl", "lsr", "asr", "adc", "sbc", "ror", //
        "tst", "neg", "cmp", "cmn", "orr", "mul", "bic", "mvn"
      ];
      return "${alu[(op >> 6) & 0xf]} ${_reg[op & 7]}, ${_reg[(op >> 3) & 7]}";
    }
    // hi register / bx
    const ops = ["add", "cmp", "mov", "bx"];
    final code = (op >> 8) & 3;
    final rd = (op & 7) | ((op >> 4) & 8);
    final rs = ((op >> 3) & 7) | ((op >> 3) & 8);
    if (code == 3) return "bx ${_reg[rs]}";
    return "${ops[code]} ${_reg[rd]}, ${_reg[rs]}";
  }
}
