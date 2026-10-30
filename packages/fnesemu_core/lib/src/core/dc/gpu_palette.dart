import 'dart:typed_data';

import '../../state.dart';
import 'fault.dart';

/// On-chip 1024-entry palette, System Architecture §§3.6.1, 3.7.9.3 and 8.4.2.
/// Raw words are decoded at fetch; format-change/cache synchronization is unverified.
class DcGpuPalette {
  final words = Uint32List(1024);
  int _control = 0;
  int get control => _control;
  set control(int value) {
    _control = value & 3;
    version++;
  }

  /// Changes with palette contents or format; texture caches compare it.
  int version = 0;

  void saveState(StateWriter writer) {
    writer.section('dc.gpu.palette');
    writer.int64(_control);
    writer.ints(words);
  }

  void loadState(StateReader reader) {
    reader.section('dc.gpu.palette');
    final control = reader.int64(), values = reader.ints();
    if (control < 0 ||
        control > 3 ||
        values.length != words.length ||
        values.any((value) => value < 0 || value > 0xffffffff)) {
      throw const StateMismatch('GPU palette state');
    }
    _control = control;
    words.setAll(0, values);
    version++;
  }

  void reset({bool clearMemory = false}) {
    _control = 0;
    version++;
    if (clearMemory) words.fillRange(0, words.length, 0);
  }

  void _validate(int offset, int size) {
    if (size != 4 || offset & 3 != 0 || offset < 0 || offset >= 4096) {
      throw const DcUnsupported('GPU palette RAM requires aligned longwords');
    }
  }

  int read(int offset, int size) {
    _validate(offset, size);
    return words[offset ~/ 4];
  }

  void write(int offset, int size, int value) {
    _validate(offset, size);
    words[offset ~/ 4] = value & (_control == 3 ? 0xffffffff : 0xffff);
    version++;
  }

  int color(int index) {
    if (index < 0 || index >= words.length) {
      throw const DcUnsupported('GPU palette index exceeds 1024 entries');
    }
    return decode(words[index], _control, repeat: true);
  }

  static final _decoded = List<Uint32List?>.filled(6, null);

  /// Decodes a 16-bit texel or palette entry through a per-format table.
  static int decode(int value, int format, {required bool repeat}) {
    if (format == 3) return value & 0xffffffff;
    if (value >> 16 == 0 && format < 3) {
      final slot = format * 2 + (repeat ? 1 : 0);
      final table = _decoded[slot] ??= Uint32List.fromList([
        for (var i = 0; i < 0x10000; i++) _decode(i, format, repeat: repeat)
      ]);
      return table[value];
    }
    return _decode(value, format, repeat: repeat);
  }

  static int _decode(int value, int format, {required bool repeat}) {
    int expand(int component, int bits) {
      final shifted = component << (8 - bits);
      return bits == 1
          ? component * 255
          : repeat
              ? shifted | (component >> (2 * bits - 8))
              : shifted;
    }

    if (format == 1) {
      return (0xff000000 |
              (expand((value >> 11) & 31, 5) << 16) |
              (expand((value >> 5) & 63, 6) << 8) |
              expand(value & 31, 5)) &
          0xffffffff;
    }
    if (format == 2) {
      return ((expand((value >> 12) & 15, 4) << 24) |
              (expand((value >> 8) & 15, 4) << 16) |
              (expand((value >> 4) & 15, 4) << 8) |
              expand(value & 15, 4)) &
          0xffffffff;
    }
    return ((expand((value >> 15) & 1, 1) << 24) |
            (expand((value >> 10) & 31, 5) << 16) |
            (expand((value >> 5) & 31, 5) << 8) |
            expand(value & 31, 5)) &
        0xffffffff;
  }
}
