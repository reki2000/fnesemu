import 'dart:math';

import 'package:mp_jit_recompiler/src/int_map.dart';
import 'package:test/test.dart';

void main() {
  test('IntMap behaves like a Map under random puts, gets and removes', () {
    final random = Random(1);
    final map = IntMap();
    final reference = <int, int>{};
    for (var i = 0; i < 200000; i++) {
      final key = random.nextInt(3000) << (random.nextBool() ? 0 : 32);
      switch (random.nextInt(3)) {
        case 0:
          final value = random.nextInt(1 << 30);
          map.put(key, value);
          reference[key] = value;
        case 1:
          expect(map.remove(key), reference.remove(key) != null);
        default:
          expect(map.get(key), reference[key] ?? IntMap.absent);
      }
      expect(map.length, reference.length);
    }
    for (final e in reference.entries) {
      expect(map.get(e.key), e.value);
    }
    map.clear();
    expect(map.isEmpty, isTrue);
    expect(map.get(reference.keys.first), IntMap.absent);
  });
}
