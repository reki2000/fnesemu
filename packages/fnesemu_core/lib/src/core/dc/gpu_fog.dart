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
  }

  static bool handles(int offset) =>
      (offset >= 0xb0 && offset <= 0xc0 && offset & 3 == 0) ||
      (offset >= 0x200 && offset < 0x400 && offset & 3 == 0);

  void reset() {
    _tableColor = _vertexColor = _density = _minimum = _maximum = 0;
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
      case 0xbc:
        _maximum = value & 0xffffffff;
      case 0xc0:
        _minimum = value & 0xffffffff;
      default:
        throw const DcUnsupported('unimplemented fog register');
    }
  }

  double _coefficient(double depth) {
    final exponent = (_density & 255).toSigned(8);
    final scale = ((_density >> 8) / 128) * math.pow(2.0, exponent);
    var mantissa = (depth * scale).clamp(1.0, 255.9999);
    var index = 0;
    while (mantissa >= 2) {
      mantissa /= 2;
      index += 16;
    }
    final position = (mantissa - 1) * 16;
    index += position.floor();
    final fraction = position - position.floor();
    final pair = _table[index];
    return (pair >> 8) * (1 - fraction) + (pair & 255) * fraction;
  }

  int apply(int color, double depth, int offsetColor, int tsp,
      {required bool hasOffset}) {
    if (tsp & 0x200000 != 0) {
      var clamped = 0;
      for (var shift = 0; shift < 32; shift += 8) {
        final low = (_minimum >> shift) & 255;
        final high = (_maximum >> shift) & 255;
        if (low > high) {
          throw const DcUnsupported('CORE inverted color clamp bounds');
        }
        clamped |= ((color >> shift) & 255).clamp(low, high) << shift;
      }
      color = clamped;
    }
    final mode = (tsp >> 22) & 3;
    if (mode == 2 || (mode == 1 && !hasOffset)) return color;
    final coefficient =
        mode == 1 ? (offsetColor >> 24).toDouble() : _coefficient(depth);
    final fogColor = mode == 1 ? _vertexColor : _tableColor;
    if (mode == 3) {
      return ((coefficient.round() << 24) | fogColor) & 0xffffffff;
    }
    var result = color & 0xff000000;
    for (var shift = 0; shift < 24; shift += 8) {
      final input = (color >> shift) & 255, fog = (fogColor >> shift) & 255;
      result |=
          roundByte((input * (255 - coefficient) + fog * coefficient) / 255) <<
              shift;
    }
    return result & 0xffffffff;
  }
}
