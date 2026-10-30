import '../../state.dart';

/// Decoded AICA DSP arithmetic stage, original AICA manual pages 34–37.
/// This does not decode MPRO or provide memory/address generation.
class DcAicaDspAlu {
  int accumulator = 0, fraction = 0, address = 0, yRegister = 0;

  void reset() {
    accumulator = fraction = address = yRegister = 0;
  }

  void saveState(StateWriter writer) {
    writer.section('dc.aica.dsp.alu');
    for (final value in [accumulator, fraction, address, yRegister]) {
      writer.int32(value);
    }
  }

  void loadState(StateReader reader) {
    reader.section('dc.aica.dsp.alu');
    final acc = reader.int32(), frac = reader.int32();
    final addr = reader.int32(), y = reader.int32();
    if (acc < -0x2000000 ||
        acc > 0x1ffffff ||
        frac < -4096 ||
        frac > 4095 ||
        addr < 0 ||
        addr > 4095 ||
        y < 0 ||
        y > 0xffffff ||
        y & 15 != 0) {
      throw const StateMismatch('AICA DSP arithmetic latches');
    }
    accumulator = acc;
    fraction = frac;
    address = addr;
    yRegister = y;
  }

  /// One functional decoded step; latch reads precede writes.
  /// Multiplier scaling and accumulator pipeline timing need chip validation.
  int step(
      {required int input,
      required int temporary,
      required int coefficient,
      int ySelect = 0,
      int shift = 0,
      bool xInput = false,
      bool bAccumulator = false,
      bool zero = false,
      bool negate = false,
      bool latchY = false,
      bool latchFraction = false,
      bool latchAddress = false}) {
    if (ySelect < 0 || ySelect > 3 || shift < 0 || shift > 3) {
      throw ArgumentError('AICA DSP selector is outside its two-bit range');
    }
    input = input.toSigned(24);
    temporary = temporary.toSigned(24);
    final x = xInput ? input : temporary;
    final y = switch (ySelect) {
      0 => fraction.toSigned(13),
      1 => ((coefficient & 0xffff) >> 3).toSigned(13),
      2 => (yRegister >> 11).toSigned(13),
      _ => (yRegister >> 4) & 0xfff,
    };
    var b = zero
        ? 0
        : bAccumulator
            ? accumulator.toSigned(26)
            : temporary;
    if (negate) b = -b;
    // A 24x13 signed product fits a JavaScript double; bit shifts do not.
    final product = (x * y / 4096).floor();
    final next = (product + b).toSigned(26);
    final old = accumulator.toSigned(26);
    final shifted = (shift == 1 || shift == 2) ? old * 2 : old;
    final output =
        shift < 2 ? shifted.clamp(-0x800000, 0x7fffff) : shifted.toSigned(24);
    if (latchFraction) {
      fraction = shift == 3 ? output & 0xfff : (output >> 11).toSigned(13);
    }
    if (latchAddress) {
      address = shift == 3 ? (output >> 12) & 0xfff : (input >> 16) & 0xfff;
    }
    if (latchY) yRegister = input & 0xfffff0;
    accumulator = next;
    return output;
  }
}
