import 'dart:core';

import '../../../components/6502/cpu6502.dart';
import '../../../util/debug.dart';
import '../../../util/int.dart';
import '../../../util/state.dart';
import 'bus.dart';

final _log = DebugLog('nes.cpu');

typedef Regs = Cpu6502Regs;
typedef Flags = Cpu6502Flags;

/// IRQ sources sharing the CPU's IRQ line. The line is asserted while any
/// source holds it.
class IrqSource {
  static const mapper = 0x01;
  static const frameCounter = 0x02;
  static const dmc = 0x04;
  static const all = 0xff;
}

/// The Ricoh 2A03 variant layer over the shared 6502 engine. The 2A03 is an
/// NMOS 6502 whose decimal mode is disabled: the D flag exists in the status
/// register but the engine's ADC and SBC ignore it because this layer leaves
/// the engine's decimal hook off. This layer owns the NES bus wiring, the
/// IRQ and NMI line polling, the interrupt and reset sequences, the JMP
/// indirect page wrap bug and the unofficial opcodes.
class Cpu extends Cpu6502<Cpu6502Regs> {
  final Bus bus;

  Cpu(this.bus) : super(Cpu6502Regs()) {
    bus.cpu = this;
  }

  @override
  int read(int addr) => bus.read(addr);

  @override
  void write(int addr, int data) => bus.write(addr, data);

  @override
  int statusForPhp() => regs.p | Flags.B | Flags.R;

  @override
  void pullFlags(int p) {
    regs.p = (p & ~Flags.B) | Flags.R;
  }

  @override
  void onRti() {
    _assertIrq = false;
  }

  bool exec() {
    if (_assertIrq) {
      _assertIrq = false;
      // the line may have been acknowledged during the last instruction
      if (_irqLines != 0) {
        interrupt();
        cycle += 7;
        return true;
      }
    }

    // exec irq on the next execution
    if (_irqLines != 0 && (regs.p & Flags.I) == 0) {
      _assertIrq = true;
    }

    if (_assertNmi) {
      _assertNmi = false;
      _holdNmi = false;
      interrupt(nmi: true);
      cycle += 7;
      return true;
    }

    // exec nmi on the next execution
    if (_holdNmi) {
      _assertNmi = true;
    }

    final op = pc();

    return exec6502(op) || _execVariant(op);
  }

  bool _execVariant(int op) {
    // JMP (indirect) wraps the high byte fetch inside the pointer's page
    if (op == 0x6c) {
      final addr = absolute();
      regs.pc = read(addr) | (read(addr & 0xff00 | (addr + 1).mask8).shl8);
      cycle += 3;
      return true;
    }

    return execUnofficials(op);
  }

  bool execUnofficials(int op) {
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
          int value = (read(addr) - 1).mask8;
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
          int value = (read(addr) + 1).mask8;
          write(addr, value);
          int acm = regs.a - value - (1 - carry());
          flagsV(regs.a, value, acm, sub: true);
          regs.a = acm.mask8;
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
          regs.p = (regs.p & ~Flags.C) | value.shr7;
          value = value.shl1.mask8;
          write(addr, value);
          regs.a = (regs.a | value).mask8;
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
          int flagC = value.shr7;
          value = value.shl1.mask8 | carry();
          write(addr, value);
          regs.p = (regs.p & ~Flags.C) | flagC;
          regs.a = (regs.a & value).mask8;
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
          regs.p = (regs.p & ~Flags.C) | value.mask1;
          value = value.shr1;
          write(addr, value);
          regs.a = (regs.a ^ value).mask8;
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
          int flagC = value.mask1;
          value = value.shr1 | carry().shl7;
          write(addr, value);
          regs.p = (regs.p & ~Flags.C) | flagC;
          int acm = regs.a + value + carry();
          flagsV(regs.a, value, acm);
          regs.a = acm.mask8;
          cycle += 4;
        }
        break;

      // ANC
      case 0x0B:
      case 0x2B:
        {
          int value = readAddressing(op);
          regs.a = (regs.a & value).mask8;
          regs.p = (regs.p & ~Flags.C) | (regs.a.bit7 ? Flags.C : 0);
          flagsNZ(regs.a);
          cycle += 2;
        }
        break;

      // ALR
      case 0x4B:
        {
          int value = readAddressing(op);
          regs.a = (regs.a & value).mask8;
          regs.p = (regs.p & ~Flags.C) | regs.a.mask1;
          regs.a = regs.a.shr1.mask8;
          flagsNZ(regs.a);
          cycle += 2;
        }
        break;

      // ARR
      case 0x6B:
        {
          int value = readAddressing(op);
          regs.a = (regs.a & value).shr1 | carry().shl7;
          int flagC = regs.a.bit6 ? Flags.C : 0;
          int flagV = regs.a.bit6 ^ regs.a.bit5 ? Flags.V : 0;
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
        _log.warnc(() => "unimplemented opcode: ${op.x2} at ${regs.pc.x4}\n");
        return false;
    }

    return true;
  }

  /// Saves the shared 6502 state and the interrupt line state of this layer.
  @override
  void saveState(StateWriter w) {
    super.saveState(w);
    w.section('nes-cpu');
    w.int32(_irqLines);
    w.boolean(_holdNmi);
    w.boolean(_assertNmi);
    w.boolean(_assertIrq);
  }

  /// Restores the state written by [saveState].
  @override
  void loadState(StateReader s) {
    super.loadState(s);
    s.section('nes-cpu');
    _irqLines = s.int32();
    _holdNmi = s.boolean();
    _assertNmi = s.boolean();
    _assertIrq = s.boolean();
  }

  bool _holdNmi = false;
  bool _assertNmi = false;

  void onNmi() {
    _holdNmi = true;
  }

  int _irqLines = 0;
  bool _assertIrq = false;

  void holdIrq([int source = IrqSource.mapper]) {
    _irqLines |= source;
  }

  void releaseIrq([int source = IrqSource.mapper]) {
    _irqLines &= ~source;
  }

  @override
  void interrupt({bool brk = false, bool nmi = false}) {
    final pushAddr = brk ? regs.pc + 1 : regs.pc;
    push(pushAddr.shr8);
    push(pushAddr.mask8);
    // B flag exists only on the pushed value: set by BRK, clear by IRQ/NMI
    push((regs.p & ~Flags.B) | Flags.R | (brk ? Flags.B : 0));
    regs.p = (regs.p & ~Flags.B) | Flags.I;

    final addr = nmi ? 0xfffa : 0xfffe;
    regs.pc = read(addr) | read(addr + 1).shl8;
  }

  void reset() {
    cycle = 0;

    regs.a = 0;
    regs.x = 0;
    regs.y = 0;

    regs.s = 0xfd;
    regs.p = Flags.I | Flags.R;
    _assertIrq = false;
    _assertNmi = false;
    _holdNmi = false;

    const addr = 0xfffc;
    regs.pc = read(addr) | read(addr + 1).shl8;
  }
}
