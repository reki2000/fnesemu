import 'dart:math' as math;
import 'dart:typed_data';

import '../../state.dart';
import 'fault.dart';
import 'gpu_math.dart';

/// Functional color clamp and fog, System Architecture §§3.4.8, 3.7.9.2, 8.4.2.
/// Interpolation precision and rounding still require hardware measurements.
class DcGpuFog {
  final _table = Uint16List(128);
  int _tableColor = 0, _vertexColor = 0, _density = 0;
  int _minimum = 0, _maximum = 0;
  // Whether a lane of the clamp bounds has its minimum above its maximum.
  bool _invertedClamp = false;
  // The doubles of the byte values, so that a lookup replaces a conversion
  // call.
  final _bytes = Float64List.fromList([for (var i = 0; i < 256; i++) i + 0.0]);
  // The depth scale of the density register, which the table lookup of
  // every fragment uses.
  double _scale = 0;

  void _updateClamp() {
    _invertedClamp = false;
    for (var shift = 0; shift < 32; shift += 8) {
      if ((_minimum >> shift) & 255 > (_maximum >> shift) & 255) {
        _invertedClamp = true;
      }
    }
  }

  void _updateScale() {
    final exponent = (_density & 255).toSigned(8);
    _scale = ((_density >> 8) / 128) * math.pow(2.0, exponent);
  }

  void saveState(StateWriter writer) {
    writer.section('dc.gpu.fog');
    writer.ints([_tableColor, _vertexColor, _density, _minimum, _maximum]);
    writer.ints(_table);
  }

  void loadState(StateReader reader) {
    reader.section('dc.gpu.fog');
    final registers = reader.ints(), table = reader.ints();
    if (registers.length != 5 ||
        table.length != 128 ||
        registers.any((value) => value < 0) ||
        registers[0] > 0xffffff ||
        registers[1] > 0xffffff ||
        registers[2] > 0xffff ||
        registers[3] > 0xffffffff ||
        registers[4] > 0xffffffff ||
        table.any((value) => value < 0 || value > 0xffff)) {
      throw const StateMismatch('GPU fog or clamp state');
    }
    _tableColor = registers[0];
    _vertexColor = registers[1];
    _density = registers[2];
    _minimum = registers[3];
    _maximum = registers[4];
    _table.setAll(0, table);
    _updateScale();
    _updateClamp();
  }

  static bool handles(int offset) =>
      (offset >= 0xb0 && offset <= 0xc0 && offset & 3 == 0) ||
      (offset >= 0x200 && offset < 0x400 && offset & 3 == 0);

  void reset() {
    _tableColor = _vertexColor = _density = _minimum = _maximum = 0;
    _updateScale();
    _updateClamp();
    // The table has no documented power-on contents; zero is deterministic.
    _table.fillRange(0, _table.length, 0);
  }

  int read(int offset) {
    if (offset >= 0x200 && offset < 0x400 && offset & 3 == 0) {
      return _table[(offset - 0x200) ~/ 4];
    }
    return switch (offset) {
      0xb0 => _tableColor,
      0xb4 => _vertexColor,
      0xb8 => _density,
      0xbc => _maximum,
      0xc0 => _minimum,
      _ => throw const DcUnsupported('unimplemented fog register'),
    };
  }

  void write(int offset, int value) {
    if (offset >= 0x200 && offset < 0x400 && offset & 3 == 0) {
      _table[(offset - 0x200) ~/ 4] = value & 0xffff;
      return;
    }
    switch (offset) {
      case 0xb0:
        _tableColor = value & 0xffffff;
      case 0xb4:
        _vertexColor = value & 0xffffff;
      case 0xb8:
        _density = value & 0xffff;
        _updateScale();
      case 0xbc:
        _maximum = value & 0xffffffff;
        _updateClamp();
      case 0xc0:
        _minimum = value & 0xffffffff;
        _updateClamp();
      default:
        throw const DcUnsupported('unimplemented fog register');
    }
  }

  double _coefficient(double depth) {
    final scaled = depth * _scale;
    var mantissa =
        scaled < 255.9999 ? (scaled > 1.0 ? scaled : 1.0) : 255.9999;
    var index = 0;
    // Scaling by powers of two is exact, so the ladder equals halving until the value is below 2.
    if (mantissa >= 16) {
      mantissa *= 0.0625;
      index = 64;
    }
    if (mantissa >= 4) {
      mantissa *= 0.25;
      index += 32;
    }
    if (mantissa >= 2) {
      mantissa *= 0.5;
      index += 16;
    }
    final position = (mantissa - 1) * 16;
    // The position is not negative, so truncation is the floor.
    final whole = position.toInt();
    index += whole;
    final fraction = position - whole;
    final pair = _table[index];
    return (pair >> 8) * (1 - fraction) + (pair & 255) * fraction;
  }

  @pragma('vm:prefer-inline')
  int apply(int color, double depth, int offsetColor, int tsp,
      {required bool hasOffset}) {
    // The lanes are written out: a loop over the shifts keeps a range check
    // of each shift and a stack check in the compiled code.
    if (tsp & 0x200000 != 0) {
      if (_invertedClamp) {
        throw const DcUnsupported('CORE inverted color clamp bounds');
      }
      color = _clampLane(color, 0) |
          _clampLane(color, 8) |
          _clampLane(color, 16) |
          _clampLane(color, 24);
    }
    final mode = (tsp >> 22) & 3;
    if (mode == 2 || (mode == 1 && !hasOffset)) return color;
    final coefficient =
        mode == 1 ? _bytes[(offsetColor >> 24) & 255] : _coefficient(depth);
    final fogColor = mode == 1 ? _vertexColor : _tableColor;
    if (mode == 3) {
      return ((coefficient.round() << 24) | fogColor) & 0xffffffff;
    }
    final rest = 255 - coefficient;
    return ((color & 0xff000000) |
            _blendLane(color, fogColor, rest, coefficient, 0) |
            _blendLane(color, fogColor, rest, coefficient, 8) |
            _blendLane(color, fogColor, rest, coefficient, 16)) &
        0xffffffff;
  }

  @pragma('vm:prefer-inline')
  int _clampLane(int color, int shift) {
    final low = (_minimum >> shift) & 255, high = (_maximum >> shift) & 255;
    final value = (color >> shift) & 255;
    return (value < low ? low : (value > high ? high : value)) << shift;
  }

  // A multiply in place of a divide; the rounding may differ by one unit
  // in the last place.
  static const _inverse255 = 1 / 255;

  @pragma('vm:prefer-inline')
  static int _blendLane(
      int color, int fogColor, double rest, double coefficient, int shift) {
    final input = (color >> shift) & 255, fog = (fogColor >> shift) & 255;
    return roundByte((input * rest + fog * coefficient) * _inverse255) << shift;
  }
}
