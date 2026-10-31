import 'state.dart';

/// The EE interrupt controller. Its pending interrupt drives INT0 of the CPU.
class Intc {
  static const gs = 0, sbus = 1, vblankStart = 2, vblankEnd = 3;
  static const vif0 = 4, vif1 = 5, vu0 = 6, vu1 = 7, ipu = 8;
  static const timer0 = 9, sfifo = 13, vu0Watchdog = 14;

  static const statAddress = 0x1000f000, maskAddress = 0x1000f010;

  int stat = 0;
  int mask = 0;

  /// true when a register changed the output since it was last read
  bool dirty = false;

  bool get asserted => stat & mask != 0;

  /// The I_STAT bits that are raised before a read of I_STAT ends. An
  /// uncached read of an EE register takes several bus cycles, and the
  /// value is taken at the end. A VSync wait that polls I_STAT with the
  /// vblank interrupt enabled relies on this. The read sees the bit, and
  /// the interrupt is taken after the read, so the kernel handler still
  /// clears the bit afterwards.
  int Function() upcoming = _none;

  static int _none() => 0;

  void saveState(StateWriter w) => w.ints([stat, mask]);

  void loadState(StateReader s) {
    final v = s.fields(2, 'intc');
    stat = v[0];
    mask = v[1];
    dirty = true;
  }

  void raise(int line) {
    stat |= 1 << line;
    dirty = true;
  }

  int read(int address) => address == statAddress
      ? stat | upcoming()
      : (address == maskAddress ? mask : 0);

  /// Writing 1 to a I_STAT bit clears it; writing 1 to a I_MASK bit toggles it.
  void write(int address, int value) {
    if (address == statAddress) {
      stat &= ~value;
    } else if (address == maskAddress) {
      mask = (mask ^ value) & 0x7fff;
    } else {
      return;
    }
    dirty = true;
  }
}
