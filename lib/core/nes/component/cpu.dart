// Dart imports:
import 'dart:core';
import 'dart:developer';

// Project imports:
import '../../../util.dart';
import 'bus.dart';

class Regs {
  int a = 0;
  int x = 0;
  int y = 0;
  int s = 0;
  int p = 0;
  int pc = 0;
}

class Flags {
  static const C = 0x01;
  static const Z = 0x02;
  static const I = 0x04;
  static const D = 0x08;
  static const B = 0x10;
  static const R = 0x20;
  static const V = 0x40;
  static const N = 0x80;
}

class Cpu {
  final regs = Regs();

  final Bus bus;

  Cpu(this.bus) {
    bus.cpu = this;
    read = bus.read;
    write = bus.write;
  }

  int cycle = 0;
  int clocks = 0;

  late final int Function(int) read;
  late final void Function(int, int) write;

  bool exec() {
    final startCycle = cycle;

    if (_assertIrq) {
      _assertIrq = false;
      _holdIrq = false;
      interrupt();
      return true;
    }

    // exec irq on the next execution
    if (_holdIrq && (regs.p & Flags.I) == 0) {
      _assertIrq = true;
    }

    if (_assertNmi) {
      _assertNmi = false;
      _holdNmi = false;
      interrupt(nmi: true);
      return true;
    }

    // exec nmi on the next execution
    if (_holdNmi) {
      _assertNmi = true;
    }

    final op = pc();

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
        final a = regs.a;
        final b = readAddressing(op);
        regs.a += (carry() + b);
        cycle += 2;
        flagsV(a, b, regs.a);
        regs.a &= 0xff;
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
        final a = regs.a;
        final b = readAddressing(op);
        regs.a -= ((carry() ^ 0x01) + b);
        cycle += 2;
        flagsV(a, b, regs.a, sub: true);
        regs.a &= 0xff;
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
        regs.a &= readAddressing(op);
        cycle += 2;
        flagsNZ(regs.a);
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
        regs.a ^= readAddressing(op);
        cycle += 2;
        flagsNZ(regs.a);
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
        regs.a |= readAddressing(op);
        cycle += 2;
        flagsNZ(regs.a);
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
        final acm = read(addr) << 1;
        flags(acm);
        write(addr, acm);
        cycle += 4;
        break;

      // LSR
      case 0x4a:
        final mlb = regs.a & 0x01;
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
        final mlb = acm & 0x01;
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
        final msb = (regs.a >> 8) & 0x01;
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
        var acm = read(addr) << 1;
        acm |= carry();
        final msb = (acm >> 8) & 0x01;
        flags(acm);
        regs.p |= msb;
        write(addr, acm);
        cycle += 4;
        break;

      // ROR
      case 0x6a:
        final bit0 = regs.a & 0x01;
        regs.a = (regs.a >> 1) | (carry() << 7);
        flags(regs.a);
        regs.a &= 0xff;
        regs.p = (regs.p & ~Flags.C) | bit0;
        cycle += 2;
        break;
      case 0x66:
      case 0x76:
      case 0x6e:
      case 0x7e:
        final addr = address(op, st: true);
        var acm = read(addr);
        final bit0 = acm & 0x01;
        acm = (acm >> 1) | (carry() << 7);
        flags(acm);
        regs.p = (regs.p & ~Flags.C) | bit0;
        write(addr, acm);
        cycle += 4;
        break;

      // BIT
      case 0x24: // 001 001 00
      case 0x2c: // 001 011 00
        final acm = readAddressing(op);
        final negative = acm & Flags.N;
        final overflow = acm & Flags.V;
        final zero = ((regs.a & acm) == 0) ? Flags.Z : 0;
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
        final acm = read(addr) + 1;
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
        final acm = read(addr) - 1;
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
        push(regs.p | Flags.B);
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
        regs.p = (pop() & ~Flags.B) | (regs.p & Flags.B) | Flags.R;
        cycle += 4;
        break;

      // JMP
      case 0x4c:
        regs.pc = absolute();
        cycle += 1;
        break;
      case 0x6c:
        final addr = absolute();
        regs.pc = read(addr) | (read(addr & 0xff00 | ((addr + 1) & 0xff)) << 8);
        cycle += 3;
        break;

      // JSR
      case 0x20:
        final addr = absolute();
        regs.pc--;
        regs.pc &= 0xffff;
        push(regs.pc >> 8);
        push(regs.pc & 0xff);
        regs.pc = addr;
        cycle += 4;
        break;

      // RTS
      case 0x60:
        final addr = pop() | (pop() << 8);
        regs.pc = addr + 1;
        regs.pc &= 0xffff;
        cycle += 6;
        break;

      // RTI
      case 0x40:
        regs.p = pop() | Flags.R;
        final addr = pop() | (pop() << 8);
        regs.pc = addr;
        cycle += 6;
        _assertIrq = false;
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
        branch((regs.p & Flags.Z) != 0);
        break;

      // BMI
      case 0x30:
        branch((regs.p & Flags.N) != 0);
        break;

      // BNE
      case 0xd0:
        branch((regs.p & Flags.Z) == 0);
        break;

      // BPL
      case 0x10:
        branch((regs.p & Flags.N) == 0);
        break;

      // BVC
      case 0x50:
        branch((regs.p & Flags.V) == 0);
        break;

      // BVS
      case 0x70:
        branch((regs.p & Flags.V) != 0);
        break;

      // CLC
      case 0x18:
        regs.p &= ~Flags.C;
        cycle += 2;
        break;

      // CLD
      case 0xd8:
        regs.p &= ~Flags.D;
        cycle += 2;
        break;

      // CLI
      case 0x58:
        regs.p &= ~Flags.I;
        cycle += 2;
        break;

      // CLV
      case 0xb8:
        regs.p &= ~Flags.V;
        cycle += 2;
        break;

      // SEC
      case 0x38:
        regs.p |= Flags.C;
        cycle += 2;
        break;

      // SED
      case 0xf8:
        regs.p |= Flags.D;
        cycle += 2;
        break;

      // SEI
      case 0x78:
        regs.p |= Flags.I;
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
        return execUnofficials(op);
    }

    clocks += (cycle - startCycle) * 3;

    return true;
  }

  bool execUnofficials(op) {
    switch (op) {
      // SKB
      case 0x80:
      case 0x82:
      case 0x89:
      case 0xC2:
      case 0xE2:
        pc();
        cycle += 2;
        break;
      // SKB
      case 0x04:
      case 0x44:
      case 0x64:
        zeropage();
        cycle += 2;
        break;
      // SKW
      case 0x0C:
        absolute();
        cycle += 2;
        break;
      // SKB
      case 0x14:
      case 0x34:
      case 0x54:
      case 0x74:
      case 0xD4:
      case 0xF4:
        zeropageXY(regs.x);
        cycle += 2;
        break;
      // LAX
      case 0xA3:
      case 0xA7:
      case 0xAF:
      case 0xB3:
        regs.a = regs.x = readAddressing(op);
        cycle += 2;
        flagsNZ(regs.a);
        break;
      case 0xBF:
        regs.a = regs.x = read(absoluteXY(regs.y));
        cycle += 2;
        flagsNZ(regs.a);
        break;
      case 0xB7:
        regs.a = regs.x = read(zeropageXY(regs.y));
        cycle += 2;
        flagsNZ(regs.a);
        break;

      // SAX
      case 0x83:
      case 0x87:
      case 0x8F:
        write(address(op, st: true), regs.a & regs.x);
        cycle += 2;
        break;
      case 0x97:
        write(zeropageXY(regs.y), regs.a & regs.x);
        cycle += 2;
        break;

      // DCP
      case 0xC3:
      case 0xC7:
      case 0xCF:
      case 0xD3:
      case 0xD7:
      case 0xDB:
      case 0xDF:
        {
          int addr = address(op, st: true);
          int value = (read(addr) - 1) & 0xFF;
          write(addr, value);
          flags(regs.a - value, sub: true);
          cycle += 4;
        }
        break;

      // ISC
      case 0xE3:
      case 0xE7:
      case 0xEF:
      case 0xF3:
      case 0xF7:
      case 0xFB:
      case 0xFF:
        {
          int addr = address(op, st: true);
          int value = (read(addr) + 1) & 0xFF;
          write(addr, value);
          int acm = regs.a - value - (1 - carry());
          flagsV(regs.a, value, acm, sub: true);
          regs.a = acm & 0xFF;
          cycle += 4;
        }
        break;

      // SLO
      case 0x03:
      case 0x07:
      case 0x0F:
      case 0x13:
      case 0x17:
      case 0x1B:
      case 0x1F:
        {
          int addr = address(op, st: true);
          int value = read(addr);
          regs.p = (regs.p & ~Flags.C) | (value >> 7);
          value = (value << 1) & 0xFF;
          write(addr, value);
          regs.a = (regs.a | value) & 0xFF;
          flagsNZ(regs.a);
          cycle += 4;
        }
        break;

      // RLA
      case 0x23:
      case 0x27:
      case 0x2F:
      case 0x33:
      case 0x37:
      case 0x3B:
      case 0x3F:
        {
          int addr = address(op, st: true);
          int value = read(addr);
          int flagC = value >> 7;
          value = ((value << 1) & 0xFF) | carry();
          write(addr, value);
          regs.p = (regs.p & ~Flags.C) | flagC;
          regs.a = (regs.a & value) & 0xFF;
          flagsNZ(regs.a);
          cycle += 4;
        }
        break;

      // SRE
      case 0x43:
      case 0x47:
      case 0x4F:
      case 0x53:
      case 0x57:
      case 0x5B:
      case 0x5F:
        {
          int addr = address(op, st: true);
          int value = read(addr);
          regs.p = (regs.p & ~Flags.C) | (value & 1);
          value = value >> 1;
          write(addr, value);
          regs.a = (regs.a ^ value) & 0xFF;
          flagsNZ(regs.a);
          cycle += 4;
        }
        break;

      // RRA
      case 0x63:
      case 0x67:
      case 0x6F:
      case 0x73:
      case 0x77:
      case 0x7B:
      case 0x7F:
        {
          int addr = address(op, st: true);
          int value = read(addr);
          int flagC = value & 1;
          value = (value >> 1) | (carry() << 7);
          write(addr, value);
          regs.p = (regs.p & ~Flags.C) | flagC;
          int acm = regs.a + value + carry();
          flagsV(regs.a, value, acm);
          regs.a = acm & 0xFF;
          cycle += 4;
        }
        break;

      // ANC
      case 0x0B:
      case 0x2B:
        {
          int value = readAddressing(op);
          regs.a = (regs.a & value) & 0xFF;
          regs.p = (regs.p & ~Flags.C) | (bit7(regs.a) ? Flags.C : 0);
          flagsNZ(regs.a);
          cycle += 2;
        }
        break;

      // ALR
      case 0x4B:
        {
          int value = readAddressing(op);
          regs.a = (regs.a & value) & 0xFF;
          regs.p = (regs.p & ~Flags.C) | (regs.a & 1);
          regs.a = (regs.a >> 1) & 0xFF;
          flagsNZ(regs.a);
          cycle += 2;
        }
        break;

      // ARR
      case 0x6B:
        {
          int value = readAddressing(op);
          regs.a = ((regs.a & value) >> 1) | (carry() << 7);
          int flagC = bit6(regs.a) ? Flags.C : 0;
          int flagV = bit6(regs.a) ^ bit5(regs.a) ? Flags.V : 0;
          regs.p = (regs.p & ~(Flags.V | Flags.C)) | flagC | flagV;
          flagsNZ(regs.a);
          cycle += 2;
        }
        break;

      // SBC
      case 0xeb:
        final a = regs.a;
        final b = immediate();
        regs.a -= ((carry() ^ 0x01) + b);
        cycle += 2;
        flagsV(a, b, regs.a, sub: true);
        regs.a &= 0xff;
        break;

      // NOP
      case 0x1a:
      case 0x3a:
      case 0x5a:
      case 0x7a:
      case 0xda:
      case 0xfa:
        cycle += 2;
        break;

      case 0x1c:
      case 0x3c:
      case 0x5c:
      case 0x7c:
      case 0xdc:
      case 0xfc:
        absoluteXY(regs.x);
        cycle += 2;
        break;

      default:
        log("unimplemented opcode: ${hex8(op)} at ${hex16(regs.pc)}\n");
        return false;
    }

    return true;
  }

  bool _holdNmi = false;
  bool _assertNmi = false;

  void onNmi() {
    _holdNmi = true;
  }

  bool _holdIrq = false;
  bool _assertIrq = false;

  void holdIrq() {
    _holdIrq = true;
  }

  void releaseIrq() {
    _holdIrq = false;
  }

  void interrupt({bool brk = false, bool nmi = false}) {
    final pushAddr = brk ? regs.pc + 1 : regs.pc;
    push(pushAddr >> 8);
    push(pushAddr & 0xff);
    push(regs.p);
    regs.p = (regs.p & ~Flags.B) | (brk ? Flags.B : 0) | Flags.I;

    final addr = nmi ? 0xfffa : 0xfffe;
    regs.pc = read(addr) | (read(addr + 1) << 8);
  }

  void reset() {
    cycle = 0;
    clocks = 0;

    regs.a = 0;
    regs.x = 0;
    regs.y = 0;

    regs.s = 0xfd;
    regs.p = 0x00 | Flags.B | Flags.R;

    const addr = 0xfffc;
    regs.pc = read(addr) | (read(addr + 1) << 8);
  }

  void push(int val) {
    write(regs.s | 0x100, val);
    regs.s--;
    regs.s &= 0xff;
  }

  int pop() {
    regs.s++;
    regs.s &= 0xff;
    return read(regs.s | 0x100);
  }

  int pc() {
    final op = read(regs.pc);
    regs.pc = (regs.pc + 1) & 0xffff;
    return op;
  }

  void branch(bool cond) {
    final offset = ((immediate() + 128) & 0xff) - 128;
    final prevPage = regs.pc & 0xff00;
    if (cond) {
      regs.pc += offset;
      regs.pc &= 0xffff;
      cycle += (prevPage == (regs.pc & 0xff00)) ? 1 : 2;
    }
    cycle += 2;
  }

  void flagsV(int a, int b, int acm, {bool sub = false}) {
    flags(acm, sub: sub);
    final overflow = (((a ^ acm) & ((sub ? ~b : b) ^ acm)) & 0x80) >> 1;
    regs.p = (regs.p & ~Flags.V) | overflow;
  }

  void flags(int acm, {bool sub = false}) {
    var carry = (acm & 0x100 != 0) ? Flags.C : 0;
    if (sub) {
      carry ^= Flags.C;
    }
    regs.p = (regs.p & ~Flags.C) | carry;
    flagsNZ(acm);
  }

  void flagsNZ(int acm) {
    final negative = bit7(acm) ? Flags.N : 0;
    final zero = (acm & 0xff == 0) ? Flags.Z : 0;

    regs.p = (regs.p & 0x7d) | Flags.R | negative | zero;
  }

  int carry() {
    return regs.p & Flags.C;
  }

  int readAddressing(int op, {bool st = false}) {
    return ((op & 0x1c == 0x08) ||
            op == 0xa0 ||
            op == 0xa2 ||
            op == 0xc0 ||
            op == 0xe0)
        ? immediate()
        : read(address(op, st: st));
  }

  int address(int op, {bool st = false}) {
    switch (op & 0x1c) {
      case 0x04: // 001
        return zeropage();
      case 0x14: // 101
        return zeropageXY(regs.x);
      case 0x0c: // 011
        return absolute();
      case 0x1c: // 111
        return absoluteXY(regs.x, st: st);
      case 0x18: // 110
        return absoluteXY(regs.y, st: st);
      case 0x00: // 000
        return indirectX();
      case 0x10: // 100
        return indirectY(st: st);
      default:
        log("umimplemented addressing mode: $op\n");
        return 0;
    }
  }

  int immediate() => pc();

  int zeropage() {
    cycle += 1;
    return pc();
  }

  int zeropageXY(int offset) {
    cycle += 2;
    return (pc() + offset) & 0xff;
  }

  int absolute() {
    cycle += 2;
    return (pc() | (pc() << 8));
  }

  int absoluteXY(int offset, {bool st = false}) {
    final base = (pc() | (pc() << 8));
    if (st || (base & 0xff00 != (base + offset) & 0xff00)) {
      cycle += 3;
    } else {
      cycle += 2;
    }
    return (base + offset) & 0xffff;
  }

  int indirectX() {
    cycle += 4;
    final addr = (pc() + regs.x) & 0xff;
    return read(addr) | (read((addr + 1) & 0xff) << 8);
  }

  int indirectY({bool st = false}) {
    final addr = pc();
    final base = (read(addr) | (read((addr + 1) & 0xff) << 8));
    if (st || (base & 0xff00 != (base + regs.y) & 0xff00)) {
      cycle += 4;
    } else {
      cycle += 3;
    }
    return (base + regs.y) & 0xffff;
  }
}
