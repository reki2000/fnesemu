// Dart imports:
import 'dart:core';

import 'cpu.dart';

extension Cpu6280 on Cpu {
  bool exec6280(op) {
    switch (op) {
      // SXY : swap X and Y
      case 0x02:
        int temp = regs.x;
        regs.x = regs.y;
        regs.y = temp;
        cycle += 3;
        break;

      // SAX : swap A and X
      case 0x22:
        int temp = regs.a;
        regs.a = regs.x;
        regs.x = temp;
        cycle += 3;
        break;

      // SAY : swap A and Y
      case 0x42:
        int temp = regs.a;
        regs.a = regs.y;
        regs.y = temp;
        cycle += 3;
        break;

      // CLA
      case 0x62:
        regs.a = 0;
        cycle += 2;
        break;

      // CLX
      case 0x82:
        regs.x = 0;
        cycle += 2;
        break;

      // CLY
      case 0xC2:
        regs.y = 0;
        cycle += 2;
        break;

      // ST0
      case 0x03:
        bus.vdc.writeReg(immediate());
        cycle += 5;
        break;

      // ST1
      case 0x13:
        bus.vdc.writeLsb(immediate());
        cycle += 5;
        break;

      // ST2
      case 0x23:
        bus.vdc.writeMsb(immediate());
        cycle += 5;
        break;

      // TMA
      case 0x43:
        int reg = immediate();
        for (int i = 0; i < 8; i++) {
          if (reg & 0x01 == 1) {
            regs.a = regs.mpr[i];
          }
          reg >>= 1;
        }
        cycle += 5;
        break;

      // TAM
      case 0x53:
        int reg = immediate();
        for (int i = 0; i < 8; i++) {
          if (reg & 0x01 == 1) {
            regs.mpr[i] = regs.a;
            regs.mprAddress[i] = regs.a << 13;
          }
          reg >>= 1;
        }
        cycle += 4;
        break;

      // TII
      case 0x73:
        int from = absolute();
        int to = absolute();
        int count = absolute();
        if (count == 0) {
          count = 0x10000;
        }
        while (count-- != 0) {
          to &= 0xffff;
          from &= 0xffff;
          write(to++, read(from++));
          cycle += 6;
        }
        cycle += 17;
        break;

      // TST
      case 0x83:
      case 0x93:
      case 0xa3:
      case 0xb3:
        final n = immediate();
        final addr = switch (op) {
          0x83 => zeropage(),
          0xa3 => zeropageXY(regs.x),
          0x93 => absolute(),
          0xb3 => absoluteXY(regs.x),
          _ => 0, // never reach
        };
        final a = n & read(addr);
        regs.p = (a & 0xc0) | ((a == 0) ? Flags.Z : 0) | (regs.p & 0x3d);
        cycle += 6;
        break;

      // TDD
      case 0xc3:
        int from = absolute();
        int to = absolute();
        int count = absolute();
        if (count == 0) {
          count = 0x10000;
        }
        while (count-- != 0) {
          to &= 0xffff;
          from &= 0xffff;
          write(to--, read(from--));
          cycle += 6;
        }
        cycle += 17;
        break;

      // TIN
      case 0xd3:
        int from = absolute();
        int to = absolute();
        int count = absolute();
        if (count == 0) {
          count = 0x10000;
        }
        while (count-- != 0) {
          from &= 0xffff;
          write(to, read(from++));
          cycle += 6;
        }
        cycle += 17;
        break;

      // TIA
      case 0xe3:
        int from = absolute();
        int to = absolute();
        int count = absolute();
        if (count == 0) {
          count = 0x10000;
        }
        int alt = 0;
        while (count-- != 0) {
          from &= 0xffff;
          write((to + alt) & 0xffff, read(from++));
          alt ^= 1;
          cycle += 6;
        }
        cycle += 17;
        break;

      // TAI
      case 0xf3:
        int from = absolute();
        int to = absolute();
        int count = absolute();
        if (count == 0) {
          count = 0x10000;
        }
        int alt = 0;
        while (count-- != 0) {
          to &= 0xffff;
          write(to++, read((from + alt) & 0xffff));
          alt ^= 1;
          cycle += 6;
        }
        cycle += 17;
        break;

      // BSR
      case 0x44:
        push(regs.pc >> 8);
        push(regs.pc & 0xff);
        branch(true);
        cycle += 5;
        break;

      // CSL
      case 0x54:
        isHighSpeed = false;
        cycle += 3;
        break;

      // CSH
      case 0xD4:
        isHighSpeed = true;
        cycle += 3;
        break;

      // SET : set T flag
      case 0xf4:
        tFlagOn = true;
        cycle += 2;
        break;

      // NOP
      default:
        cycle += 2;
        return true;
    }

    return true;
  }
}
