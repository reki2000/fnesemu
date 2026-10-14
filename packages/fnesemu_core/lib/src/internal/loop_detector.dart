import 'dart:collection';

import '../types.dart';

enum TraceRepeatMode { exact, path }

enum LoopState { searching, checking, repeating }

/// An immutable pre-instruction snapshot, with the execution result and the
/// caller's context. CPU register arrays may change after this is constructed.
class TraceStatus {
  final TraceLog log;
  final String context;
  final int? nextPc;

  TraceStatus(TraceLog source, {this.context = '', this.nextPc})
      : log = TraceLog(source.pc, source.cycle, source.disasm, source.regs,
            List<int>.unmodifiable(source.state),
            frame: source.frame,
            scanline: source.scanline,
            flow: source.flow,
            indent: source.indent,
            scope: source.scope,
            instructionKey: source.instructionKey);
}

class LoopStatistics {
  final int period, iterations, skippedInstructions, partialInstructions;
  final TraceStatus first, last;
  final TraceRepeatMode mode;
  final bool registersChanged;

  const LoopStatistics(
      {required this.period,
      required this.iterations,
      required this.skippedInstructions,
      required this.partialInstructions,
      required this.first,
      required this.last,
      required this.mode,
      required this.registersChanged});

  /// Span of the first and last matching pre-instruction snapshots.
  int get elapsedClocks => last.log.cycle - first.log.cycle;
}

class LoopEnd {
  /// Only the unfinished exit cycle. Completed repeated cycles are counted in
  /// statistics and never returned or retained for output.
  final List<TraceStatus> states;
  final LoopStatistics statistics;

  LoopEnd(Iterable<TraceStatus> states, this.statistics)
      : states = List.unmodifiable(states);
}

class LoopUpdate {
  final LoopState state;

  /// Ordinary output: instructions with no candidate, or a rejected candidate.
  /// Output [ended] before these states when both are present.
  final List<TraceStatus> ready;
  final LoopEnd? ended;

  LoopUpdate(this.state, {Iterable<TraceStatus> ready = const [], this.ended})
      : ready = List.unmodifiable(ready);

  const LoopUpdate._empty(this.state)
      : ready = const [],
        ended = null;
}

typedef _ExpiredStatus = ({int index, TraceStatus status});

/// An append-only logical list whose indices never move. Its valid range is
/// [start, end); storage for expired entries is released by the queue.
class _TraceHistory {
  final int capacity;
  final _entries = ListQueue<TraceStatus>();
  int start = 0, end = 0;

  _TraceHistory(this.capacity) {
    if (capacity < 1) throw ArgumentError.value(capacity, 'capacity');
  }

  int get length => end - start;

  TraceStatus operator [](int index) {
    if (index < start || index >= end) {
      throw RangeError.range(index, start, end - 1, 'index');
    }
    return _entries.elementAt(index - start);
  }

  _ExpiredStatus? add(TraceStatus status) {
    _entries.addLast(status);
    end++;
    if (_entries.length <= capacity) return null;
    return (index: start++, status: _entries.removeFirst());
  }

  void clear() {
    _entries.clear();
    start = end;
  }

  void retain(int length) {
    while (_entries.length > length) {
      _entries.removeFirst();
      start++;
    }
  }
}

class _Candidate {
  final int period;
  final TraceStatus first;
  bool registersChanged;

  _Candidate(this.period, this.first, this.registersChanged);
}

/// Detects consecutive single-period repeats without formatting or output.
/// PC-index lookup visits at most [maxCandidates] recent occurrences. Limiting
/// candidates can miss repeats; every unconfirmed instruction stays in ready.
/// Once confirmed, the index is released and only the previous cycle is read.
class LoopDetector {
  final TraceRepeatMode mode;
  final int maxCandidates;
  final _TraceHistory _history;
  final _positions = HashMap<int, ListQueue<int>>();
  final _candidates = <_Candidate>[];
  final _pending = <TraceStatus>[];
  int _indexedStates = 0;
  int _period = 0, _iterations = 0, _skipped = 0;
  TraceStatus? _first, _last;
  bool _registersChanged = false;

  LoopDetector(
      {int capacity = 2048,
      this.maxCandidates = 8,
      this.mode = TraceRepeatMode.exact})
      : _history = _TraceHistory(capacity) {
    if (maxCandidates < 1) {
      throw ArgumentError.value(maxCandidates, 'maxCandidates');
    }
  }

  LoopState get state => _period > 0
      ? LoopState.repeating
      : _candidates.isNotEmpty
          ? LoopState.checking
          : LoopState.searching;

  int get historyStart => _history.start;
  int get historyEnd => _history.end;
  int get retainedStates => _history.length;
  int get indexedStates => _indexedStates;
  int get indexedPcs => _positions.length;

  bool _sameRegisters(TraceStatus a, TraceStatus b) {
    final x = a.log, y = b.log;
    if (x.regs != y.regs || x.state.length != y.state.length) return false;
    for (var i = 0; i < x.state.length; i++) {
      if (x.state[i] != y.state[i]) return false;
    }
    return true;
  }

  bool _matches(TraceStatus a, TraceStatus b) {
    final x = a.log, y = b.log;
    return x.pc == y.pc &&
        x.scope == y.scope &&
        (x.instructionKey ?? x.disasm) == (y.instructionKey ?? y.disasm) &&
        a.context == b.context &&
        a.nextPc == b.nextPc &&
        x.flow.kind == y.flow.kind &&
        x.flow.target == y.flow.target &&
        x.flow.returnAddress == y.flow.returnAddress &&
        x.flow.delaySlots == y.flow.delaySlots &&
        x.state.length == y.state.length &&
        (mode == TraceRepeatMode.path || _sameRegisters(a, b));
  }

  bool _changed(TraceStatus a, TraceStatus b) =>
      mode == TraceRepeatMode.path && !_sameRegisters(a, b);

  void _append(TraceStatus status, {required bool indexed}) {
    final index = _history.end;
    final expired = _history.add(status);
    if (!indexed) {
      if (_period > 0) _history.retain(_period);
      return;
    }
    if (expired != null) {
      final pc = expired.status.log.pc;
      final positions = _positions[pc]!;
      positions.removeFirst();
      _indexedStates--;
      if (positions.isEmpty) _positions.remove(pc);
    }
    (_positions[status.log.pc] ??= ListQueue<int>()).addLast(index);
    _indexedStates++;
  }

  void _confirm(_Candidate candidate, TraceStatus status) {
    _period = candidate.period;
    _iterations = 2; // The first cycle was already output normally.
    _skipped = _period;
    _first = candidate.first;
    _last = status;
    _registersChanged = candidate.registersChanged;
    _pending.clear(); // The second complete cycle is also omitted.
    _candidates.clear();
    _positions.clear();
    _indexedStates = 0;
  }

  LoopUpdate _search(TraceStatus status, {List<TraceStatus> ready = const []}) {
    final positions = _positions[status.log.pc];
    if (positions != null) {
      final limit =
          (positions.length - maxCandidates).clamp(0, positions.length);
      for (var i = positions.length - 1; i >= limit; i--) {
        final index = positions.elementAt(i);
        final previous = _history[index];
        if (_matches(previous, status)) {
          _candidates.add(_Candidate(
              _history.end - index, previous, _changed(previous, status)));
        }
      }
    }
    if (_candidates.isEmpty) {
      _append(status, indexed: true);
      return LoopUpdate(LoopState.searching, ready: [...ready, status]);
    }
    _pending.add(status);
    if (_candidates.first.period == 1) {
      _confirm(_candidates.first, status);
      _append(status, indexed: false);
    } else {
      _append(status, indexed: true);
    }
    return ready.isEmpty
        ? (state == LoopState.repeating
            ? const LoopUpdate._empty(LoopState.repeating)
            : const LoopUpdate._empty(LoopState.checking))
        : LoopUpdate(state, ready: ready);
  }

  LoopUpdate add(TraceStatus status) {
    if (status.log.flow.kind == TraceFlowKind.exception ||
        status.log.flow.kind == TraceFlowKind.interruptReturn) {
      final update = finish();
      // Boundaries still consume a logical execution index.
      _append(status, indexed: false);
      _history.clear();
      return LoopUpdate(LoopState.searching,
          ready: [...update.ready, status], ended: update.ended);
    }
    if (_period > 0) {
      final previous = _history[_history.end - _period];
      if (!_matches(previous, status)) {
        final ended = finish().ended;
        _append(status, indexed: true);
        return LoopUpdate(LoopState.searching, ready: [status], ended: ended);
      }
      _registersChanged = _registersChanged || _changed(previous, status);
      _last = status;
      _pending.add(status);
      if (_pending.length == _period) {
        _iterations++;
        _skipped += _period;
        _pending.clear();
      }
      _append(status, indexed: false);
      return const LoopUpdate._empty(LoopState.repeating);
    }
    if (_candidates.isNotEmpty) {
      _candidates.removeWhere((candidate) =>
          !_matches(_history[_history.end - candidate.period], status));
      if (_candidates.isEmpty) {
        final ready = List<TraceStatus>.of(_pending);
        _pending.clear();
        return _search(status, ready: ready);
      }
      for (final candidate in _candidates) {
        candidate.registersChanged = candidate.registersChanged ||
            _changed(_history[_history.end - candidate.period], status);
      }
      _pending.add(status);
      final complete = _candidates.where((c) => c.period == _pending.length);
      if (complete.isNotEmpty) {
        _confirm(complete.first, status);
        _append(status, indexed: false);
        return const LoopUpdate._empty(LoopState.repeating);
      }
      _append(status, indexed: true);
      return const LoopUpdate._empty(LoopState.checking);
    }
    return _search(status);
  }

  /// Closes the current segment for stop/Copy. Repeated calls are harmless.
  LoopUpdate finish() {
    final LoopUpdate update;
    if (_period > 0) {
      update = LoopUpdate(LoopState.searching,
          ended: LoopEnd(
              _pending,
              LoopStatistics(
                  period: _period,
                  iterations: _iterations,
                  skippedInstructions: _skipped,
                  partialInstructions: _pending.length,
                  first: _first!,
                  last: _last!,
                  mode: mode,
                  registersChanged: _registersChanged)));
    } else {
      update = LoopUpdate(LoopState.searching, ready: _pending);
    }
    reset();
    return update;
  }

  /// Discards capture without returning output. Logical indices stay monotonic.
  void reset() {
    _history.clear();
    _positions.clear();
    _indexedStates = 0;
    _candidates.clear();
    _pending.clear();
    _period = _iterations = _skipped = 0;
    _first = _last = null;
    _registersChanged = false;
  }
}
