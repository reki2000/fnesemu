import 'dart:typed_data';

import '../../state.dart';
import 'fault.dart';

/// SH7750 RTC register bring-up (hardware manual section 11.2).
/// Oscillator advancement and RTC interrupts remain unimplemented.
class DcRtc {
  final _registers = Uint16List(16)..[15] = 9;
  static const _masks = [
    0x7f,
    0x7f,
    0x7f,
    0x3f,
    7,
    0x3f,
    0x1f,
    0xffff,
    0xff,
    0xff,
    0xbf,
    0x87,
    0xbf,
    0x9f,
    0x99,
    0xff
  ];

  static int? offset(int address) {
    if (address >= 0xc0000000 && address < 0xe0000000) return null;
    final physical = address & 0x1fffffff;
    return physical >= 0x1fc80000 && physical <= 0x1fc8003c
        ? physical - 0x1fc80000
        : null;
  }

  int _index(int offset, int size) {
    if (offset & 3 != 0 ||
        offset < 0 ||
        offset > 0x3c ||
        size != (offset == 0x1c ? 2 : 1)) {
      throw const DcUnsupported('SH7750 RTC access width or offset');
    }
    return offset ~/ 4;
  }

  int read(int offset, int size) => _registers[_index(offset, size)];
  void write(int offset, int size, int value) {
    final index = _index(offset, size);
    if (index == 0) throw const DcUnsupported('SH7750 R64CNT is read-only');
    if (index == 14) {
      _registers[index] = (value & 0x18) | (_registers[index] & value & 0x81);
    } else if (index == 15) {
      if (value & 4 != 0) {
        throw const DcUnsupported('SH7750 RTC 30-second adjustment');
      }
      if (value & 2 != 0) _registers[0] = 0;
      _registers[index] = value & 0xf9;
    } else {
      _registers[index] = value & _masks[index];
    }
  }

  void reset({bool powerOn = true}) {
    _registers[14] = 0;
    _registers[15] = powerOn ? 9 : _registers[15] & 9;
    if (powerOn) {
      for (var i = 8; i < 14; i++) {
        _registers[i] &= 0x7f;
      }
    }
  }

  void saveState(StateWriter writer) {
    writer.section('dc.sh4.rtc');
    writer.ints(_registers);
  }

  void loadState(StateReader reader) {
    reader.section('dc.sh4.rtc');
    final values = reader.ints();
    if (values.length != 16) throw const StateMismatch('SH7750 RTC layout');
    for (var i = 0; i < 16; i++) {
      if (values[i] < 0 ||
          values[i] & ~_masks[i] != 0 ||
          (i == 15 && values[i] & 6 != 0)) {
        throw const StateMismatch('SH7750 RTC register');
      }
    }
    _registers.setAll(0, values);
  }
}
