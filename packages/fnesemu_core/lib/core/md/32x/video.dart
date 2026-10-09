import 'dart:typed_data';

/// MD 32x double-buffered bitmap VDP. All bus storage is big-endian.
class ExpansionVideo {
  final frames = [Uint8List(0x20000), Uint8List(0x20000)];
  final palette = Uint16List(256);
  final output = Uint32List(320 * 224);
  int mode = 0, shift = 0, fillLength = 0, fillAddress = 0;
  int displayBank = 0, _requestedBank = 0, _fillClocks = 0;
  bool vblank = true, hblank = true;
  bool get busy => _fillClocks > 0;
  Uint8List get accessFrame => frames[displayBank ^ 1];

  void reset() {
    mode = shift = fillLength =
        fillAddress = displayBank = _requestedBank = _fillClocks = 0;
    vblank = hblank = true;
    output.fillRange(0, output.length, 0xff000000);
  }

  int readRegister(int offset) => switch (offset & 0xe) {
        0 => mode | 0x8000, // NTSC
        2 => shift,
        4 => fillLength,
        6 => fillAddress,
        0xa => (vblank ? 0x8000 : 0) |
            (hblank ? 0x4000 : 0) |
            ((vblank || hblank) ? 0x2000 : 0) |
            (busy ? 2 : 0) |
            displayBank,
        _ => 0,
      };
  void writeRegister(int offset, int value) {
    switch (offset & 0xe) {
      case 0:
        mode = value & 0x83;
      case 2:
        shift = value & 1;
      case 4:
        fillLength = value & 255;
      case 6:
        fillAddress = value & 0xffff;
      case 8:
        final frame = accessFrame;
        final page = fillAddress & 0xff00;
        for (int i = 0; i <= fillLength; i++) {
          final address = (page | ((fillAddress + i) & 255)) * 2;
          frame[address] = (value >> 8) & 255;
          frame[address + 1] = value & 255;
        }
        fillAddress = page | ((fillAddress + fillLength + 1) & 255);
        _fillClocks = (fillLength + 1) * 2;
      case 0xa:
        _requestedBank = value & 1;
        if (vblank || (mode & 3) == 0) displayBank = _requestedBank;
    }
  }

  void tick(int cycles) =>
      _fillClocks = (_fillClocks - cycles).clamp(0, 0x7fffffff);
  void beginLine(int line) {
    hblank = false;
    vblank = line < 0 || line >= 224;
    if (vblank) displayBank = _requestedBank;
  }

  int readFrame8(int offset) => accessFrame[offset & 0x1ffff];
  void writeFrame8(int offset, int value, {bool overwrite = false}) {
    if (!overwrite || (value & 255) != 0) {
      accessFrame[offset & 0x1ffff] = value & 255;
    }
  }

  static int color(int value) {
    int expand(int v) => (v << 3) | (v >> 2);
    return 0xff000000 |
        (expand((value >> 10) & 31) << 16) |
        (expand((value >> 5) & 31) << 8) |
        expand(value & 31);
  }

  void renderLine(
      int line, Uint32List mdPixels, Uint8List mdOpaque, int mdWidth) {
    if (line < 0 || line >= 224) return;
    final frame = frames[displayBank];
    final linePointer = ((frame[line * 2] << 8) | frame[line * 2 + 1]) * 2;
    final bitmapMode = mode & 3;
    int source = linePointer, run = 0, index = 0;
    for (int x = 0; x < 320; x++) {
      final mdOffset = line * mdWidth + x * mdWidth ~/ 320;
      int pixel = 0;
      bool visible = false;
      switch (bitmapMode) {
        case 1:
          index = frame[(linePointer + x + shift) & 0x1ffff];
          pixel = palette[index];
          visible = true;
        case 2:
          source = (linePointer + x * 2) & 0x1fffe;
          pixel = (frame[source] << 8) | frame[source + 1];
          visible = true;
        case 3:
          if (run == 0) {
            run = frame[source & 0x1ffff] + 1;
            index = frame[(source + 1) & 0x1ffff];
            source += 2;
          }
          run--;
          pixel = palette[index];
          visible = true;
      }
      // The priority bit inverts the global plane priority for this pixel.
      final front = ((pixel & 0x8000) != 0) != ((mode & 0x80) != 0);
      output[line * 320 + x] = visible && (front || mdOpaque[mdOffset] == 0)
          ? color(pixel)
          : mdPixels[mdOffset];
    }
  }
}
