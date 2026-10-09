import 'dart:typed_data';

import 'package:fnesemu_core/util/debug.dart';
import 'package:fnesemu_core/util/int.dart';
import 'package:fnesemu_core/util/uint8list.dart';

import '../log.dart';
import 'exception.dart';

part 'alu.dart';
part 'bios.dart';
part 'cop0.dart';
part 'cop2.dart';
part 'cop2_command.dart';
part 'cop2_math.dart';
part 'hook.dart';

/// A simple bus interface for MIPS memory accesses.
abstract class BusR3000 {
  int read8(int addr);
  int read16(int addr);
  int read32(int addr);
  void write8(int addr, int value);
  void write16(int addr, int value);
  void write32(int addr, int value);
}

typedef RegNo = int;

/// A minimal MIPS R3000 emulator in Dart.
class R3000 {
  final BusR3000 bus;
  late final Cop2 cop2;

  R3000(this.bus) {
    cop2 = Cop2(this);
  }

  /// 32 general-purpose registers. Note: r0 is always 0.
  final r = Uint32List(32);

  int pc = 0; // the PC (actually the next instruction during execution)
  int nextPc = 0; // the PC to be executed next, reflects branch delay slot
  int instPc = 0; // the PC of the current instruction

  /// HI and LO registers (used by multiply/divide instructions).
  int hi = 0, lo = 0;

  /// COP0 registers.
  int sr = 0, cause = 0, epc = 0, badvaddr = 0, tar = 0;

  /// A simple clock counter.
  int clocks = 0;

  //  slots to handle delay
  int nextDelayReg = 0, nextDelayVal = 0;
  int delayReg = 0, delayVal = 0;
  int immediateReg = 0, immediateVal = 0;
  bool inBranchTaken = false;
  bool inBranchDelay = false;

  // bios putchar() hacking
  final console = StringBuffer();

  // ps-exe bianry to be sideloaded
  Uint8List exe = Uint8List(0);

  void reset() {
    pc = 0xbfc00000;
    nextPc = pc.inc4;

    nextDelayReg = 0;
    nextDelayVal = 0;
    immediateReg = 0;
    immediateVal = 0;

    inBranchTaken = false;
    inBranchDelay = false;

    r.fillRange(0, 32, 0);
    hi = 0;
    lo = 0;

    sr = 0;
    cause = 0;
    epc = 0;
    tar = 0;

    clocks = 0;

    console.clear();

    cop2.reset();
  }

  bool get _cacheIsolated => sr.bit16;

  int read8(int addr) => bus.read8(addr.mask32).mask8;

  // int read16(int addr) => (addr & 0x01 != 0)
  //     ? throw ReadMisalignException(addr)
  //     : bus.read16(addr & 0xfffffffe).mask16;
  int read16(int addr) => bus.read16(addr & 0xfffffffe).mask16;

  // int read32(int addr) => (addr & 0x03 != 0)
  //     ? throw ReadMisalignException(addr)
  //     : bus.read32(addr & 0xfffffffc);
  int read32(int addr) => bus.read32(addr & 0xfffffffc);

  void write8(int addr, int value) =>
      _cacheIsolated ? 0 : bus.write8(addr.mask32, value.mask8);

  // void write16(int addr, int value) => (addr & 0x01 != 0)
  //     ? throw WriteMisalignException(addr)
  //     : _cacheIsolated
  //         ? 0
  //         : bus.write16(addr & 0xfffffffe, value.mask16);
  void write16(int addr, int value) =>
      _cacheIsolated ? 0 : bus.write16(addr & 0xfffffffe, value.mask16);

  // void write32(int addr, int value) => (addr & 0x03 != 0)
  //     ? throw WriteMisalignException(addr)
  //     : _cacheIsolated
  //         ? 0
  //         : bus.write32(addr & 0xfffffffc, value.mask32);
  void write32(int addr, int value) =>
      _cacheIsolated ? 0 : bus.write32(addr & 0xfffffffc, value.mask32);

  void setInterruptPending(bool onoff) =>
      cause = cause.setBit(10, onoff); // set cop0.cuase.ip2 on

  /// Executes a single instruction.
  /// Register indices below are masked to five bits before accessing the
  /// fixed 32-entry register file; keep that invariant with bounds checks off.
  @pragma('vm:unsafe:no-bounds-checks')
  bool step() {
    hook();

    instPc = pc; // points the current instruction.
    pc = nextPc; // points the next instruction. "PC" refers this.
    nextPc = nextPc.inc4.mask32;

    delayReg = nextDelayReg;
    delayVal = nextDelayVal;
    nextDelayReg = 0;
    nextDelayVal = 0;
    immediateReg = 0;
    immediateVal = 0;

    if ((cause & sr & 0xff00 != 0) && sr.bit0 && read32(instPc).shr26 != 0x12) {
      // delay excaption if the current instruction is cop2
      exception(Exception.interrupt);
    } else {
      // try {
      inBranchTaken = false;
      inBranchDelay = false;
      exec(read32(instPc));
      // } catch (e) {
      //   if (e is ReadMisalignException) {
      //     exception(Exception.readalign, badvaddr: e.addr);
      //   } else if (e is WriteMisalignException) {
      //     exception(Exception.writeAlign, badvaddr: e.addr);
      //   } else if (e is UnknownOpcodeException) {
      //     exception(Exception.illegalInstruction);
      //   } else {
      //     rethrow;
      //   }
      // }
    }

    r[delayReg & 0x1f] = delayVal;
    r[immediateReg & 0x1f] = immediateVal;

    r[0] = 0; // r0 is always hardwired to 0.

    clocks += 2; // not accurate, but enough for now.

    return true;
  }

  /// raises Reserved Instruction exception instead of stopping the emulator
  void _unknown(int inst32) => exception(Exception.illegalInstruction);

  void delay(RegNo dst, int val) {
    if (dst == delayReg) {
      delayReg = 0;
      delayVal = 0;
    }
    nextDelayReg = dst;
    nextDelayVal = val;
  }

  void immediate(RegNo dst, int val) {
    immediateReg = dst;
    immediateVal = val;
  }

  void jump(int addr) {
    inBranchTaken = true;
    inBranchDelay = true;
    nextPc = addr.mask32;
  }

  void exception(int excode, {int? badvaddr}) {
    sr = sr.masked(0x3f,
        sr.shl2); // save old mode, ie bit0-1, and set new mode to kernel (0x00)

    cause &= 0xff00; // clear, keep bit8-15 (IM)
    cause |= excode.shl2;

    if (badvaddr != null) {
      this.badvaddr = badvaddr;
    }

    if (inBranchDelay) {
      epc = instPc.dec4.mask32;
      cause |= 0x80000000.setBit(30, inBranchTaken);
      tar = pc;
    } else {
      epc = instPc;
    }

    pc = sr.bit22 ? 0xbfc00180 : 0x80000080; // bit22: BEV
    nextPc = pc.inc4;

    // debugLog(
    //     "cpu: exception  excode:${excode.x2} sr:${sr.x8} cause:${cause.x8} epc:${epc.x8}");
  }

  void branch(bool cond, int rel16) {
    inBranchDelay = true;
    if (cond) {
      jump(pc + rel16.shl2);
    }
  }

  /// Main instruction dispatch. Constant cases allow jump-table compilation.
  /// rs/rt/rd are five-bit indices into the 32-entry register files. New
  /// decoding paths must preserve those bounds under the unsafe pragma.
  @pragma('vm:unsafe:no-bounds-checks')
  void exec(int inst32) {
    final r = this.r;
    final rs = (inst32 >> 21) & 0x1f;
    final rt = (inst32 >> 16) & 0x1f;

    switch ((inst32 >> 26) & 0x3f) {
      case 0x00:
        final rd = (inst32 >> 11) & 0x1f;
        switch (inst32 & 0x3f) {
          case 0x00: // sll
            immediate(rd, (r[rt] << ((inst32 >> 6) & 0x1f)) & 0xffffffff);
          case 0x02: // srl
            immediate(rd, r[rt] >> ((inst32 >> 6) & 0x1f));
          case 0x03: // sra
            immediate(rd, (r[rt].rel32 >> ((inst32 >> 6) & 0x1f)) & 0xffffffff);
          case 0x04: // sllv
            immediate(rd, (r[rt] << (r[rs] & 0x1f)) & 0xffffffff);
          case 0x06: // srlv
            immediate(rd, r[rt] >> (r[rs] & 0x1f));
          case 0x07: // srav
            immediate(rd, (r[rt].rel32 >> (r[rs] & 0x1f)) & 0xffffffff);
          case 0x08: // jr
            jump(r[rs]);
          case 0x09: // jalr
            jal(true, rd, r[rs]);
          case 0x0c:
            exception(Exception.syscall);
          case 0x0d:
            exception(Exception.break_);
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
            _unknown(inst32);
        }
      case 0x01:
        final rel = (inst32 & 0xffff).rel16;
        switch (rt) {
          case 0x10: // bltzal
            jal(r[rs].rel32 < 0, 31, pc + (rel << 2));
          case 0x11: // bgezal
            jal(r[rs].rel32 >= 0, 31, pc + (rel << 2));
          default:
            if (rt & 1 == 0) {
              branch(r[rs].rel32 < 0, rel); // bltz
            } else {
              branch(r[rs].rel32 >= 0, rel); // bgez
            }
        }
      case 0x02: // j
        jump(pc & 0xf0000000 | (inst32 & 0x3ffffff) << 2);
      case 0x03: // jal
        jal(true, 31, pc & 0xf0000000 | (inst32 & 0x3ffffff) << 2);
      case 0x04: // beq
        branch(r[rs] == r[rt], (inst32 & 0xffff).rel16);
      case 0x05: // bne
        branch(r[rs] != r[rt], (inst32 & 0xffff).rel16);
      case 0x06: // blez
        branch(r[rs].rel32 <= 0, (inst32 & 0xffff).rel16);
      case 0x07: // bgtz
        branch(r[rs].rel32 > 0, (inst32 & 0xffff).rel16);
      case 0x08: // addi
        add(rt, r[rs], (inst32 & 0xffff).rel16);
      case 0x09: // addiu
        immediate(rt, r[rs] + ((inst32 & 0xffff).rel16 & 0xffffffff));
      case 0x0a: // slti
        immediate(rt, r[rs].rel32 < (inst32 & 0xffff).rel16 ? 1 : 0);
      case 0x0b: // sltiu
        immediate(rt, r[rs] < ((inst32 & 0xffff).rel16 & 0xffffffff) ? 1 : 0);
      case 0x0c: // andi
        immediate(rt, r[rs] & (inst32 & 0xffff));
      case 0x0d: // ori
        immediate(rt, r[rs] | (inst32 & 0xffff));
      case 0x0e: // xori
        immediate(rt, r[rs] ^ (inst32 & 0xffff));
      case 0x0f: // lui
        immediate(rt, (inst32 & 0xffff) << 16);
      case 0x10:
        final rd = (inst32 >> 11) & 0x1f;
        if (rs >= 0x10) {
          execCop0(inst32);
        } else if (rs == 0x00) {
          delay(rt, readCop0(rd)); // mfc0
        } else if (rs == 0x04) {
          writeCop0(rd, r[rt]); // mtc0
        } else {
          _unknown(inst32);
        }
      case 0x12:
        final rd = (inst32 >> 11) & 0x1f;
        if (rs >= 0x10) {
          cop2.execCmd(inst32);
        } else {
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
              _unknown(inst32);
          }
        }
      case 0x20: // lb
        delay(rt, read8(r[rs] + (inst32 & 0xffff).rel16).rel8);
      case 0x21: // lh
        delay(rt, read16(r[rs] + (inst32 & 0xffff).rel16).rel16);
      case 0x22: // lwl
        delay(
            rt,
            lwl(r[rs] + (inst32 & 0xffff).rel16,
                rt == delayReg ? delayVal : r[rt]));
      case 0x23: // lw
        delay(rt, read32(r[rs] + (inst32 & 0xffff).rel16));
      case 0x24: // lbu
        delay(rt, read8(r[rs] + (inst32 & 0xffff).rel16));
      case 0x25: // lhu
        delay(rt, read16(r[rs] + (inst32 & 0xffff).rel16));
      case 0x26: // lwr
        delay(
            rt,
            lwr(r[rs] + (inst32 & 0xffff).rel16,
                rt == delayReg ? delayVal : r[rt]));
      case 0x28: // sb
        write8(r[rs] + (inst32 & 0xffff).rel16, r[rt]);
      case 0x29: // sh
        write16(r[rs] + (inst32 & 0xffff).rel16, r[rt]);
      case 0x2a: // swl
        swl(r[rs] + (inst32 & 0xffff).rel16, r[rt]);
      case 0x2b: // sw
        write32(r[rs] + (inst32 & 0xffff).rel16, r[rt]);
      case 0x2e: // swr
        swr(r[rs] + (inst32 & 0xffff).rel16, r[rt]);
      case 0x32: // lwc2
        cop2.writeReg(rt, read32(r[rs] + (inst32 & 0xffff).rel16));
      case 0x3a: // swc2
        write32(r[rs] + (inst32 & 0xffff).rel16, cop2.readReg(rt));
      default:
        _unknown(inst32);
    }
  }

  void jal(bool cond, RegNo rd, int addr) {
    immediate(rd, pc.inc4.mask32);

    if (cond) {
      jump(addr);
    }
  }

  String dump() {
    final regs = [
      for (int i = 0; i < 32; i += 8)
        "r${i.d2z}:"
            "${range(i, i + 4).map((v) => r[v].x8).join(" ")}"
            " r${(i + 4).d2z}:"
            "${range(i + 4, i + 8).map((v) => r[v].x8).join(" ")}"
    ].join("\n");
    return "$regs\npc:${pc.x8} hi:${hi.x8} lo:${lo.x8} sr:${sr.x8} cause:${cause.x8} epc:${epc.x8}";
  }
}
