part of 'arm7.dart';

/// ARM (32-bit) instruction set.
extension ArmIsa on Arm7 {
  int _executeArm(int op) {
    final cond = op >>> 28;
    if (cond != 0xe && !checkCond(cond)) return 1;

    // BX  (cond 0001 0010 1111 1111 1111 0001 Rn)
    if ((op & 0x0ffffff0) == 0x012fff10) {
      _bx(_rd(op & 0xf));
      return 3;
    }

    final kind = (op >> 25) & 0x7;
    switch (kind) {
      case 0x5: // 0b101
        return _armBranch(op);
      case 0x4: // 0b100
        return _armBlock(op);
      case 0x2: // 0b010
      case 0x3: // 0b011
        return _armSingle(op);
      case 0x7: // 0b111
        // bit24 set => SWI; coprocessor ops are undefined on GBA
        if ((op >> 24) & 1 == 1) {
          raiseSwi();
          return 3;
        }
        raiseUndefined();
        return 3;
      default: // 0b000 / 0b001
        if (kind == 0x0 && (op & 0x90) == 0x90) {
          // bit7=bit4=1 => multiply / swap / halfword transfer
          if ((op & 0x60) == 0) {
            // SH field 00 => multiply family or swap
            return ((op >> 24) & 1 == 0) ? _armMultiply(op) : _armSwap(op);
          }
          return _armHalf(op);
        }
        return _armDataProc(op);
    }
  }

  // --- branch ---------------------------------------------------------------

  int _armBranch(int op) {
    final link = (op >> 24) & 1 != 0;
    final off = (op & 0xffffff).toSigned(24) << 2;
    if (link) regs.r[14] = (regs.r[15] - 4) & 0xffffffff; // return addr
    _setPC((regs.r[15] + off) & 0xffffffff);
    return 3;
  }

  // --- data processing / PSR transfer --------------------------------------

  int _armDataProc(int op) {
    final opcode = (op >> 21) & 0xf;
    final s = (op >> 20) & 1 != 0;
    final rn = (op >> 16) & 0xf;
    final rd = (op >> 12) & 0xf;
    final i = (op >> 25) & 1 != 0;
    final regShift = !i && (op >> 4) & 1 != 0;

    // PSR transfer (MRS/MSR) hides in the comparison opcodes when S=0
    if (!s && (opcode & 0xc) == 0x8) {
      return ((op >> 21) & 1 == 0) ? _armMrs(op) : _armMsr(op);
    }

    final pcOff = regShift ? 4 : 0; // r15 reads +12 when shifted by register
    int rdReg(int n) => n == 15 ? (regs.r[15] + pcOff) & 0xffffffff : regs.r[n];

    // operand 2
    int op2;
    if (i) {
      final imm = op & 0xff;
      final rot = ((op >> 8) & 0xf) * 2;
      if (rot == 0) {
        op2 = imm;
        _shiftC = regs.cf;
      } else {
        op2 = ((imm >>> rot) | (imm << (32 - rot))) & 0xffffffff;
        _shiftC = op2 & 0x80000000 != 0;
      }
    } else {
      final type = (op >> 5) & 3;
      final rm = op & 0xf;
      if (regShift) {
        final amount = regs.r[(op >> 8) & 0xf] & 0xff;
        op2 = _barrel(type, rdReg(rm), amount, imm: false);
      } else {
        final amount = (op >> 7) & 0x1f;
        op2 = _barrel(type, rdReg(rm), amount, imm: true);
      }
    }

    final a = rdReg(rn);
    int res = 0;
    bool write = true;
    bool logical = false;

    switch (opcode) {
      case 0x0: res = a & op2; logical = true; break; // AND
      case 0x1: res = a ^ op2; logical = true; break; // EOR
      case 0x2: res = _sbc(a, op2, 1); break; // SUB
      case 0x3: res = _sbc(op2, a, 1); break; // RSB
      case 0x4: res = _adc(a, op2, 0); break; // ADD
      case 0x5: res = _adc(a, op2, regs.cf ? 1 : 0); break; // ADC
      case 0x6: res = _sbc(a, op2, regs.cf ? 1 : 0); break; // SBC
      case 0x7: res = _sbc(op2, a, regs.cf ? 1 : 0); break; // RSC
      case 0x8: res = a & op2; logical = true; write = false; break; // TST
      case 0x9: res = a ^ op2; logical = true; write = false; break; // TEQ
      case 0xa: res = _sbc(a, op2, 1); write = false; break; // CMP
      case 0xb: res = _adc(a, op2, 0); write = false; break; // CMN
      case 0xc: res = a | op2; logical = true; break; // ORR
      case 0xd: res = op2; logical = true; break; // MOV
      case 0xe: res = a & (~op2 & 0xffffffff); logical = true; break; // BIC
      default: res = (~op2) & 0xffffffff; logical = true; break; // MVN
    }

    if (rd == 15 && write) {
      if (s) {
        regs.restoreCpsr();
        regs.pc = res & (regs.thumb ? ~1 : ~3);
        _flushPipeline();
      } else {
        _setPC(res);
      }
      return 3;
    }

    if (write) regs.r[rd] = res;

    if (s) {
      if (logical) {
        regs.setNZ(res & 0x80000000 != 0, res == 0);
        regs.cf = _shiftC;
      } else {
        regs.setNZCV(res & 0x80000000 != 0, res == 0, _aluC, _aluV);
      }
    }

    return regShift ? 2 : 1;
  }

  int _armMrs(int op) {
    final rd = (op >> 12) & 0xf;
    final useSpsr = (op >> 22) & 1 != 0;
    regs.r[rd] = useSpsr ? regs.spsr : regs.cpsr;
    return 1;
  }

  int _armMsr(int op) {
    final useSpsr = (op >> 22) & 1 != 0;
    final i = (op >> 25) & 1 != 0;

    int val;
    if (i) {
      final imm = op & 0xff;
      final rot = ((op >> 8) & 0xf) * 2;
      val = rot == 0 ? imm : ((imm >>> rot) | (imm << (32 - rot))) & 0xffffffff;
    } else {
      val = regs.r[op & 0xf];
    }

    // field mask bits: 16=control 17=ext 18=status 19=flags
    int mask = 0;
    if ((op >> 16) & 1 != 0) mask |= 0x000000ff;
    if ((op >> 17) & 1 != 0) mask |= 0x0000ff00;
    if ((op >> 18) & 1 != 0) mask |= 0x00ff0000;
    if ((op >> 19) & 1 != 0) mask |= 0xff000000;

    if (useSpsr) {
      regs.spsr = (regs.spsr & ~mask) | (val & mask);
    } else {
      // in user mode only the flag byte is writable
      if (regs.mode == CpuMode.usr) mask &= 0xff000000;
      final newCpsr = (regs.cpsr & ~mask) | (val & mask);
      if (mask & 0xff != 0) {
        regs.switchMode(newCpsr & 0x1f); // bank registers before committing
      }
      regs.cpsr = newCpsr;
    }
    return 1;
  }

  // --- multiply -------------------------------------------------------------

  int _armMultiply(int op) {
    final s = (op >> 20) & 1 != 0;
    final long = (op >> 23) & 1 != 0;

    if (!long) {
      final rd = (op >> 16) & 0xf;
      final rn = (op >> 12) & 0xf;
      final rs = (op >> 8) & 0xf;
      final rm = op & 0xf;
      final acc = (op >> 21) & 1 != 0;
      var res = (regs.r[rm] * regs.r[rs]) & 0xffffffff;
      if (acc) res = (res + regs.r[rn]) & 0xffffffff;
      regs.r[rd] = res;
      if (s) regs.setNZ(res & 0x80000000 != 0, res == 0);
      return 4;
    }

    // long multiply (UMULL/UMLAL/SMULL/SMLAL)
    final rdHi = (op >> 16) & 0xf;
    final rdLo = (op >> 12) & 0xf;
    final rs = (op >> 8) & 0xf;
    final rm = op & 0xf;
    final signed = (op >> 22) & 1 != 0;
    final acc = (op >> 21) & 1 != 0;

    final m = signed
        ? BigInt.from(regs.r[rm].toSigned(32))
        : BigInt.from(regs.r[rm]);
    final sN = signed
        ? BigInt.from(regs.r[rs].toSigned(32))
        : BigInt.from(regs.r[rs]);
    var prod = m * sN;
    if (acc) {
      final lo = BigInt.from(regs.r[rdLo]);
      final hi = BigInt.from(regs.r[rdHi]) << 32;
      prod += (hi | lo);
    }
    final lo = (prod & BigInt.from(0xffffffff)).toInt();
    final hi = ((prod >> 32) & BigInt.from(0xffffffff)).toInt();
    regs.r[rdLo] = lo;
    regs.r[rdHi] = hi;
    if (s) regs.setNZ(hi & 0x80000000 != 0, hi == 0 && lo == 0);
    return 5;
  }

  // --- single data swap -----------------------------------------------------

  int _armSwap(int op) {
    final byte = (op >> 22) & 1 != 0;
    final rn = (op >> 16) & 0xf;
    final rd = (op >> 12) & 0xf;
    final rm = op & 0xf;
    final addr = regs.r[rn];
    if (byte) {
      final tmp = bus.read8(addr);
      bus.write8(addr, regs.r[rm]);
      regs.r[rd] = tmp;
    } else {
      final tmp = _ldrWord(addr);
      bus.write32(addr & ~3, regs.r[rm]);
      regs.r[rd] = tmp;
    }
    return 4;
  }

  // --- single data transfer (LDR/STR) --------------------------------------

  int _armSingle(int op) {
    final i = (op >> 25) & 1 != 0; // 1 = register offset (shifted)
    final pre = (op >> 24) & 1 != 0;
    final up = (op >> 23) & 1 != 0;
    final byte = (op >> 22) & 1 != 0;
    final wb = (op >> 21) & 1 != 0;
    final load = (op >> 20) & 1 != 0;
    final rn = (op >> 16) & 0xf;
    final rd = (op >> 12) & 0xf;

    int offset;
    if (!i) {
      offset = op & 0xfff;
    } else {
      final type = (op >> 5) & 3;
      final amount = (op >> 7) & 0x1f;
      offset = _barrel(type, regs.r[op & 0xf], amount, imm: true);
    }

    var addr = regs.r[rn];
    final base = addr;
    if (pre) addr = up ? (addr + offset) & 0xffffffff : (addr - offset) & 0xffffffff;

    if (load) {
      final v = byte ? bus.read8(addr) : _ldrWord(addr);
      // writeback before the load result so Rn==Rd ends up with loaded value
      if (!pre) {
        final wbAddr =
            up ? (base + offset) & 0xffffffff : (base - offset) & 0xffffffff;
        regs.r[rn] = wbAddr;
      } else if (wb) {
        regs.r[rn] = addr;
      }
      _wr(rd, v);
      return 3;
    } else {
      final v = rd == 15 ? (regs.r[15] + 4) & 0xffffffff : regs.r[rd];
      if (byte) {
        bus.write8(addr, v);
      } else {
        bus.write32(addr & ~3, v);
      }
      if (!pre) {
        regs.r[rn] =
            up ? (base + offset) & 0xffffffff : (base - offset) & 0xffffffff;
      } else if (wb) {
        regs.r[rn] = addr;
      }
      return 2;
    }
  }

  /// LDR word with the ARM unaligned-rotate behaviour.
  int _ldrWord(int addr) {
    final v = bus.read32(addr & ~3);
    final rot = (addr & 3) * 8;
    return rot == 0 ? v : ((v >>> rot) | (v << (32 - rot))) & 0xffffffff;
  }

  // --- halfword / signed transfer ------------------------------------------

  int _armHalf(int op) {
    final pre = (op >> 24) & 1 != 0;
    final up = (op >> 23) & 1 != 0;
    final immForm = (op >> 22) & 1 != 0;
    final wb = (op >> 21) & 1 != 0;
    final load = (op >> 20) & 1 != 0;
    final rn = (op >> 16) & 0xf;
    final rd = (op >> 12) & 0xf;
    final sh = (op >> 5) & 3; // 01=H 10=SB 11=SH

    final offset = immForm
        ? (((op >> 8) & 0xf) << 4) | (op & 0xf)
        : regs.r[op & 0xf];

    var addr = regs.r[rn];
    final base = addr;
    if (pre) addr = up ? (addr + offset) & 0xffffffff : (addr - offset) & 0xffffffff;

    if (load) {
      int v;
      switch (sh) {
        case 1: // LDRH
          final raw = bus.read16(addr & ~1);
          v = (addr & 1 != 0) ? ((raw >>> 8) | (raw << 24)) & 0xffffffff : raw;
          break;
        case 2: // LDRSB
          v = bus.read8(addr).toSigned(8) & 0xffffffff;
          break;
        default: // 3: LDRSH
          if (addr & 1 != 0) {
            v = bus.read8(addr).toSigned(8) & 0xffffffff; // misaligned -> SB
          } else {
            v = bus.read16(addr).toSigned(16) & 0xffffffff;
          }
          break;
      }
      if (!pre) {
        regs.r[rn] =
            up ? (base + offset) & 0xffffffff : (base - offset) & 0xffffffff;
      } else if (wb) {
        regs.r[rn] = addr;
      }
      _wr(rd, v);
      return 3;
    } else {
      // STRH only
      final v = regs.r[rd];
      bus.write16(addr & ~1, v & 0xffff);
      if (!pre) {
        regs.r[rn] =
            up ? (base + offset) & 0xffffffff : (base - offset) & 0xffffffff;
      } else if (wb) {
        regs.r[rn] = addr;
      }
      return 2;
    }
  }

  // --- block data transfer (LDM/STM) ---------------------------------------

  int _armBlock(int op) {
    final pre = (op >> 24) & 1 != 0;
    final up = (op >> 23) & 1 != 0;
    final psr = (op >> 22) & 1 != 0; // S bit
    final wb = (op >> 21) & 1 != 0;
    final load = (op >> 20) & 1 != 0;
    final rn = (op >> 16) & 0xf;
    final list = op & 0xffff;

    final regsInList = <int>[];
    for (int i = 0; i < 16; i++) {
      if (list & (1 << i) != 0) regsInList.add(i);
    }
    final count = regsInList.isEmpty ? 16 : regsInList.length;

    final base = regs.r[rn];
    // lowest register always maps to lowest address
    int addr;
    int writeback;
    if (up) {
      addr = pre ? base + 4 : base;
      writeback = base + count * 4;
    } else {
      addr = pre ? base - count * 4 : base - count * 4 + 4;
      writeback = base - count * 4;
    }
    addr &= 0xffffffff;
    writeback &= 0xffffffff;

    // empty list: ldm/stm r15 only, base +/- 0x40 (handled via count=16 above)
    final transferUser = psr && !(load && (list & 0x8000 != 0));

    if (load) {
      if (regsInList.isEmpty) {
        // LDM with empty list loads PC
        final v = bus.read32(addr & ~3);
        if (wb) regs.r[rn] = writeback;
        _setPC(v);
        return 4;
      }
      for (final r in regsInList) {
        final v = bus.read32(addr & ~3);
        addr += 4;
        if (transferUser) {
          _writeUserReg(r, v);
        } else if (r == 15) {
          if (psr) regs.restoreCpsr();
          regs.pc = v & (regs.thumb ? ~1 : ~3);
          _flushPipeline();
        } else {
          regs.r[r] = v;
        }
      }
      // writeback unless base was loaded
      if (wb && (list & (1 << rn)) == 0) regs.r[rn] = writeback;
      return count + 2;
    } else {
      if (regsInList.isEmpty) {
        bus.write32(addr & ~3, (regs.r[15] + 4) & 0xffffffff);
        if (wb) regs.r[rn] = writeback;
        return 3;
      }
      var first = true;
      for (final r in regsInList) {
        int v;
        if (r == 15) {
          v = (regs.r[15] + 4) & 0xffffffff;
        } else if (transferUser) {
          v = _readUserReg(r);
        } else {
          v = regs.r[r];
        }
        // base-first stores old base; otherwise the (already computed) new base
        if (r == rn && !first && wb) v = writeback;
        bus.write32(addr & ~3, v);
        addr += 4;
        first = false;
      }
      if (wb) regs.r[rn] = writeback;
      return count + 1;
    }
  }

  // user-bank register access for LDM/STM with the S bit (^).
  int _readUserReg(int n) {
    if (n < 8 || n == 15) return regs.r[n];
    // temporarily read the user/system bank value
    return regs.userModeReg(n);
  }

  void _writeUserReg(int n, int v) {
    if (n < 8 || n == 15) {
      regs.r[n] = v;
    } else {
      regs.setUserModeReg(n, v);
    }
  }
}
