import 'dart:typed_data';

import 'package:mp_jit_recompiler/mp_jit_recompiler.dart';
import 'package:test/test.dart';

void main() {
  test('profiles isolate mode tags and replace stale version tokens', () {
    final profiles = JitEntryProfiles<JitEntrySamples>(capacity: 2);
    final first = profiles.obtain(0x100, 0, (1, 2), () => JitEntrySamples(1));
    first.observe(Uint32List.fromList([42]));
    final other = profiles.obtain(0x100, 1, (1, 2), () => JitEntrySamples(1));
    expect(profiles.lookup(0x100, 0, (1, 2)), same(first));
    expect(other, isNot(same(first)));
    first.disableSpecialization();
    expect(profiles.lookup(0x100, 0, (2, 2)), isNull);
    final changed = profiles.obtain(0x100, 0, (2, 2), () => JitEntrySamples(1));
    changed.observe(Uint32List.fromList([99]));
    expect(changed.samples, 1);
    expect(changed.stableValue(0), 99);
    expect(profiles.lookup(0x100, 1, (1, 2)), same(other));
    profiles.remove(0x100, 0);
    expect(profiles.length, 1);
    expect(profiles.lookup(0x100, 1, (1, 2)), same(other));
    profiles.clear();
    expect(profiles.length, 0);
  });

  test('capacity clears only observations and never grows past its bound', () {
    final profiles = JitEntryProfiles<Object>(capacity: 2);
    final first = profiles.obtain(0, 0, 1, Object.new);
    profiles.obtain(1, 0, 1, Object.new);
    expect(profiles.obtain(0, 0, 1, Object.new), same(first));
    expect(profiles.length, 2);
    profiles.obtain(2, 0, 1, Object.new);
    expect(profiles.length, 1);
    expect(profiles.lookup(0, 0, 1), isNull);
    for (var i = 0; i < 100; i++) {
      profiles.obtain(i, 0, 1, Object.new);
      expect(profiles.length, lessThanOrEqualTo(2));
    }
    expect(() => JitEntryProfiles<Object>(capacity: 0), throwsArgumentError);
  });

  test(
    'stability copies unsigned words and rejects values that change back',
    () {
      final values = Uint32List.fromList([0, 0xffffffff, 0x80000000, 7]);
      final samples = JitEntrySamples(4);
      expect(samples.stableValue(0), isNull);
      samples.observe(values);
      values[0] = 1;
      samples.observe(values);
      values[0] = 0;
      samples.observe(values);
      expect(samples.samples, 3);
      expect(samples.stableValue(0), isNull);
      expect(samples.stableValue(1), 0xffffffff);
      expect(samples.stableValue(2), 0x80000000);
      expect(samples.stableValue(3), 7);
      expect(() => samples.stableValue(4), throwsRangeError);
      expect(() => samples.observe(Uint32List(3)), throwsArgumentError);
      expect(samples.samples, 3);
      expect(() => JitEntrySamples(0), throwsArgumentError);
    },
  );

  test('word stability remains independent across a 32-word boundary', () {
    final values = Uint32List.fromList(List.generate(40, (i) => i));
    final samples = JitEntrySamples(40)..observe(values);
    values[32] = 99;
    values[39] = 99;
    samples.observe(values);
    expect(samples.stableValue(0), 0);
    expect(samples.stableValue(31), 31);
    expect(samples.stableValue(32), isNull);
    expect(samples.stableValue(38), 38);
    expect(samples.stableValue(39), isNull);
  });

  test(
    'disabled specialization and count-only samples do not retain candidates',
    () {
      final samples = JitEntrySamples(1);
      samples.observe(null);
      expect(samples.samples, 1);
      expect(samples.stableValue(0), isNull);
      samples.observe(Uint32List.fromList([42]));
      expect(samples.stableValue(0), 42);
      samples.disableSpecialization();
      samples.observe(Uint32List.fromList([99]));
      samples.observe(null);
      expect(samples.samples, 4);
      expect(samples.stableValue(0), isNull);
    },
  );
}
