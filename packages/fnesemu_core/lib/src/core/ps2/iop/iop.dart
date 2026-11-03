import '../../../components/r3000/bus.dart';
import '../../../components/r3000/r3000.dart';
import '../state.dart';

/// Memory interface of the IOP, the shared R3000 bus under its established name.
typedef IopBus = R3000Bus;

/// The I/O processor: the PS2 embedding of the shared R3000 core, a MIPS I (R3000A class) CPU without the GTE.
/// Exceptions and the load delay slot follow the MIPS I architecture; the IOP layer keeps the interrupt line and its mirroring into Cause.IP2, the address error exceptions on misaligned accesses, and the state serialization.
class Iop extends R3000Core {
  static const cop0BadVAddr = R3000Core.cop0BadVAddr;
  static const cop0Status = R3000Core.cop0Status;
  static const cop0Cause = R3000Core.cop0Cause;
  static const cop0Epc = R3000Core.cop0Epc;
  static const cop0PrId = R3000Core.cop0PrId;
  static const resetVector = R3000Core.resetVector;

  static const excInterrupt = R3000Core.excInterrupt;
  static const excAdEL = R3000Core.excAdEL;
  static const excAdES = R3000Core.excAdES;
  static const excSyscall = R3000Core.excSyscall;
  static const excBreak = R3000Core.excBreak;
  static const excReserved = R3000Core.excReserved;
  static const excCopUnusable = R3000Core.excCopUnusable;
  static const excOverflow = R3000Core.excOverflow;

  bool _hwInterrupt = false;

  Iop(super.bus, {super.regs}) {
    reset();
  }

  @override
  bool get strictAlignment => true;

  @override
  bool linksRegimm(int rt) => (rt & 0x1e) == 0x10;

  @override
  bool cop0CommandApplies(int rs) => rs != 0x00 && rs != 0x04;

  @override
  int readCop0(int reg) => cop0[reg];

  @override
  void writeCop0(int reg, int value) {
    switch (reg) {
      case cop0Cause:
        cop0[reg] = (cop0[reg] & ~0x300) | (value & 0x300);
      case cop0Status:
        cop0[reg] = value;
      case 3 || 5 || 6 || 7 || 9 || 11:
        cop0[reg] = value; // breakpoint registers: stored only
      default:
        break;
    }
  }

  @override
  void copAbsent(int op) => exception(excCopUnusable, coprocessor: op & 3);

  @override
  void exception(int code, {int coprocessor = 0, int? badvaddr}) {
    final sr = cop0[cop0Status];
    final bev = sr & 0x00400000 != 0;
    var cause = cop0[cop0Cause] & ~0x8000007c & ~0x30000000;
    cause |= code << 2;
    cause |= coprocessor << 28;
    if (inDelaySlot) {
      cop0[cop0Epc] = instPc - 4;
      cause |= 0x80000000;
    } else {
      cop0[cop0Epc] = instPc;
    }
    cop0[cop0Cause] = cause;
    cop0[cop0Status] = (sr & ~0x3f) | ((sr << 2) & 0x3c);
    final vector = bev ? 0xbfc00180 : 0x80000080;
    pc = vector;
    nextPc = vector + 4;
    inDelaySlot = inBranchDelay = false;
    nextDelayReg = 0;
  }

  /// Whether compiled code may run from [pc]: the next instruction is
  /// not a branch delay slot, no interrupt is ready to be taken under
  /// the same test [step] applies, and the cache is not isolated.
  bool prepareCompiled() =>
      !inBranchDelay && nextPc == pc + 4 && !cacheIsolated && !_interruptPending();

  bool _interruptPending() {
    final sr = cop0[cop0Status];
    if (sr & 1 == 0) return false;
    final ip = (cop0[cop0Cause] & 0x300) | (_hwInterrupt ? 0x400 : 0);
    return ip & sr & 0xff00 != 0;
  }

  /// the interrupt line, as [step] mirrors it into Cause.IP2
  bool get interruptAsserted => _hwInterrupt;

  /// The load still in its delay, for the compiled code adapter: the
  /// register it writes and its value. Between instructions the
  /// in-flight load is always zero, so this is the whole state a block
  /// hands over.
  (int, int) pendingLoad() => (nextDelayReg, nextDelayVal);

  void setPendingLoad(int reg, int value) {
    nextDelayReg = reg;
    nextDelayVal = value;
  }

  void reset() {
    r.fillRange(0, 32, 0);
    cop0.fillRange(0, 32, 0);
    cop0[cop0Status] = 0x00400000; // BEV
    cop0[cop0PrId] = 0x1f;
    pc = resetVector;
    nextPc = resetVector + 4;
    hi = lo = 0;
    inDelaySlot = inBranchDelay = false;
    inBranchTaken = delaySlotTaken = false;
    nextDelayReg = delayReg = 0;
    _hwInterrupt = false;
  }

  void saveState(StateWriter w) {
    w.section('iop');
    w.typed(r);
    w.typed(cop0);
    w.ints([
      pc, nextPc, hi, lo, clocks, nextDelayReg, nextDelayVal, delayReg, //
      delayVal, instPc
    ]);
    for (final b in [inDelaySlot, inBranchDelay, _hwInterrupt]) {
      w.boolean(b);
    }
  }

  void loadState(StateReader s) {
    s.section('iop');
    s.typed(r);
    s.typed(cop0);
    final v = s.fields(10, 'iop');
    pc = v[0];
    nextPc = v[1];
    hi = v[2];
    lo = v[3];
    clocks = v[4];
    nextDelayReg = v[5];
    nextDelayVal = v[6];
    delayReg = v[7];
    delayVal = v[8];
    instPc = v[9];
    inDelaySlot = s.boolean();
    inBranchDelay = s.boolean();
    _hwInterrupt = s.boolean();
  }

  /// the interrupt line, seen as Cause.IP2
  void setInterrupt(bool asserted) {
    _hwInterrupt = asserted;
  }

  void jump(int address) {
    pc = address;
    nextPc = address + 4;
    inDelaySlot = inBranchDelay = false;
  }

  /// Executes one instruction.
  void step() {
    clocks++;
    final cause = cop0[cop0Cause];
    final hwBit = _hwInterrupt ? 0x400 : 0;
    final ip = (cause & 0x300) | hwBit;
    // Cause.IP2 mirrors the interrupt line; write it only when it changes.
    if ((cause & 0x400) != hwBit) cop0[cop0Cause] = (cause & ~0x400) | hwBit;
    final sr = cop0[cop0Status];
    final at = pc;
    instPc = at;
    inDelaySlot = inBranchDelay;
    if (sr & 1 != 0 && (ip & sr & 0xff00) != 0) {
      // the interrupted instruction is not executed; EPC points at it. The
      // load of the previous instruction still completes.
      if (nextDelayReg != 0) r[nextDelayReg] = nextDelayVal;
      r[0] = 0;
      exception(excInterrupt);
      return;
    }

    final ir = bus.read32(at);
    pc = nextPc;
    nextPc = pc + 4;
    inBranchDelay = false;

    // The load issued by the previous instruction lands after this one reads
    // its operands and before this instruction's own write lands, as in the
    // PS step: a write to the loaded register wins over the load.
    delayReg = nextDelayReg;
    delayVal = nextDelayVal;
    nextDelayReg = 0;
    immediateReg = 0;
    immediateVal = 0;
    exec(ir);
    if (delayReg != 0 && nextDelayReg != delayReg) {
      r[delayReg] = delayVal;
    }
    delayReg = 0;
    if (immediateReg != 0) r[immediateReg] = immediateVal;
    r[0] = 0;
  }
}
