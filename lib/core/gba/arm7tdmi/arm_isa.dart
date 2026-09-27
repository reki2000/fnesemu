part of 'arm7.dart';

/// ARM (32-bit) instruction set.
extension ArmIsa on Arm7 {
  int _executeArm(int op) {
    final cond = op >>> 28;
    if (cond != 0xe && !checkCond(cond)) return 1;

    // BX  (cond 0001 0010 1111 1111 1111 0001 Rn)
    if ((op & 0x0ffffff0) == 0x012fff10) {
      _bx(_rd(op.mask4));
      return 3;
    }

    final kind = op.shr25.mask3;
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
        if (op.bit24) {
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
            return !op.bit24 ? _armMultiply(op) : _armSwap(op);
          }
          return _armHalf(op);
        }
        return _armDataProc(op);
    }
  }

  // --- branch ---------------------------------------------------------------

  int _armBranch(int op) {
    final link = op.bit24;
    final off = op.mask24.toSigned(24).shl2;
    if (link) regs.r[14] = (regs.r[15] - 4).mask32; // return addr
    _setPC((regs.r[15] + off).mask32);
    return 3;
  }

  // --- data processing / PSR transfer --------------------------------------

  int _armDataProc(int op) {
    final opcode = op.shr21.mask4;
    final s = op.bit20;
    final rn = op.shr16.mask4;
    final rd = op.shr12.mask4;
    final i = op.bit25;
    final regShift = !i && op.bit4;

    // PSR transfer (MRS/MSR) hides in the comparison opcodes when S=0
    if (!s && (opcode & 0xc) == 0x8) {
      return !op.bit21 ? _armMrs(op) : _armMsr(op);
    }

    final pcOff = regShift ? 4 : 0; // r15 reads +12 when shifted by register
    int rdReg(int n) => n == 15 ? (regs.r[15] + pcOff).mask32 : regs.r[n];

    // operand 2
    int op2;
    if (i) {
      final imm = op.mask8;
      final rot = op.shr8.mask4 * 2;
      if (rot == 0) {
        op2 = imm;
        _shiftC = regs.cf;
      } else {
        op2 = (imm >>> rot | imm.shl(32 - rot)).mask32;
        _shiftC = op2.bit31;
      }
    } else {
      final type = op.shr5.mask2;
      final rm = op.mask4;
      if (regShift) {
        final amount = regs.r[op.shr8.mask4].mask8;
        op2 = _barrel(type, rdReg(rm), amount, imm: false);
      } else {
        final amount = op.shr7.mask5;
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
      case 0xe: res = a & (~op2).mask32; logical = true; break; // BIC
      default: res = (~op2).mask32; logical = true; break; // MVN
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
        regs.setNZ(res.bit31, res == 0);
        regs.cf = _shiftC;
      } else {
        regs.setNZCV(res.bit31, res == 0, _aluC, _aluV);
      }
    }

    return regShift ? 2 : 1;
  }

  int _armMrs(int op) {
    final rd = op.shr12.mask4;
    final useSpsr = op.bit22;
    regs.r[rd] = useSpsr ? regs.spsr : regs.cpsr;
    return 1;
  }

  int _armMsr(int op) {
    final useSpsr = op.bit22;
    final i = op.bit25;

    int val;
    if (i) {
      final imm = op.mask8;
      final rot = op.shr8.mask4 * 2;
      val = rot == 0 ? imm : (imm >>> rot | imm.shl(32 - rot)).mask32;
    } else {
      val = regs.r[op.mask4];
    }

    // field mask bits: 16=control 17=ext 18=status 19=flags
    int mask = 0;
    if (op.bit16) mask |= 0x000000ff;
    if (op.bit17) mask |= 0x0000ff00;
    if (op.bit18) mask |= 0x00ff0000;
    if (op.bit19) mask |= 0xff000000;

    if (useSpsr) {
      regs.spsr = (regs.spsr & ~mask) | (val & mask);
    } else {
      // in user mode only the flag byte is writable
      if (regs.mode == CpuMode.usr) mask &= 0xff000000;
      final newCpsr = (regs.cpsr & ~mask) | (val & mask);
      if (mask.mask8 != 0) {
        regs.switchMode(newCpsr.mask5); // bank registers before committing
      }
      regs.cpsr = newCpsr;
    }
    return 1;
  }

  // --- multiply -------------------------------------------------------------

  int _armMultiply(int op) {
    final s = op.bit20;
    final long = op.bit23;

    if (!long) {
      final rd = op.shr16.mask4;
      final rn = op.shr12.mask4;
      final rs = op.shr8.mask4;
      final rm = op.mask4;
      final acc = op.bit21;
      var res = (regs.r[rm] * regs.r[rs]).mask32;
      if (acc) res = (res + regs.r[rn]).mask32;
      regs.r[rd] = res;
      if (s) regs.setNZ(res.bit31, res == 0);
      return 4;
    }

    // long multiply (UMULL/UMLAL/SMULL/SMLAL)
    final rdHi = op.shr16.mask4;
    final rdLo = op.shr12.mask4;
    final rs = op.shr8.mask4;
    final rm = op.mask4;
    final signed = op.bit22;
    final acc = op.bit21;

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
    if (s) regs.setNZ(hi.bit31, hi == 0 && lo == 0);
    return 5;
  }

  // --- single data swap -----------------------------------------------------

  int _armSwap(int op) {
    final byte = op.bit22;
    final rn = op.shr16.mask4;
    final rd = op.shr12.mask4;
    final rm = op.mask4;
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
    final i = op.bit25; // 1 = register offset (shifted)
    final pre = op.bit24;
    final up = op.bit23;
    final byte = op.bit22;
    final wb = op.bit21;
    final load = op.bit20;
    final rn = op.shr16.mask4;
    final rd = op.shr12.mask4;

    int offset;
    if (!i) {
      offset = op.mask12;
    } else {
      final type = op.shr5.mask2;
      final amount = op.shr7.mask5;
      offset = _barrel(type, regs.r[op.mask4], amount, imm: true);
    }

    var addr = regs.r[rn];
    final base = addr;
    if (pre) addr = up ? (addr + offset).mask32 : (addr - offset).mask32;

    if (load) {
      final v = byte ? bus.read8(addr) : _ldrWord(addr);
      // writeback before the load result so Rn==Rd ends up with loaded value
      if (!pre) {
        final wbAddr =
            up ? (base + offset).mask32 : (base - offset).mask32;
        regs.r[rn] = wbAddr;
      } else if (wb) {
        regs.r[rn] = addr;
      }
      _wr(rd, v);
      return 3;
    } else {
      final v = rd == 15 ? (regs.r[15] + 4).mask32 : regs.r[rd];
      if (byte) {
        bus.write8(addr, v);
      } else {
        bus.write32(addr & ~3, v);
      }
      if (!pre) {
        regs.r[rn] =
            up ? (base + offset).mask32 : (base - offset).mask32;
      } else if (wb) {
        regs.r[rn] = addr;
      }
      return 2;
    }
  }

  /// LDR word with the ARM unaligned-rotate behaviour.
  int _ldrWord(int addr) {
    final v = bus.read32(addr & ~3);
    final rot = addr.mask2 * 8;
    return rot == 0 ? v : (v >>> rot | v.shl(32 - rot)).mask32;
  }

  // --- halfword / signed transfer ------------------------------------------

  int _armHalf(int op) {
    final pre = op.bit24;
    final up = op.bit23;
    final immForm = op.bit22;
    final wb = op.bit21;
    final load = op.bit20;
    final rn = op.shr16.mask4;
    final rd = op.shr12.mask4;
    final sh = op.shr5.mask2; // 01=H 10=SB 11=SH

    final offset = immForm
        ? op.shr8.mask4.shl4 | op.mask4
        : regs.r[op.mask4];

    var addr = regs.r[rn];
    final base = addr;
    if (pre) addr = up ? (addr + offset).mask32 : (addr - offset).mask32;

    if (load) {
      int v;
      switch (sh) {
        case 1: // LDRH
          final raw = bus.read16(addr & ~1);
          v = addr.bit0 ? (raw >>> 8 | raw.shl24).mask32 : raw;
          break;
        case 2: // LDRSB
          v = bus.read8(addr).toSigned(8).mask32;
          break;
        default: // 3: LDRSH
          if (addr.bit0) {
            v = bus.read8(addr).toSigned(8).mask32; // misaligned -> SB
          } else {
            v = bus.read16(addr).toSigned(16).mask32;
          }
          break;
      }
      if (!pre) {
        regs.r[rn] =
            up ? (base + offset).mask32 : (base - offset).mask32;
      } else if (wb) {
        regs.r[rn] = addr;
      }
      _wr(rd, v);
      return 3;
    } else {
      // STRH only
      final v = regs.r[rd];
      bus.write16(addr & ~1, v.mask16);
      if (!pre) {
        regs.r[rn] =
            up ? (base + offset).mask32 : (base - offset).mask32;
      } else if (wb) {
        regs.r[rn] = addr;
      }
      return 2;
    }
  }

  // --- block data transfer (LDM/STM) ---------------------------------------

  int _armBlock(int op) {
    final pre = op.bit24;
    final up = op.bit23;
    final psr = op.bit22; // S bit
    final wb = op.bit21;
    final load = op.bit20;
    final rn = op.shr16.mask4;
    final list = op.mask16;

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
    final transferUser = psr && !(load && list.bit15);

    if (load) {
      if (regsInList.isEmpty) {
        // LDM with empty list loads PC
        final v = bus.read32(addr & ~3);
        if (wb) regs.r[rn] = writeback;
        _setPC(v);
        return 4;
      }
      // writeback unless base is loaded. done before the loads so that a
      // `ldm rn!, {..,pc}^` updates rn in the current mode's bank, not in the
      // bank of the mode restored from SPSR.
      if (wb && (list & (1 << rn)) == 0) regs.r[rn] = writeback;
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
      return count + 2;
    } else {
      if (regsInList.isEmpty) {
        bus.write32(addr & ~3, (regs.r[15] + 4).mask32);
        if (wb) regs.r[rn] = writeback;
        return 3;
      }
      var first = true;
      for (final r in regsInList) {
        int v;
        if (r == 15) {
          v = (regs.r[15] + 4).mask32;
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
