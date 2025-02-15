// Sampler stores samples and prints its avelage/min/max values.
class Sampler {
  final List<int> _samples = [];
  final int size;

  Sampler(this.size);

  void add(int sample, Function(String) onPrint) {
    _samples.add(sample);

    if (_samples.length >= size) {
      int sum = 0, max = 0, min = 1 << 62;
      for (final i in _samples) {
        sum += i;
        max = (i > max) ? i : max;
        min = (i < min) ? i : min;
      }

      onPrint('elapsed: ${sum ~/ size} (max: $max, min: $min)');

      _samples.clear();
    }
  }
}
