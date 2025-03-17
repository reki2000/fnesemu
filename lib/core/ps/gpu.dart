import 'dart:typed_data';

import 'package:fnesemu/util/int.dart';
import 'package:fnesemu/util/uint8list.dart';

import '../../util/debug.dart';
import '../types.dart';
import 'bus.dart';

part 'gpu_renderer.dart';
part 'gpu0.dart';
part 'gpu1.dart';

class Gpu {
  int status = 0;
  int gp0 = 0;
  int gp1 = 0;
  final Bus bus;

  Gpu(this.bus);

  // rendering status
  int width = 320; //  256, 320, 368, 512, 640
  int height = 240; // 240p or 480i
  Uint32List buffer = Uint32List(320 * 240);

  ImageBuffer get imageBuffer =>
      ImageBuffer(width, height, buffer.buffer.asUint8List(),
          displayWidth_: 320);

  static const scanlinesInFrame = 240;

  int scanline = 0;

  // GP1 status register
  final cmd = List<int>.filled(16, 0);
  int cmdSize = 0;
  bool get cmdReady => cmdSize == 0;

  int textureMaskX = 0;
  int textureMaskY = 0;
  int textureOffsetX = 0;
  int textureOffsetY = 0;

  int drawingX1 = 0;
  int drawingY1 = 0;
  int drawingX2 = 0;
  int drawingY2 = 0;

  int drawingOffsetX = 0;
  int drawingOffsetY = 0;

  int bltSizeX = 0;
  int bltSizeY = 0;
  int bltPosX = 0;
  int bltPosY = 0;
  int bltFromX = 0;
  int bltFromY = 0;

  int readReg() {
    // debugLog("GPREAD: ${readValue.hex32}");
    final result = readValue;
    postRead();

    return result;
  }

  int readStat() {
    const alwaysOn = 0x18000000; // dma is available
    final result = status.setBit(26, cmdReady) | alwaysOn;
    // debugLog("GPSTAT: ${result.hex32}");
    return result;
  }

  // GP1 status register
  int startDisplayX = 0;
  int startDisplayY = 0;

  int displayMode = 0;
  bool get isH480 => displayMode.bit2;
  bool get isPal => displayMode.bit3;
  bool get isRgb24 => displayMode.bit4;
  bool get isInterlaced => displayMode.bit5;

  final frameBuffer = Uint8List(512 * 2048);

  int readValue = 0;

  writeFrameBuffer32(int x, int y, int u32) {
    debugLog("writeFrameBuffer($x, $y, ${u32.hex32})");
    if (x < drawingX1 || x >= drawingX2 || y < drawingY1 || y >= drawingY2) {
      return;
    }
    final offset = y * 2048 + x * 2;
    frameBuffer.setUInt32LE(offset, u32);
  }

  int readFrameBuffer32(int x, int y) {
    final offset = y * 2048 + x * 2;
    return frameBuffer.getUInt32LE(offset);
  }

  int getTexureColor(int u, int v, int clut) {
    final textureBaseX = status << 6 & 0x3c0;
    final textureBaseY = status << 8 & 0x100;
    final base = textureBaseX + (textureBaseY + v.mask8) * 2048;

    final clutMode = status >> 7 & 3;
    if (clutMode == 2) {
      return frameBuffer.getUInt16LE(base + u.mask8).mask24;
    }

    final clutBase = (clut >> 6 & Gpu0.yMask) * 2048 + clut << 4 & 0x1f0;
    final clutIndex = switch (clutMode) {
      1 => (u.bit0
          ? frameBuffer[base + u.mask8 ~/ 2]
          : frameBuffer[base + u.mask8 ~/ 2 + 1]),
      0 => switch (u & 3) {
          0 => frameBuffer.getUInt16LE(base + u.mask8 ~/ 4) >> 4,
          1 => frameBuffer.getUInt16LE(base + u.mask8 ~/ 4) & 0x0f,
          2 => frameBuffer.getUInt16LE(base + u.mask8 ~/ 4 + 1) >> 4,
          3 => frameBuffer.getUInt16LE(base + u.mask8 ~/ 4 + 1) & 0x0f,
          _ => throw "unreachable",
        },
      _ => 0,
    };

    return frameBuffer.getUInt16LE(clutBase + clutIndex * 2).mask24;
  }

  clut256(int index) {
    final offset = status << 9 & 0x7e00;
    return frameBuffer.getUInt16LE(offset + index * 2);
  }

  clut16(int index) {
    final offset = status << 9 & 0x7e00;
    return frameBuffer.getUInt16LE(offset + index * 2);
  }

  pset24(int x, int y, int c24) {
    if (status.bit9) {
      // dithering
      const dither = [
        [0, 8, 2, 10],
        [12, 4, 14, 6],
        [3, 11, 1, 9],
        [15, 7, 13, 5]
      ];
      final d = dither[y & 3][x & 3];
      final r = c24 >> 16 & 0xff;
      final g = c24 >> 8 & 0xff;
      final b = c24 & 0xff;
      final r2 = r + d;
      final g2 = g + d;
      final b2 = b + d;
      c24 = r2 << 16 | g2 << 8 | b2;
    }
    // argb24 -> 0 bbbbb ggggg rrrrr
    final c16 = c24 >> 3 & 0x1f | c24 >> 6 & 0x3e0 | c24 >> 9 & 0x7c00;
    pset16(x, y, c16);
  }

  pset16(int x, int y, int c16) {
    x += drawingOffsetX;
    y += drawingOffsetY;

    if (x < drawingX1 || x >= drawingX2 || y < drawingY1 || y >= drawingY2) {
      return;
    }
    final old = frameBuffer.getUInt16LE(y * 2048 + x * 2);

    if (status.bit12 && old.bit15) {
      return;
    }

    frameBuffer.setUInt16LE(
        y * 2048 + x * 2, c16 | (status.bit13 ? (1 << 15) : 0));
  }

  String dump() =>
      "GPU: ${status.hex32} ${width}x$height $startDisplayX,$startDisplayY";
}
