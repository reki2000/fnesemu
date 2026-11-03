import 'dart:typed_data';

import '../../util/int.dart';
import 'bus.dart';

/// The shared SH-2 (SH7604) integer interpreter: the register and control
/// state, the single-step execution around fetch and delay slots, exception
/// entry and the instruction dispatch itself.
///
/// The SS and 32X CPUs apply this mixin and supply the parts that are
/// genuinely core-specific through [execBus], [div1], [macL] and [macW]:
/// each core wires its own address map in front of the CPU, and the DIV1 and
/// MAC instructions keep the exact semantics and clock charges the two cores
/// have today (the SS forms saturate through the 48-bit accumulator and set
/// the MACH overflow flag in MAC.W, the 32X forms charge two extra clocks
/// for MAC.L and MAC.W), so they stay as per-core hooks instead of being
/// forced onto one formulation. Interrupt acceptance, compiled-block
/// dispatch, on-chip ticking and save states also stay in the core layers.
mixin Sh2Interpreter {
  /// the bus seen by the instructions, supplied by the core
  Sh2Bus get execBus;

  /// DIV1 (opcode 3/4): one division step, supplied by the core
  void div1(int n, int rm);

  /// MAC.L (opcode 0/15): supplied by the core
  void macL(int n, int m);

  /// MAC.W (opcode 4/15): supplied by the core
  void macW(int n, int m);

  // stores wrap to 32 bits, and typed data keeps the values unboxed.
  // [state] shares its storage with the JIT context: 0 SR, 1 GBR, 2 VBR,
  // 3 PR, 4 MACH, 5 MACL, 6 last opcode, 7 native write count.
  late final Uint32List r;
  late final Uint32List state;
  int pc = 0;
  int clocks = 0;
  bool sleeping = false, inDelay = false;
  // -1: none (avoids boxing of nullable ints)
  int delayTarget = -1, restoreSr = -1;

  @pragma('vm:prefer-inline')
  int get sr => state[0];
  @pragma('vm:prefer-inline')
  set sr(int value) => state[0] = value;
  @pragma('vm:prefer-inline')
  int get gbr => state[1];
  @pragma('vm:prefer-inline')
  set gbr(int value) => state[1] = value;
  @pragma('vm:prefer-inline')
  int get vbr => state[2];
  @pragma('vm:prefer-inline')
  set vbr(int value) => state[2] = value;
  @pragma('vm:prefer-inline')
  int get pr => state[3];
  @pragma('vm:prefer-inline')
  set pr(int value) => state[3] = value;
  @pragma('vm:prefer-inline')
  int get mach => state[4];
  @pragma('vm:prefer-inline')
  set mach(int value) => state[4] = value;
  @pragma('vm:prefer-inline')
  int get macl => state[5];
  @pragma('vm:prefer-inline')
  set macl(int value) => state[5] = value;
  @pragma('vm:prefer-inline')
  int get lastOpcode => state[6];
  @pragma('vm:prefer-inline')
  set lastOpcode(int value) => state[6] = value;
  @pragma('vm:prefer-inline')
  bool get t => sr.bit0;
  @pragma('vm:prefer-inline')
  set t(bool value) => sr = (sr & ~1) | (value ? 1 : 0);
  @pragma('vm:prefer-inline')
  int get interruptMask => sr.shr4.mask4;

  /// enters an exception or interrupt: pushes SR and the return PC, sets the
  /// interrupt mask to [level] when given and jumps through the vector table
  void raiseException(int vector, int savedPc, {int? level}) {
    r[15] = (r[15] - 4).mask32;
    execBus.write32(r[15], sr);
    r[15] = (r[15] - 4).mask32;
    execBus.write32(r[15], savedPc);
    if (level != null) sr = (sr & ~0xf0) | level.shl4;
    pc = execBus.read32((vbr + vector * 4).mask32);
    delayTarget = restoreSr = -1;
    sleeping = false;
    clocks += 5;
  }

  /// executes one interpreted instruction, fetching its opcode through
  /// [fetch]; interrupt acceptance and compiled execution are the caller's
  /// job and happen before this call. returns false when the instruction is
  /// unsupported, with the CPU state rolled back to the instruction
  bool execInterpreted(int Function(int address) fetch) {
    if (sleeping) {
      clocks++;
      return true;
    }
    if (pc.bit0) {
      raiseException(9, pc);
      return true;
    }
    final target = delayTarget;
    final restore = restoreSr;
    final address = pc;
    final op = fetch(address);
    // the lastOpcode slot, also read by the JIT context and saved states
    state[6] = op;
    pc = (pc + 2).mask32;
    delayTarget = restoreSr = -1;
    inDelay = target >= 0;
    if (!_execute(op, address)) {
      pc = address;
      delayTarget = target;
      restoreSr = restore;
      return false;
    }
    sr &= 0x3f3;
    clocks++;
    if (target >= 0) {
      pc = target;
      if (restore >= 0) sr = restore & 0x3f3;
    }
    return true;
  }

  @pragma('vm:prefer-inline')
  bool _branch(int target, {bool delay = true}) {
    if (inDelay) return false;
    if (delay) {
      delayTarget = target.mask32;
    } else {
      pc = target.mask32;
    }
    clocks++;
    return true;
  }

  bool _execute(int op, int address) {
    final n = op.shr8.mask4, m = op.shr4.mask4, low = op.mask4;
    switch (op.shr12) {
      case 0xe:
        r[n] = op.rel8;
        return true;
      case 7:
        r[n] += op.rel8;
        return true;
      case 9:
        r[n] = execBus.read16(address + 4 + op.mask8 * 2).rel16;
        return true;
      case 0xd:
        r[n] = execBus.read32(((address + 4) & ~3) + op.mask8 * 4);
        return true;
      case 1:
        execBus.write32(r[n] + low * 4, r[m]);
        return true;
      case 5:
        r[n] = execBus.read32(r[m] + low * 4);
        return true;
      case 0xa:
        return _branch(address + 4 + op.rel12 * 2);
      case 0xb:
        if (inDelay) return false;
        pr = (address + 4).mask32;
        return _branch(address + 4 + op.rel12 * 2);
      case 6:
        final value = r[m];
        switch (low) {
          case 0:
            r[n] = execBus.read8(value).rel8;
          case 1:
            r[n] = execBus.read16(value).rel16;
          case 2:
            r[n] = execBus.read32(value);
          case 3:
            r[n] = value;
          case 4:
            r[n] = execBus.read8(value).rel8;
            if (n != m) r[m] += 1;
          case 5:
            r[n] = execBus.read16(value).rel16;
            if (n != m) r[m] += 2;
          case 6:
            r[n] = execBus.read32(value);
            if (n != m) r[m] += 4;
          case 7:
            r[n] = ~value;
          case 8:
            r[n] = (value & 0xffff0000) | value.mask8.shl8 | value.shr8.mask8;
          case 9:
            r[n] = value.mask16.shl16 | value.shr16;
          case 10:
            final result = -value - (t ? 1 : 0);
            r[n] = result;
            t = result < 0;
          case 11:
            r[n] = -value;
          case 12:
            r[n] = value.mask8;
          case 13:
            r[n] = value.mask16;
          case 14:
            r[n] = value.rel8;
          case 15:
            r[n] = value.rel16;
        }
        return true;
      case 2:
        final value = r[m];
        switch (low) {
          case 0:
            execBus.write8(r[n], value);
          case 1:
            execBus.write16(r[n], value);
          case 2:
            execBus.write32(r[n], value);
          case 4:
            r[n] -= 1;
            execBus.write8(r[n], value);
          case 5:
            r[n] -= 2;
            execBus.write16(r[n], value);
          case 6:
            r[n] -= 4;
            execBus.write32(r[n], value);
          case 7:
            final q = r[n].shr31.mask1, mb = value.shr31.mask1;
            sr = (sr & ~0x301) | q.shl8 | mb.shl9 | (q ^ mb);
          case 8:
            t = (r[n] & value) == 0;
          case 9:
            r[n] &= value;
          case 10:
            r[n] ^= value;
          case 11:
            r[n] |= value;
          case 12:
            final diff = r[n] ^ value;
            t = diff.mask8 == 0 ||
                diff & 0xff00 == 0 ||
                diff & 0xff0000 == 0 ||
                diff & 0xff000000 == 0;
          case 13:
            r[n] = value.shl16 | r[n].shr16;
          case 14:
            macl = r[n].mask16 * value.mask16;
          case 15:
            macl = (r[n].rel16 * value.rel16).mask32;
          default:
            return false;
        }
        return true;
      case 3:
        final a = r[n], b = r[m];
        switch (low) {
          case 0:
            t = a == b;
          case 2:
            t = a >= b;
          case 3:
            t = a.rel32 >= b.rel32;
          case 4:
            div1(n, b);
          case 5 || 13:
            final product = low == 5 ? a * b : a.rel32 * b.rel32;
            macl = product.mask32;
            mach = (product >> 32).mask32;
          case 6:
            t = a > b;
          case 7:
            t = a.rel32 > b.rel32;
          case 8:
            r[n] = a - b;
          case 10:
            final result = a - b - (t ? 1 : 0);
            r[n] = result;
            t = result < 0;
          case 11:
            final result = a - b;
            r[n] = result;
            t = ((a ^ b) & (a ^ result)).bit31;
          case 12:
            r[n] = a + b;
          case 14:
            final result = a + b + (t ? 1 : 0);
            r[n] = result;
            t = result > 0xffffffff;
          case 15:
            final result = a + b;
            r[n] = result;
            t = (~(a ^ b) & (a ^ result)).bit31;
          default:
            return false;
        }
        return true;
      case 8:
        final displacement = op.rel8 * 2;
        switch (op.shr8.mask4) {
          case 0:
            execBus.write8(r[m] + low, r[0]);
          case 1:
            execBus.write16(r[m] + low * 2, r[0]);
          case 4:
            r[0] = execBus.read8(r[m] + low).rel8;
          case 5:
            r[0] = execBus.read16(r[m] + low * 2).rel16;
          case 8:
            t = r[0] == op.rel8.mask32;
          case 9 || 11 || 13 || 15:
            if (inDelay) return false;
            final take = (n == 9 || n == 13) ? t : !t;
            if (take) {
              return _branch(address + 4 + displacement, delay: n >= 13);
            }
          default:
            return false;
        }
        return true;
      case 0xc:
        final imm = op.mask8;
        switch (n) {
          case 0:
            execBus.write8(gbr + imm, r[0]);
          case 1:
            execBus.write16(gbr + imm * 2, r[0]);
          case 2:
            execBus.write32(gbr + imm * 4, r[0]);
          case 3:
            if (inDelay) return false;
            raiseException(imm, pc);
          case 4:
            r[0] = execBus.read8(gbr + imm).rel8;
          case 5:
            r[0] = execBus.read16(gbr + imm * 2).rel16;
          case 6:
            r[0] = execBus.read32(gbr + imm * 4);
          case 7:
            r[0] = ((address + 4) & ~3) + imm * 4;
          case 8:
            t = (r[0] & imm) == 0;
          case 9:
            r[0] &= imm;
          case 10:
            r[0] ^= imm;
          case 11:
            r[0] |= imm;
          case 12:
            t = (execBus.read8(gbr + r[0]) & imm) == 0;
          case 13:
            execBus.write8(gbr + r[0], execBus.read8(gbr + r[0]) & imm);
          case 14:
            execBus.write8(gbr + r[0], execBus.read8(gbr + r[0]) ^ imm);
          case 15:
            execBus.write8(gbr + r[0], execBus.read8(gbr + r[0]) | imm);
        }
        return true;
    }
    if (op.shr12 == 0) {
      switch (low) {
        case 4:
          execBus.write8(r[n] + r[0], r[m]);
          return true;
        case 5:
          execBus.write16(r[n] + r[0], r[m]);
          return true;
        case 6:
          execBus.write32(r[n] + r[0], r[m]);
          return true;
        case 7:
          macl = (r[n] * r[m]).mask32;
          return true;
        case 12:
          r[n] = execBus.read8(r[m] + r[0]).rel8;
          return true;
        case 13:
          r[n] = execBus.read16(r[m] + r[0]).rel16;
          return true;
        case 14:
          r[n] = execBus.read32(r[m] + r[0]);
          return true;
        case 15:
          macL(n, m);
          return true;
      }
      switch (op & 0xf0ff) {
        case 0x0002:
          r[n] = sr;
          return true;
        case 0x0012:
          r[n] = gbr;
          return true;
        case 0x0022:
          r[n] = vbr;
          return true;
        case 0x000a:
          r[n] = mach;
          return true;
        case 0x001a:
          r[n] = macl;
          return true;
        case 0x002a:
          r[n] = pr;
          return true;
        case 0x0029:
          r[n] = t ? 1 : 0;
          return true;
        case 0x0003:
          if (inDelay) return false;
          pr = address + 4;
          return _branch(address + 4 + r[n]);
        case 0x0023:
          return _branch(address + 4 + r[n]);
      }
      switch (op) {
        case 0x0008:
          t = false;
          return true;
        case 0x0018:
          t = true;
          return true;
        case 0x0009:
          return true;
        case 0x0019:
          sr &= ~0x301;
          return true;
        case 0x0028:
          mach = macl = 0;
          return true;
        case 0x000b:
          return _branch(pr);
        case 0x001b:
          if (inDelay) return false;
          sleeping = true;
          return true;
        case 0x002b:
          if (inDelay) return false;
          final next = execBus.read32(r[15]);
          final status = execBus.read32(r[15] + 4);
          r[15] += 8;
          restoreSr = status;
          return _branch(next);
      }
    }
    if (op.shr12 == 4) {
      if (low == 15) {
        macW(n, m);
        return true;
      }
      switch (op.mask8) {
        case 0x00 || 0x20:
          t = r[n].bit31;
          r[n] <<= 1;
        case 0x01:
          t = r[n].isOdd;
          r[n] >>= 1;
        case 0x21:
          t = r[n].isOdd;
          r[n] = r[n].rel32.shr1;
        case 0x04:
          final carry = r[n].shr31.mask1;
          r[n] = r[n].shl1 | carry;
          t = carry != 0;
        case 0x05:
          final carry = r[n].mask1;
          r[n] = r[n].shr1 | carry.shl31;
          t = carry != 0;
        case 0x24:
          final old = t;
          t = r[n].bit31;
          r[n] = r[n].shl1 | (old ? 1 : 0);
        case 0x25:
          final old = t;
          t = r[n].isOdd;
          r[n] = r[n].shr1 | (old ? 0x80000000 : 0);
        case 0x08:
          r[n] <<= 2;
        case 0x09:
          r[n] >>= 2;
        case 0x18:
          r[n] <<= 8;
        case 0x19:
          r[n] >>= 8;
        case 0x28:
          r[n] <<= 16;
        case 0x29:
          r[n] >>= 16;
        case 0x10:
          r[n]--;
          t = r[n].mask32 == 0;
        case 0x11:
          t = r[n].rel32 >= 0;
        case 0x15:
          t = r[n].rel32 > 0;
        case 0x0b:
          if (inDelay) return false;
          pr = address + 4;
          return _branch(r[n]);
        case 0x2b:
          return _branch(r[n]);
        case 0x1b:
          final value = execBus.read8(r[n]);
          t = value == 0;
          execBus.write8(r[n], value | 0x80);
        case 0x0e:
          sr = r[n] & 0x3f3;
        case 0x1e:
          gbr = r[n];
        case 0x2e:
          vbr = r[n];
        case 0x0a:
          mach = r[n];
        case 0x1a:
          macl = r[n];
        case 0x2a:
          pr = r[n];
        case 0x02 || 0x12 || 0x22 || 0x03 || 0x13 || 0x23:
          final value = switch (op.mask8) {
            2 => mach,
            0x12 => macl,
            0x22 => pr,
            3 => sr,
            0x13 => gbr,
            _ => vbr
          };
          r[n] -= 4;
          execBus.write32(r[n], value);
        case 0x06 || 0x16 || 0x26 || 0x07 || 0x17 || 0x27:
          final value = execBus.read32(r[n]);
          r[n] += 4;
          switch (op.mask8) {
            case 6:
              mach = value;
            case 0x16:
              macl = value;
            case 0x26:
              pr = value;
            case 7:
              sr = value & 0x3f3;
            case 0x17:
              gbr = value;
            case 0x27:
              vbr = value;
          }
        default:
          return false;
      }
      return true;
    }
    return false;
  }

}
