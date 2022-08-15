// Dart imports:
import 'dart:async';

/// a ring buffer to supress redundant log which is identical to past N lines except X,Y registers
/// used for supress VBLANK wait loop, filling memory, etc.
class RingBuffer {
  final List<String> _buf;
  int _index = 0;
  bool _skipped = false;
  bool _recovered = false;

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
      if (_skipped) {
        _recovered = true;
      } else {
        _recovered = false;
      }
      _skipped = false;
      return true;
    }
    _recovered = false;
    _skipped = true;
    return false;
  }

  bool get recovered => _recovered;
}

class Trace {
  final StreamController<String> traceStreamController;
  final _ringBuffer = RingBuffer(20);

  Trace(this.traceStreamController);

  void addLog(String log) {
    // check redundancy of the first 73 chars which represents the CPU state
    // C78C  10 FB     BPL $C789                       A:00 X:00 Y:00 P:32 SP:FD
    // change of X or Y is ignored for X,Y are often used as a loop counter
    final state = log;
    if (_ringBuffer.addOnlyNewItem(state.replaceRange(53, 63, "          "))) {
      if (_ringBuffer.recovered) {
        traceStreamController.add("...supress...\n");
      }
      traceStreamController.add("$state\n");
    }
  }
}
