// Dart imports:
import 'dart:async';

/// a ring buffer to supress redundant log which is identical to past N lines except X,Y registers
/// used for supress VBLANK wait loop, filling memory, etc.
class RingBuffer {
  final List<String> _buf;
  int _index = 0;
  bool _skipped = false;

  bool recovered = false; // previously skipped and currently not skipped

  RingBuffer(int size) : _buf = List.filled(size, "");

  void _add(String item) {
    _buf[_index] = item;
    _index++;
    if (_index == _buf.length) {
      _index = 0;
    }
  }

  bool addOnlyNewItem(String item) {
    if (!_buf.contains(item)) {
      _add(item);

      recovered = _skipped;
      _skipped = false;
      return true;
    }
    recovered = false;
    _skipped = true;
    return false;
  }
}

class Tracer {
  final StreamController<String> traceStreamController;
  final _ringBuffer = RingBuffer(40);

  Tracer(this.traceStreamController);

  void addLog(String log) {
    // check redundancy of the first 73 chars which represents the CPU state
    // C78C  10 FB     BPL $C789                       A:00 X:00 Y:00 P:32 SP:FD
    // E084  BD CE E0  LDA $E0CE, X                    A:02 X:12 Y:00 P:94 SP:FF
    // 0123456789012345678901234567890123456789012345678901234567890123456789012
    // 0         1         2         3         4         5         6         7
    // change of X or Y is ignored for X,Y are often used as a loop counter
    final state = log;
    if (_ringBuffer
        .addOnlyNewItem(state.substring(0, 73).replaceRange(48, 62, ""))) {
      if (_ringBuffer.recovered) {
        traceStreamController.add("...\n");
      }
      traceStreamController.add("$state\n");
    }
  }
}
