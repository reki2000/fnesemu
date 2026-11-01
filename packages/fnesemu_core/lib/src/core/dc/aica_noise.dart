import '../../state.dart';
import 'fault.dart';

/// Continuous noise input for SSCTL, independent of wave RAM and the LFO.
/// The xorshift sequence and per-slot seed are provisional, not measured AICA circuitry.
class DcAicaNoise {
  DcAicaNoise(int slot)
      : _random = ((0x6d2b79f5 ^ ((slot + 1) * 40503)) & 0xffffffff) | 1;

  int _random, _position = -1, _previous = 0, _current = 0;

  int sample(int position) {
    if (position == _position - 1) return _previous;
    if (position < _position) {
      throw const DcUnsupported('AICA noise input moved backwards');
    }
    while (_position < position) {
      var value = _random;
      value = (value ^ (value << 13)) & 0xffffffff;
      value ^= value >> 17;
      _random = (value ^ (value << 5)) & 0xffffffff;
      _previous = _current;
      _current = (_random >> 16).toSigned(16);
      _position++;
    }
    return _current;
  }

  void saveState(StateWriter writer) {
    writer.section('dc.aica.noise');
    writer.ints([_random, _position, _previous, _current]);
  }

  factory DcAicaNoise.fromState(StateReader reader) {
    reader.section('dc.aica.noise');
    final data = reader.ints();
    if (data.length != 4 ||
        data[0] <= 0 ||
        data[0] > 0xffffffff ||
        data[1] < -1 ||
        data[2] < -32768 ||
        data[2] > 32767 ||
        data[3] < -32768 ||
        data[3] > 32767) {
      throw const StateMismatch('AICA noise input state');
    }
    return DcAicaNoise(0)
      .._random = data[0]
      .._position = data[1]
      .._previous = data[2]
      .._current = data[3];
  }
}
