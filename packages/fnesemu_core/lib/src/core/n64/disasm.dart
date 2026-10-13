/// VR4300 (MIPS III) instruction formatting; never reads machine state.
import '../../util/int.dart';

class Vr4300Disasm {
  static String _hex(int value) =>
      '0x${value.mask32.toRadixString(16).padLeft(8, '0')}';
  static const _cp0 = [
    'index',
    'random',
    'entrylo0',
    'entrylo1',
    'context',
    'pagemask',
    'wired',
    'reserved7',
    'badvaddr',
    'count',
    'entryhi',
    'compare',
    'status',
    'cause',
    'epc',
    'prid',
    'config',
    'lladdr',
    'watchlo',
    'watchhi',
    'xcontext',
    'reserved21',
    'reserved22',
    'reserved23',
    'reserved24',
    'reserved25',
    'perr',
    'cacheerr',
    'taglo',
    'taghi',
    'errorepc',
    'reserved31'
  ];
  static String disasm(int word, int pc) {
    final op = word >>> 26, rs = (word >>> 21).mask5, rt = (word >>> 16).mask5;
    final rd = (word >>> 11).mask5, sa = (word >>> 6).mask5, fn = word.mask6;
    final immediate = word.mask16, signed = immediate.rel16;
    final branch = _hex(pc + 4 + signed * 4);
    String memory(String name, {bool floating = false}) =>
        '$name ${floating ? "f" : "r"}$rt, $signed(r$rs)';
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
        63: 'dsra32'
      };
      if (shifts.containsKey(fn)) return '${shifts[fn]} r$rd, r$rt, $sa';
      const variableShifts = {
        4: 'sllv',
        6: 'srlv',
        7: 'srav',
        20: 'dsllv',
        22: 'dsrlv',
        23: 'dsrav'
      };
      if (variableShifts.containsKey(fn)) {
        return '${variableShifts[fn]} r$rd, r$rt, r$rs';
      }
      if (fn == 8) return 'jr r$rs';
      if (fn == 9) return 'jalr r$rd, r$rs';
      if (fn == 12 || fn == 13) {
        return '${fn == 12 ? "syscall" : "break"} 0x${(word >>> 6 & 0xfffff).toRadixString(16)}';
      }
      if (fn == 15) return 'sync $sa';
      if (fn == 16 || fn == 18) return '${fn == 16 ? "mfhi" : "mflo"} r$rd';
      if (fn == 17 || fn == 19) return '${fn == 17 ? "mthi" : "mtlo"} r$rs';
      const multiply = {
        24: 'mult',
        25: 'multu',
        26: 'div',
        27: 'divu',
        28: 'dmult',
        29: 'dmultu',
        30: 'ddiv',
        31: 'ddivu'
      };
      if (multiply.containsKey(fn)) return '${multiply[fn]} r$rs, r$rt';
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
        44: 'dadd',
        45: 'daddu',
        46: 'dsub',
        47: 'dsubu'
      };
      if (alu.containsKey(fn)) return '${alu[fn]} r$rd, r$rs, r$rt';
      const traps = {
        48: 'tge',
        49: 'tgeu',
        50: 'tlt',
        51: 'tltu',
        52: 'teq',
        54: 'tne'
      };
      if (traps.containsKey(fn)) {
        return '${traps[fn]} r$rs, r$rt, ${(word >>> 6).mask10}';
      }
    } else if (op == 1) {
      const branches = {
        0: 'bltz',
        1: 'bgez',
        2: 'bltzl',
        3: 'bgezl',
        16: 'bltzal',
        17: 'bgezal',
        18: 'bltzall',
        19: 'bgezall'
      };
      if (branches.containsKey(rt)) return '${branches[rt]} r$rs, $branch';
      const traps = {
        8: 'tgei',
        9: 'tgeiu',
        10: 'tlti',
        11: 'tltiu',
        12: 'teqi',
        14: 'tnei'
      };
      if (traps.containsKey(rt)) return '${traps[rt]} r$rs, $signed';
    } else if (op == 2 || op == 3) {
      return '${op == 2 ? "j" : "jal"} ${_hex((pc + 4) & 0xf0000000 | word.mask26.shl2)}';
    } else if ([4, 5, 20, 21].contains(op)) {
      const branches = {4: 'beq', 5: 'bne', 20: 'beql', 21: 'bnel'};
      return '${branches[op]} r$rs, r$rt, $branch';
    } else if ([6, 7, 22, 23].contains(op)) {
      const branches = {6: 'blez', 7: 'bgtz', 22: 'blezl', 23: 'bgtzl'};
      return '${branches[op]} r$rs, $branch';
    } else if (op == 16) {
      const moves = {0: 'mfc0', 1: 'dmfc0', 4: 'mtc0', 5: 'dmtc0'};
      if (moves.containsKey(rs)) return '${moves[rs]} r$rt, ${_cp0[rd]}';
      if (rs == 16) {
        const operations = {
          1: 'tlbr',
          2: 'tlbwi',
          6: 'tlbwr',
          8: 'tlbp',
          24: 'eret',
          32: 'wait'
        };
        if (operations.containsKey(fn)) return operations[fn]!;
      }
    } else if (op == 17) {
      const moves = {
        0: 'mfc1',
        1: 'dmfc1',
        2: 'cfc1',
        4: 'mtc1',
        5: 'dmtc1',
        6: 'ctc1'
      };
      if (moves.containsKey(rs)) {
        return '${moves[rs]} r$rt, ${rs == 2 || rs == 6 ? "fcr" : "f"}$rd';
      }
      if (rs == 8 && rt < 4) {
        return '${['bc1f', 'bc1t', 'bc1fl', 'bc1tl'][rt]} $branch';
      }
      final format = {16: 's', 17: 'd', 20: 'w', 21: 'l'}[rs];
      if (format != null) {
        const binary = {0: 'add', 1: 'sub', 2: 'mul', 3: 'div'};
        if (rs < 20 && binary.containsKey(fn)) {
          return '${binary[fn]}.$format f$sa, f$rd, f$rt';
        }
        const unary = {
          4: 'sqrt',
          5: 'abs',
          6: 'mov',
          7: 'neg',
          8: 'round.l',
          9: 'trunc.l',
          10: 'ceil.l',
          11: 'floor.l',
          12: 'round.w',
          13: 'trunc.w',
          14: 'ceil.w',
          15: 'floor.w',
          32: 'cvt.s',
          33: 'cvt.d',
          36: 'cvt.w',
          37: 'cvt.l'
        };
        if (unary.containsKey(fn) && (rs < 20 || fn == 32 || fn == 33)) {
          return '${unary[fn]}.$format f$sa, f$rd';
        }
        if (rs < 20 && fn >= 48) {
          const predicates = [
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
            'ngt'
          ];
          return 'c.${predicates[fn - 48]}.$format f$rd, f$rt';
        }
      }
    } else {
      const arithmetic = {
        8: 'addi',
        9: 'addiu',
        10: 'slti',
        11: 'sltiu',
        24: 'daddi',
        25: 'daddiu'
      };
      if (arithmetic.containsKey(op)) {
        return '${arithmetic[op]} r$rt, r$rs, $signed';
      }
      const logic = {12: 'andi', 13: 'ori', 14: 'xori'};
      if (logic.containsKey(op)) {
        return '${logic[op]} r$rt, r$rs, 0x${immediate.toRadixString(16)}';
      }
      if (op == 15) return 'lui r$rt, 0x${immediate.toRadixString(16)}';
      const loads = {
        26: 'ldl',
        27: 'ldr',
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
        48: 'll',
        52: 'lld',
        55: 'ld',
        56: 'sc',
        60: 'scd',
        63: 'sd'
      };
      if (loads.containsKey(op)) return memory(loads[op]!);
      const floating = {49: 'lwc1', 53: 'ldc1', 57: 'swc1', 61: 'sdc1'};
      if (floating.containsKey(op)) {
        return memory(floating[op]!, floating: true);
      }
      if (op == 47) return 'cache 0x${rt.toRadixString(16)}, $signed(r$rs)';
    }
    return '.word ${_hex(word)}';
  }
}
