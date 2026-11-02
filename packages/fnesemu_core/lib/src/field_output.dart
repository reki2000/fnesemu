import 'dart:typed_data';

import 'state.dart';
import 'types.dart';

/// Writes alternating rows without changing the physical display size.
class FieldOutput {
  ImageBuffer? image;

  void reset() => image = null;

  ImageBuffer writeField(ImageBuffer field, int parity) {
    assert(parity == 0 || parity == 1);
    var current = image;
    final width = field.width, height = field.height * 2;
    final displayHeight = field.displayHeight ?? field.height;
    if (current == null ||
        current.width != width ||
        current.height != height ||
        current.displayWidth != field.displayWidth ||
        current.displayHeight != displayHeight) {
      current = image = ImageBuffer(width, height,
          Uint32List(width * height)..fillRange(0, width * height, 0xff000000),
          displayWidth_: field.displayWidth, displayHeight: displayHeight);
    }
    final pixels = current.buffer;
    for (var y = 0; y < field.height; y++) {
      final target = (y * 2 + parity) * width;
      pixels.setRange(target, target + width, field.buffer, y * width);
    }
    return current;
  }

  void saveState(StateWriter w) {
    final current = image;
    if (current == null) {
      w.ints(const []);
      return;
    }
    w.ints([current.width, current.height, current.displayWidth,
      current.displayHeight ?? current.height]);
    w.bytes(current.bytes);
  }

  void loadState(StateReader s) {
    final size = s.ints();
    if (size.isEmpty) {
      reset();
      return;
    }
    if (size.length != 4 || size.any((n) => n <= 0 || n > 4096)) {
      throw const StateMismatch('field output dimensions');
    }
    final pixels = Uint32List(size[0] * size[1]);
    s.bytesInto(pixels.buffer.asUint8List());
    image = ImageBuffer(size[0], size[1], pixels,
        displayWidth_: size[2], displayHeight: size[3]);
  }
}
