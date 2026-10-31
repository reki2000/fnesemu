import 'dart:typed_data';

import '../../state.dart';

/// Sequential AICA ADPCM with history retained across long-stream loops.
/// System Architecture §8.1.1.1–2; bus prefetch timing is not modeled.
class DcAicaAdpcmStream {
  DcAicaAdpcmStream(this.memory,
      {required this.start, required this.loopStart, required this.end});
  final Uint8List memory;
  final int start, loopStart, end;
  int _position = -1, _previous = 0, _value = 0, _step = 127;

  void saveState(StateWriter writer) {
    writer.section('dc.aica.adpcm-stream');
    for (final value in [start, loopStart, end]) {
      writer.int32(value);
    }
    writer.int64(_position);
    for (final value in [_previous, _value, _step]) {
      writer.int32(value);
    }
  }

  /// Bind restored history to the owning AICA instance's existing wave RAM.
  factory DcAicaAdpcmStream.fromState(Uint8List memory, StateReader reader) {
    reader.section('dc.aica.adpcm-stream');
    final start = reader.int32(), loop = reader.int32(), end = reader.int32();
    final position = reader.int64();
    final previous = reader.int32(),
        value = reader.int32(),
        step = reader.int32();
    if (start < 0 ||
        loop < 0 ||
        end < loop ||
        start + end ~/ 2 >= memory.length ||
        position < -1 ||
        (loop == end && position > end) ||
        previous < -32768 ||
        previous > 32767 ||
        value < -32768 ||
        value > 32767 ||
        step < 127 ||
        step > 24576) {
      throw const StateMismatch('AICA ADPCM stream state');
    }
    return DcAicaAdpcmStream(memory, start: start, loopStart: loop, end: end)
      .._position = position
      .._previous = previous
      .._value = value
      .._step = step;
  }

  /// Interpolation may revisit the previous sample after one-sample lookahead.
  int sample(int position) {
    if (position < 0 || position < _position - 1) {
      throw ArgumentError.value(
          position, 'position', 'ADPCM stream moved back');
    }
    if (position == _position - 1) return _previous;
    const factors = [230, 230, 230, 230, 307, 409, 512, 614];
    while (_position < position) {
      _position++;
      final index = _position <= end
          ? _position
          : loopStart + 1 + (_position - end - 1) % (end - loopStart);
      final nibble = (memory[start + index ~/ 2] >> ((index & 1) * 4)) & 15;
      final delta = ((2 * (nibble & 7) + 1) * _step) ~/ 8;
      _previous = _value;
      _value =
          (_value + (nibble & 8 != 0 ? -delta : delta)).clamp(-32768, 32767);
      _step = (_step * factors[nibble & 7] ~/ 256).clamp(127, 24576);
    }
    return _value;
  }
}
