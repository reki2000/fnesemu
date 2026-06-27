// Dart imports:
import 'dart:async';

import 'package:fnesemu/util/int.dart';

import 'types.dart';

class TraceLogState {
  final int _pc;
  final List<int> _state;
  const TraceLogState(this._pc, this._state);
  static const empty = TraceLogState(-1, []);

  @override
  String toString() => "${_pc.x6}:${_state.map((e) => e.x8).join(",")}}";

  bool matched(TraceLogState b, int allowDiffCounts) {
    // pc should match
    if (_pc != b._pc) {
      return false;
    }
    if (b._state.length < _state.length) {
      return b.matched(this, allowDiffCounts);
    }

    int diff = b._state.length - _state.length;

    if (diff > allowDiffCounts) {
      return false;
    }

    for (int i = 0; i < _state.length; i++) {
      if (_state[i] != b._state[i]) {
        diff++;
        if (diff > allowDiffCounts) {
          return false;
        }
      }
    }

    return true;
  }
}

class SlidingBuffer<T> {
  final List<T> _buf;

  SlidingBuffer(size, T filler) : _buf = List.filled(size, filler);

  int _index = 0;

  int get size => _buf.length;

  void add(T item) {
    _buf[_index] = item;
    _index = (_index + 1) % _buf.length;
  }

  T operator [](int i) => i >= _buf.length
      ? throw RangeError("index out of range")
      : _buf[(_index + i) % _buf.length];
}

/// a ring buffer to supress redundant log which is identical to past N lines except for a few chars
/// used for supress VBLANK wait loop, filling memory, etc.
class RepeatDetector {
  final SlidingBuffer<TraceLogState> _buf;
  final int _allowDiffStates;

  int _nextIndex = 0;
  int _repeatCount = 0;
  final List<(TraceLogState, TraceLog)> _pendingLogs = [];

  RepeatDetector(int size, {int allowDiffStates = 0})
      : _allowDiffStates = allowDiffStates,
        _buf = SlidingBuffer(size, TraceLogState.empty);

  void add(TraceLogState item) {
    _repeatCount = 0;
    _pendingLogs.clear();
    _buf.add(item);
  }

  // check if the different states between a and b are less than the threshold(_allowDiffStates)
  bool _matched(TraceLogState a, TraceLogState b) =>
      a.matched(b, _allowDiffStates);

  // if the item has already occured in the ring buffer, set the return the matched index
  int _detect(TraceLogState item) {
    for (_nextIndex = 0; _nextIndex < _buf.size; _nextIndex++) {
      if (_matched(_buf[_nextIndex], item)) {
        return _nextIndex;
      }
    }

    return _buf.size;
  }

  // check if the item is matched with the expected line
  // returns (shouldSkip, skippedCount, pendingLogs)
  (bool, int, List<(TraceLogState, TraceLog)>) isRepeating(
      TraceLogState item, TraceLog log,
      {int minSkipThreshold = 0}) {
    if (_nextIndex < _buf.size && _matched(_buf[_nextIndex], item)) {
      _repeatCount++;
      _nextIndex++;

      // Threshold check: clear pendingLogs when threshold is exceeded
      if (_repeatCount <= minSkipThreshold) {
        _pendingLogs.add((item, log));
      } else if (_repeatCount == minSkipThreshold + 1) {
        // Clear pendingLogs immediately when threshold is exceeded to free memory
        _pendingLogs.clear();
      }
      return (true, 0, []); // Skip but pending
    }

    _nextIndex = _detect(item);
    if (_nextIndex < _buf.size) {
      _nextIndex++;
      _repeatCount++;

      // Threshold check: clear pendingLogs when threshold is exceeded
      if (_repeatCount <= minSkipThreshold) {
        _pendingLogs.add((item, log));
      } else if (_repeatCount == minSkipThreshold + 1) {
        // Clear pendingLogs immediately when threshold is exceeded to free memory
        _pendingLogs.clear();
      }
      return (true, 0, []); // Skip but pending
    }

    // End of repeat pattern
    final result = _repeatCount;
    final pendingLogs = List<(TraceLogState, TraceLog)>.from(_pendingLogs);

    _repeatCount = 0;
    _pendingLogs.clear();

    if (result > 0) {
      // Threshold check
      if (result <= minSkipThreshold) {
        // If below threshold, output all pending logs
        return (false, 0, pendingLogs);
      } else {
        // If above threshold, only output skip message
        return (false, result, []);
      }
    }

    return (false, 0, []);
  }
}

// Tracer: logs CPU traces, with skipping repeating lines
class Tracer {
  final StreamSink<String> _stream;
  final RepeatDetector _detector;
  final int _minSkipThreshold;

  Tracer(this._stream,
      {int size = 20, int maxDiffChars = 0, int minSkipThreshold = 3})
      : _detector = RepeatDetector(size, allowDiffStates: maxDiffChars),
        _minSkipThreshold = minSkipThreshold;

  void addTraceLog(TraceLog log) {
    final line = TraceLogState(log.pc, log.state);

    final (repeating, skippedCount, pendingLogs) =
        _detector.isRepeating(line, log, minSkipThreshold: _minSkipThreshold);

    if (repeating) {
      return; // Skip during repeat pattern (pending)
    }

    // Output pending logs first if any
    for (final (_, pendingLog) in pendingLogs) {
      _stream.add(
          "${pendingLog.disasm} ${pendingLog.regs} cl:${pendingLog.cycle.format3}\n");
    }

    if (skippedCount > 0) {
      _stream.add("...skipped $skippedCount lines...\n");
    }

    _detector.add(line);
    _stream.add(
        "${log.disasm} ${log.regs} cl:${log.cycle.format3} f:${log.frame} s:${log.scanline}\n");
  }
}
