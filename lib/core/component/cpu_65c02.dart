// Dart imports:
import 'dart:core';

import 'cpu.dart';

mixin Cpu65c02 on Cpu {
  bool exec65c02(op) {
    switch (op) {
      // BRA
      case 0x80:
        branch(true);
        break;

      // TSB : Test and Set Bits with A
      case 0x04:
      case 0x0c:
        final addr = (op == 0x04) ? zeropage() : absolute();
        final a = read(addr) | regs.a;
        flagsNZ(a);
        regs.p = (a & Flags.V) | (regs.p & ~Flags.V);
        write(addr, a);
        cycle += 5;

      // TRB : Test and Reset Bits with A
      case 0x14:
      case 0x1c:
        final addr = (op == 0x14) ? zeropage() : absolute();
        final a = read(addr) & ~regs.a;
        flagsNZ(a);
        regs.p = (a & Flags.V) | (regs.p & ~Flags.V);
        write(addr, a);
        cycle += 5;
        break;

      // STZ
      case 0x64:
        write(zeropage(), 0);
        cycle += 2;
        break;

      case 0x74:
        write(zeropageXY(regs.x), 0);
        cycle += 2;
        break;
      case 0x9c:
        write(absolute(), 0);
        cycle += 2;
        break;
      case 0x9e:
        write(absoluteXY(regs.x), 0);
        cycle += 2;
        break;

      // RMB
      case 0x07:
      case 0x17:
      case 0x27:
      case 0x37:
      case 0x47:
      case 0x57:
      case 0x67:
      case 0x77:
        final value = read(zeropage());
        write(zeropage(), value & ~(1 << (op >> 4)));
        regs.p = 0;
        cycle += 7;
        break;

      // SMB
      case 0x87:
      case 0x97:
      case 0xa7:
      case 0xb7:
      case 0xc7:
      case 0xd7:
      case 0xe7:
      case 0xf7:
        final value = read(zeropage());
        write(zeropage(), value | (1 << ((op & 0x70) >> 4)));
        regs.p = 0;
        cycle += 7;
        break;

      // INC
      case 0x1a:
        regs.a++;
        flagsNZ(regs.a);
        regs.a &= 0xff;
        cycle += 2;
        break;

      // DEC
      case 0x3a:
        regs.a--;
        flagsNZ(regs.a);
        regs.a &= 0xff;
        cycle += 2;
        break;

      // PHX
      case 0xda:
        push(regs.x);
        cycle += 3;
        break;
      // PLX
      case 0xfa:
        regs.x = pop();
        cycle += 4;
        break;

      // PHY
      case 0x5a:
        push(regs.y);
        cycle += 3;
        break;
      // PLY
      case 0x7a:
        regs.y = pop();
        cycle += 4;
        break;

      // BBS : Branch if bit n is Set (also some 65c02)
      case 0x0f:
      case 0x1f:
      case 0x2f:
      case 0x3f:
      case 0x4f:
      case 0x5f:
      case 0x6f:
      case 0x7f:
        int value = read(zeropage());
        branch((value >> (op >> 4)) & 0x01 == 1);
        cycle += 5;
        break;

      // BBR : Branch if bit n is Reset (also some 65c02)
      case 0x8f:
      case 0x9f:
      case 0xaf:
      case 0xbf:
      case 0xcf:
      case 0xdf:
      case 0xef:
      case 0xff:
        int value = read(zeropage());
        branch((value >> ((op & 0x70) >> 4)) & 0x01 == 0);
        cycle += 5;
        break;

      default:
        return false;
    }

    return true;
  }
}
