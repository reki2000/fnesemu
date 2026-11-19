import '../../util/int.dart';

/// Disassembler for the PS2 Emotion Engine (R5900) and IOP (R3000).
class Ps2Disasm {
  static const _gpr = [
    'zero',
    'at',
    'v0',
    'v1',
    'a0',
    'a1',
    'a2',
    'a3',
    't0',
    't1',
    't2',
    't3',
    't4',
    't5',
    't6',
    't7',
    's0',
    's1',
    's2',
    's3',
    's4',
    's5',
    's6',
    's7',
    't8',
    't9',
    'k0',
    'k1',
    'gp',
    'sp',
    'fp',
    'ra',
  ];

  static const _eeCop0 = [
    'Index',
    'Random',
    'EntryLo0',
    'EntryLo1',
    'Context',
    'PageMask',
    'Wired',
    'Reserved7',
    'BadVAddr',
    'Count',
    'EntryHi',
    'Compare',
    'Status',
    'Cause',
    'EPC',
    'PRId',
    'Config',
    'Reserved17',
    'Reserved18',
    'Reserved19',
    'Reserved20',
    'Reserved21',
    'Reserved22',
    'BadPAddr',
    'Debug',
    'Perf',
    'Reserved26',
    'Reserved27',
    'TagLo',
    'TagHi',
    'ErrorEPC',
    'Reserved31',
  ];

  static const _iopCop0 = [
    'Index',
    'Random',
    'EntryLo',
    'BPC',
    'Context',
    'BDA',
    'TAR',
    'DCIC',
    'BadVAddr',
    'BDAM',
    'BPCM',
    'SR',
    'Status',
    'Cause',
    'EPC',
    'PRId',
    'Config',
    'Reserved17',
    'Reserved18',
    'Reserved19',
    'Reserved20',
    'Reserved21',
    'Reserved22',
    'Reserved23',
    'Reserved24',
    'Reserved25',
    'Reserved26',
    'Reserved27',
    'Reserved28',
    'Reserved29',
    'Reserved30',
    'Reserved31',
  ];

  static String _hex(int value) =>
      '0x${value.mask32.toRadixString(16).padLeft(8, '0')}';

  /// Disassembles an Emotion Engine (R5900) instruction.
  static String ee(int word, int pc) {
    final op = word >>> 26;
    final rs = (word >>> 21) & 31,
        rt = (word >>> 16) & 31,
        rd = (word >>> 11) & 31;
    final sa = (word >>> 6) & 31, fn = word & 63;
    final imm = word & 0xffff, simm = imm.rel16;
    final branch = _hex(pc + 4 + simm * 4);
    final regS = _gpr[rs], regT = _gpr[rt], regD = _gpr[rd];

    String mem(String name) => '$name $regT, $simm($regS)';

    if (op == 0) {
      if (word == 0) return 'nop';
      const shifts = {
        0: 'sll',
        2: 'srl',
        3: 'sra',
        56: 'dsll',
        58: 'dsrl',
        59: 'dsra',
        60: 'dsll32',
        62: 'dsrl32',
        63: 'dsra32',
      };
      if (shifts.containsKey(fn)) return '${shifts[fn]} $regD, $regT, $sa';
      const varShifts = {
        4: 'sllv',
        6: 'srlv',
        7: 'srav',
        20: 'dsllv',
        22: 'dsrlv',
        23: 'dsrav',
      };
      if (varShifts.containsKey(fn)) {
        return '${varShifts[fn]} $regD, $regT, $regS';
      }
      if (fn == 8) return 'jr $regS';
      if (fn == 9) return rd == 31 ? 'jalr $regS' : 'jalr $regD, $regS';
      if (fn == 10) return 'movz $regD, $regS, $regT';
      if (fn == 11) return 'movn $regD, $regS, $regT';
      if (fn == 12) {
        return 'syscall 0x${((word >>> 6) & 0xfffff).toRadixString(16)}';
      }
      if (fn == 13) {
        return 'break 0x${((word >>> 6) & 0xfffff).toRadixString(16)}';
      }
      if (fn == 15) return 'sync';
      if (fn == 16) return 'mfhi $regD';
      if (fn == 17) return 'mthi $regS';
      if (fn == 18) return 'mflo $regD';
      if (fn == 19) return 'mtlo $regS';
      if (fn == 24) return 'mult $regD, $regS, $regT';
      if (fn == 25) return 'multu $regD, $regS, $regT';
      if (fn == 26) return 'div $regS, $regT';
      if (fn == 27) return 'divu $regS, $regT';
      if (fn == 33 && rs == 0) return 'move $regD, $regT';
      if (fn == 35 && rs == 0) return 'negu $regD, $regT';
      const alu = {
        32: 'add',
        33: 'addu',
        34: 'sub',
        35: 'subu',
        36: 'and',
        37: 'or',
        38: 'xor',
        39: 'nor',
        40: 'mfsa',
        42: 'slt',
        43: 'sltu',
        44: 'dadd',
        45: 'daddu',
        46: 'dsub',
        47: 'dsubu',
      };
      if (fn == 40) return 'mfsa $regD';
      if (fn == 41) return 'mtsa $regS';
      if (alu.containsKey(fn)) return '${alu[fn]} $regD, $regS, $regT';
      const traps = {
        48: 'tge',
        49: 'tgeu',
        50: 'tlt',
        51: 'tltu',
        52: 'teq',
        54: 'tne',
      };
      if (traps.containsKey(fn)) return '${traps[fn]} $regS, $regT';
    } else if (op == 1) {
      const branches = {
        0: 'bltz',
        1: 'bgez',
        2: 'bltzl',
        3: 'bgezl',
        16: 'bltzal',
        17: 'bgezal',
        18: 'bltzall',
        19: 'bgezall',
      };
      if (branches.containsKey(rt)) return '${branches[rt]} $regS, $branch';
      const traps = {
        8: 'tgei',
        9: 'tgeiu',
        10: 'tlti',
        11: 'tltiu',
        12: 'teqi',
        14: 'tnei',
      };
      if (traps.containsKey(rt)) return '${traps[rt]} $regS, $simm';
      if (rt == 24) return 'mtsab $regS, $simm';
      if (rt == 25) return 'mtsah $regS, $simm';
    } else if (op == 2 || op == 3) {
      return '${op == 2 ? "j" : "jal"} ${_hex((pc + 4) & 0xf0000000 | (word & 0x03ffffff) << 2)}';
    } else if (op == 4) {
      if (rs == 0 && rt == 0) return 'b $branch';
      if (rt == 0) return 'beqz $regS, $branch';
      return 'beq $regS, $regT, $branch';
    } else if (op == 5) {
      if (rt == 0) return 'bnez $regS, $branch';
      return 'bne $regS, $regT, $branch';
    } else if (op == 6) {
      return 'blez $regS, $branch';
    } else if (op == 7) {
      return 'bgtz $regS, $branch';
    } else if (op == 20 || op == 21) {
      return '${op == 20 ? "beql" : "bnel"} $regS, $regT, $branch';
    } else if (op == 22 || op == 23) {
      return '${op == 22 ? "blezl" : "bgtzl"} $regS, $branch';
    } else if (op == 16) {
      if (rs == 0) return 'mfc0 $regT, ${_eeCop0[rd]}';
      if (rs == 4) return 'mtc0 $regT, ${_eeCop0[rd]}';
      if (rs == 16) {
        const cop0Ops = {
          1: 'tlbr',
          2: 'tlbwi',
          6: 'tlbwr',
          8: 'tlbp',
          24: 'eret',
          56: 'ei',
          57: 'di',
        };
        if (cop0Ops.containsKey(fn)) return cop0Ops[fn]!;
      }
    } else if (op == 17) {
      if (rs == 0) return 'mfc1 $regT, f$rd';
      if (rs == 2) return 'cfc1 $regT, fcr$rd';
      if (rs == 4) return 'mtc1 $regT, f$rd';
      if (rs == 6) return 'ctc1 $regT, fcr$rd';
      if (rs == 8) {
        const bc1 = ['bc1f', 'bc1t', 'bc1fl', 'bc1tl'];
        if (rt < 4) return '${bc1[rt]} $branch';
      }
      if (rs == 16) {
        const binFpu = {
          0: 'add.s',
          1: 'sub.s',
          2: 'mul.s',
          3: 'div.s',
          22: 'rsqrt.s',
          24: 'adda.s',
          25: 'suba.s',
          26: 'mula.s',
          28: 'madd.s',
          29: 'msub.s',
          30: 'madda.s',
          31: 'msuba.s',
          40: 'max.s',
          41: 'min.s',
        };
        if (binFpu.containsKey(fn)) return '${binFpu[fn]} f$sa, f$rd, f$rt';
        const unaryFpu = {
          4: 'sqrt.s',
          5: 'abs.s',
          6: 'mov.s',
          7: 'neg.s',
          36: 'cvt.w.s',
        };
        if (unaryFpu.containsKey(fn)) return '${unaryFpu[fn]} f$sa, f$rd';
        if (fn >= 48 && fn < 64) {
          const conds = [
            'f',
            'un',
            'eq',
            'ueq',
            'olt',
            'ult',
            'ole',
            'ule',
            'sf',
            'ngle',
            'seq',
            'ngl',
            'lt',
            'nge',
            'le',
            'ngt',
          ];
          return 'c.${conds[fn - 48]}.s f$rd, f$rt';
        }
      }
      if (rs == 20 && fn == 32) return 'cvt.s.w f$sa, f$rd';
    } else if (op == 18) {
      if (rs == 0) return 'mfc2 $regT, vi$rd';
      if (rs == 1) return 'qmfc2 $regT, vf$rd';
      if (rs == 2) return 'cfc2 $regT, vi$rd';
      if (rs == 4) return 'mtc2 $regT, vi$rd';
      if (rs == 5) return 'qmtc2 $regT, vf$rd';
      if (rs == 6) return 'ctc2 $regT, vi$rd';
      if (rs == 8) {
        const bc2 = ['bc2f', 'bc2t', 'bc2fl', 'bc2tl'];
        if (rt < 4) return '${bc2[rt]} $branch';
      }
      if (rs >= 16) return 'c2 0x${word.mask32.toRadixString(16)}';
    } else if (op == 28) {
      return _mmi(word, rs, rt, rd, sa, fn);
    } else {
      if (op == 9 && rs == 0) return 'li $regT, $simm';
      const arith = {
        8: 'addi',
        9: 'addiu',
        10: 'slti',
        11: 'sltiu',
        24: 'daddi',
        25: 'daddiu',
      };
      if (arith.containsKey(op)) return '${arith[op]} $regT, $regS, $simm';
      const logic = {12: 'andi', 13: 'ori', 14: 'xori'};
      if (logic.containsKey(op)) {
        return '${logic[op]} $regT, $regS, 0x${imm.toRadixString(16)}';
      }
      if (op == 15) return 'lui $regT, 0x${imm.toRadixString(16)}';
      const loads = {
        26: 'ldl',
        27: 'ldr',
        30: 'lq',
        31: 'sq',
        32: 'lb',
        33: 'lh',
        34: 'lwl',
        35: 'lw',
        36: 'lbu',
        37: 'lhu',
        38: 'lwr',
        39: 'lwu',
        40: 'sb',
        41: 'sh',
        42: 'swl',
        43: 'sw',
        44: 'sdl',
        45: 'sdr',
        46: 'swr',
        55: 'ld',
        63: 'sd',
      };
      if (loads.containsKey(op)) return mem(loads[op]!);
      if (op == 47) return 'cache 0x${rt.toRadixString(16)}, $simm($regS)';
      if (op == 49) return 'lwc1 f$rt, $simm($regS)';
      if (op == 51) return 'pref 0x${rt.toRadixString(16)}, $simm($regS)';
      if (op == 53) return 'ldc1 f$rt, $simm($regS)';
      if (op == 54) return 'lqc2 vf$rt, $simm($regS)';
      if (op == 57) return 'swc1 f$rt, $simm($regS)';
      if (op == 61) return 'sdc1 f$rt, $simm($regS)';
      if (op == 62) return 'sqc2 vf$rt, $simm($regS)';
    }
    return '.word ${_hex(word)}';
  }

  static String _mmi(int word, int rs, int rt, int rd, int sa, int fn) {
    final regS = _gpr[rs], regT = _gpr[rt], regD = _gpr[rd];
    switch (fn) {
      case 0x00:
        return 'madd $regD, $regS, $regT';
      case 0x01:
        return 'maddu $regD, $regS, $regT';
      case 0x04:
        return 'plzcw $regD, $regS';
      case 0x08:
        const mmi0 = {
          0x00: 'paddw',
          0x01: 'psubw',
          0x02: 'pcgtw',
          0x03: 'pmaxw',
          0x04: 'paddh',
          0x05: 'psubh',
          0x06: 'pcgth',
          0x07: 'pmaxh',
          0x08: 'paddb',
          0x09: 'psubb',
          0x0a: 'pcgtb',
          0x10: 'paddsw',
          0x11: 'psubsw',
          0x12: 'pextlw',
          0x13: 'ppacw',
          0x14: 'paddsh',
          0x15: 'psubsh',
          0x16: 'pextlh',
          0x17: 'ppach',
          0x18: 'paddsb',
          0x19: 'psubsb',
          0x1a: 'pextlb',
          0x1b: 'ppacb',
          0x1e: 'pext5',
          0x1f: 'ppac5',
        };
        if (mmi0.containsKey(sa)) return '${mmi0[sa]} $regD, $regS, $regT';
      case 0x09:
        const mmi2 = {
          0x00: 'pmaddw',
          0x02: 'psllvw',
          0x03: 'psrlvw',
          0x04: 'pmsubw',
          0x08: 'pmfhi',
          0x09: 'pmflo',
          0x0a: 'pinth',
          0x0c: 'pmultw',
          0x0d: 'pdivw',
          0x0e: 'pcpyld',
          0x10: 'pmaddh',
          0x11: 'phmadh',
          0x12: 'pand',
          0x13: 'pxor',
          0x14: 'pmsubh',
          0x15: 'phmsbh',
          0x1a: 'pexeh',
          0x1b: 'prevh',
          0x1c: 'pmulth',
          0x1d: 'pdivbw',
          0x1e: 'pexew',
          0x1f: 'prot3w',
        };
        if (sa == 0x08 || sa == 0x09) return '${mmi2[sa]} $regD';
        if (sa == 0x1a || sa == 0x1b || sa == 0x1e || sa == 0x1f) {
          return '${mmi2[sa]} $regD, $regT';
        }
        if (mmi2.containsKey(sa)) return '${mmi2[sa]} $regD, $regS, $regT';
      case 0x10:
        return 'mfhi1 $regD';
      case 0x11:
        return 'mthi1 $regS';
      case 0x12:
        return 'mflo1 $regD';
      case 0x13:
        return 'mtlo1 $regS';
      case 0x18:
        return 'mult1 $regD, $regS, $regT';
      case 0x19:
        return 'multu1 $regD, $regS, $regT';
      case 0x1a:
        return 'div1 $regS, $regT';
      case 0x1b:
        return 'divu1 $regS, $regT';
      case 0x20:
        return 'madd1 $regD, $regS, $regT';
      case 0x21:
        return 'maddu1 $regD, $regS, $regT';
      case 0x28:
        const mmi1 = {
          0x01: 'pabsw',
          0x02: 'pceqw',
          0x03: 'pminw',
          0x04: 'padsbh',
          0x05: 'pabsh',
          0x06: 'pceqh',
          0x07: 'pminh',
          0x0a: 'pceqb',
          0x10: 'padduw',
          0x11: 'psubuw',
          0x12: 'pextuw',
          0x14: 'padduh',
          0x15: 'psubuh',
          0x16: 'pextuh',
          0x18: 'paddub',
          0x19: 'psubub',
          0x1a: 'pextub',
          0x1b: 'qfsrv',
        };
        if (sa == 0x01 || sa == 0x05) return '${mmi1[sa]} $regD, $regT';
        if (mmi1.containsKey(sa)) return '${mmi1[sa]} $regD, $regS, $regT';
      case 0x29:
        const mmi3 = {
          0x00: 'pmadduw',
          0x03: 'psravw',
          0x08: 'pmthi',
          0x09: 'pmtlo',
          0x0a: 'pinteh',
          0x0c: 'pmultuw',
          0x0d: 'pdivuw',
          0x0e: 'pcpyud',
          0x12: 'por',
          0x13: 'pnor',
          0x1a: 'pexch',
          0x1b: 'pcpyh',
          0x1e: 'pexcw',
        };
        if (sa == 0x08 || sa == 0x09) return '${mmi3[sa]} $regS';
        if (sa == 0x1a || sa == 0x1b || sa == 0x1e) {
          return '${mmi3[sa]} $regD, $regT';
        }
        if (mmi3.containsKey(sa)) return '${mmi3[sa]} $regD, $regS, $regT';
      case 0x30:
        const pmfhl = ['lw', 'uw', 'slw', 'lh', 'sh'];
        return 'pmfhl.${sa < pmfhl.length ? pmfhl[sa] : sa} $regD';
      case 0x31:
        return 'pmthl.lw $regS';
      case 0x34:
        return 'psllh $regD, $regT, ${sa & 15}';
      case 0x36:
        return 'psrlh $regD, $regT, ${sa & 15}';
      case 0x37:
        return 'psrah $regD, $regT, ${sa & 15}';
      case 0x3c:
        return 'psllw $regD, $regT, $sa';
      case 0x3e:
        return 'psrlw $regD, $regT, $sa';
      case 0x3f:
        return 'psraw $regD, $regT, $sa';
    }
    return '.mmi 0x${word.mask32.toRadixString(16)}';
  }

  /// Disassembles an IOP (R3000) instruction.
  static String iop(int word, int pc) {
    final op = word >>> 26;
    final rs = (word >>> 21) & 31,
        rt = (word >>> 16) & 31,
        rd = (word >>> 11) & 31;
    final sa = (word >>> 6) & 31, fn = word & 63;
    final imm = word & 0xffff, simm = imm.rel16;
    final branch = _hex(pc + 4 + simm * 4);
    final regS = _gpr[rs], regT = _gpr[rt], regD = _gpr[rd];

    String mem(String name) => '$name $regT, $simm($regS)';

    if (op == 0) {
      if (word == 0) return 'nop';
      const shifts = {0: 'sll', 2: 'srl', 3: 'sra'};
      if (shifts.containsKey(fn)) return '${shifts[fn]} $regD, $regT, $sa';
      const varShifts = {4: 'sllv', 6: 'srlv', 7: 'srav'};
      if (varShifts.containsKey(fn)) {
        return '${varShifts[fn]} $regD, $regT, $regS';
      }
      if (fn == 8) return 'jr $regS';
      if (fn == 9) return rd == 31 ? 'jalr $regS' : 'jalr $regD, $regS';
      if (fn == 12) {
        return 'syscall 0x${((word >>> 6) & 0xfffff).toRadixString(16)}';
      }
      if (fn == 13) {
        return 'break 0x${((word >>> 6) & 0xfffff).toRadixString(16)}';
      }
      if (fn == 16) return 'mfhi $regD';
      if (fn == 17) return 'mthi $regS';
      if (fn == 18) return 'mflo $regD';
      if (fn == 19) return 'mtlo $regS';
      if (fn == 24) return 'mult $regS, $regT';
      if (fn == 25) return 'multu $regS, $regT';
      if (fn == 26) return 'div $regS, $regT';
      if (fn == 27) return 'divu $regS, $regT';
      if (fn == 33 && rs == 0) return 'move $regD, $regT';
      if (fn == 35 && rs == 0) return 'negu $regD, $regT';
      const alu = {
        32: 'add',
        33: 'addu',
        34: 'sub',
        35: 'subu',
        36: 'and',
        37: 'or',
        38: 'xor',
        39: 'nor',
        42: 'slt',
        43: 'sltu',
      };
      if (alu.containsKey(fn)) return '${alu[fn]} $regD, $regS, $regT';
    } else if (op == 1) {
      const branches = {
        0: 'bltz',
        1: 'bgez',
        16: 'bltzal',
        17: 'bgezal',
      };
      if (branches.containsKey(rt)) return '${branches[rt]} $regS, $branch';
    } else if (op == 2 || op == 3) {
      return '${op == 2 ? "j" : "jal"} ${_hex((pc + 4) & 0xf0000000 | (word & 0x03ffffff) << 2)}';
    } else if (op == 4) {
      if (rs == 0 && rt == 0) return 'b $branch';
      if (rt == 0) return 'beqz $regS, $branch';
      return 'beq $regS, $regT, $branch';
    } else if (op == 5) {
      if (rt == 0) return 'bnez $regS, $branch';
      return 'bne $regS, $regT, $branch';
    } else if (op == 6) {
      return 'blez $regS, $branch';
    } else if (op == 7) {
      return 'bgtz $regS, $branch';
    } else if (op == 16) {
      if (rs == 0) return 'mfc0 $regT, ${_iopCop0[rd]}';
      if (rs == 4) return 'mtc0 $regT, ${_iopCop0[rd]}';
      if (word == 0x42000010) return 'rfe';
    } else {
      if (op == 9 && rs == 0) return 'li $regT, $simm';
      const arith = {
        8: 'addi',
        9: 'addiu',
        10: 'slti',
        11: 'sltiu',
      };
      if (arith.containsKey(op)) return '${arith[op]} $regT, $regS, $simm';
      const logic = {12: 'andi', 13: 'ori', 14: 'xori'};
      if (logic.containsKey(op)) {
        return '${logic[op]} $regT, $regS, 0x${imm.toRadixString(16)}';
      }
      if (op == 15) return 'lui $regT, 0x${imm.toRadixString(16)}';
      const loads = {
        32: 'lb',
        33: 'lh',
        34: 'lwl',
        35: 'lw',
        36: 'lbu',
        37: 'lhu',
        38: 'lwr',
        40: 'sb',
        41: 'sh',
        42: 'swl',
        43: 'sw',
        46: 'swr',
      };
      if (loads.containsKey(op)) return mem(loads[op]!);
    }
    return '.word ${_hex(word)}';
  }
}
