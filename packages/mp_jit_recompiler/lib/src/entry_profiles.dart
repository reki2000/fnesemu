import 'dart:typed_data';

/// Bounded cold-entry data keyed by PC, mode tag and a frontend version token.
/// Tokens must have stable equality; the frontend chooses their code coverage.
/// A full table drops observations, never installed code or runtime state.
final class JitEntryProfiles<T extends Object> {
  final int capacity;
  final _entries = <(int, int), (Object?, T)>{};

  JitEntryProfiles({this.capacity = 4096}) {
    if (capacity <= 0) throw ArgumentError.value(capacity, 'capacity');
  }

  int get length => _entries.length;

  /// A changed token discards the previous observation before it can be reused.
  T? lookup(int pc, int tag, Object? version) {
    final key = (pc, tag), entry = _entries[(pc, tag)];
    if (entry == null) return null;
    if (entry.$1 != version) {
      _entries.remove(key);
      return null;
    }
    return entry.$2;
  }

  T obtain(int pc, int tag, Object? version, T Function() create) {
    final existing = lookup(pc, tag, version);
    if (existing != null) return existing;
    if (_entries.length >= capacity) clear();
    final value = create();
    _entries[(pc, tag)] = (version, value);
    return value;
  }

  void remove(int pc, int tag) => _entries.remove((pc, tag));
  void clear() => _entries.clear();
}

/// Exact unsigned-word samples; stability selects candidates rather than proofs.
/// Frontends still decide which values may specialize and emit all guards.
final class JitEntrySamples {
  final int words;
  int _samples = 0;
  int get samples => _samples;
  bool _disabled = false;
  Uint32List? _first;
  Uint8List? _stable;

  JitEntrySamples(this.words) {
    if (words <= 0) throw ArgumentError.value(words, 'words');
  }

  void observe(Uint32List? values) {
    if (values != null && values.length != words) {
      throw ArgumentError.value(
        values.length,
        'values.length',
        'expected $words',
      );
    }
    _samples++;
    if (values == null || _disabled) return;
    final first = _first;
    if (first == null) {
      _first = Uint32List.fromList(values);
      _stable = Uint8List(words)..fillRange(0, words, 1);
    } else {
      for (var i = 0; i < words; i++) {
        if (first[i] != values[i]) _stable![i] = 0;
      }
    }
  }

  int? stableValue(int index) {
    RangeError.checkValidIndex(index, this, 'index', words);
    if (_disabled || _first == null || _stable![index] == 0) return null;
    return _first![index];
  }

  /// Keeps subsequent observations generic until this entry is discarded.
  void disableSpecialization() {
    _disabled = true;
    _first = null;
    _stable = null;
  }
}
