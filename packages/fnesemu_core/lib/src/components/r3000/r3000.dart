import 'dart:typed_data';

import '../../util/int.dart';
import 'bus.dart';
import 'coprocessor.dart';

/// The shared MIPS I (R3000 class) integer core and COP0 register file.
///
/// The two embeddings of this core, the PS CPU and the PS2 IOP, share the instruction execution, the load delay and branch delay state and the memory accessors below, and keep their differences in the subclass hooks: the COP0 register access policy ([readCop0] and [writeCop0]), the exception entry ([exception]), the treatment of absent coprocessors ([copAbsent]), whether misaligned accesses raise exceptions ([strictAlignment]), which REGIMM encodings link ([linksRegimm]), the step cycle with its interrupt test, and the reset state. The COP2 device is attached by the embedding that has one, through [cop2].
///
/// The general registers live in [r], whose storage the caller may supply, so that compiled code and the interpreter share it exactly as the embeddings did before the unification.
abstract class R3000Core {
  static const cop0BadVAddr = 8, cop0Status = 12, cop0Cause = 13, cop0Epc = 14;
  static const cop0PrId = 15;
  static const resetVector = 0xbfc00000;

  static const excInterrupt = 0, excAdEL = 4, excAdES = 5, excSyscall = 8;
  static const excBreak = 9, excReserved = 10, excCopUnusable = 11;
  static const excOverflow = 12;

  final R3000Bus bus;

  /// [regs] places the registers in memory shared with a recompiler.
  R3000Core(this.bus, {Uint32List? regs}) : r = regs ?? Uint32List(32);

  /// 32 general-purpose registers. Note: r0 is always 0.
  final Uint32List r;

  int pc = 0; // the PC (actually the next instruction during execution)
  int nextPc = 0; // the PC to be executed next, reflects branch delay slot
  int instPc = 0; // the PC of the current instruction

  /// HI and LO registers (used by multiply/divide instructions).
  int hi = 0, lo = 0;

  /// COP0 registers, indexed by register number; the variants expose their own views and access policies over this storage.
  final Uint32List cop0 = Uint32List(32);

  /// A simple clock counter, advanced by each variant's step cycle.
  int clocks = 0;

  //  slots to handle delay: a load issued by one instruction lands at the
  //  end of the next, and an ordinary register write lands at the end of
  //  its own instruction, behind a load still in flight
  int nextDelayReg = 0, nextDelayVal = 0;
  int delayReg = 0, delayVal = 0;
  int immediateReg = 0, immediateVal = 0;
  bool inBranchTaken = false;
  bool inBranchDelay = false;
  // the current instruction is in the delay slot of a branch (taken or not)
  bool inDelaySlot = false;
  bool delaySlotTaken = false;

  /// Whether misaligned halfword and word accesses raise address error exceptions, as on the IOP, instead of masking the address, as on the PS CPU.
  bool get strictAlignment => false;

  /// The attached COP2 device, or null when the embedding has none.
  R3000Cop2? get cop2 => null;

  /// Raises the exception [code] with the variant's entry sequence; [coprocessor] is the coprocessor number of a coprocessor-unusable exception.
  void exception(int code, {int coprocessor = 0, int? badvaddr});

  /// Reads COP0 register [reg] under the variant's access policy.
  int readCop0(int reg);

  /// Writes COP0 register [reg] under the variant's access policy.
  void writeCop0(int reg, int value);

  /// Handles an instruction for a coprocessor the embedding does not have: opcode [op] is the primary opcode, so the coprocessor number is `op & 3`.
  void copAbsent(int op) => exception(excReserved);

  /// Whether the REGIMM encoding [rt] writes the return address to r31, which differs between the variants for the encodings outside bltzal and bgezal.
  bool linksRegimm(int rt);

  /// Whether a COP0 instruction with sub-opcode [rs], other than the register transfers, is executed as a COP0 command: the PS CPU restricts commands to the command sub-opcodes, while the IOP tests the function field of every other sub-opcode.
  bool cop0CommandApplies(int rs);

  /// Records a memory access for the execution statistics of an embedding that collects them; the default records nothing.
  void recordMemory(int addr, int size, {bool write = false, bool fetch = false}) {}

  bool get cacheIsolated => cop0[cop0Status].bit16;

  int read8(int addr) {
    recordMemory(addr.mask32, 1);
    return bus.read8(addr.mask32).mask8;
  }

  int read16(int addr) {
    recordMemory(addr & 0xfffffffe, 2);
    return bus.read16(addr & 0xfffffffe).mask16;
  }

  int read32(int addr, {bool instruction = false}) {
    recordMemory(addr & 0xfffffffc, 4, fetch: instruction);
    return bus.read32(addr & 0xfffffffc);
  }

  void write8(int addr, int value) {
    if (cacheIsolated) return;
    recordMemory(addr.mask32, 1, write: true);
    bus.write8(addr.mask32, value.mask8);
  }

  void write16(int addr, int value) {
    if (cacheIsolated) return;
    recordMemory(addr & 0xfffffffe, 2, write: true);
    bus.write16(addr & 0xfffffffe, value.mask16);
  }

  void write32(int addr, int value) {
    if (cacheIsolated) return;
    recordMemory(addr & 0xfffffffc, 4, write: true);
    bus.write32(addr & 0xfffffffc, value.mask32);
  }

  /// Raises the reserved instruction exception instead of stopping the emulator.
  void unknownInstruction() => exception(excReserved);

  void delay(int dst, int val) {
    if (dst == delayReg) {
      delayReg = 0;
      delayVal = 0;
    }
    nextDelayReg = dst;
    nextDelayVal = val;
  }

  void immediate(int dst, int val) {
    immediateReg = dst;
    immediateVal = val;
  }

  void jumpTo(int addr) {
    inBranchTaken = true;
    inBranchDelay = true;
    nextPc = addr.mask32;
  }

  void branch(bool cond, int rel16) {
    inBranchDelay = true;
    if (cond) {
      jumpTo(pc + rel16.shl2);
    }
  }

  void jal(bool cond, int rd, int addr) {
    immediate(rd, pc.inc4.mask32);
    // The next instruction is in the delay slot even if not taken.
    inBranchDelay = true;

    if (cond) {
      jumpTo(addr);
    }
  }

  /// Executes a COP0 command word: RFE is the only command of MIPS I, and it pops the mode stack the same way in both variants.
  void execCop0Command(int inst32) {
    switch (inst32.mask6) {
      case 0x10: // rfe
        cop0[cop0Status] = cop0[cop0Status].masked(0x0f, cop0[cop0Status].shr2);
      default:
        unknownInstruction();
    }
  }

  int lwl(int addr, int org) {
    final value = read32(addr & 0xfffffffc);
    return switch (addr.mask2) {
      0 => value.mask8.shl24 | org.mask24,
      1 => value.mask16.shl16 | org.mask16,
      2 => value.mask24.shl8 | org.mask8,
      _ => value,
    };
  }

  int lwr(int addr, int org) {
    final value = read32(addr & 0xfffffffc);
    return switch (addr.mask2) {
      0 => value,
      1 => value.shr8 | org & 0xff000000,
      2 => value.shr16 | org & 0xffff0000,
      _ => value.shr24 | org & 0xffffff00,
    };
  }

  void swl(int addr, int value) {
    final aligned = addr & 0xfffffffc;
    switch (addr.mask2) {
      case 0:
        write32(aligned, value.shr24 | read32(aligned) & 0xffffff00);
      case 1:
        write32(aligned, value.shr16 | read32(aligned) & 0xffff0000);
      case 2:
        write32(aligned, value.shr8 | read32(aligned) & 0xff000000);
      case 3:
        write32(aligned, value);
    }
  }

  void swr(int addr, int value) {
    final aligned = addr & 0xfffffffc;
    switch (addr.mask2) {
      case 0:
        write32(aligned, value);
      case 1:
        write32(aligned, value.mask24.shl8 | read32(aligned).mask8);
      case 2:
        write32(aligned, value.mask16.shl16 | read32(aligned).mask16);
      case 3:
        write32(aligned, value.mask8.shl24 | read32(aligned).mask24);
    }
  }

  int sll(int value, int shift) => (value << shift.mask5).mask32;
  int srl(int value, int shift) => value.mask32 >> shift.mask5;
  int sra(int value, int shift) => (value.rel32 >> shift.mask5).mask32;

  void add(int rd, int a, int b) {
    final result = (a + b).mask32;
    // overflow occurs when the same sign results the opposite sign.
    if ((~(a ^ b) & (result ^ a)).bit31) {
      exception(excOverflow);
      return;
    }

    immediate(rd, result.mask32);
  }

  void sub(int rd, int a, int b) {
    final result = (a - b).mask32;
    // overflow occurs when the opposite sign results the opposite sign.
    if (((a ^ b) & (result ^ a)).bit31) {
      exception(excOverflow);
      return;
    }

    immediate(rd, result.mask32);
  }

  void mult(int a, int b) {
    // correct 32-bit overflow behavior despite Dart's Javascript float precision
    // (a32 * b32) = (a_low16 * b32) + ((a_high16 * b32) << 16)
    b = b.rel32;
    int low = a.mask16 * b;
    int high = a.rel32.shr16 * b;
    low += high.mask16.shl16;
    lo = low.mask32;
    hi = ((low >> 32) + high.shr16).mask32;
  }

  void multu(int a, int b) {
    // correct 32-bit overflow behavior despite Dart's Javascript float precision
    // (a32 * b32) = (a_low16 * b32) + ((a_high16 * b32) << 16)
    b = b.mask32;
    int low = a.mask16 * b; // 48bit
    int high = (a.mask32 >>> 16) * b; // 48bit
    low += high.mask16.shl16;
    lo = low.mask32;
    hi = ((low >>> 32) + (high >>> 16)).mask32;
  }

  void div(int a, int b) {
    a = a.mask32;
    b = b.mask32;

    if (b == 0) {
      lo = a.bit31 ? 1 : 0xffffffff;
      hi = a;
      return;
    }

    if (a == 0x80000000 && b == 0xffffffff) {
      lo = 0x80000000;
      hi = 0;
      return;
    }

    final q = a.rel32 ~/ b.rel32;
    lo = q.mask32;
    hi = (a.rel32 - q * b.rel32).mask32;
  }

  void divu(int a, int b) {
    a = a.mask32;
    b = b.mask32;

    if (b == 0) {
      lo = 0xffffffff;
      hi = a;
      return;
    }

    lo = a ~/ b;
    hi = (a - (lo * b).mask32).mask32;
  }

  /// Main instruction dispatch. Constant cases allow jump-table compilation.
  /// rs/rt/rd are five-bit indices into the 32-entry register files. New
  /// decoding paths must preserve those bounds under the unsafe pragma.
  @pragma('vm:unsafe:no-bounds-checks')
  void exec(int inst32) {
    final r = this.r;
    final rs = inst32.shr21.mask5;
    final rt = inst32.shr16.mask5;

    switch (inst32.shr26.mask6) {
      case 0x00:
        final rd = inst32.shr11.mask5;
        switch (inst32.mask6) {
          case 0x00: // sll
            immediate(rd, (r[rt] << inst32.shr6.mask5).mask32);
          case 0x02: // srl
            immediate(rd, r[rt] >> inst32.shr6.mask5);
          case 0x03: // sra
            immediate(rd, (r[rt].rel32 >> inst32.shr6.mask5).mask32);
          case 0x04: // sllv
            immediate(rd, (r[rt] << r[rs].mask5).mask32);
          case 0x06: // srlv
            immediate(rd, r[rt] >> r[rs].mask5);
          case 0x07: // srav
            immediate(rd, (r[rt].rel32 >> r[rs].mask5).mask32);
          case 0x08: // jr
            jumpTo(r[rs]);
          case 0x09: // jalr
            jal(true, rd, r[rs]);
          case 0x0c:
            exception(excSyscall);
          case 0x0d:
            exception(excBreak);
          case 0x10: // mfhi
            immediate(rd, hi);
          case 0x11: // mthi
            hi = r[rs];
          case 0x12: // mflo
            immediate(rd, lo);
          case 0x13: // mtlo
            lo = r[rs];
          case 0x18:
            mult(r[rs], r[rt]);
          case 0x19:
            multu(r[rs], r[rt]);
          case 0x1a:
            div(r[rs], r[rt]);
          case 0x1b:
            divu(r[rs], r[rt]);
          case 0x20:
            add(rd, r[rs], r[rt]);
          case 0x21: // addu
            immediate(rd, r[rs] + r[rt]);
          case 0x22:
            sub(rd, r[rs], r[rt]);
          case 0x23: // subu
            immediate(rd, r[rs] - r[rt]);
          case 0x24: // and
            immediate(rd, r[rs] & r[rt]);
          case 0x25: // or
            immediate(rd, r[rs] | r[rt]);
          case 0x26: // xor
            immediate(rd, r[rs] ^ r[rt]);
          case 0x27: // nor
            immediate(rd, ~(r[rs] | r[rt]));
          case 0x2a: // slt
            immediate(rd, r[rs].rel32 < r[rt].rel32 ? 1 : 0);
          case 0x2b: // sltu
            immediate(rd, r[rs] < r[rt] ? 1 : 0);
          default:
            unknownInstruction();
        }
      case 0x01:
        final rel = inst32.rel16;
        final neg = r[rs].rel32 < 0;
        final taken = rt.bit0 ? !neg : neg;
        if (linksRegimm(rt)) {
          jal(taken, 31, pc + rel.shl2);
        } else {
          branch(taken, rel); // bltz / bgez
        }
      case 0x02: // j
        jumpTo(pc & 0xf0000000 | inst32.mask26.shl2);
      case 0x03: // jal
        jal(true, 31, pc & 0xf0000000 | inst32.mask26.shl2);
      case 0x04: // beq
        branch(r[rs] == r[rt], inst32.rel16);
      case 0x05: // bne
        branch(r[rs] != r[rt], inst32.rel16);
      case 0x06: // blez
        branch(r[rs].rel32 <= 0, inst32.rel16);
      case 0x07: // bgtz
        branch(r[rs].rel32 > 0, inst32.rel16);
      case 0x08: // addi
        add(rt, r[rs], inst32.rel16);
      case 0x09: // addiu
        immediate(rt, r[rs] + inst32.rel16.mask32);
      case 0x0a: // slti
        immediate(rt, r[rs].rel32 < inst32.rel16 ? 1 : 0);
      case 0x0b: // sltiu
        immediate(rt, r[rs] < inst32.rel16.mask32 ? 1 : 0);
      case 0x0c: // andi
        immediate(rt, r[rs] & inst32.mask16);
      case 0x0d: // ori
        immediate(rt, r[rs] | inst32.mask16);
      case 0x0e: // xori
        immediate(rt, r[rs] ^ inst32.mask16);
      case 0x0f: // lui
        immediate(rt, inst32.mask16.shl16);
      case 0x10:
        final rd = inst32.shr11.mask5;
        if (rs == 0x00) {
          delay(rt, readCop0(rd)); // mfc0
        } else if (rs == 0x04) {
          writeCop0(rd, r[rt]); // mtc0
        } else if (cop0CommandApplies(rs)) {
          execCop0Command(inst32);
        } else {
          unknownInstruction();
        }
      case 0x11 || 0x13:
        copAbsent(inst32.shr26.mask6);
      case 0x12:
        final cop2 = this.cop2;
        if (cop2 == null) {
          copAbsent(0x12);
        } else if (rs >= 0x10) {
          cop2.execCmd(inst32);
        } else {
          final rd = inst32.shr11.mask5;
          switch (rs) {
            case 0x00: // mfc2
              delay(rt, cop2.readReg(rd));
            case 0x02: // cfc2
              delay(rt, cop2.readCtrl(rd));
            case 0x04: // mtc2
              cop2.writeReg(rd, r[rt]);
            case 0x06: // ctc2
              cop2.writeCtrl(rd, r[rt]);
            default:
              unknownInstruction();
          }
        }
      case 0x20: // lb
        delay(rt, read8(r[rs] + inst32.rel16).rel8);
      case 0x21: // lh
        final addr = r[rs] + inst32.rel16;
        if (strictAlignment && addr & 1 != 0) {
          cop0[cop0BadVAddr] = addr.mask32;
          exception(excAdEL);
        } else {
          delay(rt, read16(addr).rel16);
        }
      case 0x22: // lwl
        delay(rt, lwl(r[rs] + inst32.rel16, rt == delayReg ? delayVal : r[rt]));
      case 0x23: // lw
        final addr = r[rs] + inst32.rel16;
        if (strictAlignment && addr & 3 != 0) {
          cop0[cop0BadVAddr] = addr.mask32;
          exception(excAdEL);
        } else {
          delay(rt, read32(addr));
        }
      case 0x24: // lbu
        delay(rt, read8(r[rs] + inst32.rel16));
      case 0x25: // lhu
        final addr = r[rs] + inst32.rel16;
        if (strictAlignment && addr & 1 != 0) {
          cop0[cop0BadVAddr] = addr.mask32;
          exception(excAdEL);
        } else {
          delay(rt, read16(addr));
        }
      case 0x26: // lwr
        delay(rt, lwr(r[rs] + inst32.rel16, rt == delayReg ? delayVal : r[rt]));
      case 0x28: // sb
        write8(r[rs] + inst32.rel16, r[rt]);
      case 0x29: // sh
        final addr = r[rs] + inst32.rel16;
        if (strictAlignment && addr & 1 != 0) {
          cop0[cop0BadVAddr] = addr.mask32;
          exception(excAdES);
        } else {
          write16(addr, r[rt]);
        }
      case 0x2a: // swl
        swl(r[rs] + inst32.rel16, r[rt]);
      case 0x2b: // sw
        final addr = r[rs] + inst32.rel16;
        if (strictAlignment && addr & 3 != 0) {
          cop0[cop0BadVAddr] = addr.mask32;
          exception(excAdES);
        } else {
          write32(addr, r[rt]);
        }
      case 0x2e: // swr
        swr(r[rs] + inst32.rel16, r[rt]);
      case 0x32: // lwc2
        final cop2 = this.cop2;
        if (cop2 == null) {
          unknownInstruction();
        } else {
          cop2.writeReg(rt, read32(r[rs] + inst32.rel16));
        }
      case 0x3a: // swc2
        final cop2 = this.cop2;
        if (cop2 == null) {
          unknownInstruction();
        } else {
          write32(r[rs] + inst32.rel16, cop2.readReg(rt));
        }
      default:
        unknownInstruction();
    }
  }
}
