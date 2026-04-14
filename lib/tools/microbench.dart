import 'dart:developer';
import 'dart:typed_data';

import 'package:fnesemu/util/sampler.dart';
import 'package:fnesemu/util/uint8list.dart';

void main(List<String> args) {
  final v = DateTime.now().second > 0 ? 1 : 0;
  final s = DateTime.now().second > 0 ? 1 : 2;

  measure(v, s, 10, testGetUint32Le);
  measure(v, s, 10, testGetUint32List);
}

void measure(int v, s, t, int Function(int, int, int) f) {
  final sampler = Sampler(10);
  for (int t = 0; t < sampler.size; t++) {
    final start = DateTime.now().microsecondsSinceEpoch;
    log("${f(v, s, 50 * 1000 * 1000)}");
    sampler.add(DateTime.now().microsecondsSinceEpoch - start, log);
  }
}

int test1(int v, s, count) {
  double sum = 0;
  for (int i = 0; i < count; i++) {
    sum += v.clamp(0, s);
  }
  return sum.toInt();
}

int test2(int v, s, count) {
  double sum = 0;
  for (int i = 0; i < count; i++) {
    sum += v < -s
        ? -s
        : v > s
            ? s
            : v;
  }
  return sum.toInt();
}

Uint8List data =
    Uint8List.fromList(List.generate(1024 * 1024, (i) => i & 0xff));
Uint32List data32 = data.buffer.asUint32List();

int testGetUint32Le(int v, int s, int count) {
  int sum = 0;
  for (int i = 0; i < count; i++) {
    sum += data.getUint32LE(v & 0xfffff);
  }
  return sum;
}

int testGetUint32List(int v, int s, int count) {
  int sum = 0;
  for (int i = 0; i < count; i++) {
    sum += data32[v & 0xfffff >> 2];
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
