import 'dart:typed_data';

/// Stamp-map coordinate conversion into the VDP's column-major cell format.
class CdGraphics {
  final Uint8List ram, registers;
  final void Function() interrupt;
  CdGraphics(this.ram, this.registers, this.interrupt);
  int _remainingCycles = 0;
  bool get busy => _remainingCycles > 0;
  int _reg(int offset) => (registers[offset] << 8) | registers[offset + 1];
  int _word(int address) =>
      (ram[address & 0x3ffff] << 8) | ram[(address + 1) & 0x3ffff];
  void reset() => _remainingCycles = 0;

  void start(int priority) {
    if (busy) return;
    final flags = _reg(0x58);
    final stampSize = (flags & 2) != 0 ? 32 : 16;
    final mapSize = (flags & 4) != 0 ? 4096 : 256;
    final mapMask = mapSize - 1;
    final mapWidth = mapSize ~/ stampSize;
    final mapBytes = mapWidth * mapWidth * 2;
    final mapBase = (_reg(0x5a) << 2) & ~(mapBytes - 1);
    final imageBase = (_reg(0x5e) << 2) & 0x3ffe0;
    final verticalCells = (_reg(0x5c) & 31) + 1;
    final offset = _reg(0x60);
    final width = _reg(0x62) & 0x1ff;
    final height = _reg(0x64) & 0xff;
    final traceBase = (_reg(0x66) << 2) & 0x3fff8;
    for (int line = 0; line < height; line++) {
      final trace = traceBase + line * 8;
      // Start coordinates have three fractional bits; deltas have eleven.
      int x = _word(trace).toSigned(16) << 8;
      int y = _word(trace + 2).toSigned(16) << 8;
      final dx = _word(trace + 4).toSigned(16);
      final dy = _word(trace + 6).toSigned(16);
      for (int pixel = 0; pixel < width; pixel++, x += dx, y += dy) {
        int sx = x >> 11, sy = y >> 11, color = 0;
        if ((flags & 1) != 0 ||
            (sx >= 0 && sy >= 0 && sx < mapSize && sy < mapSize)) {
          sx &= mapMask;
          sy &= mapMask;
          final entry = _word(
              mapBase + ((sy ~/ stampSize) * mapWidth + sx ~/ stampSize) * 2);
          final stamp = (entry & 0x7ff) & (stampSize == 32 ? ~3 : ~0);
          if (stamp != 0) {
            int px = sx & (stampSize - 1), py = sy & (stampSize - 1);
            if ((entry & 0x8000) != 0) px = stampSize - 1 - px;
            // after the flip: bit14 turns the stamp by 180 degrees, then
            // bit13 by 90 degrees (column <- inverted row, row <- column)
            switch ((entry >> 13) & 3) {
              case 1:
                final old = px;
                px = stampSize - 1 - py;
                py = old;
              case 2:
                px = stampSize - 1 - px;
                py = stampSize - 1 - py;
              case 3:
                final old = px;
                px = py;
                py = stampSize - 1 - old;
            }
            final source = stamp * 128 +
                ((px >> 3) * (stampSize >> 3) + (py >> 3)) * 32 +
                (py & 7) * 4 +
                ((px & 7) >> 1);
            color = (ram[source & 0x3ffff] >> (px.isEven ? 4 : 0)) & 15;
          }
        }
        final ix = pixel + (offset & 7), iy = line + ((offset >> 3) & 7);
        final destination = (imageBase +
                ((ix >> 3) * verticalCells + (iy >> 3)) * 32 +
                (iy & 7) * 4 +
                ((ix & 7) >> 1)) &
            0x3ffff;
        final shift = ix.isEven ? 4 : 0;
        final old = (ram[destination] >> shift) & 15;
        if ((priority == 1 && old != 0) || (priority == 2 && color == 0)) {
          continue;
        }
        ram[destination] =
            (ram[destination] & ~(15 << shift)) | (color << shift);
      }
    }
    _remainingCycles = (width * height * 5 + height * 8).clamp(1, 0x7fffffff);
  }

  void tick(int cycles) {
    if (!busy) return;
    _remainingCycles -= cycles;
    if (_remainingCycles <= 0) {
      _remainingCycles = 0;
      registers[0x64] = registers[0x65] = 0;
      interrupt();
    }
  }
}
