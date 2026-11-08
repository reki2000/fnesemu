import 'dart:io';

import 'package:test/test.dart';

import '../../tool/headless/benchmark_lock.dart';
import '../../tool/headless/comparison.dart';

void main() {

  test('output comparison detects trailing bytes and bounds detail storage',
      () {
    expect(firstMismatch([1, 2], [1, 2]), isNull);
    expect(firstMismatch([1, 2], [1, 3]), 1);
    expect(firstMismatch([1], [1, 2]), 1);
    expect(firstMismatch([1, 2], [1]), 1);
    expect(differenceBytes(0x100, [1, 2, 3], [1, 4], limit: 1), [
      {'address': 0x101, 'baseline': 2, 'variant': 4}
    ]);
    expect(differenceBytes(0, [1], [1, 2]), [
      {'address': 1, 'baseline': null, 'variant': 2}
    ]);
  });

}
