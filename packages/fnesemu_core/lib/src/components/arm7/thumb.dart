part of 'arm7.dart';

/// THUMB (16-bit) instruction set, part of the shared ARM7 engine.
/// Runs only on cores with Thumb state; the ARM7DI embedding never
/// enables it. Register reads of r15 see the fetch pointer (executing
/// address + 4), as the TDMI pipeline model exposes it.
extension Arm7Thumb on Arm7Core {
  @pragma('vm:unsafe:no-bounds-checks')
  int _execThumb(int op) {
    _pc = regs.r[15] - 4;
    _nextPc = _pc + 2;
    final hi = op.shr13;
    switch (hi) {
      case 0:
        return (op & 0x1800) == 0x1800 ? _thAddSub(op) : _thShift(op);
      case 1:
        return _thMovCmpImm(op);
      case 2:
        if (op.bit12) {
          // Bit 12 set: load/store with register offset / sign-extended.
          return !op.bit9 ? _thLdStReg(op) : _thLdStSign(op);
        }
        if (op.bit11) return _thLdrPc(op); // PC-relative load
        // ALU (bit 10 clear) or hi-register operations (bit 10 set).
        return !op.bit10 ? _thAlu(op) : _thHiReg(op);
      case 3:
        return _thLdStImm(op);
      case 4:
        return !op.bit12 ? _thLdStHalf(op) : _thLdStSp(op);
      case 5:
        if (!op.bit12) return _thLoadAddr(op);
        if ((op & 0x0f00) == 0x0000) return _thAddSp(op);
        return _thPushPop(op);
      case 6:
        if (!op.bit12) return _thBlock(op);
        if ((op & 0x0f00) == 0x0f00) {
          onSwi();
          return 3;
        }
        return _thCondBranch(op);
      default: // 7
        return !op.bit12 ? _thBranch(op) : _thLongBranch(op);
    }
  }

  // Format 1: move shifted register.
  int _thShift(int op) {
    final type = op.shr11.mask2; // 0 LSL 1 LSR 2 ASR
    final offset = op.shr6.mask5;
    final rs = op.shr3.mask3;
    final rd = op.mask3;
    final res = barrelShift(type, regs.r[rs], offset, imm: true);
    regs.r[rd] = res;
    regs.setNZ(res.bit31, res == 0);
    regs.cf = shiftCarry;
    return 1;
  }

  // Format 2: add/subtract.
  int _thAddSub(int op) {
    final imm = op.bit10;
    final sub = op.bit9;
    final rnOff = op.shr6.mask3;
    final rs = op.shr3.mask3;
    final rd = op.mask3;
    final b = imm ? rnOff : regs.r[rnOff];
    final a = regs.r[rs];
    final res = sub ? sbc(a, b, 1) : adc(a, b, 0);
    regs.r[rd] = res;
    regs.setNZCV(res.bit31, res == 0, aluCarry, aluOverflow);
    return 1;
  }

  // Format 3: move/compare/add/subtract immediate.
  int _thMovCmpImm(int op) {
    final sub = op.shr11.mask2;
    final rd = op.shr8.mask3;
    final imm = op.mask8;
    final a = regs.r[rd];
    switch (sub) {
      case 0: // MOV
        regs.r[rd] = imm;
        regs.setNZ(false, imm == 0);
      case 1: // CMP
        final res = sbc(a, imm, 1);
        regs.setNZCV(res.bit31, res == 0, aluCarry, aluOverflow);
      case 2: // ADD
        final res = adc(a, imm, 0);
        regs.r[rd] = res;
        regs.setNZCV(res.bit31, res == 0, aluCarry, aluOverflow);
      default: // SUB
        final res = sbc(a, imm, 1);
        regs.r[rd] = res;
        regs.setNZCV(res.bit31, res == 0, aluCarry, aluOverflow);
    }
    return 1;
  }

  // Format 4: ALU operations.
  int _thAlu(int op) {
    final code = op.shr6.mask4;
    final rs = op.shr3.mask3;
    final rd = op.mask3;
    final a = regs.r[rd];
    final b = regs.r[rs];
    int res;
    var write = true;
    var arith = false;

    switch (code) {
      case 0x0:
        res = a & b; // AND
      case 0x1:
        res = a ^ b; // EOR
      case 0x2:
        res = barrelShift(0, a, b.mask8, imm: false); // LSL
      case 0x3:
        res = barrelShift(1, a, b.mask8, imm: false); // LSR
      case 0x4:
        res = barrelShift(2, a, b.mask8, imm: false); // ASR
      case 0x5:
        res = adc(a, b, regs.cf ? 1 : 0);
        arith = true; // ADC
      case 0x6:
        res = sbc(a, b, regs.cf ? 1 : 0);
        arith = true; // SBC
      case 0x7:
        res = barrelShift(3, a, b.mask8, imm: false); // ROR
      case 0x8:
        res = a & b;
        write = false; // TST
      case 0x9:
        res = sbc(0, b, 1);
        arith = true; // NEG
      case 0xa:
        res = sbc(a, b, 1);
        arith = true;
        write = false; // CMP
      case 0xb:
        res = adc(a, b, 0);
        arith = true;
        write = false; // CMN
      case 0xc:
        res = a | b; // ORR
      case 0xd:
        res = (a * b).mask32; // MUL
      case 0xe:
        res = a & (~b).mask32; // BIC
      default:
        res = (~b).mask32; // MVN
    }

    if (write) regs.r[rd] = res;

    if (arith) {
      regs.setNZCV(res.bit31, res == 0, aluCarry, aluOverflow);
    } else {
      regs.setNZ(res.bit31, res == 0);
      // Shift operations update C; logical operations leave it as is.
      if (code == 0x2 || code == 0x3 || code == 0x4 || code == 0x7) {
        regs.cf = shiftCarry;
      }
    }
    return 1;
  }

  // Format 5: hi register operations / BX.
  int _thHiReg(int op) {
    final code = op.shr8.mask2;
    final rd = op.mask3 | op.shr4 & 8;
    final rs = op.shr3.mask3 | op.shr3 & 8;
    final a = regs.r[rd];
    final b = regs.r[rs];
    switch (code) {
      case 0: // ADD (no flags)
        final res = (a + b).mask32;
        if (rd == 15) {
          branchTo(res);
        } else {
          regs.r[rd] = res;
        }
      case 1: // CMP (flags only)
        final res = sbc(a, b, 1);
        regs.setNZCV(res.bit31, res == 0, aluCarry, aluOverflow);
      case 2: // MOV (no flags)
        if (rd == 15) {
          branchTo(b);
        } else {
          regs.r[rd] = b;
        }
      default: // 3: BX
        bx(b);
    }
    return code == 3 || rd == 15 ? 3 : 1;
  }

  // Format 6: PC-relative load.
  int _thLdrPc(int op) {
    final rd = op.shr8.mask3;
    final imm = op.mask8.shl2;
    final addr = ((regs.r[15] & ~2) + imm).mask32;
    regs.r[rd] = readMem(addr & ~3, 4);
    return 3;
  }

  // Format 7: load/store with register offset.
  int _thLdStReg(int op) {
    final load = op.bit11;
    final byte = op.bit10;
    final ro = op.shr6.mask3;
    final rb = op.shr3.mask3;
    final rd = op.mask3;
    final addr = (regs.r[rb] + regs.r[ro]).mask32;
    if (load) {
      regs.r[rd] = byte ? readMem(addr, 1) : loadWordRotated(addr);
      return 3;
    } else {
      if (byte) {
        writeMem(addr, 1, regs.r[rd]);
      } else {
        writeMem(addr, 4, regs.r[rd]);
      }
      return 2;
    }
  }

  // Format 8: load/store sign-extended byte/halfword.
  int _thLdStSign(int op) {
    final h = op.bit11;
    final s = op.bit10;
    final ro = op.shr6.mask3;
    final rb = op.shr3.mask3;
    final rd = op.mask3;
    final addr = (regs.r[rb] + regs.r[ro]).mask32;
    if (!s && !h) {
      // STRH
      writeMem(addr, 2, regs.r[rd].mask16);
      return 2;
    } else if (!s && h) {
      // LDRH
      regs.r[rd] = loadHalfRotated(addr);
      return 3;
    } else if (s && !h) {
      // LDRSB
      regs.r[rd] = readMem(addr, 1).rel8.mask32;
      return 3;
    } else {
      // LDRSH (a misaligned address reads a signed byte)
      if (addr.bit0) {
        regs.r[rd] = readMem(addr, 1).rel8.mask32;
      } else {
        regs.r[rd] = readMem(addr, 2).rel16.mask32;
      }
      return 3;
    }
  }

  // Format 9: load/store with immediate offset.
  int _thLdStImm(int op) {
    final byte = op.bit12;
    final load = op.bit11;
    final offset = op.shr6.mask5;
    final rb = op.shr3.mask3;
    final rd = op.mask3;
    final addr = (regs.r[rb] + (byte ? offset : offset.shl2)).mask32;
    if (load) {
      regs.r[rd] = byte ? readMem(addr, 1) : loadWordRotated(addr);
      return 3;
    } else {
      if (byte) {
        writeMem(addr, 1, regs.r[rd]);
      } else {
        writeMem(addr, 4, regs.r[rd]);
      }
      return 2;
    }
  }

  // Format 10: load/store halfword.
  int _thLdStHalf(int op) {
    final load = op.bit11;
    final offset = op.shr6.mask5.shl1;
    final rb = op.shr3.mask3;
    final rd = op.mask3;
    final addr = (regs.r[rb] + offset).mask32;
    if (load) {
      regs.r[rd] = loadHalfRotated(addr);
      return 3;
    } else {
      writeMem(addr, 2, regs.r[rd].mask16);
      return 2;
    }
  }

  // Format 11: SP-relative load/store.
  int _thLdStSp(int op) {
    final load = op.bit11;
    final rd = op.shr8.mask3;
    final imm = op.mask8.shl2;
    final addr = (regs.r[13] + imm).mask32;
    if (load) {
      regs.r[rd] = loadWordRotated(addr);
      return 3;
    } else {
      writeMem(addr, 4, regs.r[rd]);
      return 2;
    }
  }

  // Format 12: load address (PC/SP + immediate).
  int _thLoadAddr(int op) {
    final useSp = op.bit11;
    final rd = op.shr8.mask3;
    final imm = op.mask8.shl2;
    final base = useSp ? regs.r[13] : (regs.r[15] & ~2);
    regs.r[rd] = (base + imm).mask32;
    return 1;
  }

  // Format 13: add offset to stack pointer.
  int _thAddSp(int op) {
    final imm = op.mask7.shl2;
    final sub = op.bit7;
    regs.r[13] = (regs.r[13] + (sub ? -imm : imm)).mask32;
    return 1;
  }

  // Format 14: push/pop registers.
  int _thPushPop(int op) {
    final load = op.bit11; // pop
    final pclr = op.bit8;
    final list = op.mask8;

    final regsInList = <int>[
      for (var i = 0; i < 8; i++)
        if (list & (1 << i) != 0) i,
    ];

    if (load) {
      // POP: ascending from SP.
      var addr = regs.r[13];
      for (final r in regsInList) {
        regs.r[r] = readMem(addr & ~3, 4);
        addr += 4;
      }
      if (pclr) {
        final v = readMem(addr & ~3, 4);
        addr += 4;
        regs.r[13] = addr.mask32;
        branchTo(v & ~1); // ARMv4: stays in Thumb state
        return regsInList.length + 3;
      }
      regs.r[13] = addr.mask32;
      return regsInList.length + 2;
    } else {
      // PUSH: descending, lowest register at the lowest address.
      final count = regsInList.length + (pclr ? 1 : 0);
      var addr = (regs.r[13] - count * 4).mask32;
      regs.r[13] = addr;
      for (final r in regsInList) {
        writeMem(addr & ~3, 4, regs.r[r]);
        addr += 4;
      }
      if (pclr) writeMem(addr & ~3, 4, regs.r[14]);
      return count + 1;
    }
  }

  // Format 15: multiple load/store.
  int _thBlock(int op) {
    final load = op.bit11;
    final rb = op.shr8.mask3;
    final list = op.mask8;

    final regsInList = <int>[
      for (var i = 0; i < 8; i++)
        if (list & (1 << i) != 0) i,
    ];

    var addr = regs.r[rb];

    if (regsInList.isEmpty) {
      // Empty list edge case: transfers r15, base moves by 0x40.
      if (load) {
        branchTo(readMem(addr & ~3, 4));
      } else {
        writeMem(addr & ~3, 4, (regs.r[15] + 2).mask32);
      }
      regs.r[rb] = (addr + 0x40).mask32;
      return 3;
    }

    if (load) {
      for (final r in regsInList) {
        regs.r[r] = readMem(addr & ~3, 4);
        addr += 4;
      }
      // Writeback unless the base was in the list.
      if (!list.bit(rb)) regs.r[rb] = addr.mask32;
      return regsInList.length + 2;
    } else {
      final writeback = (addr + regsInList.length * 4).mask32;
      var first = true;
      for (final r in regsInList) {
        var v = regs.r[r];
        if (r == rb && !first) v = writeback; // base not first: new value
        writeMem(addr & ~3, 4, v);
        addr += 4;
        first = false;
      }
      regs.r[rb] = writeback;
      return regsInList.length + 1;
    }
  }

  // Format 16: conditional branch.
  int _thCondBranch(int op) {
    final cond = op.shr8.mask4;
    if (!checkCond(cond)) return 1;
    final off = op.rel8.shl1;
    branchTo((regs.r[15] + off).mask32);
    return 3;
  }

  // Format 18: unconditional branch.
  int _thBranch(int op) {
    final off = op.rel11.shl1;
    branchTo((regs.r[15] + off).mask32);
    return 3;
  }

  // Format 19: long branch with link (two half-instructions).
  int _thLongBranch(int op) {
    final low = op.bit11; // second half
    if (!low) {
      // First half: LR = PC + (offset << 12).
      final off = op.rel11.shl12;
      regs.r[14] = (regs.r[15] + off).mask32;
      return 1;
    } else {
      // Second half: PC = LR + (offset << 1); LR = return address | 1.
      final off = op.mask11.shl1;
      final target = (regs.r[14] + off).mask32;
      regs.r[14] = ((regs.r[15] - 2) | 1).mask32;
      branchTo(target & ~1);
      return 3;
    }
  }
}
