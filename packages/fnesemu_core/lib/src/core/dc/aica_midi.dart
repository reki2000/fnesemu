import 'dart:collection';

import '../../state.dart';

/// Functional byte endpoint for System Architecture §8.4.5 MIDI registers.
/// RX capacity is specified as four bytes; TX capacity is a model policy.
class DcAicaMidi {
  final _input = Queue<int>(), _output = Queue<int>();
  bool _overflow = false;
  int _lastInput = 0;
  bool get hasInput => _input.isNotEmpty;
  bool get hasOutput => _output.isNotEmpty;

  void reset() {
    _input.clear();
    _output.clear();
    _overflow = false;
    _lastInput = 0;
  }

  void saveState(StateWriter writer) {
    writer.section('dc.aica.midi');
    writer.bytes(_input.toList());
    writer.bytes(_output.toList());
    writer.int32(_lastInput);
    writer.boolean(_overflow);
  }

  void loadState(StateReader reader) {
    reader.section('dc.aica.midi');
    final input = reader.bytes(), output = reader.bytes();
    final last = reader.int32(), overflow = reader.boolean();
    if (input.length > 4 || output.length > 4 || last < 0 || last > 255) {
      throw const StateMismatch('AICA MIDI FIFO state');
    }
    _input
      ..clear()
      ..addAll(input);
    _output
      ..clear()
      ..addAll(output);
    _lastInput = last;
    _overflow = overflow;
  }

  /// A full RX FIFO retains its oldest bytes and drops the newly arrived byte.
  bool receive(int value) {
    if (_input.length == 4) {
      _overflow = true;
      return false;
    }
    _input.add(value & 255);
    return true;
  }

  int read({bool sideEffects = true}) {
    final status = (_output.length == 4 ? 0x1000 : 0) |
        (_output.isEmpty ? 0x800 : 0) |
        (_overflow ? 0x400 : 0) |
        (_input.length == 4 ? 0x200 : 0) |
        (_input.isEmpty ? 0x100 : 0);
    final value = _input.isEmpty ? _lastInput : _input.first;
    if (sideEffects) {
      if (_input.isNotEmpty) _lastInput = _input.removeFirst();
      // Overflow read-clear and empty-read retention need hardware validation.
      _overflow = false;
    }
    return status | value;
  }

  /// Full TX FIFO writes are dropped; software should check MOFUL first.
  bool write(int value) {
    if (_output.length == 4) return false;
    _output.add(value & 255);
    return true;
  }

  int? takeOutput() => _output.isEmpty ? null : _output.removeFirst();
}
