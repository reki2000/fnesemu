import 'dart:core';

import '../../util/int.dart';
import '../../util/state.dart';

/// Register file shared by every 6502 family variant.
class Cpu6502Regs {
  int a = 0;
  int x = 0;
  int y = 0;
  int s = 0;
  int p = 0;
  int pc = 0;
}

/// Status flag bits shared by every 6502 family variant. Bit 5 has no
/// dedicated function on the NMOS 6502: the NES reads it as the R bit (always
/// set in the stored status) and the HuC6280 uses the same bit as the T flag.
class Cpu6502Flags {
  static const C = 0x01;
  static const Z = 0x02;
  static const I = 0x04;
  static const D = 0x08;
  static const B = 0x10;
  static const U = 0x20;
  static const R = 0x20;
  static const T = 0x20;
  static const V = 0x40;
  static const N = 0x80;
}

/// The shared NMOS 6502 opcode engine: instruction decode and execute,
/// addressing modes and flag computation for the base 6502 instruction set.
///
/// Variant behaviour is layered on top through hooks, never averaged into
/// the engine. The Ricoh 2A03 (NES) keeps decimal mode disabled so ADC and
/// SBC always run in binary even when the D flag is set. The Hudson HuC6280
/// (PCE) enables decimal mode and the T flag memory operations, drops the
/// page-cross cycle penalties, maps the zero page and the stack through its
/// MPR paging (expressed here as the zero page and stack bases), and adds
/// the 65C02 zero page indirect addressing mode. The 65C02 and HuC6280
/// instruction additions themselves live in the PCE variant layer, as do
/// each core's bus translation, interrupt wiring and reset sequence.
abstract class Cpu6502<R extends Cpu6502Regs> {
  Cpu6502(this.regs);

  final R regs;

  int cycle = 0;

  /// Saves the register file and the cycle counter shared by every variant; a variant layer saves its own extra state after this section.
  void saveState(StateWriter w) {
    w.section('6502');
    w.ints([regs.a, regs.x, regs.y, regs.s, regs.p, regs.pc]);
    w.int64(cycle);
  }

  /// Restores the state written by [saveState] into the existing registers.
  void loadState(StateReader s) {
    s.section('6502');
    final v = s.ints();
    if (v.length != 6) throw const StateMismatch('6502 state layout');
    regs.a = v[0];
    regs.x = v[1];
    regs.y = v[2];
    regs.s = v[3];
    regs.p = v[4];
    regs.pc = v[5];
    cycle = s.int64();
  }

  /// Reads one byte through the variant's bus wiring.
  int read(int addr);

  /// Writes one byte through the variant's bus wiring.
  void write(int addr, int data);

  /// Enters the variant's interrupt sequence. BRK shares this entry point.
  void interrupt({bool brk = false, bool nmi = false});

  /// Restores the status register for PLP and RTI in the variant's form.
  void pullFlags(int p);

  /// The status byte pushed by PHP in the variant's form.
  int statusForPhp();

  /// Extra variant state to settle on RTI. The base engine has none.
  void onRti() {}

  /// Whether ADC and SBC honour the D flag. The 2A03 disables decimal mode,
  /// so its layer leaves this false and the D flag stays inert.
  bool get decimalEnabled => false;

  /// Whether the T flag redirects the accumulator operations to the zero
  /// page cell addressed by X, as on the HuC6280.
  bool get supportsTFlag => false;

  /// Whether indexed and branch addressing charge the extra cycle for
  /// crossing a page boundary, as on the NMOS 6502. The HuC6280 does not.
  bool get pageCrossPenalty => true;

  /// Whether the 65C02 zero page indirect addressing mode (opcodes whose
  /// low bits select it) exists, as on the HuC6280.
  bool get zeroPageIndirect => false;

  /// The logical base of the zero page in the variant's address space.
  int get zeroPageBase => 0x0000;

  /// The logical base of the stack page in the variant's address space.
  int get stackBase => 0x0100;

  void push(int val) {
    write(regs.s | stackBase, val);
    regs.s--;
    regs.s &= 0xff;
  }

  int pop() {
    regs.s++;
    regs.s &= 0xff;
    return read(regs.s | stackBase);
  }

  @pragma('vm:prefer-inline')
  int pc() {
    final op = read(regs.pc);
    regs.pc = (regs.pc + 1).mask16;
    return op;
  }

  void branch(bool cond) {
    final offset = (immediate() + 128).mask8 - 128;
    if (pageCrossPenalty) {
      final prevPage = regs.pc & 0xff00;
      if (cond) {
        regs.pc += offset;
        regs.pc &= 0xffff;
        cycle += (prevPage == (regs.pc & 0xff00)) ? 1 : 2;
      }
      cycle += 2;
    } else {
      if (cond) {
        regs.pc = (regs.pc + offset).mask16;
      }
      cycle += 2;
    }
  }

  void flagsV(int a, int b, int acm, {bool sub = false}) {
    flags(acm, sub: sub);
    final overflow = (((a ^ acm) & ((sub ? ~b : b) ^ acm)) & 0x80).shr1;
    regs.p = (regs.p & ~Cpu6502Flags.V) | overflow;
  }

  void flags(int acm, {bool sub = false}) {
    var carry = acm.bit8 ? Cpu6502Flags.C : 0;
    if (sub) {
      carry ^= Cpu6502Flags.C;
    }
    regs.p = (regs.p & ~Cpu6502Flags.C) | carry;
    flagsNZ(acm);
  }

  void flagsNZ(int acm) {
    final negative = acm.bit7 ? Cpu6502Flags.N : 0;
    final zero = (acm.mask8 == 0) ? Cpu6502Flags.Z : 0;

    regs.p = (regs.p & 0x7d) | Cpu6502Flags.U | negative | zero;
  }

  int carry() {
    return regs.p & Cpu6502Flags.C;
  }

  bool isDecimal() {
    return decimalEnabled && regs.p & Cpu6502Flags.D != 0;
  }

  /// Reads a zero page byte. The variant's paging, if any, is part of its
  /// read wiring, so addressing the cell through the zero page base is the
  /// same access.
  int readZeroPage(int addr, {int cycle = 0}) {
    this.cycle += cycle;
    return read(addr.mask8 | zeroPageBase);
  }

  int readAddressing(int op, {bool st = false}) => switch (op) {
        0xa0 || 0xa2 || 0xc0 || 0xe0 => immediate(),
        _ => switch (op & 0x1c) {
            0x08 => immediate(),
            0x04 => readZeroPage(pc(), cycle: 1),
            0x14 => readZeroPage(pc() + regs.x, cycle: 2),
            _ => read(address(op, st: st))
          }
      };

  int address(int op, {bool st = false}) => switch (op & 0x1c) {
        0x04 => zeropage(), // 001
        0x14 => zeropageXY(regs.x), // 101
        0x0c => absolute(), // 011
        0x1c => absoluteXY(regs.x, st: st), // 111
        0x18 => absoluteXY(regs.y, st: st), // 110
        0x00 => indirectX(), // 000
        0x10 => zeroPageIndirect && op.mask4 == 0x02
            ? indirect()
            : indirectY(st: st), // 010
        _ => 0,
      };

  int immediate() => pc();

  int zeropage() {
    cycle += 1;
    return pc() | zeroPageBase;
  }

  int zeropageXY(int offset) {
    cycle += 2;
    return (pc() + offset).mask8 | zeroPageBase;
  }

  int absolute() {
    cycle += 2;
    return pc() | pc().shl8;
  }

  int absoluteXY(int offset, {bool st = false}) {
    final base = pc() | pc().shl8;
    if (!pageCrossPenalty) {
      cycle += 2;
    } else if (st || (base & 0xff00 != (base + offset) & 0xff00)) {
      cycle += 3;
    } else {
      cycle += 2;
    }
    return (base + offset).mask16;
  }

  int indirect() {
    cycle += 4;
    final addr = pc();
    return readZeroPage(addr) | readZeroPage(addr + 1).shl8;
  }

  int indirectX() {
    cycle += 4;
    final addr = pc() + regs.x;
    return readZeroPage(addr) | readZeroPage(addr + 1).shl8;
  }

  int indirectY({bool st = false}) {
    final addr = pc();
    final base = readZeroPage(addr) | readZeroPage(addr + 1).shl8;
    if (!pageCrossPenalty) {
      cycle += 3;
    } else if (st || (base & 0xff00 != (base + regs.y) & 0xff00)) {
      cycle += 4;
    } else {
      cycle += 3;
    }
    return (base + regs.y).mask16;
  }

  /// ADC for the opcode in [op]. The HuC6280 layer calls this again for the
  /// 65C02 zero page indirect form so the arithmetic stays single sourced.
  void execAdc(int op) {
    final t = supportsTFlag && (regs.p & Cpu6502Flags.T) != 0;

    final a = t ? readZeroPage(regs.x) : regs.a;
    final b = readAddressing(op);
    int c = a + (carry() + b);

    if (isDecimal()) {
      // add the bcd digits, carrying from the low digit to the high one
      var lo = a.mask4 + b.mask4 + carry();
      if (lo > 0x09) lo += 0x06;
      c = (a & 0xf0) + (b & 0xf0) + (lo > 0x0f ? 0x10 : 0) + lo.mask4;
      if (c > 0x9f) c += 0x60;
      regs.p = (regs.p & ~Cpu6502Flags.C) | (c > 0xff ? Cpu6502Flags.C : 0);
      c &= 0xff;
      flagsNZ(c);
    } else {
      flagsV(a, b, c, sub: false);
      c &= 0xff;
    }
    cycle += 2;

    if (t) {
      write(zeroPageBase | regs.x, c);
    } else {
      regs.a = c;
    }
  }

  /// SBC for the opcode in [op], the counterpart of [execAdc].
  void execSbc(int op) {
    // the T flag does not apply to SBC
    final a = regs.a;
    final b = readAddressing(op);
    int c = a - ((carry() ^ 0x01) + b);

    if (isDecimal()) {
      // subtract the bcd digits, borrowing from the high digit
      final borrow = carry() ^ 0x01;
      var lo = a.mask4 - b.mask4 - borrow;
      var hi = (a & 0xf0) - (b & 0xf0);
      if (lo < 0) {
        lo -= 0x06;
        hi -= 0x10;
      }
      if (hi < 0) hi -= 0x60;
      regs.p = (regs.p & ~Cpu6502Flags.C) | (c >= 0 ? Cpu6502Flags.C : 0);
      c = (hi & 0xf0) | lo.mask4;
      flagsNZ(c);
    } else {
      flagsV(a, b, c, sub: true);
      c &= 0xff;
    }
    cycle += 2;
    regs.a = c;
  }

  /// AND for the opcode in [op], with the HuC6280 T flag form included.
  void execAnd(int op) {
    if (supportsTFlag && regs.p & Cpu6502Flags.T != 0) {
      final addr = regs.x | zeroPageBase;
      final a = read(addr) & readAddressing(op);
      write(addr, a);
      cycle += 2;
      flagsNZ(a);
    } else {
      regs.a &= readAddressing(op);
      cycle += 2;
      flagsNZ(regs.a);
    }
  }

  /// EOR for the opcode in [op], the counterpart of [execAnd].
  void execEor(int op) {
    if (supportsTFlag && regs.p & Cpu6502Flags.T != 0) {
      final addr = regs.x | zeroPageBase;
      final a = read(addr) ^ readAddressing(op);
      write(addr, a);
      cycle += 2;
      flagsNZ(a);
    } else {
      regs.a ^= readAddressing(op);
      cycle += 2;
      flagsNZ(regs.a);
    }
  }

  /// ORA for the opcode in [op], the counterpart of [execAnd].
  void execOra(int op) {
    if (supportsTFlag && regs.p & Cpu6502Flags.T != 0) {
      final addr = regs.x | zeroPageBase;
      final a = read(addr) | readAddressing(op);
      write(addr, a);
      cycle += 2;
      flagsNZ(a);
    } else {
      regs.a |= readAddressing(op);
      cycle += 2;
      flagsNZ(regs.a);
    }
  }

  /// Executes one base 6502 opcode and returns false when the opcode is not
  /// part of the base set, leaving it to the variant layer.
  bool exec6502(int op) {
    switch (op) {
      // LDA
      case 0xa9: // immediate 101 010 01
      case 0xa5: // zero page 101 001 01
      case 0xb5: // zeropage, X 101 101 01
      case 0xad: // absolute 101 011 01
      case 0xbd: // absolute, X 101 111 01
      case 0xb9: // absolute, Y 101 110 01
      case 0xa1: // (indirect, X) 101 000 01
      case 0xb1: // (indirect), Y 101 100 01
        regs.a = readAddressing(op);
        cycle += 2;
        flagsNZ(regs.a);
        break;

      // LDX
      case 0xa2: // immediate 101 000 10
      case 0xa6: // zeropage 101 001 10
      case 0xae: // absolute 101 011 10
        regs.x = readAddressing(op);
        cycle += 2;
        flagsNZ(regs.x);
        break;
      case 0xb6: // zeropage, Y 101 101 10
        regs.x = read(zeropageXY(regs.y));
        cycle += 2;
        flagsNZ(regs.x);
        break;
      case 0xbe: // absolute, Y 101 111 10
        regs.x = read(absoluteXY(regs.y));
        cycle += 2;
        flagsNZ(regs.x);
        break;

      // LDY
      case 0xa0: // immediate 101 000 00
      case 0xa4: // zeropage 101 001 00
      case 0xb4: // zeropage, X 101 101 00
      case 0xac: // absolute 101 011 00
      case 0xbc: // absolute, X 101 111 00
        regs.y = readAddressing(op);
        cycle += 2;
        flagsNZ(regs.y);
        break;

      // STA
      case 0x85: // zero page
      case 0x95: // zeropage, X
      case 0x8d: // absolute
      case 0x9d: // absolute, X
      case 0x99: // absolute, Y
      case 0x81: // (indirect, X)
      case 0x91: // (indirect), Y
        write(address(op, st: true), regs.a);
        cycle += 2;
        break;

      // STX
      case 0x86: // zero page 100 001 10
      case 0x8e: // absolute 100 011 10
        write(address(op, st: true), regs.x);
        cycle += 2;
        break;
      case 0x96: // zeropage, Y 100 101 10
        write(zeropageXY(regs.y), regs.x);
        cycle += 2;
        break;

      // STY
      case 0x84: // zero page 100 001 00
      case 0x94: // zeropage, X 100 101 00
      case 0x8c: // absolute 100 011 00
        write(address(op, st: true), regs.y);
        cycle += 2;
        break;

      // TAX
      case 0xaa:
        regs.x = regs.a;
        flagsNZ(regs.x);
        cycle += 2;
        break;

      // TAY
      case 0xa8:
        regs.y = regs.a;
        flagsNZ(regs.y);
        cycle += 2;
        break;

      // TSX
      case 0xba:
        regs.x = regs.s;
        flagsNZ(regs.x);
        cycle += 2;
        break;

      // TXA
      case 0x8a:
        regs.a = regs.x;
        flagsNZ(regs.a);
        cycle += 2;
        break;

      // TXS
      case 0x9a:
        regs.s = regs.x;
        cycle += 2;
        break;

      // TYA
      case 0x98:
        regs.a = regs.y;
        flagsNZ(regs.a);
        cycle += 2;
        break;

      // ADC
      case 0x69:
      case 0x65:
      case 0x75:
      case 0x6d:
      case 0x7d:
      case 0x79:
      case 0x61:
      case 0x71:
        execAdc(op);
        break;

      // SBC
      case 0xe9:
      case 0xe5:
      case 0xf5:
      case 0xed:
      case 0xfd:
      case 0xf9:
      case 0xe1:
      case 0xf1:
        execSbc(op);
        break;

      // AND
      case 0x29:
      case 0x25:
      case 0x35:
      case 0x2d:
      case 0x3d:
      case 0x39:
      case 0x21:
      case 0x31:
        execAnd(op);
        break;

      // EOR
      case 0x49:
      case 0x45:
      case 0x55:
      case 0x4d:
      case 0x5d:
      case 0x59:
      case 0x41:
      case 0x51:
        execEor(op);
        break;

      // ORA
      case 0x09:
      case 0x05:
      case 0x15:
      case 0x0d:
      case 0x1d:
      case 0x19:
      case 0x01:
      case 0x11:
        execOra(op);
        break;

      // ASL
      case 0x0a:
        regs.a <<= 1;
        cycle += 2;
        flags(regs.a);
        regs.a &= 0xff;
        break;
      case 0x06:
      case 0x16:
      case 0x0e:
      case 0x1e:
        final addr = address(op, st: true);
        final acm = read(addr).shl1;
        flags(acm);
        write(addr, acm.mask8);
        cycle += 4;
        break;

      // LSR
      case 0x4a:
        final mlb = regs.a.mask1;
        regs.a >>= 1;
        flags(regs.a);
        regs.p |= mlb;
        cycle += 2;
        break;
      case 0x46:
      case 0x56:
      case 0x4e:
      case 0x5e:
        final addr = address(op, st: true);
        var acm = read(addr);
        final mlb = acm.mask1;
        acm >>= 1;
        flags(acm);
        regs.p |= mlb;
        write(addr, acm);
        cycle += 4;
        break;

      // ROL
      case 0x2a:
        regs.a <<= 1;
        regs.a |= carry();
        final msb = regs.a.shr8.mask1;
        cycle += 2;
        flags(regs.a);
        regs.p |= msb;
        regs.a &= 0xff;
        break;
      case 0x26:
      case 0x36:
      case 0x2e:
      case 0x3e:
        final addr = address(op, st: true);
        var acm = read(addr).shl1;
        acm |= carry();
        final msb = acm.shr8.mask1;
        flags(acm);
        regs.p |= msb;
        write(addr, acm.mask8);
        cycle += 4;
        break;

      // ROR
      case 0x6a:
        final bit0 = regs.a.mask1;
        regs.a = regs.a.shr1 | carry().shl7;
        flags(regs.a);
        regs.a &= 0xff;
        regs.p = (regs.p & ~Cpu6502Flags.C) | bit0;
        cycle += 2;
        break;
      case 0x66:
      case 0x76:
      case 0x6e:
      case 0x7e:
        final addr = address(op, st: true);
        var acm = read(addr);
        final bit0 = acm.mask1;
        acm = acm.shr1 | carry().shl7;
        flags(acm);
        regs.p = (regs.p & ~Cpu6502Flags.C) | bit0;
        write(addr, acm);
        cycle += 4;
        break;

      // BIT
      case 0x24: // 001 001 00
      case 0x2c: // 001 011 00
        final acm = readAddressing(op);
        final negative = acm & Cpu6502Flags.N;
        final overflow = acm & Cpu6502Flags.V;
        final zero = ((regs.a & acm) == 0) ? Cpu6502Flags.Z : 0;
        regs.p = (regs.p & 0x3d) | negative | overflow | zero;
        cycle += 2;
        break;

      // CMP
      case 0xc9: // 110 010 01
      case 0xc5: // 110 001 01
      case 0xd5: // 110 101 01
      case 0xcd: // 110 011 01
      case 0xdd: // 110 111 01
      case 0xd9: // 110 110 01
      case 0xc1: // 110 000 01
      case 0xd1: // 110 100 01
        final cmp = regs.a - readAddressing(op);
        cycle += 2;
        flags(cmp, sub: true);
        break;

      // CPX
      case 0xe0: // immediate 111 000 00
      case 0xe4: // zeropage 111 001 00
      case 0xec: // absolute 111 011 00
        final cmp = regs.x - readAddressing(op);
        cycle += 2;
        flags(cmp, sub: true);
        break;

      // CPY
      case 0xc0: // immediate 110 000 00
      case 0xc4: // zeropage 110 001 00
      case 0xcc: // absolute 110 011 00
        final cmp = regs.y - readAddressing(op);
        cycle += 2;
        flags(cmp, sub: true);
        break;

      // INC
      case 0xe6:
      case 0xf6:
      case 0xee:
      case 0xfe:
        final addr = address(op, st: true);
        final acm = (read(addr) + 1).mask8;
        flagsNZ(acm);
        write(addr, acm);
        cycle += 4;
        break;

      // INX
      case 0xe8:
        regs.x++;
        flagsNZ(regs.x);
        regs.x &= 0xff;
        cycle += 2;
        break;

      // INY
      case 0xc8:
        regs.y++;
        flagsNZ(regs.y);
        regs.y &= 0xff;
        cycle += 2;
        break;

      // DEC
      case 0xc6:
      case 0xd6:
      case 0xce:
      case 0xde:
        final addr = address(op, st: true);
        final acm = (read(addr) - 1).mask8;
        flagsNZ(acm);
        write(addr, acm);
        cycle += 4;
        break;

      // DEX
      case 0xca:
        regs.x--;
        flagsNZ(regs.x);
        regs.x &= 0xff;
        cycle += 2;
        break;

      // DEY
      case 0x88:
        regs.y--;
        flagsNZ(regs.y);
        regs.y &= 0xff;
        cycle += 2;
        break;

      // PHA
      case 0x48:
        push(regs.a);
        cycle += 3;
        break;

      // PHP
      case 0x08:
        push(statusForPhp());
        cycle += 3;
        break;

      // PLA
      case 0x68:
        regs.a = pop();
        cycle += 4;
        flagsNZ(regs.a);
        break;

      // PLP
      case 0x28:
        pullFlags(pop());
        cycle += 4;
        break;

      // JMP
      case 0x4c:
        regs.pc = absolute();
        cycle += 1;
        break;

      // JSR
      case 0x20:
        final addr = absolute();
        regs.pc--;
        regs.pc &= 0xffff;
        push(regs.pc.shr8);
        push(regs.pc.mask8);
        regs.pc = addr;
        cycle += 4;
        break;

      // RTS
      case 0x60:
        final addr = pop() | pop().shl8;
        regs.pc = addr + 1;
        regs.pc &= 0xffff;
        cycle += 6;
        break;

      // RTI
      case 0x40:
        pullFlags(pop());
        final addr = pop() | pop().shl8;
        regs.pc = addr;
        cycle += 6;
        onRti();
        break;

      // BCC
      case 0x90:
        branch(carry() == 0);
        break;

      // BCS
      case 0xb0:
        branch(carry() != 0);
        break;

      // BEQ
      case 0xf0:
        branch((regs.p & Cpu6502Flags.Z) != 0);
        break;

      // BMI
      case 0x30:
        branch((regs.p & Cpu6502Flags.N) != 0);
        break;

      // BNE
      case 0xd0:
        branch((regs.p & Cpu6502Flags.Z) == 0);
        break;

      // BPL
      case 0x10:
        branch((regs.p & Cpu6502Flags.N) == 0);
        break;

      // BVC
      case 0x50:
        branch((regs.p & Cpu6502Flags.V) == 0);
        break;

      // BVS
      case 0x70:
        branch((regs.p & Cpu6502Flags.V) != 0);
        break;

      // CLC
      case 0x18:
        regs.p &= ~Cpu6502Flags.C;
        cycle += 2;
        break;

      // CLD
      case 0xd8:
        regs.p &= ~Cpu6502Flags.D;
        cycle += 2;
        break;

      // CLI
      case 0x58:
        regs.p &= ~Cpu6502Flags.I;
        cycle += 2;
        break;

      // CLV
      case 0xb8:
        regs.p &= ~Cpu6502Flags.V;
        cycle += 2;
        break;

      // SEC
      case 0x38:
        regs.p |= Cpu6502Flags.C;
        cycle += 2;
        break;

      // SED
      case 0xf8:
        regs.p |= Cpu6502Flags.D;
        cycle += 2;
        break;

      // SEI
      case 0x78:
        regs.p |= Cpu6502Flags.I;
        cycle += 2;
        break;

      // BRK
      case 0x00:
        interrupt(brk: true);
        cycle += 7;
        break;

      // NOP
      case 0xea:
        cycle += 2;
        break;

      default:
        return false;
    }

    return true;
  }
}
