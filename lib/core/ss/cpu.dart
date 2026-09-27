/// CPU abstraction used by the SS core.
///
/// The SH-2 interpreter is derived from another core of this project and plugged
/// in through this interface. The on-chip peripherals of SH7604 (FRT, DIVU,
/// DMAC, INTC, WDT, cache) belong to the CPU implementation.
abstract class SsCpu {
  /// elapsed CPU clocks since reset
  int get clocks;

  int get pc;
  int get sp;

  /// executes one instruction, returns false on an unimplemented instruction
  bool step();

  /// executes instructions until `clocks` reaches `targetClocks`
  bool run(int targetClocks) {
    while (clocks < targetClocks) {
      if (!step()) return false;
    }
    return true;
  }

  void reset();

  /// external interrupt request level (IRL, 0 = none).
  /// When the CPU accepts the interrupt, it calls `onIrlAck` to get the vector.
  void setIrl(int level);
  int Function() onIrlAck = () => 0x40;

  void nmi();

  /// FRT input capture (MINIT / SINIT)
  void frtInputCapture();

  String dump();

  /// returns (disassembled instruction, instruction bytes)
  (String, int) disasm(int addr);
}

/// memory bus seen from the SH-2 (external area only, big-endian)
abstract class SsCpuBus {
  int read8(int addr);
  int read16(int addr);
  int read32(int addr);
  void write8(int addr, int data);
  void write16(int addr, int data);
  void write32(int addr, int data);
}

/// placeholder until the shared SH-2 interpreter is available
class NullCpu extends SsCpu {
  final SsCpuBus bus;
  final bool master;

  NullCpu(this.bus, {this.master = true});

  int _clocks = 0;
  int _pc = 0;
  int _sp = 0;

  @override
  int get clocks => _clocks;

  @override
  int get pc => _pc;

  @override
  int get sp => _sp;

  @override
  bool step() {
    _clocks += 1;
    return true;
  }

  @override
  void reset() {
    // SH-2 power-on reset vector: PC at 0x00000000, SP at 0x00000004
    _pc = bus.read32(0);
    _sp = bus.read32(4);
    _clocks = 0;
  }

  @override
  void setIrl(int level) {}

  @override
  void nmi() {}

  @override
  void frtInputCapture() {}

  @override
  String dump() => "pc:${_pc.toRadixString(16)} (no sh-2 core)";

  @override
  (String, int) disasm(int addr) => ("${addr.toRadixString(16)}: ???", 2);
}
