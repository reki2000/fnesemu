import 'dart:typed_data';
import '../../../util/int.dart';

/// Stamp-map coordinate conversion into the VDP's column-major cell format.
class CdGraphics {
  final Uint8List ram, registers;
  final void Function() interrupt;
  CdGraphics(this.ram, this.registers, this.interrupt);
  int _remainingCycles = 0;
  bool get busy => _remainingCycles > 0;
  int _reg(int offset) => registers[offset].shl8 | registers[offset + 1];
  int _word(int address) =>
      ram[address & 0x3ffff].shl8 | ram[(address + 1) & 0x3ffff];
  void reset() => _remainingCycles = 0;

  void start(int priority) {
    if (busy) return;
    final flags = _reg(0x58);
    final stampSize = flags.bit1 ? 32 : 16;
    final mapSize = flags.bit2 ? 4096 : 256;
    final mapMask = mapSize - 1;
    final mapWidth = mapSize ~/ stampSize;
    final mapBytes = mapWidth * mapWidth * 2;
    final mapBase = _reg(0x5a).shl2 & ~(mapBytes - 1);
    final imageBase = _reg(0x5e).shl2 & 0x3ffe0;
    final verticalCells = _reg(0x5c).mask5 + 1;
    final offset = _reg(0x60);
    final width = _reg(0x62).mask9;
    final height = _reg(0x64).mask8;
    final traceBase = _reg(0x66).shl2 & 0x3fff8;
    for (int line = 0; line < height; line++) {
      final trace = traceBase + line * 8;
      // Start coordinates have three fractional bits; deltas have eleven.
      int x = _word(trace).rel16.shl8;
      int y = _word(trace + 2).rel16.shl8;
      final dx = _word(trace + 4).rel16;
      final dy = _word(trace + 6).rel16;
      for (int pixel = 0; pixel < width; pixel++, x += dx, y += dy) {
        int sx = x.shr11, sy = y.shr11, color = 0;
        if (flags.bit0 ||
            (sx >= 0 && sy >= 0 && sx < mapSize && sy < mapSize)) {
          sx &= mapMask;
          sy &= mapMask;
          final entry = _word(
              mapBase + ((sy ~/ stampSize) * mapWidth + sx ~/ stampSize) * 2);
          final stamp = entry.mask11 & (stampSize == 32 ? ~3 : ~0);
          if (stamp != 0) {
            int px = sx & (stampSize - 1), py = sy & (stampSize - 1);
            if (entry.bit15) px = stampSize - 1 - px;
            // after the flip: bit14 turns the stamp by 180 degrees, then
            // bit13 by 90 degrees (column <- inverted row, row <- column)
            switch (entry.shr13.mask2) {
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
                (px.shr3 * stampSize.shr3 + py.shr3) * 32 +
                py.mask3 * 4 +
                px.mask3.shr1;
            color = (ram[source & 0x3ffff] >> (px.isEven ? 4 : 0)).mask4;
          }
        }
        final ix = pixel + offset.mask3, iy = line + offset.shr3.mask3;
        final destination = (imageBase +
                (ix.shr3 * verticalCells + iy.shr3) * 32 +
                iy.mask3 * 4 +
                ix.mask3.shr1) &
            0x3ffff;
        final shift = ix.isEven ? 4 : 0;
        final old = (ram[destination] >> shift).mask4;
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
