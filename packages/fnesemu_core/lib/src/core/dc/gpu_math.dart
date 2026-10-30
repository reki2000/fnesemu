/// Rounds a channel half up and clamps it to a byte.
///
/// `double.round` and `int.clamp` are calls in the AOT build; this stays inline.
/// Negative ties round toward zero, which the clamp hides.
int roundByte(double value) {
  final rounded = (value + 0.5).toInt();
  return rounded < 0 ? 0 : (rounded > 255 ? 255 : rounded);
}
