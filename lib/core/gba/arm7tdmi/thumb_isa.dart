part of 'arm7.dart';

/// THUMB (16-bit) instruction set.
extension ThumbIsa on Arm7 {
  int _executeThumb(int op) {
    final hi = op >> 13;
    switch (hi) {
      case 0:
        return (op & 0x1800) == 0x1800 ? _thAddSub(op) : _thShift(op);
      case 1:
        return _thMovCmpImm(op);
      case 2:
        if ((op & 0x1000) != 0) {
          // bit12=1 -> load/store with register offset / sign-extended
          return (op & 0x0200) == 0 ? _thLdStReg(op) : _thLdStSign(op);
        }
        if ((op & 0x0800) != 0) return _thLdrPc(op); // bit11=1 -> PC load
        // bit12=0,bit11=0 -> ALU (bit10=0) or hi-register (bit10=1)
        return (op & 0x0400) == 0 ? _thAlu(op) : _thHiReg(op);
      case 3:
        return _thLdStImm(op);
      case 4:
        return (op & 0x1000) == 0 ? _thLdStHalf(op) : _thLdStSp(op);
      case 5:
        if ((op & 0x1000) == 0) return _thLoadAddr(op);
        if ((op & 0x0f00) == 0x0000) return _thAddSp(op);
        return _thPushPop(op);
      case 6:
        if ((op & 0x1000) == 0) return _thBlock(op);
        if ((op & 0x0f00) == 0x0f00) {
          raiseSwi();
          return 3;
        }
        return _thCondBranch(op);
      default: // 7
        return (op & 0x1000) == 0 ? _thBranch(op) : _thLongBranch(op);
    }
  }

  // format 1: move shifted register
  int _thShift(int op) {
    final type = (op >> 11) & 3; // 0 LSL 1 LSR 2 ASR
    final offset = (op >> 6) & 0x1f;
    final rs = (op >> 3) & 7;
    final rd = op & 7;
    final res = _barrel(type, regs.r[rs], offset, imm: true);
    regs.r[rd] = res;
    regs.setNZ(res & 0x80000000 != 0, res == 0);
    regs.cf = _shiftC;
    return 1;
  }

  // format 2: add/subtract
  int _thAddSub(int op) {
    final imm = (op >> 10) & 1 != 0;
    final sub = (op >> 9) & 1 != 0;
    final rnOff = (op >> 6) & 7;
    final rs = (op >> 3) & 7;
    final rd = op & 7;
    final b = imm ? rnOff : regs.r[rnOff];
    final a = regs.r[rs];
    final res = sub ? _sbc(a, b, 1) : _adc(a, b, 0);
    regs.r[rd] = res;
    regs.setNZCV(res & 0x80000000 != 0, res == 0, _aluC, _aluV);
    return 1;
  }

  // format 3: move/compare/add/subtract immediate
  int _thMovCmpImm(int op) {
    final sub = (op >> 11) & 3;
    final rd = (op >> 8) & 7;
    final imm = op & 0xff;
    final a = regs.r[rd];
    switch (sub) {
      case 0: // MOV
        regs.r[rd] = imm;
        regs.setNZ(false, imm == 0);
        break;
      case 1: // CMP
        final res = _sbc(a, imm, 1);
        regs.setNZCV(res & 0x80000000 != 0, res == 0, _aluC, _aluV);
        break;
      case 2: // ADD
        final res = _adc(a, imm, 0);
        regs.r[rd] = res;
        regs.setNZCV(res & 0x80000000 != 0, res == 0, _aluC, _aluV);
        break;
      default: // SUB
        final res = _sbc(a, imm, 1);
        regs.r[rd] = res;
        regs.setNZCV(res & 0x80000000 != 0, res == 0, _aluC, _aluV);
        break;
    }
    return 1;
  }

  // format 4: ALU operations
  int _thAlu(int op) {
    final code = (op >> 6) & 0xf;
    final rs = (op >> 3) & 7;
    final rd = op & 7;
    final a = regs.r[rd];
    final b = regs.r[rs];
    int res;
    bool write = true;
    bool arith = false;

    switch (code) {
      case 0x0: res = a & b; break; // AND
      case 0x1: res = a ^ b; break; // EOR
      case 0x2: res = _barrel(0, a, b & 0xff, imm: false); break; // LSL
      case 0x3: res = _barrel(1, a, b & 0xff, imm: false); break; // LSR
      case 0x4: res = _barrel(2, a, b & 0xff, imm: false); break; // ASR
      case 0x5: res = _adc(a, b, regs.cf ? 1 : 0); arith = true; break; // ADC
      case 0x6: res = _sbc(a, b, regs.cf ? 1 : 0); arith = true; break; // SBC
      case 0x7: res = _barrel(3, a, b & 0xff, imm: false); break; // ROR
      case 0x8: res = a & b; write = false; break; // TST
      case 0x9: res = _sbc(0, b, 1); arith = true; break; // NEG
      case 0xa: res = _sbc(a, b, 1); arith = true; write = false; break; // CMP
      case 0xb: res = _adc(a, b, 0); arith = true; write = false; break; // CMN
      case 0xc: res = a | b; break; // ORR
      case 0xd: res = (a * b) & 0xffffffff; break; // MUL
      case 0xe: res = a & (~b & 0xffffffff); break; // BIC
      default: res = (~b) & 0xffffffff; break; // MVN
    }

    if (write) regs.r[rd] = res;

    if (arith) {
      regs.setNZCV(res & 0x80000000 != 0, res == 0, _aluC, _aluV);
    } else {
      regs.setNZ(res & 0x80000000 != 0, res == 0);
      // shift ops update C; logical ops leave C as-is
      if (code == 0x2 || code == 0x3 || code == 0x4 || code == 0x7) {
        regs.cf = _shiftC;
      }
    }
    return 1;
  }

  // format 5: hi register operations / BX
  int _thHiReg(int op) {
    final code = (op >> 8) & 3;
    final rd = (op & 7) | ((op >> 4) & 8);
    final rs = ((op >> 3) & 7) | ((op >> 3) & 8);
    final a = regs.r[rd];
    final b = regs.r[rs];
    switch (code) {
      case 0: // ADD (no flags)
        final res = (a + b) & 0xffffffff;
        if (rd == 15) {
          _setPC(res);
        } else {
          regs.r[rd] = res;
        }
        break;
      case 1: // CMP (flags only)
        final res = _sbc(a, b, 1);
        regs.setNZCV(res & 0x80000000 != 0, res == 0, _aluC, _aluV);
        break;
      case 2: // MOV (no flags)
        if (rd == 15) {
          _setPC(b);
        } else {
          regs.r[rd] = b;
        }
        break;
      default: // 3: BX
        _bx(b);
        break;
    }
    return code == 3 || rd == 15 ? 3 : 1;
  }

  // format 6: PC-relative load
  int _thLdrPc(int op) {
    final rd = (op >> 8) & 7;
    final imm = (op & 0xff) << 2;
    final addr = ((regs.r[15] & ~2) + imm) & 0xffffffff;
    regs.r[rd] = bus.read32(addr & ~3);
    return 3;
  }

  // format 7: load/store with register offset
  int _thLdStReg(int op) {
    final load = (op >> 11) & 1 != 0;
    final byte = (op >> 10) & 1 != 0;
    final ro = (op >> 6) & 7;
    final rb = (op >> 3) & 7;
    final rd = op & 7;
    final addr = (regs.r[rb] + regs.r[ro]) & 0xffffffff;
    if (load) {
      regs.r[rd] = byte ? bus.read8(addr) : _ldrWord(addr);
      return 3;
    } else {
      if (byte) {
        bus.write8(addr, regs.r[rd]);
      } else {
        bus.write32(addr & ~3, regs.r[rd]);
      }
      return 2;
    }
  }

  // format 8: load/store sign-extended byte/halfword
  int _thLdStSign(int op) {
    final h = (op >> 11) & 1 != 0;
    final s = (op >> 10) & 1 != 0;
    final ro = (op >> 6) & 7;
    final rb = (op >> 3) & 7;
    final rd = op & 7;
    final addr = (regs.r[rb] + regs.r[ro]) & 0xffffffff;
    if (!s && !h) {
      // STRH
      bus.write16(addr & ~1, regs.r[rd] & 0xffff);
      return 2;
    } else if (!s && h) {
      // LDRH
      final raw = bus.read16(addr & ~1);
      regs.r[rd] =
          (addr & 1 != 0) ? ((raw >>> 8) | (raw << 24)) & 0xffffffff : raw;
      return 3;
    } else if (s && !h) {
      // LDRSB
      regs.r[rd] = bus.read8(addr).toSigned(8) & 0xffffffff;
      return 3;
    } else {
      // LDRSH
      if (addr & 1 != 0) {
        regs.r[rd] = bus.read8(addr).toSigned(8) & 0xffffffff;
      } else {
        regs.r[rd] = bus.read16(addr).toSigned(16) & 0xffffffff;
      }
      return 3;
    }
  }

  // format 9: load/store with immediate offset
  int _thLdStImm(int op) {
    final byte = (op >> 12) & 1 != 0;
    final load = (op >> 11) & 1 != 0;
    final offset = (op >> 6) & 0x1f;
    final rb = (op >> 3) & 7;
    final rd = op & 7;
    final addr =
        (regs.r[rb] + (byte ? offset : offset << 2)) & 0xffffffff;
    if (load) {
      regs.r[rd] = byte ? bus.read8(addr) : _ldrWord(addr);
      return 3;
    } else {
      if (byte) {
        bus.write8(addr, regs.r[rd]);
      } else {
        bus.write32(addr & ~3, regs.r[rd]);
      }
      return 2;
    }
  }

  // format 10: load/store halfword
  int _thLdStHalf(int op) {
    final load = (op >> 11) & 1 != 0;
    final offset = ((op >> 6) & 0x1f) << 1;
    final rb = (op >> 3) & 7;
    final rd = op & 7;
    final addr = (regs.r[rb] + offset) & 0xffffffff;
    if (load) {
      final raw = bus.read16(addr & ~1);
      regs.r[rd] =
          (addr & 1 != 0) ? ((raw >>> 8) | (raw << 24)) & 0xffffffff : raw;
      return 3;
    } else {
      bus.write16(addr & ~1, regs.r[rd] & 0xffff);
      return 2;
    }
  }

  // format 11: SP-relative load/store
  int _thLdStSp(int op) {
    final load = (op >> 11) & 1 != 0;
    final rd = (op >> 8) & 7;
    final imm = (op & 0xff) << 2;
    final addr = (regs.r[13] + imm) & 0xffffffff;
    if (load) {
      regs.r[rd] = _ldrWord(addr);
      return 3;
    } else {
      bus.write32(addr & ~3, regs.r[rd]);
      return 2;
    }
  }

  // format 12: load address (PC/SP + imm)
  int _thLoadAddr(int op) {
    final useSp = (op >> 11) & 1 != 0;
    final rd = (op >> 8) & 7;
    final imm = (op & 0xff) << 2;
    final base = useSp ? regs.r[13] : (regs.r[15] & ~2);
    regs.r[rd] = (base + imm) & 0xffffffff;
    return 1;
  }

  // format 13: add offset to stack pointer
  int _thAddSp(int op) {
    final imm = (op & 0x7f) << 2;
    final sub = (op >> 7) & 1 != 0;
    regs.r[13] =
        (regs.r[13] + (sub ? -imm : imm)) & 0xffffffff;
    return 1;
  }

  // format 14: push/pop registers
  int _thPushPop(int op) {
    final load = (op >> 11) & 1 != 0; // pop
    final pclr = (op >> 8) & 1 != 0;
    final list = op & 0xff;

    final regsInList = <int>[];
    for (int i = 0; i < 8; i++) {
      if (list & (1 << i) != 0) regsInList.add(i);
    }

    if (load) {
      // POP: ascending from SP
      var addr = regs.r[13];
      for (final r in regsInList) {
        regs.r[r] = bus.read32(addr & ~3);
        addr += 4;
      }
      if (pclr) {
        final v = bus.read32(addr & ~3);
        addr += 4;
        regs.r[13] = addr & 0xffffffff;
        _setPC(v & ~1); // ARMv4: stays THUMB
        return regsInList.length + 3;
      }
      regs.r[13] = addr & 0xffffffff;
      return regsInList.length + 2;
    } else {
      // PUSH: descending, lowest reg at lowest address
      final count = regsInList.length + (pclr ? 1 : 0);
      var addr = (regs.r[13] - count * 4) & 0xffffffff;
      regs.r[13] = addr;
      for (final r in regsInList) {
        bus.write32(addr & ~3, regs.r[r]);
        addr += 4;
      }
      if (pclr) bus.write32(addr & ~3, regs.r[14]);
      return count + 1;
    }
  }

  // format 15: multiple load/store
  int _thBlock(int op) {
    final load = (op >> 11) & 1 != 0;
    final rb = (op >> 8) & 7;
    final list = op & 0xff;

    final regsInList = <int>[];
    for (int i = 0; i < 8; i++) {
      if (list & (1 << i) != 0) regsInList.add(i);
    }

    var addr = regs.r[rb];

    if (regsInList.isEmpty) {
      // empty list edge case: transfers r15, base += 0x40
      if (load) {
        _setPC(bus.read32(addr & ~3));
      } else {
        bus.write32(addr & ~3, (regs.r[15] + 2) & 0xffffffff);
      }
      regs.r[rb] = (addr + 0x40) & 0xffffffff;
      return 3;
    }

    if (load) {
      for (final r in regsInList) {
        regs.r[r] = bus.read32(addr & ~3);
        addr += 4;
      }
      // writeback unless base was in list
      if (list & (1 << rb) == 0) regs.r[rb] = addr & 0xffffffff;
      return regsInList.length + 2;
    } else {
      final writeback = (addr + regsInList.length * 4) & 0xffffffff;
      var first = true;
      for (final r in regsInList) {
        var v = regs.r[r];
        if (r == rb && !first) v = writeback; // base not first -> new value
        bus.write32(addr & ~3, v);
        addr += 4;
        first = false;
      }
      regs.r[rb] = writeback;
      return regsInList.length + 1;
    }
  }

  // format 16: conditional branch
  int _thCondBranch(int op) {
    final cond = (op >> 8) & 0xf;
    if (!checkCond(cond)) return 1;
    final off = (op & 0xff).toSigned(8) << 1;
    _setPC((regs.r[15] + off) & 0xffffffff);
    return 3;
  }

  // format 18: unconditional branch
  int _thBranch(int op) {
    final off = (op & 0x7ff).toSigned(11) << 1;
    _setPC((regs.r[15] + off) & 0xffffffff);
    return 3;
  }

  // format 19: long branch with link (two half-instructions)
  int _thLongBranch(int op) {
    final low = (op >> 11) & 1 != 0; // second half
    if (!low) {
      // first half: LR = PC + (offset<<12)
      final off = (op & 0x7ff).toSigned(11) << 12;
      regs.r[14] = (regs.r[15] + off) & 0xffffffff;
      return 1;
    } else {
      // second half: PC = LR + (offset<<1); LR = next | 1
      final off = (op & 0x7ff) << 1;
      final target = (regs.r[14] + off) & 0xffffffff;
      final retLr = ((regs.r[15] - 2) | 1) & 0xffffffff;
      regs.r[14] = retLr;
      _setPC(target & ~1);
      return 3;
    }
  }
}
