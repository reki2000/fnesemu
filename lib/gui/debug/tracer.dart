// Dart imports:
import 'dart:async';

/// a ring buffer to supress redundant log which is identical to past N lines except for a few chars
/// used for supress VBLANK wait loop, filling memory, etc.
class RingBuffer {
  final List<String> _buf;
  final int _maxDiffChars;

  int _index = 0;
  int _nextIndex = 0;

  int skippedCount = 0;

  RingBuffer(int size, {int maxDiffChars = 0})
      : _maxDiffChars = maxDiffChars,
        _buf = List.filled(size, "");

  void add(String item) {
    _buf[_index] = item;
    _index = _inc(_index);
  }

  bool _matched(String a, String b) {
    if (b.length < a.length) {
      return _matched(b, a);
    }

    int diff = b.length - a.length;

    if (diff > _maxDiffChars) {
      return false;
    }

    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
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
  bool isExpected(String item) {
    if (_matched(_buf[_nextIndex], item)) {
      _nextIndex = _inc(_nextIndex);
      skippedCount++;
      return true;
    }

    return false;
  }

  // prepare when the item is conteined in the buffer
  bool prepare(String item) {
    _nextIndex = _index;
    for (int i = 0; i < _buf.length; i++) {
      if (_matched(_buf[_nextIndex], item)) {
        _nextIndex = _inc(_nextIndex);
        skippedCount++;
        return true;
      }
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

  String previousPc = "";
  bool isLoop = false;

  Tracer(this.traceStreamController,
      {int size = 10, this.start = 0, this.end, int maxDiffChars = 0})
      : _ringBuffer = RingBuffer(size, maxDiffChars: maxDiffChars);

  void addLog(String log) {
    final pc = log.substring(0, 6);
    final line = log.substring(start, end);

    // if the PC is back to the previous one, it means the CPU is in the loop
    final jumpedToPrevious = pc.compareTo(previousPc) < 0;
    previousPc = pc;

    if (jumpedToPrevious) {
      isLoop = _ringBuffer.prepare(line);
      if (isLoop) {
        return;
      }
    }

    if (isLoop) {
      if (_ringBuffer.isExpected(line)) {
        return;
      }

      isLoop = false;
      traceStreamController
          .add("...skipped ${_ringBuffer.skippedCount} lines...\n");
    }

    _ringBuffer.add(line);
    traceStreamController.add("$log\n");
  }
}
