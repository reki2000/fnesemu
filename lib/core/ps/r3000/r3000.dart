import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';
import 'package:fnesemu/util/util.dart';

import '../../../util/debug.dart';
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
typedef Slot = (RegNo, int);

/// A minimal MIPS R3000 emulator in Dart.
class R3000 {
  final BusR3000 bus;
  late final Cop2 cop2;

  R3000(this.bus) {
    cop2 = Cop2(this);
  }

  /// 32 general-purpose registers. Note: r0 is always 0.
  final r = List.filled(32, 0);

  int pc = 0; // the PC (actually the next instruction during execution)
  int nextPc = 0; // the PC to be executed next, reflects branch delay slot
  int instPc = 0; // the PC of the current instruction

  /// HI and LO registers (used by multiply/divide instructions).
  int hi = 0, lo = 0;

  /// COP0 registers.
  int sr = 0, cause = 0, epc = 0, badvaddr = 0;

  /// A simple clock counter.
  int clocks = 0;

  //  slots to handle delay
  Slot nextDelaySlot = (0, 0), delaySlot = (0, 0), immediateSlot = (0, 0);
  bool inBranchDelay = false;

  // bios putchar() hacking
  final StringBuffer console = StringBuffer();

  // ps-exe bianry to sideload
  Uint8List exe = Uint8List(0);

  void reset() {
    pc = 0xbfc00000;
    nextPc = pc.inc4;

    nextDelaySlot = (0, 0);
    immediateSlot = (0, 0);

    inBranchDelay = false;

    r.fillRange(0, 32, 0);
    hi = 0;
    lo = 0;

    sr = 0;
    cause = 0;
    epc = 0;

    clocks = 0;

    console.clear();

    intAsserted = false;

    cop2.reset();
  }

  bool get _cacheIsolated => sr.bit16;

  int read8(int addr) => bus.read8(addr.mask32).mask8;

  int read16(int addr) => (addr & 0x01 != 0)
      ? throw ReadMisalignException(addr)
      : bus.read16(addr & 0xfffffffe).mask16;

  int read32(int addr) => (addr & 0x03 != 0)
      ? throw ReadMisalignException(addr)
      : bus.read32(addr & 0xfffffffc);

  void write8(int addr, int value) =>
      _cacheIsolated ? 0 : bus.write8(addr.mask32, value.mask8);

  void write16(int addr, int value) => (addr & 0x01 != 0)
      ? throw WriteMisalignException(addr)
      : _cacheIsolated
          ? 0
          : bus.write16(addr & 0xfffffffe, value.mask16);

  void write32(int addr, int value) => (addr & 0x03 != 0)
      ? throw WriteMisalignException(addr)
      : _cacheIsolated
          ? 0
          : bus.write32(addr & 0xfffffffc, value.mask32);

  bool intAsserted = false;

  void interrupt(bool onoff) {
    if (onoff) {
      if (cause.bit10) {
        return;
      }
      intAsserted = true;
      cause = cause.setBit(10, true);
    } else {
      intAsserted = false;
      cause = cause.setBit(10, false);
    }
  }

  /// Executes a single instruction.
  bool step() {
    hook();

    instPc = pc; // points the current instruction.
    pc = nextPc; // points the next instruction. "PC" refers this.
    nextPc = nextPc.inc4.mask32;

    delaySlot = nextDelaySlot;
    nextDelaySlot = (0, 0);
    immediateSlot = (0, 0);

    if (intAsserted && sr & 0x401 == 0x401) {
      intAsserted = false;
      exception(Exception.interrupt);
    } else {
      try {
        inBranchDelay = false;
        exec(read32(instPc));
      } catch (e) {
        if (e is ReadMisalignException) {
          exception(Exception.readalign, badvaddr: e.addr);
        } else if (e is WriteMisalignException) {
          exception(Exception.writeAlign, badvaddr: e.addr);
        } else if (e is UnknownOpcodeException) {
          exception(Exception.illegalInstruction);
        } else {
          rethrow;
        }
      }
    }

    r[delaySlot.$1] = delaySlot.$2;
    r[immediateSlot.$1] = immediateSlot.$2;

    r[0] = 0; // r0 is always hardwired to 0.

    clocks += 2; // not accurate, but enough for now.

    return true;
  }

  static _unknown(int inst32) => throw UnknownOpcodeException();

  void delay(RegNo dst, int val) {
    if (dst == delaySlot.$1) {
      delaySlot = (0, 0);
    }
    nextDelaySlot = (dst, val.mask32);
  }

  void immediate(RegNo dst, int val) => immediateSlot = (dst, val.mask32);

  void jump(int addr) {
    inBranchDelay = true;
    nextPc = addr.mask32;
  }

  void exception(int excode, {int? badvaddr}) {
    sr = sr.masked(0x3f, sr << 2);

    cause = cause.masked(0x7c, excode << 2);

    if (badvaddr != null) {
      this.badvaddr = badvaddr;
    }

    if (inBranchDelay) {
      epc = instPc.dec4.mask32;
      cause |= 0x80000000;
    } else {
      epc = instPc;
    }

    pc = sr.bit22 ? 0xbfc00180 : 0x80000080; // bit22: BEV
    nextPc = pc.inc4;

    // debugLog(
    //     "cpu: [$clocks] exception  excode:${excode.hex8} istat:${bus.read32(0x1f801070).hex16} "
    //     "sr:${sr.hex32} cause:${cause.hex32} epc:${epc.hex32} pc:${instPc.hex32} ");
  }

  /// Main instruction dispatch.
  void exec(int inst32) {
    final op = inst32 >> 26 & 0x3f;
    final rs = inst32 >> 21 & 0x1f;
    final rd = inst32 >> 11 & 0x1f;
    final rt = inst32 >> 16 & 0x1f;

    final im16 = inst32.mask16;
    final rel16 = im16.rel16;

    return switch (op) {
      0x00 => switch (inst32 & 0x3f) {
          0x00 => immediate(rd, sll(r[rt], inst32 >> 6)),
          0x02 => immediate(rd, srl(r[rt], inst32 >> 6)),
          0x03 => immediate(rd, sra(r[rt], inst32 >> 6)),
          0x04 => immediate(rd, sll(r[rt], r[rs])), // sllv
          0x06 => immediate(rd, srl(r[rt], r[rs])), // srlv
          0x07 => immediate(rd, sra(r[rt], r[rs])), // srav
          0x08 => jump(r[rs]),
          0x09 => jal(true, rd, r[rs]), // jalr
          0x0c => exception(Exception.syscall),
          0x0d => exception(Exception.break_),
          0x10 => immediate(rd, hi), // mfhi
          0x11 => hi = r[rs], // mthi
          0x12 => immediate(rd, lo), // mflo
          0x13 => lo = r[rs], // mtlo
          0x18 => mult(r[rs], r[rt]),
          0x19 => multu(r[rs], r[rt]),
          0x1a => div(r[rs], r[rt]),
          0x1b => divu(r[rs], r[rt]),
          0x20 => add(rd, r[rs], r[rt]),
          0x21 => immediate(rd, r[rs] + r[rt]), // addu
          0x22 => sub(rd, r[rs], r[rt]),
          0x23 => immediate(rd, r[rs] - r[rt]), // subu
          0x24 => immediate(rd, r[rs] & r[rt]), // and
          0x25 => immediate(rd, r[rs] | r[rt]), // or
          0x26 => immediate(rd, r[rs] ^ r[rt]), // xor
          0x27 => immediate(rd, ~(r[rs] | r[rt])), // nor
          0x2a => immediate(rd, r[rs].rel32 < r[rt].rel32 ? 1 : 0), // slt
          0x2b => immediate(rd, r[rs] < r[rt] ? 1 : 0), // sltu
          _ => _unknown(inst32),
        },
      0x01 => switch (rt) {
          0x10 => jal(r[rs].rel32 < 0, 31, pc + (rel16 << 2)), // bltzal
          0x11 => jal(r[rs].rel32 >= 0, 31, pc + (rel16 << 2)), // bgezal
          _ => switch (rt & 1) {
              0x00 => r[rs].rel32 < 0 ? jump(pc + (rel16 << 2)) : 0, // bltz
              0x01 => r[rs].rel32 >= 0 ? jump(pc + (rel16 << 2)) : 0, // bgez
              _ => _unknown(inst32),
            }
        },
      0x02 => jump(pc & 0xf0000000 | inst32.mask26 << 2),
      0x03 => jal(true, 31, pc & 0xf0000000 | inst32.mask26 << 2), // jal
      0x04 => r[rs] == r[rt] ? jump(pc + (rel16 << 2)) : 0, // beq
      0x05 => r[rs] != r[rt] ? jump(pc + (rel16 << 2)) : 0, // bne
      0x06 => r[rs].rel32 <= 0 ? jump(pc + (rel16 << 2)) : 0, // blez
      0x07 => r[rs].rel32 > 0 ? jump(pc + (rel16 << 2)) : 0, // bgtz
      0x08 => add(rt, r[rs], rel16),
      0x09 => immediate(rt, r[rs] + rel16.mask32), // addiu
      0x0a => immediate(rt, r[rs].rel32 < rel16 ? 1 : 0), // slti
      0x0b => immediate(rt, r[rs] < rel16.mask32 ? 1 : 0), // sltiu
      0x0c => immediate(rt, r[rs] & im16), // andi
      0x0d => immediate(rt, r[rs] | im16), // ori
      0x0e => immediate(rt, r[rs] ^ im16), // xori
      0x0f => immediate(rt, im16 << 16), // lui
      0x10 => switch (rs) {
          0x00 => delay(rt, readCop0(rd)), // mfc0,
          0x04 => writeCop0(rd, r[rt]), // mtc0
          >= 0x10 && <= 0x1f => execCop0(inst32),
          _ => _unknown(inst32),
        },
      0x12 => switch (rs) {
          0x00 => delay(rt, cop2.readReg(rd)), // mfc2
          0x02 => delay(rt, cop2.readCtrl(rd)), // cfc2
          0x04 => cop2.writeReg(rd, r[rt]), // mtc2
          0x06 => cop2.writeCtrl(rd, r[rt]), // ctc2
          >= 0x10 && <= 0x1f => cop2.execCmd(inst32),
          _ => _unknown(inst32),
        },
      0x20 => delay(rt, read8(r[rs] + rel16).rel8), // lb
      0x21 => delay(rt, read16(r[rs] + rel16).rel16), // lh
      0x22 => delay(rt,
          lwl(r[rs] + rel16, rt == delaySlot.$1 ? delaySlot.$2 : r[rt])), // lwl
      0x23 => delay(rt, read32(r[rs] + rel16)), // lw
      0x24 => delay(rt, read8(r[rs] + rel16)), // lbu
      0x25 => delay(rt, read16(r[rs] + rel16)), // lhu
      0x26 => delay(rt,
          lwr(r[rs] + rel16, rt == delaySlot.$1 ? delaySlot.$2 : r[rt])), // lwr
      0x28 => write8(r[rs] + rel16, r[rt]), // sb
      0x29 => write16(r[rs] + rel16, r[rt]), // sh
      0x2a => swl(r[rs] + rel16, r[rt]), // swl
      0x2b => write32(r[rs] + rel16, r[rt]), // sw
      0x2e => swr(r[rs] + rel16, r[rt]), // swr
      0x32 => cop2.writeReg(rt, read32(r[rs] + rel16)), // lwc2
      0x3a => write32(r[rs] + rel16, cop2.readReg(rt)), // swc2
      _ => _unknown(inst32),
    };
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
        "r${i.toString().padLeft(2, "0")}:"
            "${range(i, i + 4).map((v) => r[v].hex32).join(" ")}"
            " r${(i + 4).toString().padLeft(2, "0")}:"
            "${range(i + 4, i + 8).map((v) => r[v].hex32).join(" ")}"
    ].join("\n");
    return "$regs\npc:${pc.hex32} hi:${hi.hex32} lo:${lo.hex32} sr:${sr.hex32} cause:${cause.hex32} epc:${epc.hex32}";
  }
}
