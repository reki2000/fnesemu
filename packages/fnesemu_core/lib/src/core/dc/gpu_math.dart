/// Rounds half away from zero like `double.round` and clamps to a byte.
///
/// `double.round` and `int.clamp` are calls in the AOT build; this stays inline.
int roundByte(double value) {
  final whole = value.toInt();
  final fraction = value - whole;
  final rounded =
      fraction >= 0.5 ? whole + 1 : (fraction <= -0.5 ? whole - 1 : whole);
  return rounded < 0 ? 0 : (rounded > 255 ? 255 : rounded);
}
