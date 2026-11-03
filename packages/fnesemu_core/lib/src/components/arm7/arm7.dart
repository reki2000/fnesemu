import 'dart:typed_data';

import '../../util/int.dart';
import 'regs.dart';

part 'thumb.dart';

/// Shared ARM7-family instruction execution engine.
///
/// Holds the register file and executes the ARM instruction set both
/// cores share: data processing, multiply, single and block transfers,
/// swaps, branches and PSR transfers. The Thumb instruction set is part
/// of the engine too and runs only on cores that enable it.
///
/// The two embeddings differ in policy, not in shared semantics, so the
/// differences sit behind small hooks in the style of the shared R3000
/// core: memory access and opcode fetch, exception entry for SWI and
/// undefined instructions, cycle costs, the MSR writable mask, the CPSR
/// write mask, and strict handling of encodings the ARM7DI prohibits.
/// The ARM7DI embedding runs with [strict] set: encodings it prohibits
/// fault through [unsupported] before they have any effect, and its
/// tuned cycle accounting comes from its cost hook overrides. The
/// ARM7TDMI embedding is lenient and keeps its flat cycle costs.
///
/// r[15] in the register file is the fetch pointer (see [Arm7Regs]);
/// execution derives the executing instruction's address from it and
/// redirects it through an internal next-PC, exactly like the ARM7DI
/// interpreter did. Branches, loads to PC and exception entries set the
/// next PC; the sequential advance happens once per instruction.
abstract class Arm7Core {
  Arm7Core({
    Uint32List? registers,
    required this.hasThumb,
    required this.armV4,
    this.strict = false,
    Never Function(String message)? onUnsupported,
  })  : unsupported = onUnsupported ??
            ((String message) => throw StateError(message)),
        regs = Arm7Regs(
          registers: registers,
          strictModes: strict,
          spsrThrowsInUserBank: strict,
          onFault: onUnsupported,
        ) {
    // Execution starts at address 0, the fetch pointer 8 past it.
    regs.r[15] = 8;
  }

  /// The shared register file; also the compiled code's register store
  /// when an embedding shares it with a JIT context.
  final Arm7Regs regs;

  /// Whether the core executes Thumb state (ARM7TDMI only).
  final bool hasThumb;

  /// Whether ARMv4 extensions beyond the ARM7DI's ARMv3 set are present:
  /// long multiply and halfword transfers. The TDMI sets it, the DI
  /// core faults on those encodings instead.
  final bool armV4;

  /// Whether prohibited encodings fault and the ARM7DI's other strict
  /// checks apply (its MSR form, its bank restore order, its SPSR
  /// restore on data processing to PC).
  final bool strict;

  /// Faults an encoding or state the core prohibits, in the embedding's
  /// own error type. Never invoked on a lenient core.
  final Never Function(String message) unsupported;

  /// Carry-out of the barrel shifter, consumed by logical operations.
  /// Public because an embedding serializes it in its CPU state.
  bool shiftCarry = false;

  /// Carry and overflow of the last arithmetic ALU operation. Public
  /// because an embedding serializes them in its CPU state.
  bool aluCarry = false, aluOverflow = false;

  int _pc = 0; // address of the executing instruction
  int _nextPc = 0; // address of the next instruction

  /// The address of the instruction [execArm] or [execThumb] executes,
  /// also what exception links and PC-relative reads derive from.
  int get execPc => _pc;

  /// Fetches the instruction at [address], already aligned by the
  /// caller to the current instruction width.
  int fetch(int address);

  /// Reads [size] bytes (1, 2 or 4) at [address] for a data access.
  int readMem(int address, int size);

  /// Writes [value] as [size] bytes (1, 2 or 4) at [address]. Word
  /// stores pass the raw address; the embedding's bus applies the same
  /// alignment it always applied.
  void writeMem(int address, int size, int value);

  /// Enters the supervisor exception for a software interrupt. The
  /// caller charges the 3 cycles both cores charge.
  void onSwi();

  /// Enters the undefined-instruction exception (also used for
  /// coprocessor encodings neither core has hardware for). The caller
  /// charges the 3 cycles both cores charge.
  void onUndefined();

  /// Cycles for a short multiply whose Rs value is [rsValue]. The TDMI
  /// charges a flat 4; the DI core overrides this with its early
  /// termination model.
  int multiplyCycles(int rsValue) => 4;

  /// Cycles for a single-data-transfer load; [toPc] says the load
  /// branches. The TDMI charges 3 either way, the DI core 5 to PC.
  int singleLoadCycles(bool toPc) => 3;

  /// Cycles for a block-transfer load of [count] registers; [toPc] says
  /// the list ends at PC. The TDMI charges count + 2 either way, the DI
  /// core count + 4 to PC.
  int blockLoadCycles(int count, bool toPc) => count + 2;

  /// Cycles for a data-processing instruction. The TDMI charges 1, 2
  /// with a register-controlled shift, and 3 when the result branches.
  /// The DI core charges the base plus 2 when the result branches.
  int dataProcCycles(bool registerShift, bool toPc) =>
      toPc ? 3 : (registerShift ? 2 : 1);

  /// The mask of CPSR/SPSR bits an MSR may write on this core.
  int msrMask(int op, bool toSpsr);

  /// The mask applied to whole-CPSR writes (mode changes, exception
  /// entry, MSR, restores). The DI core clears the Thumb and reserved
  /// bits; the TDMI core stores values unchanged.
  int get cpsrWriteMask => 0xffffffff;

  /// Restores the CPSR from the SPSR on an exception-return form. The
  /// TDMI core uses the register file's restore, which is a no-op in
  /// user and system modes; the DI core overrides this to copy its SPSR
  /// unconditionally (its SPSR access faults in user mode first).
  void restoreCpsr() => regs.restoreCpsr();

  /// Executes one ARM-state instruction and returns its cycle count.
  /// The instruction address is derived from the fetch pointer.
  @pragma('vm:unsafe:no-bounds-checks')
  int execArm(int op) {
    final cost = _execArm(op);
    _advance();
    return cost;
  }

  /// Executes one Thumb-state instruction and returns its cycle count.
  @pragma('vm:unsafe:no-bounds-checks')
  int execThumb(int op) {
    final cost = _execThumb(op);
    _advance();
    return cost;
  }

  /// Points the fetch pointer past [_nextPc] in the (possibly new)
  /// current state.
  void _advance() {
    regs.r[15] = (_nextPc + (regs.thumb ? 4 : 8)).mask32;
  }

  /// Redirects execution to [address], aligned to the current state's
  /// instruction width.
  void branchTo(int address) {
    _nextPc = address & (regs.thumb ? ~1 : ~3);
  }

  /// Branch-and-exchange: bit 0 of [address] selects Thumb state.
  void bx(int address) {
    regs.thumb = address.bit0;
    branchTo(address);
  }

  /// Writes register [n]; writing r15 branches.
  void writeReg(int n, int v) {
    if (n == 15) {
      branchTo(v);
    } else {
      regs.r[n] = v.mask32;
    }
  }

  /// Reads register [n] as an instruction operand; r15 reads as the
  /// executing address plus [ahead] (8 normally, 12 for register shifts
  /// and stores, matching the pipeline both cores model).
  int regRead(int n, [int ahead = 8]) =>
      n == 15 ? (_pc + ahead).mask32 : regs.r[n];

  /// Reads the user-bank value of register [n] for a block transfer
  /// with the S bit. r15 is handled by the transfer itself.
  int readUserReg(int n) =>
      n < 8 || n == 15 ? regs.r[n] : regs.userModeReg(n);

  /// Writes the user-bank value of register [n] for a block transfer
  /// with the S bit.
  void writeUserReg(int n, int v) {
    if (n < 8 || n == 15) {
      regs.r[n] = v;
    } else {
      regs.setUserModeReg(n, v);
    }
  }

  /// Enters an exception at [vector]: banks to [mode], saves the CPSR
  /// in the new mode's SPSR, sets its LR to [link], disables IRQ (and
  /// FIQ for the fast interrupt), leaves Thumb state, and redirects
  /// execution to the vector.
  void enterException(int vector, int mode, int link, {bool fiq = false}) {
    final saved = regs.cpsr;
    regs.setCpsrBanked(
        (saved & ~0x3f) | mode | 0x80 | (fiq ? 0x40 : 0), cpsrWriteMask);
    regs.spsr = saved;
    regs.r[14] = link.mask32;
    _nextPc = vector;
    regs.r[15] = vector + 8;
  }

  /// Condition-code evaluation (the executing core's NZCV).
  bool checkCond(int cond) => switch (cond) {
        0x0 => regs.zf, // EQ
        0x1 => !regs.zf, // NE
        0x2 => regs.cf, // CS
        0x3 => !regs.cf, // CC
        0x4 => regs.nf, // MI
        0x5 => !regs.nf, // PL
        0x6 => regs.vf, // VS
        0x7 => !regs.vf, // VC
        0x8 => regs.cf && !regs.zf, // HI
        0x9 => !regs.cf || regs.zf, // LS
        0xa => regs.nf == regs.vf, // GE
        0xb => regs.nf != regs.vf, // LT
        0xc => !regs.zf && (regs.nf == regs.vf), // GT
        0xd => regs.zf || (regs.nf != regs.vf), // LE
        0xe => true, // AL
        _ => false, // NV (reserved)
      };

  /// Barrel shifter. [type] is 0 LSL, 1 LSR, 2 ASR, 3 ROR. [imm] selects
  /// the immediate-form special cases (a zero amount means 32, or RRX
  /// for ROR); the register form takes the amount modulo 256 with its
  /// own edge cases. Records the carry-out in [shiftCarry].
  int barrelShift(int type, int v, int amount, {required bool imm}) {
    v &= 0xffffffff;
    if (imm) {
      switch (type) {
        case 0: // LSL
          if (amount == 0) {
            shiftCarry = regs.cf; // C unchanged
            return v;
          }
          shiftCarry = v.shr(32 - amount).bit0;
          return v.shl(amount).mask32;
        case 1: // LSR (#0 means #32)
          if (amount == 0) {
            shiftCarry = v.bit31;
            return 0;
          }
          shiftCarry = v.shr(amount - 1).bit0;
          return v >>> amount;
        case 2: // ASR (#0 means #32)
          if (amount == 0) {
            shiftCarry = v.bit31;
            return shiftCarry ? 0xffffffff : 0;
          }
          shiftCarry = v.shr(amount - 1).bit0;
          return v.rel32.shr(amount).mask32;
        default: // 3: ROR (#0 means RRX)
          if (amount == 0) {
            final cin = regs.cf ? 1 : 0;
            shiftCarry = v.bit0;
            return (v >>> 1 | cin.shl31).mask32;
          }
          shiftCarry = v.shr(amount - 1).bit0;
          return (v >>> amount | v.shl(32 - amount)).mask32;
      }
    } else {
      // Register form.
      if (amount == 0) {
        shiftCarry = regs.cf; // C unchanged, value passes through
        return v;
      }
      switch (type) {
        case 0: // LSL
          if (amount < 32) {
            shiftCarry = v.shr(32 - amount).bit0;
            return v.shl(amount).mask32;
          }
          if (amount == 32) {
            shiftCarry = v.bit0;
            return 0;
          }
          shiftCarry = false;
          return 0;
        case 1: // LSR
          if (amount < 32) {
            shiftCarry = v.shr(amount - 1).bit0;
            return v >>> amount;
          }
          if (amount == 32) {
            shiftCarry = v.bit31;
            return 0;
          }
          shiftCarry = false;
          return 0;
        case 2: // ASR
          if (amount < 32) {
            shiftCarry = v.shr(amount - 1).bit0;
            return v.rel32.shr(amount).mask32;
          }
          shiftCarry = v.bit31;
          return shiftCarry ? 0xffffffff : 0;
        default: // 3: ROR
          final a = amount.mask5;
          if (a == 0) {
            shiftCarry = v.bit31;
            return v;
          }
          shiftCarry = v.shr(a - 1).bit0;
          return (v >>> a | v.shl(32 - a)).mask32;
      }
    }
  }

  /// Add with carry; records carry and overflow in [aluCarry] and
  /// [aluOverflow].
  int adc(int a, int b, int cin) {
    final sum = a + b + cin; // Dart ints are 64-bit, no overflow to 2^33
    aluCarry = sum > 0xffffffff;
    final res = sum.mask32;
    aluOverflow = ((a ^ res) & (b ^ res)).bit31;
    return res;
  }

  /// Subtract with carry (a - b - (1 - cin)); records carry and
  /// overflow like [adc].
  int sbc(int a, int b, int cin) => adc(a, (~b).mask32, cin);

  /// Loads a word with the ARM unaligned-rotate behaviour.
  int loadWordRotated(int address) {
    final v = readMem(address & ~3, 4);
    final rot = address.mask2 * 8;
    return rot == 0 ? v : (v >>> rot | v.shl(32 - rot)).mask32;
  }

  /// Loads a halfword; an odd address reads the aligned halfword
  /// rotated by 8, as the TDMI does.
  int loadHalfRotated(int address) {
    final raw = readMem(address & ~1, 2);
    return address.bit0 ? (raw >>> 8 | raw.shl24).mask32 : raw;
  }

  @pragma('vm:unsafe:no-bounds-checks')
  int _execArm(int op) {
    _pc = regs.r[15] - 8;
    _nextPc = _pc + 4;
    final cond = op >>> 28;
    if (cond != 0xe && !checkCond(cond)) return 1;

    // BX (0001 0010 1111 1111 1111 0001 Rn) exists only with Thumb. On
    // the DI core the encoding decodes as TEQ with S clear, which its
    // data processing faults as a reserved PSR encoding.
    if ((op & 0x0ffffff0) == 0x012fff10) {
      if (!hasThumb) unsupported('ARM7DI reserved PSR encoding');
      bx(regs.r[op & 15]);
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
      case 0x6: // 0b110: coprocessor transfers
        // The DI core traps these as undefined. The TDMI core has no
        // coprocessor either, but its decoder has always fallen through
        // to data processing for this space, so it keeps doing so.
        if (strict) {
          onUndefined();
          return 3;
        }
        return _armDataProc(op);
      case 0x7: // 0b111
        // Bit 24 set is SWI; the rest is coprocessor space, undefined
        // on both cores.
        if (op.bit24) {
          onSwi();
          return 3;
        }
        onUndefined();
        return 3;
      default: // 0b000 / 0b001
        if (kind == 0x0 && (op & 0x90) == 0x90) {
          // Bit 7 and bit 4 set: multiply / swap / halfword space.
          if ((op & 0x60) == 0) {
            return op.bit24 ? _armSwap(op) : _armMultiply(op);
          }
          if (!armV4) {
            unsupported('ARM7DI reserved instruction: ${op.x8}');
          }
          return _armHalf(op);
        }
        return _armDataProc(op);
    }
  }

  // --- branch ---------------------------------------------------------------

  int _armBranch(int op) {
    final off = op.rel24.shl2;
    if (op.bit24) regs.r[14] = (_pc + 4).mask32; // link: return address
    branchTo((_pc + 8 + off).mask32);
    return 3;
  }

  // --- data processing / PSR transfer ---------------------------------------

  int _armDataProc(int op) {
    final code = op.shr21.mask4;
    final s = op.bit20;
    final rn = op.shr16.mask4;
    final rd = op.shr12.mask4;
    final test = code >= 8 && code <= 11;

    // PSR transfers hide in the test opcodes when S is clear.
    if (!s && (code & 0xc) == 0x8) {
      if (strict) _checkPsrEncoding(op);
      return op.bit21 ? _armMsr(op) : _armMrs(op);
    }
    // The DI core faults test encodings with S clear that are not PSR
    // transfers (CMP/CMN forms); the TDMI core executes them.
    if (strict && test && !s) {
      unsupported('ARM7DI reserved PSR encoding');
    }

    final imm = op.bit25;
    final regShift = !imm && op.bit4;

    // The DI core's legacy status test with rd = PC: only TEQ is
    // defined (DDI 0027D), copying the SPSR to the CPSR in privileged
    // modes before any operand is read.
    if (strict && test && rd == 15) {
      if (code != 9) {
        unsupported('ARM7DI deprecated status-test encoding');
      }
      if (regs.mode != CpuMode.usr) {
        regs.setCpsrBanked(regs.spsr, cpsrWriteMask);
      }
      return regShift ? 2 : 1;
    }

    // Operand 2. r15 reads as PC + 12 with a register shift, else + 8.
    final ahead = regShift ? 12 : 8;
    int op2;
    if (imm) {
      final value = op.mask8;
      final rot = op.shr8.mask4 * 2;
      if (rot == 0) {
        op2 = value;
        shiftCarry = regs.cf;
      } else {
        op2 = (value >>> rot | value.shl(32 - rot)).mask32;
        shiftCarry = op2.bit31;
      }
    } else {
      final type = op.shr5.mask2;
      final rm = op.mask4;
      if (regShift) {
        final amount = regs.r[op.shr8.mask4].mask8;
        op2 = barrelShift(type, regRead(rm, ahead), amount, imm: false);
      } else {
        final amount = op.shr7.mask5;
        op2 = barrelShift(type, regRead(rm, ahead), amount, imm: true);
      }
    }

    final a = regRead(rn, ahead);
    int res;
    var write = true;
    var logical = false;
    switch (code) {
      case 0x0:
        res = a & op2;
        logical = true; // AND
      case 0x1:
        res = a ^ op2;
        logical = true; // EOR
      case 0x2:
        res = sbc(a, op2, 1); // SUB
      case 0x3:
        res = sbc(op2, a, 1); // RSB
      case 0x4:
        res = adc(a, op2, 0); // ADD
      case 0x5:
        res = adc(a, op2, regs.cf ? 1 : 0); // ADC
      case 0x6:
        res = sbc(a, op2, regs.cf ? 1 : 0); // SBC
      case 0x7:
        res = sbc(op2, a, regs.cf ? 1 : 0); // RSC
      case 0x8:
        res = a & op2;
        logical = true;
        write = false; // TST
      case 0x9:
        res = a ^ op2;
        logical = true;
        write = false; // TEQ
      case 0xa:
        res = sbc(a, op2, 1);
        write = false; // CMP
      case 0xb:
        res = adc(a, op2, 0);
        write = false; // CMN
      case 0xc:
        res = a | op2;
        logical = true; // ORR
      case 0xd:
        res = op2;
        logical = true; // MOV
      case 0xe:
        res = a & (~op2).mask32;
        logical = true; // BIC
      default:
        res = (~op2).mask32;
        logical = true; // MVN
    }

    if (write) {
      if (rd == 15) {
        // A write to PC branches; with S set it is an exception return
        // and restores the CPSR from the SPSR first. Flags from the
        // operation itself are discarded either way.
        if (s) restoreCpsr();
        branchTo(res);
        return dataProcCycles(regShift, true);
      }
      regs.r[rd] = res;
    } else if (rd == 15 && s && !strict) {
      // A test with rd = PC and S set (the old TEQP form) copies the
      // SPSR to the CPSR and updates no flags. The DI core's form of
      // this was handled before the operands above.
      restoreCpsr();
      return 1;
    }

    if (s) {
      if (logical) {
        regs.setNZ(res.bit31, res == 0);
        regs.cf = shiftCarry;
      } else {
        regs.setNZCV(res.bit31, res == 0, aluCarry, aluOverflow);
      }
    }
    return dataProcCycles(regShift, false);
  }

  /// Faults PSR-transfer encodings outside the canonical MRS/MSR forms
  /// the DI core accepts.
  void _checkPsrEncoding(int op) {
    final canonical = (op & 0x0fbf0fff) == 0x010f0000 ||
        (op & 0x0fbffff0) == 0x0129f000 ||
        (op & 0x0fbffff0) == 0x0128f000 ||
        (op & 0x0fbff000) == 0x0328f000;
    if (!canonical) unsupported('ARM7DI reserved PSR encoding');
  }

  int _armMrs(int op) {
    final rd = op.shr12.mask4;
    if (strict && rd == 15) unsupported('ARM7DI MRS PC');
    regs.r[rd] = op.bit22 ? regs.spsr : regs.cpsr;
    return 1;
  }

  int _armMsr(int op) {
    final toSpsr = op.bit22;
    int value;
    if (op.bit25) {
      final imm = op.mask8;
      final rot = op.shr8.mask4 * 2;
      value = rot == 0 ? imm : (imm >>> rot | imm.shl(32 - rot)).mask32;
    } else {
      if (strict && op.mask4 == 15) unsupported('ARM7DI MSR PC');
      value = regs.r[op.mask4];
    }
    final mask = msrMask(op, toSpsr);
    if (toSpsr) {
      regs.spsr = (regs.spsr & ~mask) | (value & mask);
    } else {
      regs.setCpsrBanked((regs.cpsr & ~mask) | (value & mask), cpsrWriteMask);
    }
    return 1;
  }

  // --- multiply ---------------------------------------------------------------

  int _armMultiply(int op) {
    final s = op.bit20;
    if (!op.bit23) {
      // Short multiply (MUL/MLA).
      final rd = op.shr16.mask4;
      final rn = op.shr12.mask4;
      final rs = op.shr8.mask4;
      final rm = op.mask4;
      final acc = op.bit21;
      if (strict) {
        if (op.bit22) {
          unsupported('ARM7DI reserved instruction: ${op.x8}');
        }
        if (rd == 15 ||
            rn == 15 ||
            rs == 15 ||
            rm == 15 ||
            (acc && rd == rm)) {
          unsupported('ARM7DI prohibited multiply register combination');
        }
      }
      final a = regs.r[rm], b = regs.r[rs];
      // The DI core yields a zero product when rd == rm (its datasheet
      // behaviour for the prohibited-but-not-faulted combination).
      var res = strict && rd == rm ? 0 : (a * b).mask32;
      if (acc) res = (res + regs.r[rn]).mask32;
      regs.r[rd] = res;
      if (s) regs.setNZ(res.bit31, res == 0);
      return multiplyCycles(b);
    }

    // Long multiply (UMULL/UMLAL/SMULL/SMLAL), ARMv4 only.
    if (!armV4) unsupported('ARM7DI reserved instruction: ${op.x8}');
    final rdHi = op.shr16.mask4;
    final rdLo = op.shr12.mask4;
    final rs = op.shr8.mask4;
    final rm = op.mask4;
    final signed = op.bit22;
    final acc = op.bit21;

    // 64-bit int arithmetic wraps modulo 2^64, so the low 64 bits of
    // the product (and accumulate) are exact even for UMULL/UMLAL.
    final m = signed ? regs.r[rm].rel32 : regs.r[rm];
    final multiplicand = signed ? regs.r[rs].rel32 : regs.r[rs];
    var prod = m * multiplicand;
    if (acc) prod += regs.r[rdHi] << 32 | regs.r[rdLo];
    final lo = prod.mask32;
    final hi = (prod >> 32).mask32;
    regs.r[rdLo] = lo;
    regs.r[rdHi] = hi;
    if (s) regs.setNZ(hi.bit31, hi == 0 && lo == 0);
    return 5;
  }

  // --- single data swap -------------------------------------------------------

  int _armSwap(int op) {
    final rn = op.shr16.mask4;
    final rd = op.shr12.mask4;
    final rm = op.mask4;
    if (strict && (rn == 15 || rd == 15 || rm == 15)) {
      unsupported('ARM7DI SWP PC');
    }
    final address = regs.r[rn];
    final byte = op.bit22;
    final value = byte ? readMem(address, 1) & 0xff : loadWordRotated(address);
    writeMem(byte ? address : address & ~3, byte ? 1 : 4, regs.r[rm]);
    regs.r[rd] = value;
    return 4;
  }

  // --- single data transfer (LDR/STR) -----------------------------------------

  int _armSingle(int op) {
    final regOffset = op.bit25; // 1 = register offset (shifted)
    final pre = op.bit24;
    final up = op.bit23;
    final byte = op.bit22;
    final wb = op.bit21;
    final load = op.bit20;
    final rn = op.shr16.mask4;
    final rd = op.shr12.mask4;
    final back = !pre || wb; // post-indexed transfers always write back

    // A register offset with bit 4 set is not a transfer encoding; the
    // DI core traps it as undefined before anything else.
    if (strict && regOffset && op.bit4) {
      onUndefined();
      return 3;
    }
    if (strict) {
      if (rn == 15 && back) unsupported('ARM7DI writeback to PC');
      if (byte && rd == 15) unsupported('ARM7DI byte transfer with PC');
      if (regOffset && (op.mask4 == 15 || (!pre && op.mask4 == rn))) {
        unsupported('ARM7DI prohibited transfer offset register');
      }
      if (load && back && rn == rd) {
        unsupported('ARM7DI load/writeback register overlap');
      }
    }

    int offset;
    if (!regOffset) {
      offset = op.mask12;
    } else {
      offset = barrelShift(op.shr5.mask2, regs.r[op.mask4], op.shr7.mask5,
          imm: true);
    }

    final base = regs.r[rn];
    final modified = (base + (up ? offset : -offset)).mask32;
    final address = pre ? modified : base;

    if (load) {
      final v = byte ? readMem(address, 1) & 0xff : loadWordRotated(address);
      // Writeback before the load result so Rn == Rd ends up with the
      // loaded value (the DI core faults that overlap instead).
      if (back) regs.r[rn] = modified;
      writeReg(rd, v);
      return singleLoadCycles(rd == 15);
    } else {
      writeMem(byte ? address : address & ~3, byte ? 1 : 4, regRead(rd, 12));
      if (back) regs.r[rn] = modified;
      return 2;
    }
  }

  // --- halfword / signed transfer (ARMv4) -------------------------------------

  int _armHalf(int op) {
    final pre = op.bit24;
    final up = op.bit23;
    final immForm = op.bit22;
    final wb = op.bit21;
    final load = op.bit20;
    final rn = op.shr16.mask4;
    final rd = op.shr12.mask4;
    final sh = op.shr5.mask2; // 01=H 10=SB 11=SH

    final offset = immForm ? op.shr8.mask4.shl4 | op.mask4 : regs.r[op.mask4];

    final base = regs.r[rn];
    final modified = (base + (up ? offset : -offset)).mask32;
    final address = pre ? modified : base;

    if (load) {
      int v;
      switch (sh) {
        case 1: // LDRH
          v = loadHalfRotated(address);
        case 2: // LDRSB
          v = readMem(address, 1).rel8.mask32;
        default: // 3: LDRSH (a misaligned address reads a signed byte)
          v = address.bit0
              ? readMem(address, 1).rel8.mask32
              : readMem(address, 2).rel16.mask32;
      }
      if (!pre || wb) regs.r[rn] = modified;
      writeReg(rd, v);
      return 3;
    } else {
      // STRH only. The stored register reads raw, so r15 stores the
      // fetch pointer, as the TDMI core has always done here.
      writeMem(address, 2, regs.r[rd].mask16);
      if (!pre || wb) regs.r[rn] = modified;
      return 2;
    }
  }

  // --- block data transfer (LDM/STM) ------------------------------------------

  int _armBlock(int op) {
    final pre = op.bit24;
    final up = op.bit23;
    final psr = op.bit22; // S bit
    final wb = op.bit21;
    final load = op.bit20;
    final rn = op.shr16.mask4;
    final list = <int>[
      for (var i = 0; i < 16; i++)
        if (op & (1 << i) != 0) i,
    ];
    final restore = psr && load && list.isNotEmpty && list.last == 15;
    final transferUser = psr && !restore;

    if (strict) {
      if (list.isEmpty || rn == 15 || (psr && regs.mode == CpuMode.usr)) {
        unsupported('ARM7DI prohibited block transfer');
      }
      if (transferUser && wb) {
        unsupported('ARM7DI user-bank block writeback');
      }
    }
    // The DI core reads and validates the SPSR before the transfer; its
    // CPSR is only committed after it (see below).
    final savedSpsr = restore && strict ? regs.spsr : 0;
    if (restore && strict) regs.bankIndex(savedSpsr);

    final count = list.isEmpty ? 16 : list.length;
    final base = regs.r[rn];
    final writeback = (base + (up ? count * 4 : -count * 4)).mask32;
    var address = (up
            ? base + (pre ? 4 : 0)
            : base - count * 4 + (pre ? 0 : 4))
        .mask32;

    if (load) {
      if (list.isEmpty) {
        // An empty list loads PC only, with the base moving by 0x40.
        final v = readMem(address & ~3, 4);
        if (wb) regs.r[rn] = writeback;
        branchTo(v);
        return 4;
      }
      // The TDMI core writes back before the loads so that an
      // `ldm rn!, {.., pc}^` updates rn in the current mode's bank, not
      // in the bank of the mode restored from the SPSR. The DI core
      // writes back after the transfer but still before its CPSR
      // commit, which lands the writeback in the same bank.
      if (!strict && wb && !list.contains(rn)) regs.r[rn] = writeback;
      for (final index in list) {
        final v = readMem(address & ~3, 4);
        address = (address + 4).mask32;
        if (transferUser) {
          writeUserReg(index, v);
        } else if (index == 15) {
          if (restore && !strict) regs.restoreCpsr();
          branchTo(v);
        } else {
          regs.r[index] = v;
        }
      }
      if (strict) {
        if (wb && !list.contains(rn)) regs.r[rn] = writeback;
        if (restore) regs.setCpsrBanked(savedSpsr, cpsrWriteMask);
      }
      return blockLoadCycles(count, list.last == 15);
    } else {
      if (list.isEmpty) {
        // An empty list stores PC only, with the base moving by 0x40.
        writeMem(address & ~3, 4, regRead(15, 12));
        if (wb) regs.r[rn] = writeback;
        return 3;
      }
      var first = true;
      for (final index in list) {
        int v;
        if (index == 15) {
          v = regRead(15, 12);
        } else if (transferUser) {
          v = readUserReg(index);
        } else {
          v = regs.r[index];
        }
        // The base stores its old value first in the list, the
        // written-back value after that.
        if (wb && index == rn && !first) v = writeback;
        writeMem(address & ~3, 4, v);
        address = (address + 4).mask32;
        first = false;
      }
      if (wb) regs.r[rn] = writeback;
      return count + 1;
    }
  }
}
