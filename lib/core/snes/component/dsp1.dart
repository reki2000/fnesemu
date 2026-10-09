import 'dart:math' as math;

import '../rom/snes_file.dart';

/// DSP-1: a cartridge math coprocessor. The main cpu writes a command byte
/// and its 16-bit parameters to the data register, and reads the results
/// back from it.
///
/// The commands are computed directly (high level) after the formulas of
/// the bsnes implementation; where bsnes uses the chip's internal tables
/// (inverse, sine and the projection math), this computes the same values
/// in floating point, so results can differ in the lowest bits.
class Dsp1 {
  final SnesMapping mapping;
  final int romSize;

  Dsp1(this.mapping, this.romSize);

  static const _none = 0, _dr = 1, _sr = 2;

  /// which register [addr] is: 0 = none, 1 = data, 2 = status
  int port(int addr) {
    final bank = (addr >> 16) & 0x7f;
    final page = addr & 0xffff;
    if (mapping == SnesMapping.hiRom) {
      if (bank < 0x20 && page >= 0x6000 && page < 0x8000) {
        return page < 0x7000 ? _dr : _sr;
      }
    } else if (romSize > 0x100000) {
      if (bank >= 0x60 && bank < 0x70 && page < 0x8000) {
        return page < 0x4000 ? _dr : _sr;
      }
    } else if (bank >= 0x30 && bank < 0x40 && page >= 0x8000) {
      return page < 0xc000 ? _dr : _sr;
    }
    return _none;
  }

  // ------------------------------------------------------------ transfer
  static const _waitCommand = 0, _readInput = 1, _writeOutput = 2;
  int _state = _waitCommand;
  int _command = 0;
  bool _highByte = false;
  int _lowByte = 0;

  final _input = List<int>.filled(8, 0);
  int _inputCount = 0, _inputIndex = 0;
  List<int> _output = const [];
  int _outputIndex = 0;

  void reset() {
    _state = _waitCommand;
    _highByte = false;
    _inputIndex = _outputIndex = 0;
    _output = const [];
  }

  /// a read of the status register: the chip is always ready
  int readStatus() => 0x80;

  int readData() {
    if (_state != _writeOutput) return 0x00;
    final word = _output[_outputIndex];
    if (!_highByte) {
      _highByte = true;
      return word & 0xff;
    }
    _highByte = false;
    if (++_outputIndex == _output.length) {
      _outputIndex = 0;
      if (_isRaster(_command)) {
        // the raster command goes on with the next line until a new command
        _input[0] = _s16(_input[0] + 1);
        _output = _execute();
      } else {
        _state = _waitCommand;
      }
    }
    return (word >> 8) & 0xff;
  }

  void writeData(int data) {
    if (_state == _readInput) {
      if (!_highByte) {
        _lowByte = data;
        _highByte = true;
        return;
      }
      _highByte = false;
      _input[_inputIndex++] = _s16(_lowByte | data << 8);
      if (_inputIndex < _inputCount) return;
      _output = _execute();
      _outputIndex = 0;
      _state = _output.isEmpty ? _waitCommand : _writeOutput;
      return;
    }
    // a write while results are pending starts a new command
    _highByte = false;
    if (data & 0xc0 != 0) {
      _state = _waitCommand;
      return;
    }
    _command = data;
    _inputCount = _inputCounts[data];
    _inputIndex = 0;
    _state = _readInput;
  }

  static bool _isRaster(int c) => c & 0x0f == 0x0a;

  // the number of parameters of each command
  static final _inputCounts = List<int>.generate(64, (c) {
    switch (c) {
      case 0x00 || 0x20 || 0x10 || 0x30 || 0x04 || 0x24:
        return 2;
      case 0x0e || 0x1e || 0x2e || 0x3e:
        return 2;
      case 0x08 || 0x28 || 0x0c || 0x2c:
        return 3;
      case 0x06 || 0x16 || 0x26 || 0x36:
        return 3;
      case 0x18 || 0x38:
        return 4;
      case 0x1c || 0x3c || 0x14 || 0x34:
        return 6;
      case 0x02 || 0x12 || 0x22 || 0x32:
        return 7;
      case 0x0a || 0x1a || 0x2a || 0x3a:
        return 1;
      case 0x01 || 0x05 || 0x31 || 0x35 || 0x11 || 0x15 || 0x21 || 0x25:
        return 4;
      case 0x0d || 0x09 || 0x39 || 0x3d || 0x1d || 0x19 || 0x2d || 0x29:
        return 3;
      case 0x03 || 0x33 || 0x13 || 0x23 || 0x0b || 0x3b || 0x1b || 0x2b:
        return 3;
      default: // memory test, size and dump
        return 1;
    }
  });

  List<int> _execute() {
    final i = _input;
    switch (_command) {
      case 0x00: // multiply
        return [_s16(i[0] * i[1] >> 15)];
      case 0x20:
        return [_s16((i[0] * i[1] >> 15) + 1)];
      case 0x10 || 0x30:
        final (c, e) = _inverse(i[0], i[1]);
        return [c, e];
      case 0x04 || 0x24: // triangle
        return [_s16(i[1] * _sin(i[0]) >> 15), _s16(i[1] * _cos(i[0]) >> 15)];
      case 0x08: // radius
        final size = ((i[0] * i[0] + i[1] * i[1] + i[2] * i[2]) << 1);
        return [_s16(size), _s16(size >> 16)];
      case 0x18 || 0x38: // range
        return [
          _s16((i[0] * i[0] + i[1] * i[1] + i[2] * i[2] - i[3] * i[3]) >> 15)
        ];
      case 0x28: // distance
        final d = math.sqrt(i[0] * i[0] + i[1] * i[1] + i[2] * i[2]);
        return [math.min(d.floor(), 0x7fff)];
      case 0x0c || 0x2c: // rotate
        final s = _sin(i[0]), c = _cos(i[0]);
        return [
          _s16((i[2] * s >> 15) + (i[1] * c >> 15)),
          _s16((i[2] * c >> 15) - (i[1] * s >> 15)),
        ];
      case 0x1c || 0x3c:
        return _polar(i);
      case 0x02 || 0x12 || 0x22 || 0x32:
        return _parameter(i);
      case 0x0a || 0x1a || 0x2a || 0x3a:
        return _raster(i[0]);
      case 0x06 || 0x16 || 0x26 || 0x36:
        return _project(i[0], i[1], i[2]);
      case 0x0e || 0x1e || 0x2e || 0x3e:
        return _target(i[0], i[1]);
      case 0x01 || 0x05 || 0x31 || 0x35:
        _attitude(_matrixA, i);
        return const [];
      case 0x11 || 0x15:
        _attitude(_matrixB, i);
        return const [];
      case 0x21 || 0x25:
        _attitude(_matrixC, i);
        return const [];
      case 0x0d || 0x09 || 0x39 || 0x3d:
        return _objective(_matrixA, i);
      case 0x1d || 0x19:
        return _objective(_matrixB, i);
      case 0x2d || 0x29:
        return _objective(_matrixC, i);
      case 0x03 || 0x33:
        return _subjective(_matrixA, i);
      case 0x13:
        return _subjective(_matrixB, i);
      case 0x23:
        return _subjective(_matrixC, i);
      case 0x0b || 0x3b:
        return _scalar(_matrixA, i);
      case 0x1b:
        return _scalar(_matrixB, i);
      case 0x2b:
        return _scalar(_matrixC, i);
      case 0x14 || 0x34:
        return _gyrate(i);
      case 0x27 || 0x2f: // memory size
        return const [0x0100];
      case 0x1f || 0x17 || 0x37 || 0x3f: // data rom dump (not available)
        return List<int>.filled(1024, 0);
      default: // memory test
        return const [0x0000];
    }
  }

  // ----------------------------------------------------------- arithmetic
  static int _s16(int v) => ((v & 0xffff) ^ 0x8000) - 0x8000;

  static int _clip(num v) {
    if (v.isNaN) return 0;
    if (v >= 32767) return 32767;
    if (v <= -32768) return -32768;
    return v.floor();
  }

  static double _rad(int angle) => angle * math.pi / 32768;
  static int _sin(int a) => (math.sin(_rad(a)) * 32767).round();
  static int _cos(int a) => (math.cos(_rad(a)) * 32767).round();

  /// the reciprocal of coefficient * 2^exponent (a Q15 coefficient), as a
  /// Q15 coefficient and an exponent
  static (int, int) _inverse(int coefficient, int exponent) {
    if (coefficient == 0) return (0x7fff, 0x002f);
    var sign = 1;
    if (coefficient < 0) {
      coefficient = math.max(coefficient, -32767).abs();
      sign = -1;
    }
    while (coefficient < 0x4000) {
      coefficient <<= 1;
      exponent--;
    }
    int result;
    if (coefficient == 0x4000) {
      if (sign == 1) {
        result = 0x7fff;
      } else {
        result = -0x4000;
        exponent--;
      }
    } else {
      result = sign * ((1 << 29) ~/ coefficient);
    }
    return (result, _s16(1 - exponent));
  }

  List<int> _polar(List<int> i) {
    final az = i[0], ay = i[1], ax = i[2];
    var x1 = i[3], y1 = i[4], z1 = i[5];
    var x2 = _s16((y1 * _sin(az) >> 15) + (x1 * _cos(az) >> 15));
    var y2 = _s16((y1 * _cos(az) >> 15) - (x1 * _sin(az) >> 15));
    x1 = x2;
    y1 = y2;
    var z2 = _s16((x1 * _sin(ay) >> 15) + (z1 * _cos(ay) >> 15));
    x2 = _s16((x1 * _cos(ay) >> 15) - (z1 * _sin(ay) >> 15));
    z1 = z2;
    y2 = _s16((z1 * _sin(ax) >> 15) + (y1 * _cos(ax) >> 15));
    z2 = _s16((z1 * _cos(ax) >> 15) - (y1 * _sin(ax) >> 15));
    return [x2, y2, z2];
  }

  // -------------------------------------------------------------- matrices
  final _matrixA = List.generate(3, (_) => List<int>.filled(3, 0));
  final _matrixB = List.generate(3, (_) => List<int>.filled(3, 0));
  final _matrixC = List.generate(3, (_) => List<int>.filled(3, 0));

  void _attitude(List<List<int>> m, List<int> i) {
    final mm = i[0] >> 1;
    final sz = _sin(i[1]), cz = _cos(i[1]);
    final sy = _sin(i[2]), cy = _cos(i[2]);
    final sx = _sin(i[3]), cx = _cos(i[3]);
    final mcz = mm * cz >> 15, msz = mm * sz >> 15;
    m[0][0] = _s16(mcz * cy >> 15);
    m[0][1] = _s16(-(msz * cy >> 15));
    m[0][2] = _s16(mm * sy >> 15);
    m[1][0] = _s16((msz * cx >> 15) + ((mcz * sx >> 15) * sy >> 15));
    m[1][1] = _s16((mcz * cx >> 15) - ((msz * sx >> 15) * sy >> 15));
    m[1][2] = _s16(-((mm * sx >> 15) * cy >> 15));
    m[2][0] = _s16((msz * sx >> 15) - ((mcz * cx >> 15) * sy >> 15));
    m[2][1] = _s16((mcz * sx >> 15) + ((msz * cx >> 15) * sy >> 15));
    m[2][2] = _s16((mm * cx >> 15) * cy >> 15);
  }

  List<int> _objective(List<List<int>> m, List<int> i) => [
        for (var r = 0; r < 3; r++)
          _s16((i[0] * m[r][0] >> 15) +
              (i[1] * m[r][1] >> 15) +
              (i[2] * m[r][2] >> 15)),
      ];

  List<int> _subjective(List<List<int>> m, List<int> i) => [
        for (var c = 0; c < 3; c++)
          _s16((i[0] * m[0][c] >> 15) +
              (i[1] * m[1][c] >> 15) +
              (i[2] * m[2][c] >> 15)),
      ];

  List<int> _scalar(List<List<int>> m, List<int> i) =>
      [_s16((i[0] * m[0][0] + i[1] * m[0][1] + i[2] * m[0][2]) >> 15)];

  List<int> _gyrate(List<int> i) {
    final az = i[0], ax = i[1], ay = i[2], u = i[3], f = i[4], l = i[5];
    final sy = math.sin(_rad(ay)), cy = math.cos(_rad(ay));
    final sx = math.sin(_rad(ax)), cx = math.cos(_rad(ax));
    final rz = az + _clip((u * cy - f * sy) / cx);
    final rx = ax + (u * _sin(ay) >> 15) + (f * _cos(ay) >> 15);
    final ry = ay + _clip(-(u * cy + f * sy) * sx / cx) + l;
    return [_s16(rz), _s16(rx), _s16(ry)];
  }

  // ------------------------------------------------------------ projection
  // the zenith angle is clipped by the height of the viewpoint
  static const _maxZenith = [
    0x38b4, 0x38b7, 0x38ba, 0x38be, 0x38c0, 0x38c4, 0x38c7, 0x38ca, //
    0x38ce, 0x38d0, 0x38d4, 0x38d7, 0x38da, 0x38dd, 0x38e0, 0x38e4,
  ];

  double _sinAas = 0, _cosAas = 1, _sinAzs = 0, _cosAzs = 1;
  double _nx = 0, _ny = 0, _nz = 1;
  double _centreX = 0, _centreY = 0;
  int _centreZ = 0;
  double _gx = 0, _gy = 0, _gz = 0;
  int _les = 0;
  double _vOffset = 0, _secZenith = 1;

  // the number of left shifts normalizing a 16-bit value
  static int _normalShift(int m) {
    var bit = 0x4000, e = 0;
    if (m < 0) {
      while (m & bit != 0 && bit != 0) {
        bit >>= 1;
        e++;
      }
    } else {
      while (m & bit == 0 && bit != 0) {
        bit >>= 1;
        e++;
      }
    }
    return e;
  }

  List<int> _parameter(List<int> i) {
    final fx = i[0], fy = i[1], fz = i[2], lfe = i[3], les = i[4];
    final aas = i[5], azs = i[6];

    _sinAas = math.sin(_rad(aas));
    _cosAas = math.cos(_rad(aas));
    _sinAzs = math.sin(_rad(azs));
    _cosAzs = math.cos(_rad(azs));

    _nx = -_sinAzs * _sinAas;
    _ny = _sinAzs * _cosAas;
    _nz = _cosAzs;

    _centreX = fx + lfe * _nx;
    _centreY = fy + lfe * _ny;
    _centreZ = _clip(fz + lfe * _nz);

    _gx = _centreX - les * _nx;
    _gy = _centreY - les * _ny;
    _gz = _centreZ - les * _nz;
    _les = les;

    // clip the zenith angle
    var maxZenith = _maxZenith[math.min(_normalShift(_centreZ), 15)];
    var zenith = azs;
    if (zenith < 0) {
      maxZenith = -maxZenith;
      if (zenith < maxZenith + 1) zenith = maxZenith + 1;
    } else if (zenith > maxZenith) {
      zenith = maxZenith;
    }
    final sinZ = math.sin(_rad(zenith)), cosZ = math.cos(_rad(zenith));
    _secZenith = 1 / cosZ;

    final c = _clip(_centreZ * _secZenith) * sinZ;
    _centreX = _clip(_centreX + c * _sinAas).toDouble();
    _centreY = _clip(_centreY - c * _cosAas).toDouble();

    _vOffset = les * cosZ;
    final vva = _clip(-_vOffset / sinZ);
    return [0, vva, _centreX.toInt(), _centreY.toInt()];
  }

  List<int> _raster(int vs) {
    final t = _centreZ / (vs * _sinAzs + _vOffset);
    final c = _clip(256 * t);
    final c2 = _clip(256 * t * _secZenith);
    return [
      _clip(c * _cosAas),
      _clip(-c2 * _sinAas),
      _clip(c * _sinAas),
      _clip(c2 * _cosAas),
    ];
  }

  List<int> _project(int x, int y, int z) {
    final px = x - _gx, py = y - _gy, pz = z - _gz;
    final depth = (_les & 0xffff) - (px * _nx + py * _ny + pz * _nz);
    final scale = _les / depth;
    final h = (px * _cosAas + py * _sinAas) * scale;
    final v =
        (px * -_cosAzs * _sinAas + py * _cosAzs * _cosAas - pz * _sinAzs) *
            scale;
    return [_clip(h), _clip(v), _clip(256 * scale)];
  }

  List<int> _target(int h, int v) {
    final t = _centreZ / (v * _sinAzs + _vOffset);
    final ch = t * h, cv = t * v * _secZenith;
    return [
      _clip(_centreX + ch * _cosAas - cv * _sinAas),
      _clip(_centreY - ch * _sinAas + cv * _cosAas),
    ];
  }
}
