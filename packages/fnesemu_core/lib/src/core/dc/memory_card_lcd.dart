import 'dart:typed_data';

import '../../state.dart';
import '../../types.dart';

/// Memory card FT2 monochrome LCD packet state (memory card peripheral specification Rev. 1.00, FT2 Rev. 0.81).
class DcMemoryCardLcd {
  static const width = 48, height = 32, byteSize = 192;
  final _pixels = Uint8List(byteSize);

  void saveState(StateWriter writer) {
    writer.section('dc.memory_card.lcd');
    writer.bytes(_pixels);
  }

  void loadState(StateReader reader) {
    reader.section('dc.memory_card.lcd');
    final pixels = reader.bytes();
    if (pixels.length != byteSize) {
      throw const StateMismatch('Memory card LCD layout');
    }
    _pixels.setAll(0, pixels);
  }

  /// A copy of horizontal-1 panel data.
  Uint8List exportPixels() => Uint8List.fromList(_pixels);

  /// FT2 figures 2.5 and 2.9, memory card peripheral specification figure 4.6: row-major bytes, MSB on the left.
  ImageBuffer image() {
    final pixels = Uint32List(width * height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final black = _pixels[y * 6 + (x >> 3)] & (0x80 >> (x & 7)) != 0;
        pixels[y * width + x] = black ? 0xff000000 : 0xffffffff;
      }
    }
    return ImageBuffer(width, height, pixels);
  }

  void reset() => _pixels.fillRange(0, byteSize, 0);

  (int, List<int>) command(int code, Uint8List request) {
    (int, List<int>) error(int bits) => (0xfa, [0, 0, 0, bits]);
    if (code != 10 && code != 12 && code != 14) return (0xfd, const []);
    if (request.length < 12) return error(16);
    if (request[8] != 0) return error(1);
    if (code == 10) {
      if (request.length != 12) return error(16);
      if (request[9] != 0 || request[10] != 0 || request[11] != 0) {
        return (0xfc, const []);
      }
      return (8, const [0, 0, 0, 4, 47, 31, 0x10, 0]);
    }
    if (code == 14) {
      if (request.length != 12) return error(16);
      // The memory card declares no contrast adjustment (CT=0).
      if ((request[9] != 0 && request[9] != 255) ||
          request[10] != 0 ||
          request[11] != 0) {
        return error(32);
      }
      return (8, const [0, 0, 0, 4, 0, 0, 0, 0]);
    }
    if (request[9] != 0) return error(2);
    if (request[10] != 0 || request[11] != 0) return error(4);
    if (request.length != 12 + byteSize) return error(16);
    _pixels.setRange(0, byteSize, request, 12);
    return (7, const []);
  }
}
