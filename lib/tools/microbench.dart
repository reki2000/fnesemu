import 'package:fnesemu/util/sampler.dart';

void main(List<String> args) {
  final v = DateTime.now().second > 0 ? 1 : 0;
  final s = DateTime.now().second > 0 ? 1 : 2;

  measure(v, s, 10, test1);
  measure(v, s, 10, test2);
}

void measure(int v, s, t, int Function(int, int, int) f) {
  final sampler = Sampler(10);
  for (int t = 0; t < sampler.size; t++) {
    final start = DateTime.now().microsecondsSinceEpoch;
    print(f(v, s, 50 * 1000 * 1000));
    sampler.add(DateTime.now().microsecondsSinceEpoch - start, print);
  }
}

int test1(int v, s, count) {
  int sum = 0;
  for (int i = 0; i < count; i++) {
    sum += v.mask(s);
  }
  return sum;
}

int test2(int v, s, count) {
  int sum = 0;
  for (int i = 0; i < count; i++) {
    sum += v.mask2(s);
  }
  return sum;
}

extension IntExt on int {
  int get mask8 => this & ((1 << 8) - 1);
  int get mask16 => this & ((1 << 16) - 1);
  int get mask24 => this & ((1 << 24) - 1);
  int get mask32 => this & ((1 << 32) - 1);

  int mask(int size) => size == 1
      ? mask8
      : size == 2
          ? mask16
          : size == 4
              ? mask32
              : throw ("unreachable");

  int mask2(int size) => this & ((1 << (size << 3)) - 1);
}
