extension DoubleExt on double {
  double clip(double min, double max) => this < min
      ? min
      : this > max
          ? max
          : this;
}
