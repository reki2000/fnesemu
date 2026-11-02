/// Accumulates frame deadlines without rounding away fractional microseconds.
class FramePacer {
  int _deadlineUs = 0;
  int _fractionNumerator = 0;
  int _fractionDenominator = 1;

  int advance({
    required int clocksPerFrame,
    required int clockHz,
    required int minimumDeadlineUs,
  }) {
    assert(clocksPerFrame > 0 && clockHz > 0);
    final microseconds = clocksPerFrame * Duration.microsecondsPerSecond;
    _deadlineUs += microseconds ~/ clockHz;
    final common = _fractionDenominator.gcd(clockHz);
    final scale = clockHz ~/ common;
    final denominator = _fractionDenominator * scale;
    final numerator = _fractionNumerator * scale +
        (microseconds % clockHz) * (_fractionDenominator ~/ common);
    _deadlineUs += numerator ~/ denominator;
    final remainder = numerator % denominator;
    final reduction = remainder.gcd(denominator);
    _fractionNumerator = remainder ~/ reduction;
    _fractionDenominator = denominator ~/ reduction;

    if (_deadlineUs < minimumDeadlineUs) {
      _deadlineUs = minimumDeadlineUs;
      _fractionNumerator = 0;
      _fractionDenominator = 1;
    }
    return _deadlineUs;
  }
}
