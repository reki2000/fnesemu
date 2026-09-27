import 'dart:typed_data';

import '../types.dart';

/// Minimal uncached N64 bus. DMA completes synchronously; no TLB or RCP.
class N64Bus {
  final ram = Uint8List(0x800000);
  final sp = Uint8List(0x2000);
  Uint8List rom = Uint8List(0);
  final vi = Uint32List(14);
  final pi = Uint32List(13);
  int scanline = 0;

  int physical(int address) {
    final a = address & 0xffffffff;
    if (a >= 0x80000000 && a < 0xc0000000) return a & 0x1fffffff;
    if (a < 0x20000000) return a; // Also permits physical debugger access.
    throw UnsupportedError('N64 TLB address 0x${a.toRadixString(16)}');
  }

  int read8(int address) {
    final a = physical(address);
    if (a < ram.length) return ram[a];
    if (a >= 0x04000000 && a < 0x04002000) return sp[a - 0x04000000];
    if (a >= 0x10000000 && a - 0x10000000 < rom.length)
      return rom[a - 0x10000000];
    if (a >= 0x04400000 && a < 0x04400038) {
      final index = (a - 0x04400000) ~/ 4;
      final value = index == 4 ? scanline * 2 : vi[index];
      return (value >> ((3 - (a & 3)) * 8)) & 255;
    }
    if (a >= 0x04600000 && a < 0x04600034) {
      return (pi[(a - 0x04600000) ~/ 4] >> ((3 - (a & 3)) * 8)) & 255;
    }
    throw UnsupportedError('N64 bus read 0x${a.toRadixString(16)}');
  }

  int read(int address, int size) {
    var value = 0;
    for (var i = 0; i < size; i++) {
      value = (value << 8) | read8(address + i);
    }
    return value;
  }

  void write8(int address, int value) {
    final a = physical(address);
    if (a < ram.length) {
      ram[a] = value;
      return;
    }
    if (a >= 0x04000000 && a < 0x04002000) {
      sp[a - 0x04000000] = value;
      return;
    }
    throw UnsupportedError('N64 bus byte write 0x${a.toRadixString(16)}');
  }

  void write(int address, int value, int size) {
    final a = physical(address);
    if (size == 4 && a % 4 == 0) {
      if (a >= 0x04400000 && a < 0x04400038) {
        vi[(a - 0x04400000) ~/ 4] = value;
        return;
      }
      if (a >= 0x04600000 && a < 0x04600034) {
        final index = (a - 0x04600000) ~/ 4;
        if (index == 4) {
          pi[4] = 0;
          return;
        }
        pi[index] = value;
        if (index == 2 || index == 3) {
          final length = (value & 0xffffff) + 1;
          final dram = pi[0] & 0xffffff;
          final cart = pi[1] & 0x1fffffff;
          if (index == 2) throw UnsupportedError('N64 PI DMA to cartridge');
          if (dram + length > ram.length ||
              cart < 0x10000000 ||
              cart - 0x10000000 + length > rom.length) {
            throw StateError('N64 PI DMA outside RAM/ROM');
          }
          ram.setRange(dram, dram + length, rom, cart - 0x10000000);
          pi[0] = dram + length;
          pi[1] += length;
        }
        return;
      }
    }
    for (var i = 0; i < size; i++) {
      write8(address + i, value >> ((size - i - 1) * 8));
    }
  }

  void reset() {
    ram.fillRange(0, ram.length, 0);
    sp.fillRange(0, sp.length, 0);
    vi.fillRange(0, vi.length, 0);
    pi.fillRange(0, pi.length, 0);
    scanline = 0;
  }

  /// VI raw framebuffer scanout, without filtering or interlacing.
  ImageBuffer image() {
    final mode = vi[0] & 3;
    final stride = vi[2] & 0xfff;
    final hStart = (vi[9] >> 16) & 0x3ff;
    final hEnd = vi[9] & 0x3ff;
    final vStart = (vi[10] >> 16) & 0x3ff;
    final vEnd = vi[10] & 0x3ff;
    final width = ((hEnd - hStart) * (vi[12] & 0xfff)) ~/ 1024;
    final height = ((vEnd - vStart) * (vi[13] & 0xfff)) ~/ 2048;
    if (mode < 2 ||
        stride == 0 ||
        width <= 0 ||
        height <= 0 ||
        width > 640 ||
        height > 576) {
      return ImageBuffer(320, 240, Uint8List(320 * 240 * 4));
    }
    final output = Uint8List(width * height * 4);
    final origin = vi[1] & 0xffffff;
    final size = mode == 2 ? 2 : 4;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final source = origin + (y * stride + x) * size;
        final target = (y * width + x) * 4;
        if (x >= stride || source + size > ram.length) continue;
        if (size == 2) {
          final color = (ram[source] << 8) | ram[source + 1];
          for (var c = 0; c < 3; c++) {
            final v = (color >> (11 - c * 5)) & 31;
            output[target + c] = (v << 3) | (v >> 2);
          }
        } else {
          output.setRange(target, target + 3, ram, source);
        }
        output[target + 3] = 255;
      }
    }
    return ImageBuffer(width, height, output);
  }
}
