// Dart imports:
import 'dart:async';

class Line {
  final String pc, body;
  Line(this.pc, this.body);
  @override
  String toString() => "$pc: $body";
}

/// a ring buffer to supress redundant log which is identical to past N lines except for a few chars
/// used for supress VBLANK wait loop, filling memory, etc.
class RingBuffer {
  final List<Line> _buf;
  final int _maxDiffChars;

  int _index = 0;
  int _nextIndex = 0;

  int skippedCount = 0;

  RingBuffer(int size, {int maxDiffChars = 0})
      : _maxDiffChars = maxDiffChars,
        _buf = List.filled(size, Line("", ""));

  void add(Line item) {
    _buf[_index] = item;
    _index = _inc(_index);
  }

  // check if the different chars between a and b are less than the threshold(_maxDiffChars)
  bool _matched(Line a, Line b) {
    // pc should match
    if (a.pc != b.pc) {
      return false;
    }
    if (b.body.length < a.body.length) {
      return _matched(b, a);
    }

    int diff = b.body.length - a.body.length;

    if (diff > _maxDiffChars) {
      return false;
    }

    for (int i = 0; i < a.body.length; i++) {
      if (a.body[i] != b.body[i]) {
        diff++;
        if (diff > _maxDiffChars) {
          return false;
        }
      }
    }

    return true;
  }

  int _inc(int i) => i == _buf.length - 1 ? 0 : i + 1;

  // check if the item is matched with the expected line
  int isExpected(Line item) {
    if (_matched(_buf[_nextIndex], item)) {
      _nextIndex = _inc(_nextIndex);
      skippedCount++;
      return 0;
    }

    final result = skippedCount;
    skippedCount = 0;
    return result;
  }

  // if the item has already occured in the ring buffer, set the nextIndex to the matched index
  bool prepare(Line item) {
    _nextIndex = _index;

    for (int i = 0; i < _buf.length; i++) {
      if (_matched(_buf[_nextIndex], item)) {
        _nextIndex = _inc(_nextIndex);
        skippedCount++;
        return true;
      }

      _nextIndex = _inc(_nextIndex);
    }

    skippedCount = 0;
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

class Tracer {
  final StreamController<String> traceStreamController;

  final RingBuffer _ringBuffer;

  final int start;
  final int? end;
  final int pcWidth;

  String previousPc = "";
  bool _isSkipping = false;

  Tracer(this.traceStreamController,
      {int size = 20,
      required this.pcWidth,
      this.start = 0,
      this.end,
      int maxDiffChars = 0})
      : _ringBuffer = RingBuffer(size, maxDiffChars: maxDiffChars);

  void addLog(String log) {
    final pc = log.substring(0, pcWidth);
    final body = log.substring(pcWidth, end);
    final line = Line(pc, body);

    // If the PC is less than or equal to the previous PC,
    // assume we have looped.
    final jumpedToPrevious = pc.compareTo(previousPc) <= 0;
    previousPc = pc;

    // Only try to detect a repeating loop pattern if we are not already skipping.
    if (jumpedToPrevious) {
      if (_ringBuffer.prepare(line)) {
        _isSkipping = true;
        return;
      } else {
        _isSkipping = false;
      }
    }

    if (_isSkipping) {
      final skippedCount = _ringBuffer.isExpected(line);
      if (skippedCount == 0) {
        return;
      }

      _isSkipping = false;
      traceStreamController.add("...skipped $skippedCount lines...\n");
    }

    _ringBuffer.add(line);
    traceStreamController.add("$log\n");
  }
}
