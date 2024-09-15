// Dart imports:
import 'dart:core';

import 'cpu.dart';

extension Cpu6502 on Cpu {
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
      case 0xb2: // (indirect) 101 100 10
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
      case 0x92: // (indirect)
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
      case 0x72:
        final t = (regs.p & Flags.T) != 0;

        int addr = 0;
        int a = 0;

        if (t) {
          addr = zeropageXY(regs.x);
          a = read(addr);
        } else {
          a = regs.a;
        }

        final b = readAddressing(op);
        int c = a + (carry() + b);

        if (isDecimal()) {
          final carry = (c >= 100) ? Flags.C : 0;
          c %= 100;
          c = (c % 10) | ((c ~/ 10) << 4);
          flagsNZ(c);
          regs.p = (regs.p & ~Flags.C) | carry;
        } else {
          flagsV(a, b, c, sub: false);
          c &= 0xff;
        }
        cycle += 2;

        if (t) {
          write(addr, c);
        } else {
          regs.a = c;
        }
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
      case 0xf2:
        final t = (regs.p & Flags.T) != 0;

        int addr = 0;
        int a = 0;

        if (t) {
          addr = zeropageXY(regs.x);
          a = read(addr);
        } else {
          a = regs.a;
        }

        final b = readAddressing(op);
        int c = a - ((carry() ^ 0x01) + b);

        if (isDecimal()) {
          final carry = (c >= 100) ? Flags.C : 0;
          c %= 100;
          c = (c % 10) | ((c ~/ 10) << 4);
          flagsNZ(c);
          regs.p = (regs.p & ~Flags.C) | carry;
        } else {
          flagsV(a, b, c, sub: true);
          c &= 0xff;
        }
        cycle += 2;

        if (t) {
          write(addr, c);
        } else {
          regs.a = c;
        }
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
      case 0x32:
        if (regs.p & Flags.T != 0) {
          int a = read(regs.x);
          a &= readAddressing(op);
          write(regs.x, a);
          cycle += 2;
          flagsNZ(a);
        } else {
          regs.a &= readAddressing(op);
          cycle += 2;
          flagsNZ(regs.a);
        }
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
      case 0x52:
        if (regs.p & Flags.T != 0) {
          int a = read(regs.x);
          a ^= readAddressing(op);
          write(regs.x, a);
          cycle += 2;
          flagsNZ(a);
        } else {
          regs.a ^= readAddressing(op);
          cycle += 2;
          flagsNZ(regs.a);
        }
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
      case 0x12:
        if (regs.p & Flags.T != 0) {
          int a = read(regs.x);
          a |= readAddressing(op);
          write(regs.x, a);
          cycle += 2;
          flagsNZ(a);
        } else {
          regs.a |= readAddressing(op);
          cycle += 2;
          flagsNZ(regs.a);
        }
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
        int acm = read(addr) << 1;
        flags(acm);
        acm &= 0xff;
        write(addr, acm);
        cycle += 4;
        break;

      // LSR
      case 0x4a:
        final lsb = regs.a & 0x01;
        regs.a >>= 1;
        flags(regs.a);
        regs.p |= lsb;
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
        acm &= 0xff;
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
        acm &= 0xff;
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
        acm &= 0xff;
        regs.p = (regs.p & ~Flags.C) | bit0;
        write(addr, acm);
        cycle += 4;
        break;

      // BIT
      case 0x24: // 001 001 00
      case 0x2c: // 001 011 00
      case 0x34: // 001 101 00 65c02
      case 0x3c: // 001 111 00 65c02
      case 0x89: // 100 010 01 65c02
        final a = regs.a &
            switch (op) {
              0x3c => read(absoluteXY(regs.x)),
              0x34 => read(zeropageXY(regs.x)),
              0x89 => immediate(),
              _ => read(address(op))
            };
        flagsNZ(a);
        regs.p = (a & Flags.V) | (regs.p & ~Flags.V);
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
        final acm = (read(addr) + 1) & 0xff;
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
        final acm = (read(addr) - 1) & 0xff;
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
        regs.p = pop();
        cycle += 4;
        break;

      // JMP
      case 0x4c:
        regs.pc = absolute();
        cycle += 1;
        break;
      case 0x6c:
      case 0x7c:
        final addr = absolute() + (op == 0x7c ? regs.x : 0);
        regs.pc = read(addr) | (read((addr + 1) & 0xffff) << 8);
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
        regs.p = pop();
        final addr = pop() | (pop() << 8);
        regs.pc = addr;
        cycle += 6;
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
        return false;
    }

    return true;
  }
}
