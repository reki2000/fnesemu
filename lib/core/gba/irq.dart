/// GBA interrupt controller (IE/IF/IME).
///
/// Hardware sources set their bit in [if_] via [raise] regardless of [ie];
/// the CPU only takes the interrupt when IME is enabled, the bit is enabled in
/// IE and CPSR.I is clear (the last gate is checked on the CPU side).
class Irq {
  int ie = 0; // 0x4000200 interrupt enable
  int if_ = 0; // 0x4000202 interrupt request/acknowledge
  int ime = 0; // 0x4000208 master enable (bit0)

  /// flag a hardware interrupt source.
  void raise(int bit) => if_ |= (1 << bit);

  /// acknowledge (clear) the bits written with a 1 to IF.
  void ack(int bits) => if_ &= ~bits;

  /// an enabled interrupt is requested and the master switch is on.
  bool get pending => (ime & 1) != 0 && (ie & if_) != 0;

  /// any enabled interrupt is requested, ignoring IME. used to wake from HALT.
  bool get anyPending => (ie & if_) != 0;

  void reset() {
    ie = 0;
    if_ = 0;
    ime = 0;
  }
}

/// bit positions shared by IE and IF.
class IrqBit {
  static const vblank = 0;
  static const hblank = 1;
  static const vcount = 2;
  static const timer0 = 3; // timer0..3 = 3..6
  static const serial = 7;
  static const dma0 = 8; // dma0..3 = 8..11
  static const keypad = 12;
  static const gamepak = 13;
}
