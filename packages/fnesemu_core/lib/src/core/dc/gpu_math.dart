/// `value ~/ 255` for `0 <= value <= 2 * 255 * 255 + 127`, without a division.
int div255(int value) => (value * 0x20203) >> 25;

/// Rounds a channel half up and clamps it to a byte.
///
/// `double.round` and `int.clamp` are calls in the AOT build; this stays inline.
/// Negative ties round toward zero, which the clamp hides.
int roundByte(double value) {
  final rounded = (value + 0.5).toInt();
  return rounded < 0 ? 0 : (rounded > 255 ? 255 : rounded);
}
