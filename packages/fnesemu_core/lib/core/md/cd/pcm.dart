import 'dart:typed_data';
import '../../../util/int.dart';

/// RF5C164: eight channels of sign/magnitude PCM, with 11 fractional bits.
class CdPcm {
  static const clockHz = 12500000;
  static const sampleHz = clockHz ~/ 384;
  final ram = Uint8List(0x10000);
  final _channels = List.generate(8, (_) => _Channel());
  int _channel = 0;
  int _bank = 0;
  int _off = 0xff;
  bool _enabled = false;
  int _phase = 0;
  double _left = 0, _right = 0;

  void reset() {
    _channel = _bank = _phase = 0;
    _off = 0xff;
    _enabled = false;
    _left = _right = 0;
    for (final c in _channels) {
      c.envelope = c.pan = c.step = c.loop = c.start = c.position = 0;
    }
  }

  int read(int address) {
    final offset = address.mask14.shr1;
    if (offset >= 0x1000) return ram[_bank.shl12 | offset.mask12];
    if (offset >= 0x10 && offset < 0x20) {
      final c = _channels[(offset - 0x10).shr1];
      return (c.position >> (11 + (offset.isOdd ? 8 : 0))).mask8;
    }
    return 0xff;
  }

  void write(int address, int data) {
    data &= 0xff;
    final offset = address.mask14.shr1;
    if (offset >= 0x1000) {
      ram[_bank.shl12 | offset.mask12] = data;
      return;
    }
    final c = _channels[_channel];
    switch (offset) {
      case 0:
        c.envelope = data;
      case 1:
        c.pan = data;
      case 2:
        c.step = (c.step & 0xff00) | data;
      case 3:
        c.step = c.step.mask8 | data.shl8;
      case 4:
        c.loop = (c.loop & 0xff00) | data;
      case 5:
        c.loop = c.loop.mask8 | data.shl8;
      case 6:
        c.start = data.shl8;
        if ((_off & (1 << _channel)) != 0) c.position = c.start.shl11;
      case 7:
        _enabled = data.bit7;
        if (data.bit6) {
          _channel = data.mask3;
        } else {
          _bank = data.mask4;
        }
      case 8:
        for (int i = 0; i < 8; i++) {
          if ((data & (1 << i)) != 0) {
            _channels[i].position = _channels[i].start.shl11;
          }
        }
        _off = data;
    }
  }

  (double, double) sample(int outputHz) {
    _phase += clockHz;
    while (_phase >= outputHz * 384) {
      _phase -= outputHz * 384;
      _left = _right = 0;
      if (!_enabled) continue;
      for (int i = 0; i < 8; i++) {
        if ((_off & (1 << i)) != 0) continue;
        final c = _channels[i];
        int value = ram[c.position.shr11.mask16];
        if (value == 0xff) {
          c.position = c.loop.shl11;
          value = ram[c.loop];
          if (value == 0xff) continue;
        }
        final amplitude =
            (value.bit7 ? 1 : -1) * value.mask7 * c.envelope;
        _left += amplitude * c.pan.mask4 / (32 * 32768);
        _right += amplitude * c.pan.shr4 / (32 * 32768);
        c.position = (c.position + c.step) & 0x7ffffff;
      }
    }
    return (_left, _right);
  }
}

class _Channel {
  int envelope = 0, pan = 0, step = 0, loop = 0, start = 0, position = 0;
}
