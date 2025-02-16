// Dart imports:
import 'dart:async';

import 'package:fnesemu/util/int.dart';

import '../../core/types.dart';

class RepeatableLine {
  final int pc;
  final String body;
  const RepeatableLine(this.pc, this.body);
  static const empty = RepeatableLine(-1, "");

  @override
  String toString() => "${pc.hex24}: $body";

  bool matched(RepeatableLine b, int diffChars) {
    // pc should match
    if (pc != b.pc) {
      return false;
    }
    if (b.body.length < body.length) {
      return b.matched(this, diffChars);
    }

    int diff = b.body.length - body.length;

    if (diff > diffChars) {
      return false;
    }

    for (int i = 0; i < body.length; i++) {
      if (body[i] != b.body[i]) {
        diff++;
        if (diff > diffChars) {
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
  final SlidingBuffer<RepeatableLine> _buf;
  final int _maxDiffChars;

  int _nextIndex = 0;
  int _repeatCount = 0;

  RepeatDetector(int size, {int maxDiffChars = 0})
      : _maxDiffChars = maxDiffChars,
        _buf = SlidingBuffer(size, RepeatableLine.empty);

  void add(RepeatableLine item) {
    _buf.add(item);
  }

  // check if the different chars between a and b are less than the threshold(_maxDiffChars)
  bool _matched(RepeatableLine a, RepeatableLine b) =>
      a.matched(b, _maxDiffChars);

  // check if the item is matched with the expected line
  int isRepeating(RepeatableLine item) {
    if (_nextIndex == _buf.size || !_matched(_buf[_nextIndex], item)) {
      _nextIndex = _buf.size;
      return _repeatCount;
    }

    _repeatCount++;
    return 0;
  }

  // if the item has already occured in the ring buffer, set the nextIndex to the matched index
  bool detect(RepeatableLine item) {
    for (_nextIndex = 0; _nextIndex < _buf.size; _nextIndex++) {
      if (_matched(_buf[_nextIndex], item)) {
        _nextIndex++;
        _repeatCount = 1;
        return true;
      }
    }

    _repeatCount = 0;
    return false;
  }
}

// check redundancy of the [start:end?] chars which represents the CPU state

// 6502: start=48 end=72
// C78C  10 FB     BPL $C789                       A:00 X:00 Y:00 P:32 SP:FD
// E084  BD CE E0  LDA $E0CE, X                    A:02 X:12 Y:00 P:94 SP:FF
// 0123456789012345678901234567890123456789012345678901234567890123456789012
// 0         1         2         3         4         5         6         7
//
// M68: start=46 end=248
//
class Tracer {
  final StreamSink<String> _stream;
  final RepeatDetector _detector;

  int previousPc = -1;
  bool _isSkipping = false;

  Tracer(this._stream, {int size = 20, int maxDiffChars = 0})
      : _detector = RepeatDetector(size, maxDiffChars: maxDiffChars);

  void addTraceLog(TraceLog log) {
    final line = RepeatableLine(log.pc, log.state);

    // If the PC is less than or equal to the previous PC,
    // assume we have looped.
    final jumpedToPrevious = log.pc.compareTo(previousPc) <= 0;
    previousPc = log.pc;

    // Only try to detect a repeating loop pattern if we are not already skipping.
    if (jumpedToPrevious) {
      if (_detector.detect(line)) {
        _isSkipping = true;
        return;
      } else {
        _isSkipping = false;
      }
    }

    if (_isSkipping) {
      final skippedCount = _detector.isRepeating(line);
      if (skippedCount == 0) {
        return;
      }

      _isSkipping = false;
      _stream.add("...skipped $skippedCount lines...\n");
    }

    _detector.add(line);
    _stream.add("${log.disasm} ${log.state} cl:${log.cycle.format3}\n");
  }
}
