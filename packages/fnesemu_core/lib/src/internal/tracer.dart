import 'dart:async';

import '../types.dart';
import '../util/int.dart';

class TraceLogState {
  final int _pc;
  final List<int> _state;
  final int _scope;
  final String _instruction;
  const TraceLogState(this._pc, this._state,
      [this._scope = 0, this._instruction = '']);
  static const empty = TraceLogState(-1, []);

  @override
  String toString() => "${_pc.x6}:${_state.map((e) => e.x8).join(",")}}";

  bool matched(TraceLogState b, int allowDiffCounts) {
    // pc should match
    if (_pc != b._pc || _scope != b._scope || _instruction != b._instruction) {
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

  (int, List<TraceLog>) finish(int threshold) {
    final count = _repeatCount;
    final pending = [for (final entry in _pendingLogs) entry.$2];
    _repeatCount = 0;
    _nextIndex = 0;
    _pendingLogs.clear();
    return count > threshold ? (count, <TraceLog>[]) : (0, pending);
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

  final _calls = <(int, bool)>[];
  final _scopes = <String, int>{};
  TraceFlow? _delayedFlow;
  int _delayRemaining = 0;

  String _format(TraceLog log) =>
      '${'  ' * log.indent}${log.disasm} ${log.regs} cl:${log.cycle.format3} f:${log.frame} s:${log.scanline}\n';

  void _applyFlow(TraceFlow flow, int nextPc) {
    switch (flow.kind) {
      case TraceFlowKind.call:
      case TraceFlowKind.exception:
        if (flow.target == null || flow.target == nextPc) {
          _calls
              .add((flow.returnAddress!, flow.kind == TraceFlowKind.exception));
        }
      case TraceFlowKind.returned:
      case TraceFlowKind.jump:
      case TraceFlowKind.interruptReturn:
        final interrupt = flow.kind == TraceFlowKind.interruptReturn;
        final match = _calls.lastIndexWhere(
            (entry) => entry.$1 == nextPc && entry.$2 == interrupt);
        if (match >= 0) {
          _calls.removeRange(match, _calls.length);
        } else if (flow.kind == TraceFlowKind.returned &&
            !_calls.any((entry) => entry.$2)) {
          // A return outside the captured stack (capture may start mid-function).
          _calls.clear();
        }
      case TraceFlowKind.none:
        break;
    }
  }

  /// Emit the deferred tail when capture ends, even inside a repeated loop.
  void finish() {
    final (skipped, pending) = _detector.finish(_minSkipThreshold);
    for (final log in pending) {
      _stream.add(_format(log));
    }
    if (skipped > 0) _stream.add('...skipped $skipped lines...\n');
  }

  void addTraceLog(TraceLog source, {int? nextPc}) {
    final path = _calls.map((entry) => '${entry.$1}:${entry.$2}').join('/');
    final scope = _scopes.putIfAbsent(path, () => _scopes.length);
    final log = TraceLog(source.pc, source.cycle, source.disasm, source.regs,
        List<int>.of(source.state),
        frame: source.frame,
        scanline: source.scanline,
        flow: source.flow,
        indent: _calls.length,
        scope: scope);
    // Branch and return delay slots still belong to the caller/callee respectively.
    if (nextPc != null) {
      if (_delayedFlow != null && --_delayRemaining == 0) {
        _applyFlow(_delayedFlow!, nextPc);
        _delayedFlow = null;
      }
      if (log.flow.kind != TraceFlowKind.none) {
        if (log.flow.delaySlots > 0) {
          _delayedFlow = log.flow;
          _delayRemaining = log.flow.delaySlots;
        } else {
          _applyFlow(log.flow, nextPc);
        }
      }
    }
    final line = TraceLogState(log.pc, log.state, scope, log.disasm);
    final (repeating, skippedCount, pendingLogs) =
        _detector.isRepeating(line, log, minSkipThreshold: _minSkipThreshold);
    if (repeating) return;
    for (final (_, pending) in pendingLogs) {
      _stream.add(_format(pending));
    }
    if (skippedCount > 0) _stream.add('...skipped $skippedCount lines...\n');
    _detector.add(line);
    _stream.add(_format(log));
  }
}
