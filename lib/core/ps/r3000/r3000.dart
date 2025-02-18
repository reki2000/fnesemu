import 'package:fnesemu/util/int.dart';
import 'package:fnesemu/util/util.dart';

part 'cop0.dart';
part 'cop2.dart';
part 'alu.dart';

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

class ReadMisalignException implements Exception {}

class WriteMisalignException implements Exception {}

class UnknownOpcodeException implements Exception {}

/// A minimal MIPS R3000 emulator in Dart.
class R3000 {
  final BusR3000 bus;

  /// 32 general-purpose registers. Note: r0 is always 0.
  final r = List.filled(32, 0);

  /// Program counter.
  int pc = 0;
  int nextPc = 0;

  /// HI and LO registers (used by multiply/divide instructions).
  int hi = 0, lo = 0;

  /// COP0 registers.
  int sr = 0, cause = 0, epc = 0;

  /// A simple clock counter.
  int clocks = 0;

  // delay handling
  int nextInst32 = 0;
  (RegNo, int) delaySlot = (0, 0), immediateSlot = (0, 0);
  bool branch = false, branch2 = false;

  final StringBuffer console = StringBuffer();

  R3000(this.bus);

  void reset() {
    pc = 0xbfc00000;
    nextPc = 0xbfc00004;

    delaySlot = (0, 0);
    immediateSlot = (0, 0);

    branch = false;
    branch2 = false;

    r.fillRange(0, 32, 0);
    hi = 0;
    lo = 0;

    sr = 0;
    cause = 0;
    epc = 0;

    clocks = 0;
  }

  bool get _cacheIsolated => sr.bit16;

  int read8(int addr) => bus.read8(addr.mask32);

  int read16(int addr) => (addr & 0x01 != 0)
      ? throw ReadMisalignException()
      : bus.read16(addr & 0xfffffffe);

  int read32(int addr) => (addr & 0x03 != 0)
      ? throw ReadMisalignException()
      : bus.read32(addr & 0xfffffffc);

  void write8(int addr, int value) =>
      sr.bit16 ? 0 : bus.write8(addr.mask32, value.mask8);

  void write16(int addr, int value) => (addr & 0x01 != 0)
      ? throw WriteMisalignException()
      : _cacheIsolated
          ? 0
          : bus.write16(addr & 0xfffffffe, value.mask16);

  void write32(int addr, int value) => (addr & 0x03 != 0)
      ? throw WriteMisalignException()
      : _cacheIsolated
          ? 0
          : bus.write32(addr & 0xfffffffc, value.mask32);

  /// Executes a single instruction.
  bool step() {
    final inst32 = read32(pc);
    // if (pc == 0xb0 || pc == 0xa0 || pc == 0xc0) {
    //   if (r[9] == 0x3d) {
    //     if ((r[4] >= 0x20 && r[4] < 0x80) || r[4] == 0x0a || r[4] == 0x09) {
    //       console.write(String.fromCharCode(r[4]));
    //       print(console.toString());
    //     }
    //   } else {
    //     print("bios call ${pc.hex8}-${r[9].hex32} r4:${r[4].hex32}");
    //     // print(dump());
    //   }
    // }

    pc = nextPc;
    nextPc = nextPc.inc4.mask32;

    branch = branch2;
    branch2 = false;

    final prevDelaySlot = delaySlot;
    delaySlot = (0, 0);

    exec(inst32);

    r[prevDelaySlot.$1] = prevDelaySlot.$2;
    r[immediateSlot.$1] = immediateSlot.$2;
    immediateSlot = (0, 0);

    r[0] = 0; // r0 is always hardwired to 0.

    clocks++;

    return true;
  }

  static _unknown(int inst32) => throw UnknownOpcodeException();

  void delay(RegNo dst, int val) => delaySlot = (dst, val.mask32);

  void immediate(RegNo dst, int val) => immediateSlot = (dst, val.mask32);

  void jump(int addr) => nextPc = addr.mask32;

  static const exceptionOverflow = 0x0c;
  static const exceptionSyscall = 0x08;
  static const exceptionBreak = 0x09;
  static const exceptionReadAlign = 0x04;
  static const exceptionWriteAlign = 0x05;
  static const exceptionIllegalInstruction = 0x0a;

  void exception(int cause) {
    sr = sr & ~0x3f | (sr << 2 & 0x3f);

    this.cause = cause << 2;

    epc = pc;
    if (branch) {
      epc = epc.dec4.mask32;
      cause |= 0x80000000;
    }

    pc = sr.bit22 ? 0xbfc00180 : 0x80000080; // bit22: BEV
    nextPc = pc.inc4.mask32;
  }

  /// Main instruction dispatch.
  void exec(int inst32) {
    final op = inst32 >> 26 & 0x3f;
    final rs = inst32 >> 21 & 0x1f;
    final rd = inst32 >> 11 & 0x1f;
    final rt = inst32 >> 16 & 0x1f;

    final im16 = inst32.mask16;
    final rel16 = im16.rel16;

    try {
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
            0x0c => exception(exceptionSyscall),
            0x0d => exception(exceptionBreak),
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
        0x01 => switch (rt & 0xf1) {
            0x00 => r[rs].rel32 < 0 ? jump(pc + (rel16 << 2)) : 0, // bltz
            0x01 => r[rs].rel32 >= 0 ? jump(pc + (rel16 << 2)) : 0, // bgez
            0x10 => jal(r[rs].rel32 < 0, 31, pc + (rel16 << 2)), // bltzal
            0x11 => jal(r[rs].rel32 >= 0, 31, pc + (rel16 << 2)), // bgezal
            _ => _unknown(inst32),
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
            0x00 => delay(rt, readCop0(r[rd])), // mfc0,
            0x04 => writeCop0(rd, r[rt]), // mtc0
            >= 0x10 && <= 0x1f => execCop0(inst32),
            _ => _unknown(inst32),
          },
        0x12 => switch (rs) {
            0x00 => delay(rt, readCop2(r[rd])), // mfc2
            0x01 => delay(rt, readCop2Ctrl(r[rd])), // cfc2
            0x04 => writeCop2(rd, r[rt]), // mtc2
            0x05 => writeCop2Ctrl(rd, r[rt]), // ctc2
            >= 0x10 && <= 0x1f => execCop2(inst32),
            _ => _unknown(inst32),
          },
        0x20 => delay(rt, read8(r[rs] + rel16).rel8), // lb
        0x21 => delay(rt, read16(r[rs] + rel16).rel16), // lh
        0x22 => delay(rt, lwl(r[rs] + rel16, r[rt])), // lwl
        0x23 => delay(rt, read32(r[rs] + rel16)), // lw
        0x24 => delay(rt, read8(r[rs] + rel16)), // lbu
        0x25 => delay(rt, read16(r[rs] + rel16)), // lhu
        0x26 => delay(rt, lwr(r[rs] + rel16, r[rt])), // lwr
        0x28 => write8(r[rs] + rel16, r[rt]), // sb
        0x29 => write16(r[rs] + rel16, r[rt]), // sh
        0x2a => swl(r[rs] + rel16, r[rt]), // swl
        0x2b => write32(r[rs] + rel16, r[rt]), // sw
        0x2e => swr(r[rs] + rel16, r[rt]),
        0x32 => writeCop2(r[rt], read32(r[rs] + rel16)), // lwc2
        0x3a => write32(r[rs] + rel16, readCop2(r[rt])), // swc2
        _ => _unknown(inst32),
      };
    } catch (e) {
      if (e is ReadMisalignException) {
        exception(exceptionReadAlign);
      } else if (e is WriteMisalignException) {
        exception(exceptionWriteAlign);
      } else if (e is UnknownOpcodeException) {
        exception(exceptionIllegalInstruction);
      } else {
        rethrow;
      }
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
        "r${i.toString().padLeft(2, "0")}:${range(i, i + 8).map((v) => r[v].hex32).join(" ")}"
    ].join("\n");
    return "$regs\npc:${pc.hex32} hi:${hi.hex32} lo:${lo.hex32} sr:${sr.hex32} cause:${cause.hex32} epc:${epc.hex32}";
  }
}
